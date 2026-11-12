#!/usr/bin/env python3
"""Verify packaged app structure, signatures, versions and system-only dylibs.

Does not launch the GUI/service or substitute for interactive installation tests.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
from release_metadata import release_version
from package_app import TOOLS
from build_app_icon import verify_icon


def verify(app):
    assert app.name == "Metal Sandbox.app", "App bundle filename"
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(app)], check=True)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert info["CFBundleName"] == info["CFBundleDisplayName"] == "Metal Sandbox", "App display name"
    assert info["MetalSandboxVersion"] == release_version(), "App product version"
    assert info["CFBundleShortVersionString"] == release_version(), "Finder version"
    assert info["CFBundleExecutable"] == "metal-sandbox-ui", "GUI entry point"
    build_info = subprocess.check_output(["xcrun", "vtool", "-show-build", str(app / "Contents/MacOS/metal-sandbox-ui")], text=True)
    sdk = re.search(r"^\s*sdk ([0-9.]+)$", build_info, re.MULTILINE)
    minimum = re.search(r"^\s*minos ([0-9.]+)$", build_info, re.MULTILINE)
    assert sdk and int(sdk[1].split(".")[0]) >= 26, "GUI must link a current SDK for native Liquid Glass"
    assert minimum and minimum[1] == info["LSMinimumSystemVersion"] == "13.0", "keep macOS 13 deployment support"
    icon = verify_icon(app / "Contents/Resources", info)
    helpers = app / "Contents/Helpers"
    assert not (app / "Contents/Resources/prepare_claude.sh").exists(), "harness scripts belong to task packages, not the App"
    policy = app / "Contents/Resources/MetalSandbox_SandboxRuntime.bundle/Contents/Resources/default_task_policy.json"
    assert isinstance(json.loads(policy.read_text())["parallel"], list), "bundled default task policy JSON"
    assert {p.name for p in helpers.iterdir()} == set(TOOLS), "exact bundled runtime set"
    checked = []
    for executable in [app / "Contents/MacOS/metal-sandbox-ui", *[helpers / n for n in TOOLS]]:
        output = subprocess.check_output(["/usr/bin/otool", "-L", str(executable)], text=True)
        libraries = [line.strip().split(" (", 1)[0] for line in output.splitlines()[1:]]
        assert all(path.startswith(("/usr/lib/", "/System/Library/")) for path in libraries), f"non-system dylib in {executable}"
        checked.append(str(executable.relative_to(app)))
    for name in ("sandboxctl", "metal-sandboxd", "evaluation-runner", "metal-runner"):
        version = subprocess.check_output([str(helpers / name), "--version"], text=True).strip()
        assert version == release_version(), name + " version"
    forbidden = {".build", ".git", ".verification", "operator_token", "handle.json", "sandbox_handle.json", "active-lease.json"}
    files = {}
    for path in sorted(app.rglob("*")):
        assert not any(part in forbidden for part in path.relative_to(app).parts), "private state in App"
        assert not path.is_symlink(), "unexpected app symlink"
        if path.is_file():
            files[str(path.relative_to(app))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return {"result": "passed", "version": release_version(), "app": str(app), "systemOnlyDependencies": checked,
            "frontendSDK": sdk[1], "minimumMacOS": minimum[1],
            "signature": "codesign strict/deep verified", "notarized": False, "app_icon": icon, "files_sha256": files}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    report = verify(args.app.resolve())
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print("PASS packaged App signatures, metadata, official layered icon, bundled CLI versions and system-only dependencies")
