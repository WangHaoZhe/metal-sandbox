"""App-Sandbox-compatible tool discovery; never invoke Apple's developer shims.

PATH/CC/CXX/SDKROOT supplied by the managed host win. The small xcrun-compatible
adapter only does local lookup/exec; it is NOT the system xcrun executable.
"""
import json
import os
from pathlib import Path
import plistlib
import shlex


def configure(root):
    original = os.environ.get("PATH", "/usr/bin:/bin").split(os.pathsep)
    directories = [Path(p) for p in original if p and Path(p).is_absolute()]
    for key in ("CC", "CXX", "SWIFTC"):
        value = os.environ.get(key, "")
        if value and Path(value).is_absolute():
            directories.append(Path(value).parent)
    developer = os.environ.get("DEVELOPER_DIR")
    if developer:
        directories.append(Path(developer) / "Toolchains/XcodeDefault.xctoolchain/usr/bin")
    directories += [Path("/Library/Developer/CommandLineTools/usr/bin"),
                    Path("/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin")]

    def locate(name, override=None):
        candidates = ([Path(override)] if override and Path(override).is_absolute() else [])
        candidates += [d / name for d in directories]
        for p in candidates:
            # /usr/bin/swift*, clang*, metal* are dispatch shims, not compilers.
            if p.parent == Path("/usr/bin"):
                continue
            if p.is_file() and os.access(p, os.X_OK):
                return str(p.absolute())  # preserve swiftc basename (symlink to frontend)
        return None

    found = {name: locate(name, os.environ.get(var)) for name, var in
             (("clang", "CC"), ("clang++", "CXX"), ("swiftc", "SWIFTC"),
              ("swift", "SWIFT"), ("metal", "METAL"), ("metallib", "METALLIB"))}
    if not found["swiftc"]:
        raise RuntimeError("No real swiftc found in PATH/toolchain directories (system shims are forbidden)")
    sdk = os.environ.get("SDKROOT", "")
    if not sdk or not Path(sdk).is_dir():
        choices = [Path("/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")]
        if developer:
            choices.insert(0, Path(developer) / "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk")
        sdk = next((str(p) for p in choices if p.is_dir()), "")
    if not sdk:
        raise RuntimeError("SDKROOT is missing and no local macOS SDK was found")
    version = "unknown"
    settings = Path(sdk) / "SDKSettings.plist"
    if settings.is_file():
        with settings.open("rb") as f:
            version = str(plistlib.load(f).get("Version", "unknown"))
    bindir = root / "bin"
    bindir.mkdir(parents=True, exist_ok=True)
    for name, path in found.items():
        wrapper = bindir / name
        if path:
            flags = ""
            if name == "swiftc":
                flags = " -module-cache-path " + shlex.quote(os.environ["SWIFT_MODULECACHE_PATH"])
            elif name in ("clang", "clang++"):
                flags = " " + shlex.quote("-fmodules-cache-path=" + os.environ["CLANG_MODULE_CACHE_PATH"])
            text = "#!/bin/sh\nexec " + shlex.quote(path) + flags + ' "$@"\n'
        else:
            text = "#!/bin/sh\necho 'Required real tool is unavailable: " + name + "' >&2\nexit 127\n"
        wrapper.write_text(text)
        wrapper.chmod(0o700)
    adapter = bindir / "xcrun"
    adapter.write_text("""#!/bin/sh
set -eu
find_only=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --sdk|-sdk) [ "$#" -ge 2 ] || exit 64
            case "$2" in macosx*) ;; *) echo 'Only macosx SDK is supported' >&2; exit 64;; esac
            shift 2 ;;
        --find|-find|-f) find_only=1; shift ;;
        --show-sdk-path) printf '%s\\n' "$SDKROOT"; exit 0 ;;
        --show-sdk-version) printf '%s\\n' "$VERIFIER_SDK_VERSION"; exit 0 ;;
        --toolchain|-toolchain) echo 'Select the toolchain with PATH/CC/CXX instead' >&2; exit 64 ;;
        --*) echo "Unsupported local tool-lookup option: $1" >&2; exit 64 ;;
        *) break ;;
    esac
done
[ "$#" -gt 0 ] || exit 64
case "$1" in swift|swiftc|clang|clang++|metal|metallib) ;;
    *) echo "Unsupported local tool: $1" >&2; exit 64;; esac
tool="$VERIFIER_TOOL_BIN/$1"
shift
if [ "$find_only" = 1 ]; then printf '%s\\n' "$tool"; else exec "$tool" "$@"; fi
""")
    adapter.chmod(0o700)
    os.environ.update(PATH=str(bindir) + os.pathsep + os.pathsep.join(original),
                      SDKROOT=sdk, CC=str(bindir / "clang"), CXX=str(bindir / "clang++"),
                      SWIFTC=str(bindir / "swiftc"), VERIFIER_TOOL_BIN=str(bindir),
                      VERIFIER_SDK_VERSION=version)
    info = {"real_tools": found, "sdk": sdk, "sdk_version": version}
    (root / "tools.json").write_text(json.dumps(info, indent=2) + "\n")
    return info
