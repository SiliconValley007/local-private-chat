"""Windows inbound-firewall support for the Local Chat server.

An Android/Termux host has no firewall of its own, so a phone can talk to it the
moment Tailscale is up. Windows blocks unsolicited inbound connections by
default, and that failure is deeply misleading: the server prints a healthy
banner, ``http://127.0.0.1:8000/docs`` works on the host, and every phone still
says "Chat server is not running", because the packets are dropped before
uvicorn ever sees them.

This module recognises that state and offers to install a single narrow rule.
The OS calls live behind thin wrappers so the argument building and output
parsing stay testable on any platform.
"""

from __future__ import annotations

import ctypes
import os
import subprocess
import sys
import threading

#: Where a Local Chat client can legitimately come from: Tailscale's CGNAT range
#: (100.64.0.0/10) and the host's own subnet. A phone on mobile data arrives over
#: Tailscale, so the rule never has to accept the public internet.
ALLOWED_REMOTE_ADDRESSES = "100.64.0.0/10,LocalSubnet"

_NETSH_TIMEOUT_SECONDS = 20


def is_windows() -> bool:
    return os.name == "nt"


def rule_name(port: int) -> str:
    """Name the rule after its port so a second port gets its own rule."""
    return f"Local Chat Server (TCP {port})"


def show_rule_arguments(port: int) -> list[str]:
    return [
        "advfirewall",
        "firewall",
        "show",
        "rule",
        f"name={rule_name(port)}",
    ]


def delete_rule_arguments(port: int) -> list[str]:
    return [
        "advfirewall",
        "firewall",
        "delete",
        "rule",
        f"name={rule_name(port)}",
    ]


def add_rule_arguments(port: int) -> list[str]:
    return [
        "advfirewall",
        "firewall",
        "add",
        "rule",
        f"name={rule_name(port)}",
        "dir=in",
        "action=allow",
        "protocol=TCP",
        f"localport={port}",
        "profile=any",
        f"remoteip={ALLOWED_REMOTE_ADDRESSES}",
        "enable=yes",
        "description=Lets Local Chat clients reach this server over Tailscale "
        "or the local network.",
    ]


def netsh_command_text(port: int) -> str:
    """The exact command an operator (or a deployment script) can run by hand."""
    parts = [
        f'"{argument}"' if " " in argument else argument
        for argument in add_rule_arguments(port)
    ]
    return "netsh " + " ".join(parts)


def rule_is_present(returncode: int, output: str) -> bool:
    """Read ``netsh show rule`` for a usable rule.

    netsh exits non-zero when no rule carries the name, which is the one signal
    that means the same thing on a localised Windows. A rule that exists but has
    been switched off is treated as missing, since it lets nothing through.
    """
    if returncode != 0:
        return False
    for line in output.splitlines():
        label, separator, value = line.partition(":")
        if separator and label.strip().lower() == "enabled":
            return value.strip().lower() in {"yes", "true"}
    return True


def is_elevated() -> bool:
    """True when this process can change firewall rules without a UAC prompt."""
    if not is_windows():
        return False
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())  # type: ignore[attr-defined]
    except (AttributeError, OSError):
        return False


def _netsh(arguments: list[str]) -> tuple[int, str]:
    """Run netsh, returning its exit code and combined output.

    A missing or unusable netsh returns -1 so callers can stay quiet rather than
    accuse a working firewall of blocking the server.
    """
    try:
        done = subprocess.run(
            ["netsh", *arguments],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=_NETSH_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return -1, ""
    return done.returncode, (done.stdout or "") + (done.stderr or "")


def inbound_rule_exists(port: int) -> bool | None:
    """True/False for the rule, or None when the firewall cannot be queried."""
    returncode, output = _netsh(show_rule_arguments(port))
    if returncode == -1:
        return None
    return rule_is_present(returncode, output)


def install_rule(port: int) -> bool:
    """Create the inbound rule. Requires an already-elevated process."""
    # Replacing any same-named rule keeps this idempotent and repairs a rule that
    # was disabled or narrowed by hand.
    _netsh(delete_rule_arguments(port))
    returncode, _ = _netsh(add_rule_arguments(port))
    return returncode == 0


def self_command() -> list[str]:
    """The command that re-runs this server: frozen EXE or python + script."""
    if getattr(sys, "frozen", False):
        return [sys.executable]
    return [sys.executable, os.path.join(os.path.dirname(__file__), "run.py")]


def repair_command_text() -> str:
    """What to type to install the rule, as the operator would type it."""
    if getattr(sys, "frozen", False):
        return f"{os.path.basename(sys.executable)} allow-firewall"
    return "python run.py allow-firewall"


def elevate_and_install(port: int) -> bool:
    """Re-run this program elevated to install the rule, and wait for it.

    PowerShell's ``-Verb RunAs`` raises the UAC prompt, and ``-Wait`` means the
    rule is in place before the answer is reported.
    """
    command, *script = self_command()
    arguments = [*script, "allow-firewall", str(port)]
    quoted = ",".join(f"'{argument}'" for argument in arguments)
    try:
        subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                f"Start-Process -FilePath '{command}' "
                f"-ArgumentList {quoted} -Verb RunAs -Wait",
            ],
            capture_output=True,
            text=True,
            timeout=180,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return inbound_rule_exists(port) is True


