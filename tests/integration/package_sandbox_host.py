#!/usr/bin/env python3
"""Assemble and ad-hoc sign an owned App Sandbox application; never sign system tools."""
import argparse
import ctypes
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import struct
import uuid
import warnings
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from release_metadata import release_version, bundle_build

HOST_ENTITLEMENTS = {"com.apple.security.app-sandbox": True}
CHILD_ENTITLEMENTS = {**HOST_ENTITLEMENTS, "com.apple.security.inherit": True}


def register_app(app):
    """Register a signed bundle with Apple's public Launch Services API; never launch it."""
    cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    services = ctypes.CDLL('/System/Library/Frameworks/CoreServices.framework/CoreServices')
    cf.CFURLCreateFromFileSystemRepresentation.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_bool]
    cf.CFURLCreateFromFileSystemRepresentation.restype = ctypes.c_void_p
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    services.LSRegisterURL.argtypes = [ctypes.c_void_p, ctypes.c_bool]
    services.LSRegisterURL.restype = ctypes.c_int32
    path = bytes(app.resolve())
    url = cf.CFURLCreateFromFileSystemRepresentation(None, path, len(path), True)
    if not url:
        raise ValueError('cannot form application URL')
    try:
        status = services.LSRegisterURL(url, True)
        if status:
            warnings.warn(f'display-name registration failed ({status}): {app}')
    finally:
        cf.CFRelease(url)


def development_policy(identifier, toolchain):
    base = Path.home() / "Library/Containers" / identifier / "Data/Library/Application Support/MetalSandbox"
    tools = Path.home() / "Library/Application Support/MetalSandbox/development_tools"
    extra = []
    if toolchain.get('metalCompiler'):
        extra = [str(Path(toolchain['metalCompiler'].split('.xctoolchain/')[0] + '.xctoolchain').resolve()) + '/']
    return {**HOST_ENTITLEMENTS,
            "com.apple.security.files.user-selected.executable": True,
            "com.apple.security.files.bookmarks.app-scope": True,
            "com.apple.security.temporary-exception.files.absolute-path.read-only":
                [str(p) + "/" for p in (base / "workspace", base / "tmp", base / "home", tools / "cmake", tools / "ninja")] + extra}


def development_toolchain():
    def resolve(*args):
        return subprocess.check_output(["/usr/bin/xcrun", *args], text=True).strip()
    result = {"compiler": resolve("--find", "clang"), "cxxCompiler": resolve("--find", "clang++"),
              "sdk": resolve("--show-sdk-path"), "buildToolsDirectory": str(Path(resolve("--find", "make")).parent)}
    root = Path.home() / "Library/Application Support/MetalSandbox/development_tools"
    for key, relative in (("cmake", "cmake/CMake.app/Contents/bin/cmake"), ("ninja", "ninja/ninja")):
        if (root / relative).is_file(): result[key] = str(root / relative)
    try:
        metal, library = resolve('--find', 'metal'), resolve('--find', 'metallib')
        if '.xctoolchain/' in metal and Path(metal).parent == Path(library).parent:
            result.update(metalCompiler=metal, metallib=library)
    except subprocess.CalledProcessError:
        pass
    return result


