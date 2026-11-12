#!/usr/bin/env python3
"""Create an allowlisted source archive with per-file and archive SHA-256.

Does not build, publish, sign, notarize, install or claim runtime acceptance.
No .git, credentials, test state, caches or compiled applications are included.
"""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import tarfile
from check_release import check
from release_metadata import ROOT, release_version

FILES = (".gitignore", "AGENTS.md", "Package.swift", "Package.resolved", "README.md", "README_ZH.md", "changelog.md", "contributing.md")
DIRECTORIES = ("sources", "tests", "scripts", "examples", "docs", "frontend")
EXCLUDED = {"__pycache__", ".DS_Store", ".build", ".swiftpm"}
EXTENSIONS = {".swift", ".py", ".sh", ".md", ".png", ".json", ".c", ".cpp", ".mm", ".metal", ".svg", ".yaml", ".toml"}


def source_files():
    paths = [ROOT / name for name in FILES]
    for name in DIRECTORIES:
        if (ROOT / name).is_symlink():
            raise ValueError("refusing a symlinked source directory: " + name)
        for path in sorted((ROOT / name).rglob("*")):
            if any(part in EXCLUDED for part in path.relative_to(ROOT).parts):
                continue
            # 本地安装包保留在题包目录，源码归档跳过二进制依赖。
            if path.is_relative_to(ROOT / "examples/tasks") and path.parts[-3:] == ("agent", "vendor", "claude"):
                continue
            if path.is_symlink():
                raise ValueError("refusing a symlink in release sources: " + str(path))
            if path.is_file():
                if (path.suffix not in EXTENSIONS and not (path.is_relative_to(ROOT / "examples/tasks") and path.suffix == ".rgba32f")) or path.name in {"operator_token", "handle.json"}:
                    raise ValueError("unexpected release source file: " + str(path))
                paths.append(path)
            elif not path.is_dir():
                raise ValueError("refusing a special file: " + str(path))
    for path in paths:
        if path.is_symlink() or not path.is_file():
            raise ValueError("expected a regular source file: " + str(path))
    return sorted(paths)


def package(output):
    check()
    version = release_version()
    stem = "metal_sandbox_" + version + "_source"
    if any(output.is_relative_to(ROOT / name) for name in DIRECTORIES):
        raise ValueError("output cannot be inside a packaged source directory")
    output.mkdir(parents=True, exist_ok=True)
    archive = output / (stem + ".tar.gz")
    checksum = output / (stem + ".sha256")
    if archive.exists() or checksum.exists():
        raise ValueError("release artifacts already exist; choose a new output directory")
    files = [(str(p.relative_to(ROOT)), p.read_bytes(), 0o755 if p.stat().st_mode & 0o111 else 0o644) for p in source_files()]
    manifest = {name: hashlib.sha256(data).hexdigest() for name, data, _ in files}
    metadata = {"version": version, "kind": "source", "files": manifest, "notarized": False}
    files.append(("release_manifest.json", (json.dumps(metadata, indent=2) + "\n").encode(), 0o644))
    # Stable ordering/permissions/timestamps; identical source bytes yield identical archives.
    with archive.open("xb") as raw:
        with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as tar:
                for name, data, mode in files:
                    info = tarfile.TarInfo(stem + "/" + name)
                    info.size = len(data); info.mode = mode
                    tar.addfile(info, io.BytesIO(data))
    with tarfile.open(archive) as tar:
        actual = {m.name.removeprefix(stem + "/"): hashlib.sha256(tar.extractfile(m).read()).hexdigest()
                  for m in tar.getmembers() if not m.name.endswith("/release_manifest.json")}
        if actual != manifest:
            raise ValueError("archive verification failed")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    with checksum.open("x") as file:
        file.write(digest + "  " + archive.name + "\n")
    print(archive)
    print(checksum)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    package(parser.parse_args().output.resolve())
