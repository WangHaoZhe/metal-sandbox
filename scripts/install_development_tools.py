#!/usr/bin/env python3
"""Install pinned official CMake/Ninja into the operator's private tool directory.

No root, Homebrew, signature changes, quarantine removal or global PATH edits.
Run on the host; this does not change instance network permissions.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request

ROOT = Path.home() / "Library/Application Support/MetalSandbox/development_tools"
PACKAGES = {
    "cmake": ("4.4.3", "https://github.com/Kitware/CMake/releases/download/v4.4.3/cmake-4.4.3-macos-universal.tar.gz",
              "0c5d65251c14cc884bfa16bdbed3c263ce5bffe2e21c0d0d00962cb0610464fa"),
    "ninja": ("1.13.2", "https://github.com/ninja-build/ninja/releases/download/v1.13.2/ninja-mac.zip",
              "c99048673aa765960a99cf10c6ddb9f1fad506099ff0a0e137ad8960a88f321b"),
}


def install():
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    if ROOT.is_symlink():
        raise ValueError("refusing symlinked tool root")
    for name, (version, url, digest) in PACKAGES.items():
        target = ROOT / name
        expected = {"version": version, "url": url, "sha256": digest}
        if target.exists():
            if target.is_symlink() or json.loads((target / "installation.json").read_text()) != expected:
                raise ValueError(f"{target} already exists with a different installation; not overwriting")
        else:
            with tempfile.TemporaryDirectory(prefix="install_", dir=ROOT) as temp:
                temp = Path(temp)
                archive = temp / "download"
                print("Downloading", name, version, flush=True)
                with urllib.request.urlopen(url, timeout=60) as response, archive.open("wb") as file:
                    shutil.copyfileobj(response, file)
                if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
                    raise ValueError("official archive checksum mismatch: " + name)
                unpacked = temp / "unpacked"
                unpacked.mkdir()
                # Extract only after authenticating the pinned official archive.
                subprocess.run(["/usr/bin/tar", "-xf", str(archive), "-C", str(unpacked)], check=True)
                if name == "cmake":
                    app, = unpacked.glob("*/CMake.app")
                    shutil.move(str(app), str(unpacked / "CMake.app"))
                    for child in list(unpacked.iterdir()):
                        if child.name != "CMake.app":
                            if child.is_dir(): shutil.rmtree(child)
                            else: child.unlink()
                (unpacked / "installation.json").write_text(json.dumps(expected, indent=2) + "\n")
                unpacked.rename(target)
        binary = target / ("CMake.app/Contents/bin/cmake" if name == "cmake" else "ninja")
        subprocess.run([str(binary), "--version"], check=True, timeout=15)
    print("Installed:", ROOT)


if __name__ == "__main__":
    install()
