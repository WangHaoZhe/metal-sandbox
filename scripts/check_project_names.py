#!/usr/bin/env python3
"""Check hand-maintained paths; exclude build/OS metadata and required tool names."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
IGNORED = {".git", ".build", ".swiftpm", ".verification", "dist", "__pycache__", ".DS_Store"}
FIXED = {"Package.swift", "Package.resolved", "AGENTS.md", "README.md", "README_ZH.md", ".gitignore"}
FIXED_PATHS = {Path("frontend/resources/app_icon.icon/Assets")}


def invalid(directory):
    for path in sorted(directory.iterdir()):
        if path.name in IGNORED:
            continue
        if path.name not in FIXED and path.relative_to(ROOT) not in FIXED_PATHS and not re.fullmatch(r"[a-z0-9_]+(?:\.[a-z0-9_]+)*", path.name):
            yield path.relative_to(ROOT)
        if path.is_dir() and not path.is_symlink():
            yield from invalid(path)


if __name__ == "__main__":
    failures = list(invalid(ROOT))
    for path in failures:
        print("invalid name:", path)
    print("PASS: lowercase snake_case project paths" if not failures else "FAIL: naming convention")
    sys.exit(bool(failures))
