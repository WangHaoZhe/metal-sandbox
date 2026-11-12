#!/bin/sh
# 在实例内安装 Node 和官方 Claude 包，再启动受管理的 Agent 会话。
set -eu
umask 077
: "${METAL_SANDBOX_SHELL_HELPER:?managed shell bridge required}"
: "${METAL_SANDBOX_CLAUDE_SETTINGS:?managed Claude settings required}"
: "${METAL_SANDBOX_AGENT_SESSION:?managed agent session required}"
: "${METAL_SANDBOX_JOB_ID:?managed parent execution required}"
test -s instruction.md || { echo 'Missing instruction.md: import the task package first.' >&2; exit 2; }
version=2.1.112
node_version=24.19.0
runtime="$HOME/.local/share/claude_code/${version}_node_${node_version}"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export CLAUDE_CODE_TMPDIR="${TMPDIR:?sandbox TMPDIR is required}/claude"
mkdir -p "$CLAUDE_CONFIG_DIR" "$CLAUDE_CODE_TMPDIR"

if [ ! -d "$runtime" ]; then
    stage="$(mktemp -d "$TMPDIR/claude_install.XXXXXX")"
    trap 'rm -rf "$stage"' EXIT
    if [ -n "${CLAUDE_LOCAL_PACKAGE:-}" ]; then
        test -f "$CLAUDE_LOCAL_PACKAGE" && test -r "$CLAUDE_LOCAL_PACKAGE"
        /bin/cp "$CLAUDE_LOCAL_PACKAGE" "$stage/claude.tgz"
    else
        curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
            --connect-timeout 20 --max-time 600 \
            "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-$version.tgz" \
            -o "$stage/claude.tgz"
    fi
    if [ -n "${CLAUDE_NODE_BINARY:-}" ]; then
        test -f "$CLAUDE_NODE_BINARY" && test -r "$CLAUDE_NODE_BINARY"
        /bin/cp "$CLAUDE_NODE_BINARY" "$stage/node"
    else
        curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
            --connect-timeout 20 --max-time 600 \
            "https://nodejs.org/dist/v$node_version/node-v$node_version-darwin-arm64.tar.gz" \
            -o "$stage/node.tar.gz"
        /usr/bin/tar -xzf "$stage/node.tar.gz" -C "$stage"
        /bin/cp "$stage/node-v$node_version-darwin-arm64/bin/node" "$stage/node"
    fi
    /usr/bin/file "$stage/node" | /usr/bin/grep -q 'Mach-O.*arm64'
    /bin/chmod 700 "$stage/node"
    mkdir -p "$stage/claude"
    /usr/bin/tar -xzf "$stage/claude.tgz" --strip-components 1 -C "$stage/claude"
    test -s "$stage/claude/cli.js"
    test "$(/usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" TMPDIR="$TMPDIR" "$stage/node" --version)" = "v$node_version"
    actual="$(/usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" TMPDIR="$TMPDIR" "$stage/node" "$stage/claude/cli.js" --version)"
    case "$actual" in "$version "*) ;; *) echo 'Claude package version does not match.' >&2; exit 1;; esac
    mkdir -p "${runtime%/*}"
    /bin/mv "$stage" "$runtime"
    trap - EXIT
fi
node="$runtime/node"
claude="$runtime/claude/cli.js"
test "$(/usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" TMPDIR="$TMPDIR" "$node" --version)" = "v$node_version"
actual="$(/usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" TMPDIR="$TMPDIR" "$node" "$claude" --version)"
case "$actual" in "$version "*) ;; *) echo 'Installed Claude version does not match.' >&2; exit 1;; esac

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo 'Claude installed. Set ANTHROPIC_API_KEY in the instance environment, then run again.' >&2
    exit 2
fi
session="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
log_dir="$CLAUDE_CONFIG_DIR/rollouts/$session"
mkdir -p "$log_dir"
printf 'Claude %s started; session=%s\nConversation: %s/events.jsonl\n' "$version" "$session" "$log_dir"
set +e
/usr/bin/env -i PATH="${METAL_SANDBOX_SHELL_HELPER%/*}:/usr/bin:/bin" \
    HOME="$HOME" TMPDIR="$TMPDIR" WORKSPACE="$WORKSPACE" LANG="${LANG:-en_US.UTF-8}" \
    CC="$CC" CXX="$CXX" SDKROOT="$SDKROOT" \
    CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" CLAUDE_CODE_TMPDIR="$CLAUDE_CODE_TMPDIR" \
    DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    CLAUDE_CODE_SHELL=/bin/bash CLAUDE_CODE_SHELL_PREFIX=sandbox-shell \
    METAL_SANDBOX_HARNESS=claude \
    METAL_SANDBOX_WORKSPACE="$METAL_SANDBOX_WORKSPACE" \
    METAL_SANDBOX_CONTAINER_HOME="$METAL_SANDBOX_CONTAINER_HOME" \
    METAL_SANDBOX_BRIDGE_DIRECTORY="$METAL_SANDBOX_BRIDGE_DIRECTORY" \
    METAL_SANDBOX_SHELL_HELPER="$METAL_SANDBOX_SHELL_HELPER" \
    METAL_SANDBOX_AGENT_SESSION="$METAL_SANDBOX_AGENT_SESSION" \
    METAL_SANDBOX_JOB_ID="$METAL_SANDBOX_JOB_ID" \
    ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
    ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}" \
    ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-}" \
    "$node" "$claude" --setting-sources '' --settings "$METAL_SANDBOX_CLAUDE_SETTINGS" \
    --session-id "$session" --dangerously-skip-permissions \
    --tools Bash,Read,Write,Edit,Glob,Grep --no-chrome \
    --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
    --print --output-format stream-json --verbose \
    < instruction.md > "$log_dir/events.jsonl" 2> "$log_dir/stderr.log"
code=$?
set -e
printf '{"exit_code":%s}\n' "$code" > "$log_dir/exit.json"
printf 'Claude finished; exit=%s; conversation=%s/events.jsonl\n' "$code" "$log_dir"
exit "$code"