def sign_inherited_executable(data, directory):
    """Trusted acceptance utility: sign bytes, never open a candidate container path.

    The signing configuration is fixed; callers cannot supply entitlements or
    codesign options. This is not a Build Broker and never executes the binary.
    The runtime has its own equivalent publisher; this utility is for acceptance.
    """
    if not 32 <= len(data) or data[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("expected a bounded thin 64-bit Mach-O executable")
    if struct.unpack_from("<I", data, 12)[0] != 2:  # MH_EXECUTE, not a dylib/object
        raise ValueError("candidate must be MH_EXECUTE")
    staging = directory / uuid.uuid4().hex
    staging.mkdir(parents=True, exist_ok=False, mode=0o700)
    binary = staging / "candidate"
    binary.write_bytes(data); binary.chmod(0o700)
    entitlements = staging / "child.entitlements"
    entitlements.write_bytes(plistlib.dumps(CHILD_ENTITLEMENTS))
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements",
                    str(entitlements), str(binary)], check=True, timeout=30)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(binary)], check=True, timeout=30)
    displayed = subprocess.run(["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(binary)],
                               check=True, capture_output=True, timeout=10).stdout
    if plistlib.loads(displayed) != CHILD_ENTITLEMENTS:
        raise ValueError("signed executable does not have exactly the fixed inherited sandbox policy")
    signed = binary.read_bytes()
    return signed


def assemble(bin_dir, destination, identifier, candidate=None, logical_id=None):
    if not re.fullmatch(r"local\.metal-sandbox\.[a-z0-9-]+", identifier):
        raise ValueError("identifier must be local.metal-sandbox.<lowercase-id>")
    if logical_id is not None and (not logical_id.startswith('sbx-') or
                                  logical_id != 'sbx-' + str(uuid.UUID(logical_id[4:]))):
        raise ValueError('invalid logical sandbox ID')
    display_name = 'MetalSandboxHost' + ('-' + logical_id if logical_id else '')
    if destination.exists():
        raise ValueError("destination already exists; refusing to overwrite a signed app")
    binaries = [bin_dir / name for name in ("sandbox-host", "sandbox-probe", "metal-runner")]
    if not all(path.is_file() for path in binaries):
        raise ValueError("build sandbox-host, sandbox-probe and metal-runner first")
    executable_dir = destination / "Contents" / "MacOS"
    executable_dir.mkdir(parents=True, mode=0o700)
    info = {"CFBundleIdentifier": identifier, "CFBundleName": display_name, "CFBundleDisplayName": display_name,
            "CFBundleExecutable": "sandbox-host", "CFBundlePackageType": "APPL",
            "CFBundleVersion": bundle_build(),
            "CFBundleShortVersionString": release_version().split("-")[0],
            "MetalSandboxVersion": release_version(), "LSUIElement": True,
            "LSMinimumSystemVersion": "13.0"}
    (destination / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
    for source in binaries:
        shutil.copyfile(source, executable_dir / source.name)
        (executable_dir / source.name).chmod(0o700)
    helpers = ["sandbox-probe", "metal-runner"]
    if candidate is not None:
        if not 32 <= len(candidate) or candidate[:4] != b"\xcf\xfa\xed\xfe" or struct.unpack_from("<I", candidate, 12)[0] != 2:
            raise ValueError("candidate artifact must be a bounded Mach-O executable")
        # Publish a controller-approved immutable artifact as an owned helper,
        # BEFORE signing/launching this new Host. Do not strip quarantine from
        # files created by the running sandbox or change a live signed bundle.
        (executable_dir / "candidate").write_bytes(candidate)
        (executable_dir / "candidate").chmod(0o700)
        helpers.append("candidate")
    # Entitlements are fixed by the evaluator, never accepted from a candidate.
    toolchain = development_toolchain()
    host = development_policy(identifier, toolchain)
    child = CHILD_ENTITLEMENTS
    resources = destination / "Contents" / "Resources"
    resources.mkdir(mode=0o700)
    (resources / "development_toolchain.json").write_text(json.dumps(toolchain, indent=2))
    for name, entitlements in (("host", host), ("child", child)):
        (resources / (name + ".entitlements")).write_bytes(plistlib.dumps(entitlements))
    for name in helpers:
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements",
                        str(resources / "child.entitlements"), str(executable_dir / name)], check=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", identifier,
                    "--entitlements", str(resources / "host.entitlements"), str(destination)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(destination)], check=True)
    register_app(destination)
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--identifier", required=True)
    parser.add_argument("--logical-id", help="owned sbx-UUID used in the Finder display name")
    args = parser.parse_args()
    print(assemble(args.bin_dir.resolve(), args.output.resolve(), args.identifier, logical_id=args.logical_id))
