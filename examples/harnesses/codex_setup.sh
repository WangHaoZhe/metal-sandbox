#!/bin/sh
# 在实例内安装原生 Codex，并通过管理服务调度每条工具命令。
set -eu
umask 077
: "${METAL_SANDBOX_SHELL_HELPER:?managed shell bridge required}"
: "${METAL_SANDBOX_CODEX_HOOKS:?managed Codex hooks required}"
: "${METAL_SANDBOX_AGENT_SESSION:?managed agent session required}"
: "${METAL_SANDBOX_JOB_ID:?managed parent execution required}"
: "${OPENAI_API_KEY:?set OPENAI_API_KEY in the instance environment}"
test -s instruction.md && test -s codex_config.toml
version=0.162.1
runtime="$HOME/.local/share/codex/$version"
if [ ! -d "$runtime" ]; then
    stage="$(mktemp -d "${TMPDIR:?sandbox TMPDIR is required}/codex_install.XXXXXX")"
    trap 'rm -rf "$stage"' EXIT
    if [ -n "${CODEX_LOCAL_PACKAGE:-}" ]; then
        /bin/cp "$CODEX_LOCAL_PACKAGE" "$stage/codex"
    else
        curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
            --connect-timeout 20 --max-time 1200 \
            "https://github.com/openai/codex/releases/download/rust-v$version/codex-aarch64-apple-darwin.tar.gz" \
            -o "$stage/codex.tar.gz"
        /usr/bin/tar -xzf "$stage/codex.tar.gz" -C "$stage"
        /bin/mv "$stage/codex-aarch64-apple-darwin" "$stage/codex"
    fi
    if [ -n "${CODEX_LOCAL_CODE_MODE_HOST:-}" ]; then
        /bin/cp "$CODEX_LOCAL_CODE_MODE_HOST" "$stage/codex-code-mode-host"
    else
        curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
            --connect-timeout 20 --max-time 1200 \
            "https://github.com/openai/codex/releases/download/rust-v$version/codex-code-mode-host-aarch64-apple-darwin.tar.gz" \
            -o "$stage/code_mode_host.tar.gz"
        /usr/bin/tar -xzf "$stage/code_mode_host.tar.gz" -C "$stage"
        /bin/mv "$stage/codex-code-mode-host-aarch64-apple-darwin" "$stage/codex-code-mode-host"
    fi
    /usr/bin/file "$stage/codex" "$stage/codex-code-mode-host" | /usr/bin/grep -v 'Mach-O.*arm64' && exit 1
    /bin/chmod 700 "$stage/codex" "$stage/codex-code-mode-host"
    actual="$(/usr/bin/env -i PATH=/usr/bin:/bin "$stage/codex" --no-daemon --version)"
    test "$actual" = "codex-cli $version"
    mkdir -p "${runtime%/*}"
    /bin/mv "$stage" "$runtime"
    trap - EXIT
fi
actual="$(/usr/bin/env -i PATH=/usr/bin:/bin "$runtime/codex" --no-daemon --version)"
test "$actual" = "codex-cli $version"
export CODEX_HOME="$HOME/.codex"
mkdir -p "$CODEX_HOME"
/bin/cp codex_config.toml "$CODEX_HOME/config.toml"
/bin/cp "$METAL_SANDBOX_CODEX_HOOKS" "$CODEX_HOME/hooks.json"
session="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
log_dir="$CODEX_HOME/rollouts/$session"
mkdir -p "$log_dir"
printf 'Codex %s started; output=%s/events.jsonl\n' "$version" "$log_dir"
set +e
/usr/bin/env -i PATH=/usr/bin:/bin \
    HOME="$HOME" TMPDIR="$TMPDIR" WORKSPACE="$WORKSPACE" LANG="${LANG:-en_US.UTF-8}" \
    CC="$CC" CXX="$CXX" SDKROOT="$SDKROOT" CODEX_HOME="$CODEX_HOME" \
    METAL_SANDBOX_HARNESS=codex \
    METAL_SANDBOX_WORKSPACE="$METAL_SANDBOX_WORKSPACE" \
    METAL_SANDBOX_CONTAINER_HOME="$METAL_SANDBOX_CONTAINER_HOME" \
    METAL_SANDBOX_BRIDGE_DIRECTORY="$METAL_SANDBOX_BRIDGE_DIRECTORY" \
    METAL_SANDBOX_SHELL_HELPER="$METAL_SANDBOX_SHELL_HELPER" \
    METAL_SANDBOX_AGENT_SESSION="$METAL_SANDBOX_AGENT_SESSION" \
    METAL_SANDBOX_JOB_ID="$METAL_SANDBOX_JOB_ID" \
    OPENAI_API_KEY="$OPENAI_API_KEY" \
    "$runtime/codex" --no-daemon exec --enable hooks --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox --disable shell_snapshot \
    -c allow_login_shell=false -c shell_environment_policy.inherit=all \
    --skip-git-repo-check --json -- "$(cat instruction.md)" \
    > "$log_dir/events.jsonl" 2> "$log_dir/stderr.log"
code=$?
set -e
printf '{"exit_code":%s}\n' "$code" > "$log_dir/exit.json"
printf 'Codex finished; exit=%s; output=%s/events.jsonl\n' "$code" "$log_dir"
exit "$code"
