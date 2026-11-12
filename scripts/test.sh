#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1
OUT="${1:-.verification/run_$(date +%Y%m%d_%H%M%S)}"
if [[ $# -gt 1 || -e "$OUT" ]]; then
  echo "Usage: $0 [NEW_OUTPUT_DIRECTORY]" >&2
  exit 2
fi
python3 scripts/check_release.py
python3 tests/integration/task_setup_tests.py
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
"$BIN/sandbox-selftest"
python3 scripts/check_release.py --bin-dir "$BIN"
python3 tests/integration/app_sandbox_acceptance.py --bin-dir "$BIN" --output "$OUT/app_sandbox"
python3 tests/integration/native_management_acceptance.py --bin-dir "$BIN" --output "$OUT/management"
python3 tests/integration/native_deletion_acceptance.py --bin-dir "$BIN" --output "$OUT/deletion"
python3 tests/integration/native_development_acceptance.py --bin-dir "$BIN" --output "$OUT/development"
python3 tests/integration/task_scheduling_acceptance.py --bin-dir "$BIN" --output "$OUT/task_scheduling"
python3 tests/integration/workspace_console_acceptance.py --bin-dir "$BIN" --output "$OUT/workspace_console"
python3 tests/integration/workspace_archive_acceptance.py --bin-dir "$BIN" --output "$OUT/workspace_archive"
