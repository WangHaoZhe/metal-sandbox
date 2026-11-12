#!/bin/sh
# Copy this entire directory to workspace/tests, then execute tests/test.sh.
# No candidate is ever run in the original workspace.
set -eu
umask 077
TESTS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
export PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1
for directory in "$TESTS/.runtime" "$TESTS/.runtime/home" "$TESTS/.runtime/tmp" "$TESTS/.runtime/cache"; do
    if [ -L "$directory" ]; then echo '[FAIL] Linked runtime directory is not allowed' >&2; exit 2; fi
done
mkdir -p "$TESTS/.runtime/home" "$TESTS/.runtime/tmp" "$TESTS/.runtime/cache"
export HOME="$TESTS/.runtime/home" CFFIXED_USER_HOME="$TESTS/.runtime/home"
export TMPDIR="$TESTS/.runtime/tmp/" TMP="$TESTS/.runtime/tmp" TEMP="$TESTS/.runtime/tmp"
export XDG_CACHE_HOME="$TESTS/.runtime/cache" XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
export CLANG_MODULE_CACHE_PATH="$TESTS/.runtime/cache/clang"
export SWIFT_MODULECACHE_PATH="$TESTS/.runtime/cache/swift"
export SWIFTPM_MODULECACHE_OVERRIDE="$TESTS/.runtime/cache/swiftpm"
export SWIFTPM_CONFIG_PATH="$HOME/.swiftpm/config"
export SWIFTPM_SECURITY_PATH="$HOME/.swiftpm/security"
export SWIFTPM_CACHE_PATH="$TESTS/.runtime/cache/swiftpm_packages"
export LLVM_PROFILE_FILE="$TESTS/.runtime/profile_%p.profraw"
export MTL_SHADER_CACHE_DIR="$TESTS/.runtime/cache/metal"
export MTL_SHADER_CACHE_PATH="$TESTS/.runtime/cache/metal"
export DARWIN_USER_CACHE_DIR="$TESTS/.runtime/cache/"
export DARWIN_USER_TEMP_DIR="$TMPDIR"
export PIP_CACHE_DIR="$TESTS/.runtime/cache/pip" CCACHE_DIR="$TESTS/.runtime/cache/ccache"
export HISTFILE="$HOME/.history"
cd "$TESTS"
# Apple's /usr/bin/python3 can itself dispatch through developer-tool shims.
# Prefer the managed PATH, then real system SDK installations, without xcrun.
PYTHON=
old_ifs=$IFS
IFS=:
for directory in ${PATH:-/usr/bin:/bin}; do
    case "$directory" in /usr/bin|/bin|''|.) continue;; /*) ;; *) continue;; esac
    if [ -x "$directory/python3" ]; then PYTHON="$directory/python3"; break; fi
done
IFS=$old_ifs
if [ -z "$PYTHON" ]; then
    for candidate in "${DEVELOPER_DIR:-/nonexistent}/usr/bin/python3" \
        /Library/Developer/CommandLineTools/usr/bin/python3 \
        /Applications/Xcode.app/Contents/Developer/usr/bin/python3; do
        if [ -x "$candidate" ]; then PYTHON=$candidate; break; fi
    done
fi
if [ -z "$PYTHON" ]; then
    echo '[FAIL] No real Python3 found; system developer-tool shims are not invoked' >&2
    exit 2
fi
exec "$PYTHON" -B "$TESTS/verifier.py" "$@"
