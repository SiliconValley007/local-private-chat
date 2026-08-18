"""Start Local Chat server for LAN and/or Tailscale access."""

from __future__ import annotations

import shutil
import socket
import struct
import subprocess
import sys

import uvicorn
from app.config import ACCESS_LOG, HOST, LOW_MEMORY, MAX_CONCURRENCY, PORT

# Linux/Android ioctl for "give me this interface's IPv4 address".
_SIOCGIFADDR = 0x8915


def is_tailscale_ip(addr: str) -> bool:
    """Return True if addr is in Tailscale's CGNAT range 100.64.0.0/10."""
    parts = addr.split(".")
    if len(parts) != 4 or parts[0] != "100":
        return False
    try:
        second = int(parts[1])
    except ValueError:
        return False
    return 64 <= second <= 127


def unique_non_loopback(candidates: list[str]) -> list[str]:
    """Deduplicate IPv4 strings and drop loopback."""
    seen: set[str] = set()
    ips: list[str] = []
    for addr in candidates:
        if not addr or addr.startswith("127.") or addr in seen:
            continue
        seen.add(addr)
        ips.append(addr)
    return ips


def _ips_from_hostname() -> list[str]:
    """Collect IPv4 addresses associated with this machine's hostname."""
    candidates: list[str] = []
    hostname = socket.gethostname()
    try:
        _, _, addrs = socket.gethostbyname_ex(hostname)
        candidates.extend(addrs)
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(hostname, None, socket.AF_INET):
            candidates.append(info[4][0])
    except OSError:
        pass
    return candidates


