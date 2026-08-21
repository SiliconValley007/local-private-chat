"""Exercise the frozen Windows server exactly as a release user will.

The verifier copies the EXE to a clean folder, confirms it is a console
application, starts it twice, probes HTTP, checks request logging and durable
data placement, then exercises both bundled operator subcommands.
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path


def _console_subsystem(executable: Path) -> int:
    """Return the PE subsystem (3 is Windows console, 2 is windowed)."""
    with executable.open("rb") as stream:
        stream.seek(0x3C)
        pe_offset = struct.unpack("<I", stream.read(4))[0]
        # PE signature + COFF header = 24 bytes; Subsystem is offset 68 in the
        # PE32/PE32+ optional header.
        stream.seek(pe_offset + 24 + 68)
        return struct.unpack("<H", stream.read(2))[0]


#: A one-file EXE unpacks modules from its own archive on demand, so an antivirus
#: scanner that still holds the freshly written binary shows up as a startup crash
#: rather than a copy error. Both spellings mean "try again", not "broken build".
_TRANSIENT_STARTUP_SIGNS = ("failed to open archive", "permission denied")

#: Time given to a real-time scanner to let go of a newly written 40 MB binary.
_SETTLE_SECONDS = 3


def _is_readable(path: Path) -> bool:
    """True when the file can actually be opened and read right now."""
    try:
        with path.open("rb") as stream:
            stream.seek(-1, os.SEEK_END)
            return bool(stream.read(1))
    except OSError:
        return False


def _copy_exe(source: Path, target: Path) -> None:
    """Place a complete, readable copy of the EXE in the scratch folder."""
    expected = source.stat().st_size
    for attempt in range(5):
        if attempt:
            time.sleep(_SETTLE_SECONDS)
        try:
            shutil.copy2(source, target)
        except OSError:
            continue
        if target.stat().st_size == expected and _is_readable(target):
            time.sleep(_SETTLE_SECONDS)
            return
    raise AssertionError(f"Could not obtain an intact copy of {source}")


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def _get(url: str, *, timeout: float = 2.0) -> tuple[int, bytes]:
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return response.status, response.read()


def _wait_for_health(process: subprocess.Popen[str], port: int) -> dict:
    deadline = time.monotonic() + 120
    url = f"http://127.0.0.1:{port}/api/health"
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("Packaged server exited during startup")
        try:
            status, body = _get(url)
            if status == 200:
                return json.loads(body)
        except (OSError, ValueError):  # URLError and HTTPError are OSError.
            time.sleep(0.25)
    raise TimeoutError(f"Packaged server did not answer {url} within 120 seconds")


def _shutdown(process: subprocess.Popen[str]) -> str:
    """Stop the frozen server, its children, and return the console output.

    A one-file PyInstaller EXE runs the real Python interpreter in a child
    process. Signalling only the bootloader leaves that child holding the
    database open, so the whole tree has to go while the parent is still alive
    and its children are still enumerable.
    """
    if process.poll() is None:
        subprocess.run(
            ["taskkill", "/T", "/F", "/PID", str(process.pid)],
            capture_output=True,
            check=False,
            timeout=30,
        )
    try:
        output, _ = process.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        process.kill()
        output, _ = process.communicate(timeout=10)
    return output


def _remove_tree(folder: Path) -> None:
    """Delete the scratch folder, allowing Windows a moment to release handles."""
    for _ in range(10):
        shutil.rmtree(folder, ignore_errors=True)
        if not folder.exists():
            return
        time.sleep(0.5)


def _run_server(executable: Path, folder: Path, env: dict[str, str]) -> str:
    process = subprocess.Popen(
        [str(executable)],
        cwd=folder,
        env=env,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0),
    )
    failure: Exception | None = None
    try:
        port = int(env["LOCALCHAT_PORT"])
        health = _wait_for_health(process, port)
        if health != {"ok": True, "service": "local-chat"}:
            raise AssertionError(f"Unexpected health response: {health!r}")

        status, docs = _get(f"http://127.0.0.1:{port}/docs", timeout=5)
        if status != 200 or b"swagger" not in docs.lower():
            raise AssertionError("Packaged /docs did not return Swagger UI")
    except Exception as exc:  # Preserve console output for startup diagnostics.
        failure = exc
    finally:
        output = _shutdown(process)

    if failure is not None:
        raise RuntimeError(f"{failure}\nCONSOLE:\n{output}") from failure
    if "Local Chat is starting" not in output:
        raise AssertionError(f"Startup banner missing from console:\n{output}")
    if "/api/health" not in output or "200" not in output:
        raise AssertionError(f"Access log missing health request:\n{output}")
    # A Windows host is unreachable from any phone until inbound TCP is allowed,
    # so the packaged server has to say which of the two states it is in.
    if "windows firewall" not in output.lower():
        raise AssertionError(f"Console never reported firewall state:\n{output}")
    return output


def _start_packaged_server(
    source: Path,
    test_exe: Path,
    folder: Path,
    env: dict[str, str],
) -> str:
    """Run the packaged server, retrying a launch that died in the bootloader."""
    attempts = 3
    for attempt in range(1, attempts + 1):
        try:
            return _run_server(test_exe, folder, env)
        except RuntimeError as exc:
            message = str(exc).lower()
            transient = any(sign in message for sign in _TRANSIENT_STARTUP_SIGNS)
            if not transient or attempt == attempts:
                raise
        # Give Windows time to release the new binary, then start from a fresh copy.
        time.sleep(5)
        _copy_exe(source, test_exe)
        env["LOCALCHAT_PORT"] = str(_free_port())
    raise AssertionError("Packaged server never started")


def _run_tool(
    executable: Path,
    folder: Path,
    env: dict[str, str],
    *arguments: str,
) -> str:
    result = subprocess.run(
        [str(executable), *arguments],
        cwd=folder,
        env=env,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        timeout=120,
        check=False,
    )
    output = result.stdout + result.stderr
    if result.returncode != 0:
        raise AssertionError(
            f"{' '.join(arguments)} exited {result.returncode}:\n{output}"
        )
    return output


def verify(executable: Path) -> None:
    executable = executable.resolve()
    if not executable.is_file():
        raise FileNotFoundError(executable)
    if _console_subsystem(executable) != 3:
        raise AssertionError("LocalChatServer.exe is not a Windows console executable")

    folder = Path(tempfile.mkdtemp(prefix="localchat-package-"))
    try:
        test_exe = folder / "LocalChatServer.exe"
        _copy_exe(executable, test_exe)

        env = os.environ.copy()
        env.update(
            {
                "LOCALCHAT_HOST": "127.0.0.1",
                "LOCALCHAT_PORT": str(_free_port()),
                "LOCALCHAT_ACCESS_LOG": "1",
                # Detect and report the firewall, but never raise a UAC prompt in
                # the middle of a build.
                "LOCALCHAT_FIREWALL_AUTOFIX": "0",
                "PYTHONUNBUFFERED": "1",
            }
        )

        _start_packaged_server(executable, test_exe, folder, env)
        database = folder / "data" / "chat.db"
        secret = folder / "jwt_secret.txt"
        if not database.is_file() or not secret.is_file():
            raise AssertionError(
                "Frozen data was not created beside the EXE "
                f"(database={database.is_file()}, secret={secret.is_file()})"
            )
        first_secret = secret.read_text(encoding="utf-8")

        # A second real launch proves the one-file extraction and durable files
        # survive restart rather than living in PyInstaller's temporary folder.
        env["LOCALCHAT_PORT"] = str(_free_port())
        _run_server(test_exe, folder, env)
        if secret.read_text(encoding="utf-8") != first_secret:
            raise AssertionError("JWT secret changed across packaged-server restart")

        reset_output = _run_tool(test_exe, folder, env, "reset-password")
        if "No users in the database yet." not in reset_output:
            raise AssertionError(f"reset-password subcommand failed:\n{reset_output}")

        admin_output = _run_tool(test_exe, folder, env, "set-admin")
        if "Effective admin" not in admin_output:
            raise AssertionError(f"set-admin subcommand failed:\n{admin_output}")

        firewall_output = _run_tool(test_exe, folder, env, "allow-firewall")
        if "netsh advfirewall firewall add rule" not in firewall_output:
            raise AssertionError(
                f"allow-firewall subcommand failed:\n{firewall_output}"
            )
    finally:
        _remove_tree(folder)

    print("Windows package verified: console, startup, HTTP, access log, restart, data, tools")


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: python tools/verify_windows_package.py <LocalChatServer.exe>")
        return 2
    try:
        verify(Path(sys.argv[1]))
    except Exception as failure:  # pylint: disable=broad-exception-caught
        print(f"Windows package verification failed: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
