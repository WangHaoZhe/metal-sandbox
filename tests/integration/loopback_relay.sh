#!/bin/sh
set -eu
test "$1" = --state-dir
state="$2"
shift 2
root=$(dirname "$state")
export METAL_SANDBOX_COORDINATION_DIR="$root/c"
exec "$root/bin/sandboxctl" --state-dir "$state" "$@"
