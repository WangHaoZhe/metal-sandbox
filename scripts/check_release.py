#!/usr/bin/env python3
"""Check release documentation, source syntax, names and optional CLI identity.

This is a static release check, NOT a security or runtime acceptance gate.
"""
import argparse
import ast
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote, urlsplit
from release_metadata import ROOT, release_version, bundle_build
from check_project_names import invalid
from check_frontend import check as check_frontend


def check(bin_dir=None):
    check_frontend()
    version = release_version()
    bundle_build()
    errors = ["invalid project name: " + str(p) for p in invalid(ROOT)]
    if version not in (ROOT / "changelog.md").read_text():
        errors.append("changelog.md: current version missing")
    for path in [*ROOT.glob("*.md"), *(ROOT / "docs").rglob("*.md")]:
        # Check local file links/images (external URLs and in-page anchors excluded).
        for raw in re.findall(r"!?\[[^\]]*\]\(([^\s)]+)(?:\s+[^)]*)?\)", path.read_text()):
            link = urlsplit(raw)
            if link.scheme or not link.path:
                continue
            target = (path.parent / unquote(link.path)).resolve()
            if not target.is_relative_to(ROOT) or not target.exists():
                errors.append(f"{path.relative_to(ROOT)}: broken/nonportable link {raw}")
    for folder in (ROOT / "scripts", ROOT / "tests", ROOT / "examples"):
        for path in folder.rglob("*.py"):
            ast.parse(path.read_text(), filename=str(path))
    for script in re.findall(r"^python3 ([\w/]+\.py)", (ROOT / "scripts/test.sh").read_text(), re.MULTILINE):
        if not (ROOT / script).is_file():
            errors.append("test entrypoint missing: " + script)
    if bin_dir:
        for name in ("metal-sandboxd", "sandboxctl", "evaluation-runner", "metal-runner"):
            p = subprocess.run([str(bin_dir.resolve() / name), "--version"], capture_output=True, text=True, timeout=10)
            if p.returncode or p.stdout.strip() != version or p.stderr:
                errors.append(name + ": --version differs from source")
    if errors:
        raise ValueError("\n".join(errors))
    print(f"PASS: release {version}; paths, Markdown file links, Python syntax" + (", CLI versions" if bin_dir else ""))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path)
    args = parser.parse_args()
    check(args.bin_dir)
