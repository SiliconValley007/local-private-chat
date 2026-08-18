"""Facts about the machine hosting Local Chat.

The server usually runs on a spare Android phone under Termux, where it competes
with the OS for a little over a gigabyte of RAM and can be killed by the
low-memory killer or simply run out of battery. Surfacing those numbers in the
app is what lets someone notice trouble before the chat goes down.

Everything here is read straight from the kernel (``/proc``, ``/sys``) or from
Win32, so no third-party dependency is needed and each read costs a few hundred
bytes. Parsing is split into pure functions so the odd formats stay under test on
any OS. Every reader answers ``None`` rather than raising when a platform does
not expose the value.
"""

from __future__ import annotations

import ctypes
import os
import platform
import sys
import time
from pathlib import Path

TERMUX_FILES = "/data/data/com.termux/files"

# Recorded at import, which happens while the process is starting up.
_STARTED_MONOTONIC = time.monotonic()

# Phones disagree on the node name; the first readable one wins.
_BATTERY_DIRS = (
    "/sys/class/power_supply/battery",
    "/sys/class/power_supply/BAT0",
    "/sys/class/power_supply/BAT1",
)

_CHARGING_STATES = frozenset({"charging", "full"})


def detect_host_kind(
    *,
    sys_platform: str,
    prefix_env: str | None,
    android_root_env: str | None,
    termux_files_exists: bool,
) -> str:
    """Classify the host from cheap signals, without touching the disk.

    Termux is a Linux userland *inside* Android, so it reports ``linux`` and has
    to be told apart by its ``PREFIX`` or its private data directory.
    """

    if sys_platform.startswith("win"):
        return "windows"
    if sys_platform == "darwin":
        return "macos"
    if sys_platform.startswith("linux"):
        if (prefix_env and "com.termux" in prefix_env) or termux_files_exists:
            return "termux"
        if android_root_env:
            return "android"
        return "linux"
    return "unknown"


def host_kind() -> str:
    """[detect_host_kind] for the process actually running."""

    return detect_host_kind(
        sys_platform=sys.platform,
        prefix_env=os.environ.get("PREFIX"),
        android_root_env=os.environ.get("ANDROID_ROOT"),
        termux_files_exists=Path(TERMUX_FILES).is_dir(),
    )


def host_label(kind: str, *, machine: str, release: str) -> str:
    """Short line for the app, e.g. ``Termux on Android · aarch64``."""

    names = {
        "termux": "Termux on Android",
        "android": "Android",
        "windows": "Windows",
        "linux": "Linux",
        "macos": "macOS",
    }
    name = names.get(kind, "Unknown host")
    parts = [name]
    if kind == "windows" and release:
        parts.append(release)
    if machine:
        parts.append(machine)
    return " · ".join(parts)


def parse_meminfo(text: str) -> dict[str, int] | None:
    """Pull total and available RAM out of ``/proc/meminfo``.

    ``MemAvailable`` is the kernel's own estimate of what a new process could
    use; older kernels omit it, so free + buffers + cached stands in.
    """

    values: dict[str, int] = {}
    for line in text.splitlines():
        key, _, rest = line.partition(":")
        fields = rest.split()
        if not fields:
            continue
        try:
            amount = int(fields[0])
        except ValueError:
            continue
        # Every value of interest is reported in kB.
        values[key.strip()] = amount * 1024

    total = values.get("MemTotal")
    if not total:
        return None
    available = values.get("MemAvailable")
    if available is None:
        available = (
            values.get("MemFree", 0)
            + values.get("Buffers", 0)
            + values.get("Cached", 0)
        )
    return {
        "total_bytes": total,
        "available_bytes": min(available, total),
    }


def parse_vm_rss(text: str) -> int | None:
    """Resident size of this process from ``/proc/self/status``."""

    for line in text.splitlines():
        if not line.startswith("VmRSS:"):
            continue
        fields = line.split()
        if len(fields) < 2:
            return None
        try:
            return int(fields[1]) * 1024
        except ValueError:
            return None
    return None


def parse_uptime(text: str) -> float | None:
    """Seconds since boot from ``/proc/uptime``."""

    fields = text.split()
    if not fields:
        return None
    try:
        return round(float(fields[0]), 1)
    except ValueError:
        return None