def _ips_from_tailscale_cli() -> list[str]:
    """Ask the Tailscale CLI for this node's IPv4, if installed."""
    binary = shutil.which("tailscale")
    if not binary:
        return []
    try:
        completed = subprocess.run(
            [binary, "ip", "-4"],
            check=False,
            capture_output=True,
            text=True,
            timeout=3,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    if completed.returncode != 0:
        return []
    return [line.strip() for line in completed.stdout.splitlines() if line.strip()]


def _ips_from_interfaces() -> list[str]:
    """Read IPv4 addresses straight off the network interfaces (Linux/Android).

    This is the only method that sees Tailscale's ``tun`` interface on Android,
    where there is no ``tailscale`` CLI and the hostname resolves to loopback.
    """
    try:
        import fcntl  # pylint: disable=import-outside-toplevel  # Unix only
    except ImportError:
        return []
    try:
        names = [name for _, name in socket.if_nameindex()]
    except (AttributeError, OSError):
        return []

    found: list[str] = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        for name in names:
            try:
                packed = fcntl.ioctl(
                    probe.fileno(),
                    _SIOCGIFADDR,
                    struct.pack("256s", name.encode()[:15]),
                )
            except OSError:
                continue  # Interface has no IPv4 address (v6-only or down).
            found.append(socket.inet_ntoa(packed[20:24]))
    return found


def _ips_from_route_probe() -> list[str]:
    """Ask the OS which local address it would use to reach given targets.

    ``connect`` on UDP sends nothing; it just resolves the route. Probing a
    Tailscale address reveals our Tailscale IP even when the interface list is
    unreadable, and probing a public address reveals the LAN IP.
    """
    found: list[str] = []
    for target in ("100.100.100.100", "8.8.8.8"):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
                probe.settimeout(0.5)
                probe.connect((target, 53))
                found.append(probe.getsockname()[0])
        except OSError:
            continue
    return found


def discover_ipv4_addresses() -> list[str]:
    """Best-effort list of this host's non-loopback IPv4 addresses."""
    candidates: list[str] = []
    candidates.extend(_ips_from_interfaces())
    candidates.extend(_ips_from_route_probe())
    candidates.extend(_ips_from_hostname())
    candidates.extend(_ips_from_tailscale_cli())
    return unique_non_loopback(candidates)


def _rank_for_clients(addr: str) -> tuple[int, str]:
    """Prefer Tailscale, then typical home/LAN ranges, for the Flutter URL."""
    if is_tailscale_ip(addr):
        return (0, addr)
    if addr.startswith("192.168."):
        return (1, addr)
    if addr.startswith("10."):
        return (2, addr)
    if addr.startswith("172."):
        return (3, addr)
    return (4, addr)


def preferred_client_ip(ips: list[str] | None = None) -> str:
    """Pick the best IP for phones to type into the Flutter app."""
    addresses = ips if ips is not None else discover_ipv4_addresses()
    if not addresses:
        return "<tailscale-or-lan-ip>"
    return min(addresses, key=_rank_for_clients)


def tailscale_ips(ips: list[str] | None = None) -> list[str]:
    """Return Tailscale CGNAT addresses from the discovered set."""
    addresses = ips if ips is not None else discover_ipv4_addresses()
    return [addr for addr in addresses if is_tailscale_ip(addr)]


def lan_ips(ips: list[str] | None = None) -> list[str]:
    """Return non-Tailscale private-ish addresses (LAN / other adapters)."""
    addresses = ips if ips is not None else discover_ipv4_addresses()
    return [addr for addr in addresses if not is_tailscale_ip(addr)]


# Backwards-compatible name used by older docs/tests.
def local_ip() -> str:
    """Return preferred client-facing IPv4 (Tailscale first when available)."""
    return preferred_client_ip()


def _harden_console() -> None:
    """Never let an unprintable character stop the server from starting.

    A Windows console on a legacy code page (cp1252) cannot encode characters
    such as an em dash, and the resulting UnicodeEncodeError killed the process
    before uvicorn ever ran. The banner is plain ASCII for that reason; this is
    the belt to that braces.
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="replace")
        except (AttributeError, OSError, ValueError):
            pass


def _print_banner() -> None:
    addresses = discover_ipv4_addresses()
    primary = preferred_client_ip(addresses)
    ts = tailscale_ips(addresses)
    lan = lan_ips(addresses)

    print("=" * 60)
    print(" Local Chat is starting")
    print(f" Listening on {HOST}:{PORT} (all interfaces - LAN + Tailscale)")
    print(f" API docs on this device: http://127.0.0.1:{PORT}/docs")
    print()
    if ts:
        print(" Tailscale (use this when phones are not on the same Wi-Fi):")
        for addr in ts:
            print(f"   http://{addr}:{PORT}")
            print(f"   ws://{addr}:{PORT}/ws?token=<jwt>")
    else:
        print(" Tailscale IP not detected on this device.")
        print("   The server still accepts Tailscale traffic - this is only about")
        print("   printing the address, and Android hides it from Termux.")
        print("   Open the Tailscale app, confirm it says Connected, and use the")
        print(f"   100.x.x.x address it shows: http://100.x.x.x:{PORT}")
    if lan:
        print(" LAN / other adapters (same Wi-Fi only):")
        for addr in lan:
            print(f"   http://{addr}:{PORT}")
    print()
    print(" Flutter app -> Set server URL to:")
    print(f"   http://{primary}:{PORT}")
    print(" Close this window (or press CTRL+C) to stop.")
    print("=" * 60)


def port_is_free(host: str, port: int) -> bool:
    """True when the server could bind host:port right now."""
    bind_host = "" if host == "0.0.0.0" else host
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        try:
            probe.bind((bind_host, port))
        except OSError:
            return False
    return True


def _print_port_in_use() -> None:
    print()
    print(f"ERROR: Port {PORT} is already in use.")
    print("Another Local Chat (or other app) is still running.")
    print("Fix: close that process, or find it with:")
    print(f"  netstat -ano | findstr :{PORT}")
    print(f"  (Termux/Linux: lsof -i :{PORT}  or  ss -ltnp | grep {PORT})")
    print("Then stop that process and try again.")


if __name__ == "__main__":
    _harden_console()
    # Checked up front: uvicorn swallows the bind error and logs a one-line
    # traceback of its own, so this advice never reached the screen.
    if not port_is_free(HOST, PORT):
        _print_port_in_use()
        raise SystemExit(1)
    _print_banner()
    try:
        # Phone servers keep logging quiet and concurrency bounded so a handful
        # of uploads cannot push Termux into the Android low-memory killer.
        uvicorn_kwargs: dict = {
            "host": HOST,
            "port": PORT,
            "reload": False,
        }
        if LOW_MEMORY:
            uvicorn_kwargs["access_log"] = ACCESS_LOG
            uvicorn_kwargs["log_level"] = "info" if ACCESS_LOG else "warning"
            uvicorn_kwargs["timeout_keep_alive"] = 5
            if MAX_CONCURRENCY > 0:
                uvicorn_kwargs["limit_concurrency"] = MAX_CONCURRENCY
        uvicorn.run("app.main:app", **uvicorn_kwargs)
    except OSError as exc:
        if getattr(exc, "winerror", None) == 10048 or getattr(exc, "errno", None) in (98, 10048):
            _print_port_in_use()
            raise SystemExit(1) from exc
        raise