def blocked_warning_lines(port: int, *, command: str) -> list[str]:
    """Explain the one failure that looks exactly like a dead server."""
    return [
        "",
        "-" * 60,
        f" WINDOWS FIREWALL IS BLOCKING INBOUND PORT {port}",
        " This server is running, but Windows drops connections from your",
        " phones before they arrive, so the app will say the server is not",
        " running even though Tailscale is connected on both devices.",
        "",
        f" Fix it once, as administrator:  {command}",
        f" (Allows TCP {port} from Tailscale and your local network only.)",
        "-" * 60,
    ]


def allowed_line(port: int) -> str:
    return f" Windows Firewall: inbound TCP {port} allowed for Tailscale and LAN."


def _truthy(value: str | None) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes", "on"}


def autofix_enabled() -> bool:
    """Whether startup may raise a UAC prompt to open the port itself."""
    return not _falsy(os.environ.get("LOCALCHAT_FIREWALL_AUTOFIX"))


def _falsy(value: str | None) -> bool:
    return (value or "").strip().lower() in {"0", "false", "no", "off"}


def _install_elevated_in_background(port: int) -> None:
    """Ask for elevation without making the server wait for the answer.

    Nothing about serving chat depends on the outcome, and a operator who steps
    away from a UAC dialog must still come back to a running server.
    """

    def worker() -> None:
        if elevate_and_install(port):
            print(f" Windows Firewall: inbound TCP {port} is now allowed.")
        else:
            print(
                " Windows Firewall was not changed. Run this once as "
                f"administrator: {repair_command_text()}"
            )

    threading.Thread(target=worker, name="firewall-allow", daemon=True).start()


def ensure_inbound_access(port: int) -> None:
    """Report the firewall state and, where possible, open the port.

    This never blocks: the server has to reach ``uvicorn.run`` whatever the
    firewall says.
    """
    if not is_windows() or _truthy(os.environ.get("LOCALCHAT_SKIP_FIREWALL_CHECK")):
        return

    present = inbound_rule_exists(port)
    if present:
        print(allowed_line(port))
        return
    for line in blocked_warning_lines(port, command=repair_command_text()):
        print(line)
    if present is None:
        return

    if is_elevated():
        if install_rule(port):
            print(f" Windows Firewall: inbound TCP {port} is now allowed.")
        else:
            print(" Windows Firewall was not changed. Add the rule manually.")
        return

    if not autofix_enabled():
        return
    print(" Asking Windows for permission to open it (approve the prompt)...")
    _install_elevated_in_background(port)


def main(argv: list[str]) -> int:
    """``allow-firewall [port]`` subcommand of the packaged server."""
    from app import config  # pylint: disable=import-outside-toplevel

    port = config.PORT
    if argv:
        try:
            port = int(argv[0])
        except ValueError:
            print(f"Not a port number: {argv[0]}")
            return 2

    if not is_windows():
        print("Nothing to do: this host has no Windows Firewall.")
        return 0

    if is_elevated():
        if install_rule(port):
            print(f"Allowed inbound TCP {port} for Tailscale and the local network.")
            return 0
        print("Could not add the firewall rule.")
        return 1

    if not autofix_enabled():
        print("Run this once from an administrator console:")
        print(f"  {netsh_command_text(port)}")
        return 0

    print("Asking Windows for administrator rights...")
    if elevate_and_install(port):
        print(f"Allowed inbound TCP {port} for Tailscale and the local network.")
        return 0
    print(
        "The rule was not added. Right-click the server EXE, choose "
        '"Run as administrator", and run it with: allow-firewall'
    )
    return 1
