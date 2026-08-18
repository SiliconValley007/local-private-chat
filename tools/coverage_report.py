#!/usr/bin/env python3
"""Summarize lcov coverage for Flutter tests."""
from __future__ import annotations

import sys
from pathlib import Path


def main() -> int:
    lcov = Path(sys.argv[1] if len(sys.argv) > 1 else "coverage/lcov.info")
    if not lcov.exists():
        print(f"No coverage file at {lcov}")
        return 1

    total_lf = total_lh = 0
    files: dict[str, dict[str, int]] = {}
    cur: str | None = None

    for line in lcov.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("SF:"):
            cur = line[3:].strip().replace("\\", "/")
            files[cur] = {"lf": 0, "lh": 0}
        elif cur and line.startswith("LF:"):
            n = int(line[3:])
            files[cur]["lf"] += n
            total_lf += n
        elif cur and line.startswith("LH:"):
            n = int(line[3:])
            files[cur]["lh"] += n
            total_lh += n
        elif line.strip() == "end_of_record":
            cur = None

    pct = 100 * total_lh / total_lf if total_lf else 0.0
    print(f"Total line coverage: {total_lh}/{total_lf} ({pct:.2f}%)")

    keywords = (
        "nudge",
        "doodle",
        "message_merge",
        "message_sync",
        "sync",
    )
    print("\nNew/pure logic modules:")
    for path, data in sorted(files.items()):
        if any(k in path.lower() for k in keywords):
            lf, lh = data["lf"], data["lh"]
            fpct = 100 * lh / lf if lf else 0.0
            name = path.rsplit("/", 1)[-1]
            print(f"  {name}: {lh}/{lf} ({fpct:.1f}%)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