def parse_battery(capacity: str | None, status: str | None) -> dict[str, object] | None:
    """Battery percentage and whether it is filling up.

    A phone that is serving chat while discharging is the failure worth warning
    about, so ``charging`` matters as much as the percentage.
    """

    if capacity is None:
        return None
    try:
        percent = int(capacity.strip())
    except ValueError:
        return None
    state = (status or "").strip().lower()
    return {
        "percent": max(0, min(100, percent)),
        "charging": state in _CHARGING_STATES,
        "status": state or "unknown",
    }


def _read_text(path: str | Path) -> str | None:
    """Read a small kernel file, tolerating every way it can be unavailable."""

    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except (OSError, ValueError):
        return None


class _MemoryStatusEx(ctypes.Structure):
    """Win32 ``MEMORYSTATUSEX``, the counterpart to ``/proc/meminfo``."""

    _fields_ = [
        ("dwLength", ctypes.c_ulong),
        ("dwMemoryLoad", ctypes.c_ulong),
        ("ullTotalPhys", ctypes.c_ulonglong),
        ("ullAvailPhys", ctypes.c_ulonglong),
        ("ullTotalPageFile", ctypes.c_ulonglong),
        ("ullAvailPageFile", ctypes.c_ulonglong),
        ("ullTotalVirtual", ctypes.c_ulonglong),
        ("ullAvailVirtual", ctypes.c_ulonglong),
        ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
    ]


def _windows_memory() -> dict[str, int] | None:
    try:
        status = _MemoryStatusEx()
        status.dwLength = ctypes.sizeof(_MemoryStatusEx)
        if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):
            return None
        return {
            "total_bytes": int(status.ullTotalPhys),
            "available_bytes": int(status.ullAvailPhys),
        }
    except (AttributeError, OSError):
        return None


class _ProcessMemoryCounters(ctypes.Structure):
    """Win32 ``PROCESS_MEMORY_COUNTERS`` — working set is the RSS analogue."""

    _fields_ = [
        ("cb", ctypes.c_ulong),
        ("PageFaultCount", ctypes.c_ulong),
        ("PeakWorkingSetSize", ctypes.c_size_t),
        ("WorkingSetSize", ctypes.c_size_t),
        ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
        ("QuotaPagedPoolUsage", ctypes.c_size_t),
        ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
        ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
        ("PagefileUsage", ctypes.c_size_t),
        ("PeakPagefileUsage", ctypes.c_size_t),
    ]


def _windows_process_bytes() -> int | None:
    try:
        counters = _ProcessMemoryCounters()
        counters.cb = ctypes.sizeof(_ProcessMemoryCounters)
        handle = ctypes.windll.kernel32.GetCurrentProcess()
        if not ctypes.windll.psapi.GetProcessMemoryInfo(
            handle, ctypes.byref(counters), counters.cb
        ):
            return None
        return int(counters.WorkingSetSize)
    except (AttributeError, OSError):
        return None


def read_memory() -> dict[str, int] | None:
    """Total and available RAM on the host, plus this process's footprint."""

    if sys.platform.startswith("win"):
        memory = _windows_memory()
        process_bytes = _windows_process_bytes()
    else:
        text = _read_text("/proc/meminfo")
        memory = parse_meminfo(text) if text else None
        status = _read_text("/proc/self/status")
        process_bytes = parse_vm_rss(status) if status else None

    if memory is None:
        return None
    if process_bytes is not None:
        memory = {**memory, "process_bytes": process_bytes}
    return memory


def read_battery() -> dict[str, object] | None:
    """Battery of the phone or laptop hosting the server, when exposed."""

    for directory in _BATTERY_DIRS:
        capacity = _read_text(f"{directory}/capacity")
        if capacity is None:
            continue
        battery = parse_battery(capacity, _read_text(f"{directory}/status"))
        if battery is not None:
            return battery
    return None


def host_uptime_seconds() -> float | None:
    """How long the host has been up, which Windows does not publish this way."""

    text = _read_text("/proc/uptime")
    return parse_uptime(text) if text else None


def process_uptime_seconds() -> float:
    """How long this server process has been serving requests."""

    return round(time.monotonic() - _STARTED_MONOTONIC, 1)


def describe_host() -> dict[str, object]:
    """Identity of the host: what it is, and what Python is running it."""

    kind = host_kind()
    return {
        "kind": kind,
        "label": host_label(
            kind,
            machine=platform.machine(),
            release=platform.release(),
        ),
        "python": platform.python_version(),
    }
