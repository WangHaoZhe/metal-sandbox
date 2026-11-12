#!/usr/bin/env python3
"""Build a self-contained local macOS app and read-only installation DMG.

Uses ad-hoc signing, not Developer ID notarization. Never installs a daemon,
changes system security settings, or modifies existing user state.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid
from release_metadata import ROOT, release_version, bundle_build
from build_app_icon import build_icon

TOOLS = ("sandboxctl", "metal-sandboxd", "evaluation-runner", "sandbox-host", "sandbox-probe", "metal-runner", "sandbox-shell")


def copy_support_files(destination):
    shutil.copy2(ROOT / "README.md", destination / "README.md")
    shutil.copy2(ROOT / "README_ZH.md", destination / "README_ZH.md")
    for name in ("docs", "examples"):
        source = ROOT / name
        for path in [source, *source.rglob("*")]:
            if path.is_symlink() or not (path.is_file() or path.is_dir()):
                raise ValueError("unsupported documentation/example entry: " + str(path))
        shutil.copytree(source, destination / name,
                        ignore=shutil.ignore_patterns(".DS_Store", "__pycache__", "*.pyc"))


def run(*args, environment=None):
    subprocess.run([str(a) for a in args], cwd=ROOT, env=environment, check=True)


def build(package, test=False, environment=None):
    arguments = ["swift", "test" if test else "build", "--package-path", str(package), "-c", "release", "--arch", "arm64"]
    if package == ROOT / "frontend":
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        sdk_version = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip()
        # AppKit adopts its system design from the linked SDK, not minOS.
        arguments += ["--sdk", sdk]
        if not test:
            arguments += ["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "13.0", "-Xlinker", sdk_version]
    run(*arguments, environment=environment)
    if test:
        return
    return Path(subprocess.check_output(arguments + ["--show-bin-path"], cwd=ROOT, text=True).strip())


def validate_frontend(backend):
    validation = ROOT / ".verification" / ("app_validation_" + uuid.uuid4().hex)
    temporary = validation / "tmp"
    temporary.mkdir(parents=True)
    state = validation / "state"
    environment = dict(os.environ, METAL_SANDBOX_TEST_BIN=str(backend),
                       METAL_SANDBOX_TEST_STATE_DIR=str(state), TMPDIR=str(temporary) + "/")
    cli = [str(backend / "sandboxctl"), "--state-dir", str(state), "sandbox"]
    with (validation / "service.log").open("wb") as log:
        service = subprocess.Popen([str(backend / "metal-sandboxd"), "--allow-trusted-code",
                                    "--bin-dir", str(backend), "--state-dir", str(state)],
                                   cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)
        try:
            for _ in range(100):
                if service.poll() is not None:
                    raise RuntimeError(f"Test service exited; close any running management service first. See {validation / 'service.log'}")
                ready = subprocess.run(cli + ["status"], capture_output=True, env=environment)
                if ready.returncode == 0:
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError(f"Test service startup timed out; see {validation / 'service.log'}")
            build(ROOT / "frontend", test=True, environment=environment)
            frontend = build(ROOT / "frontend")
            run(frontend / "frontend-selftest", "--live", backend, "--state-dir", state,
                "--output", validation / "cli_results", environment=environment)
        finally:
            current = subprocess.run(cli + ["status"], capture_output=True, env=environment, timeout=15)
            if current.returncode == 0:
                subprocess.run(cli + ["shutdown"], env=environment, check=True, timeout=60)
            if service.poll() is None:
                service.wait(timeout=30)
    return frontend


def package(output, icon_developer_dir=None):
    version = release_version()
    output.mkdir(parents=True, exist_ok=True)
    app = output / "Metal Sandbox.app"
    dmg = output / f"metal_sandbox_{version}_arm64.dmg"
    checksum = dmg.with_suffix(".sha256")
    if any(p.exists() for p in (app, dmg, checksum)):
        raise ValueError("outputs already exist; choose a fresh directory")
    backend = build(ROOT)
    frontend = validate_frontend(backend)
    macos = app / "Contents/MacOS"
    helpers = app / "Contents/Helpers"
    resources = app / "Contents/Resources"
    for directory in (macos, helpers, resources):
        directory.mkdir(parents=True)
    shutil.copytree(backend / "MetalSandbox_SandboxRuntime.bundle", resources / "MetalSandbox_SandboxRuntime.bundle")
    shutil.copytree(backend / "ZIPFoundation_ZIPFoundation.bundle", resources / "ZIPFoundation_ZIPFoundation.bundle")
    shutil.copy2(frontend / "metal-sandbox-ui", macos / "metal-sandbox-ui")
    for name in TOOLS:
        binary = helpers / name
        shutil.copy2(backend / name, binary)
        binary.chmod(0o755)
        run("/usr/bin/codesign", "--force", "--sign", "-", binary)
    (macos / "metal-sandbox-ui").chmod(0o755)
    info = {
        "CFBundleIdentifier": "local.metal-sandbox.desktop",
        "CFBundleName": "Metal Sandbox", "CFBundleDisplayName": "Metal Sandbox",
        "CFBundleExecutable": "metal-sandbox-ui", "CFBundlePackageType": "APPL",
        "CFBundleVersion": bundle_build(), "CFBundleShortVersionString": version,
        "MetalSandboxVersion": version, "CFBundleIconFile": "app_icon",
        "LSMinimumSystemVersion": "13.0", "NSHighResolutionCapable": True,
        "LSApplicationCategoryType": "public.app-category.developer-tools",
    }
    info.update(build_icon(resources, icon_developer_dir))
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    with tempfile.TemporaryDirectory(prefix="metal_sandbox_package_") as temporary:
        temporary = Path(temporary)
        hashes = {str(p.relative_to(app)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(app.rglob("*")) if p.is_file()}
        (resources / "package_manifest.json").write_text(json.dumps({"version": version, "architecture": "arm64", "signing": "ad-hoc", "notarized": False, "pre_outer_sign_sha256": hashes}, indent=2) + "\n")
        run("/usr/bin/codesign", "--force", "--sign", "-", app)
        run("/usr/bin/codesign", "--verify", "--strict", "--deep", app)
        stage = temporary / "install"
        stage.mkdir()
        shutil.copytree(app, stage / app.name)
        (stage / "Applications").symlink_to("/Applications")
        copy_support_files(stage)
        run("/usr/bin/hdiutil", "create", "-volname", "Metal Sandbox", "-srcfolder", stage, "-format", "UDZO", "-ov", dmg)
    run("/usr/bin/hdiutil", "verify", dmg)
    checksum.write_text(hashlib.sha256(dmg.read_bytes()).hexdigest() + "  " + dmg.name + "\n")
    print(app)
    print(dmg)
    print(checksum)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--icon-developer-dir", type=Path, help="full Xcode 27+ Developer directory, only for actool")
    args = parser.parse_args()
    package(args.output.resolve(), args.icon_developer_dir)
