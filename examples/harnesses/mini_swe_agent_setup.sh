#!/bin/sh
# 在实例内安装 mini-swe-agent 及其 Python 运行时，通过 MetalEnvironment 调度工具命令。
set -eu
umask 077
: "${METAL_SANDBOX_SHELL_HELPER:?managed shell bridge required}"
: "${METAL_SANDBOX_AGENT_SESSION:?managed agent session required}"
: "${METAL_SANDBOX_JOB_ID:?managed parent execution required}"
: "${MINI_SWE_AGENT_LOCAL_BUNDLE:?upload the Python and mini-swe-agent runtime bundle}"
: "${MINI_SWE_AGENT_BUNDLE_SHA256:?set the uploaded archive SHA-256}"
: "${MINI_SWE_AGENT_MODEL:?set provider/model_name}"
test -s instruction.md && test -s mini_config.yaml && test -s mini_swe_agent_metal.py
version=2.4.6
runtime="${METAL_SANDBOX_BRIDGE_DIRECTORY:?}/mini_swe_agent/$version"
if [ ! -d "$runtime" ]; then
    printf '%s  %s\n' "$MINI_SWE_AGENT_BUNDLE_SHA256" "$MINI_SWE_AGENT_LOCAL_BUNDLE" | /usr/bin/shasum -a 256 -c -
    stage="$(mktemp -d "${TMPDIR:?}/mini_install.XXXXXX")"
    trap 'rm -rf "$stage"' EXIT
    /usr/bin/tar -xzf "$MINI_SWE_AGENT_LOCAL_BUNDLE" -C "$stage"
    /usr/bin/file -L "$stage/python/bin/python3" | /usr/bin/grep -q 'Mach-O.*arm64'
    actual="$(PYTHONPATH="$stage/packages" "$stage/python/bin/python3" -c 'import importlib.metadata; print(importlib.metadata.version("mini-swe-agent"))')"
    test "$actual" = "$version"
    mkdir -p "${runtime%/*}"
    /bin/mv "$stage" "$runtime"
    trap - EXIT
fi
export PYTHONPATH="$runtime/packages:$PWD"
export METAL_SANDBOX_MINI_RUNTIME="$runtime"
export MSWEA_CONFIGURED=true MSWEA_COST_TRACKING=ignore_errors
actual="$("$runtime/python/bin/python3" -c 'import importlib.metadata; print(importlib.metadata.version("mini-swe-agent"))')"
test "$actual" = "$version"
session="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
log_dir="mini_swe_agent_runs/$session"
mkdir -p "$log_dir"
printf 'mini-swe-agent %s started; output=%s/trajectory.json\n' "$version" "$log_dir"
set +e
"$runtime/python/bin/python3" -m minisweagent.run.mini \
    --yolo --model "$MINI_SWE_AGENT_MODEL" --task "$(cat instruction.md)" \
    -c mini -c mini_config.yaml --environment-class mini_swe_agent_metal.MetalEnvironment \
    --output "$log_dir/trajectory.json" --exit-immediately \
    > "$log_dir/stdout.txt" 2> "$log_dir/stderr.log"
code=$?
set -e
printf '{"exit_code":%s}\n' "$code" > "$log_dir/exit.json"
printf 'mini-swe-agent finished; exit=%s; output=%s/trajectory.json\n' "$code" "$log_dir"
exit "$code"
