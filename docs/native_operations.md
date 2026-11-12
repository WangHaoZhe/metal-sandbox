# Native Sandbox Usage Guide

The **App Sandbox backend** is for trusted local development only. The service does not install launchd jobs, require root, create users, or open TCP ports.

## 1. Start the Management Service

Terminal one:

```sh
# Run from the source root
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
"$BIN/metal-sandboxd" --allow-trusted-code
```

The service stays in the foreground. Only one management service may run per UID; different state-dir values do not allow a second service. The default state directory is `~/Library/Application Support/MetalSandbox/native`.

Use `--state-dir /absolute/path` to specify a state directory; the CLI also places `--state-dir` before `sandbox`. The management socket is fixed at `/private/tmp/metal-sandbox-<uid>/native.sock` for the current UID (check it with `id -u`). Each service startup generates a new operator token. Do not put the token in a sandbox or candidate environment.

## 2. Create Instances and Enter

Terminal two:

```sh
BIN="$(swift build -c release --show-bin-path)"
"$BIN/sandboxctl" sandbox create --count 4
"$BIN/sandboxctl" sandbox list -h
"$BIN/sandboxctl" sandbox enter <returned_sandbox_id>
```

IDs have the form `sbx-<UUID>` and accept unique prefixes. Create 1–16 at a time. Each node defaults to at most 32 active instances, configurable through node settings or `--max-instances N` for standalone services. Stopped instances do not occupy capacity; a full node causes CLI exit code 75. A failed batch attempts to stop instances created in that batch and retains failure records.

`list -h` (or `list --human`) displays the full ID, status, networking setting, allowlist/denylist mode, and local creation time in columns. An empty list shows `No sandboxes.`. Plain `list` still outputs JSON for scripts and the frontend. Use `list --help` for help.

New instances allow outbound networking by default. Disable it with `sandboxctl sandbox create --count N --no_network`. The operator chooses fixed signing entitlements only at creation. This option permits all instance programs to make outbound connections, including LAN and loopback addresses; it is not a domain allowlist and grants no inbound listening permission. It cannot be changed on a running instance. `inspect.networkClient` shows the choice, which is retained when restoring to a new instance.

Finder displays containers as `MetalSandboxHost-<full sandbox ID>`, for example `MetalSandboxHost-sbx-…`. Their disk directory names remain macOS-managed `local.metal-sandbox.instance-…`; these are different IDs. The frontend and CLI use the same creation flow, registering the App name with Launch Services before starting the Host. Snapshot restoration uses the new instance ID. Standalone test Hosts without a logical ID use `MetalSandboxHost`.

If a deleted instance leaves a system container shell after its Host bundle and name cache disappear, Finder displays the original directory name; this does not indicate another active sandbox. Name-registration failures do not prevent headless execution and are detailed in service logs. Do not rename or move system containers still in use. See deletion and residual cleanup below.

After entering, type `pwd`, `ls`, `mkdir src`, `cd src`, and similar commands. `exit` leaves only the console and **does not close the sandbox**.

**enter submits individual commands; it is not a persistent PTY.** Each command follows the instance's saved parallel or serial policy; an idle console occupies no slot. Files and the current console's cwd persist. Shell variables across commands, interactive vim/top, job control, and interactive stdin are unsupported. Changing directory into a container does not constitute entering the sandbox.

To set the directory or timeout for one command, enter:

```text
:run {"line":"pwd","timeout":30,"cwd":"."}
```

`line` is a single command line, at most 8 KiB. `timeout` is positive seconds. Omitting `cwd` retains the console's current directory; a supplied value must be workspace-relative (`.` is the root). The same scheduler handles the command and returns its execution ID and exit code. Ordinary commands and `cd`/`exit` remain available.

Browse the workspace through the read-only directory interface, separately from executing `ls` inside the console:

```sh
"$BIN/sandboxctl" sandbox ls <id>
"$BIN/sandboxctl" sandbox ls <id> src
# When nextAfter is returned, use its exact value for the next page
"$BIN/sandboxctl" sandbox ls <id> src --after '<nextAfter>'
```

Each page contains 256 entries, including hidden files and metadata for large files, without following links. Directories are queried on demand, one level at a time; scans exceeding 100000 entries in a directory fail explicitly. Listing, previewing, and downloading individual files remain available during command or agent execution. These operations use read permission and do not occupy candidate execution slots. Browsing is not a frozen snapshot; concurrent directory or file changes can require retry. Writes, imports, and full snapshot exports remain mutually exclusive with execution. See [API Documentation](api.md) for response structures.

## 3. Execute, Compile, and Run Repeatedly

### Agent Sessions and Tool Commands

Preparation starts scripts automatically with `exec --session`. The corresponding CLI command is:

```sh
"$BIN/sandboxctl" sandbox exec "$ID" --session --timeout 7200 -- /bin/sh ./setup.sh
```

The operator selects `--session` so the persistent harness session does not occupy the serial slot. Agents do not need to call sandboxctl and should not do so themselves. Ordinary `exec` without this option follows the instance policy. Session subprocess commands without an integrated adapter are not intercepted automatically.

Managed sessions support Claude Code, Codex, and mini-swe-agent. The [three preparation scripts](../examples/harnesses/README.md) configure their respective command interfaces; mini uses a Python environment adapter to send tool commands directly to the shell helper.

`METAL_SANDBOX_HARNESS` selects a registered command adapter: `claude` or `codex`, defaulting to `claude` when omitted. Each tool command requests permission through `sandbox-shell` according to the instance policy, preserving its original working directory, output, and exit code. Preparation scripts and instance environment settings configure tool installation, models, and credentials. Harbor installs harnesses when running through Harbor; see [Harbor Configuration](harbor.md).

#### Claude Code

The [example preparation script](../examples/harnesses/claude_setup.sh) installs Node 24.19.0 and the official Claude Code 2.1.112 npm package in private HOME. It supports uploaded installation files; see [Local Installation](task_packages.md#using-local-claude-installation-files). After installation, use the following startup command inside `exec --session` or the App's Preparation tab:

```sh
runtime="$HOME/.local/share/claude_code/2.1.112_node_24.19.0"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export CLAUDE_CODE_TMPDIR="$TMPDIR/claude"
mkdir -p "$CLAUDE_CONFIG_DIR" "$CLAUDE_CODE_TMPDIR"
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
    METAL_SANDBOX_AGENT_SESSION="${METAL_SANDBOX_AGENT_SESSION:?}" \
    METAL_SANDBOX_JOB_ID="${METAL_SANDBOX_JOB_ID:?}" \
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:?}" \
    ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:?}" ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-}" \
    "$runtime/node" "$runtime/claude/cli.js" \
    --setting-sources '' --settings "$METAL_SANDBOX_CLAUDE_SETTINGS" \
    --dangerously-skip-permissions --tools Bash,Read,Write,Edit,Glob,Grep --no-chrome \
    --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
    --print --output-format stream-json --verbose < instruction.md
```

Claude's official `PreToolUse` hook classifies the original Bash command. Parallel commands execute in the original instance; serial commands request the shared serial slot through the Host's private channel. Do not use `--bare`, which skips the hook. `HOME`, Claude configuration, and temporary files all stay inside the instance. Noninteractive startup does not need `TERM` or `SHELL`. For a Messages API proxy, use the service root URL; the client appends `/v1/messages`.

#### Codex

The [Codex preparation script](../examples/harnesses/codex_setup.sh) installs Codex 0.162.1 and matching `codex-code-mode-host` in private HOME. The workspace must contain `instruction.md` and `codex_config.toml`, and the instance environment must contain `OPENAI_API_KEY`. Specify the model, provider, and Responses API URL in `codex_config.toml`. `CODEX_LOCAL_PACKAGE` and `CODEX_LOCAL_CODE_MODE_HOST` can point to the two uploaded native files.

```sh
"$BIN/sandboxctl" sandbox write "$ID" setup.sh --from examples/harnesses/codex_setup.sh
"$BIN/sandboxctl" sandbox write "$ID" codex_config.toml --from /path/to/codex_config.toml
"$BIN/sandboxctl" sandbox exec "$ID" --session --timeout 7200 -- /bin/sh ./setup.sh
```

After installation, the script starts with this command. It first copies `codex_config.toml` to `CODEX_HOME/config.toml`; authentication comes from the instance environment:

```sh
export CODEX_HOME="$HOME/.codex"
mkdir -p "$CODEX_HOME"
cp codex_config.toml "$CODEX_HOME/config.toml"
cp "$METAL_SANDBOX_CODEX_HOOKS" "$CODEX_HOME/hooks.json"
/usr/bin/env -i PATH=/usr/bin:/bin \
    HOME="$HOME" TMPDIR="$TMPDIR" WORKSPACE="$WORKSPACE" LANG="${LANG:-en_US.UTF-8}" \
    CC="$CC" CXX="$CXX" SDKROOT="$SDKROOT" CODEX_HOME="$CODEX_HOME" \
    METAL_SANDBOX_HARNESS=codex \
    METAL_SANDBOX_WORKSPACE="$METAL_SANDBOX_WORKSPACE" \
    METAL_SANDBOX_CONTAINER_HOME="$METAL_SANDBOX_CONTAINER_HOME" \
    METAL_SANDBOX_BRIDGE_DIRECTORY="$METAL_SANDBOX_BRIDGE_DIRECTORY" \
    METAL_SANDBOX_SHELL_HELPER="$METAL_SANDBOX_SHELL_HELPER" \
    METAL_SANDBOX_AGENT_SESSION="${METAL_SANDBOX_AGENT_SESSION:?}" \
    METAL_SANDBOX_JOB_ID="${METAL_SANDBOX_JOB_ID:?}" \
    OPENAI_API_KEY="${OPENAI_API_KEY:?}" \
    "$HOME/.local/share/codex/0.162.1/codex" --no-daemon exec \
    --enable hooks --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox --disable shell_snapshot \
    -c allow_login_shell=false -c shell_environment_policy.inherit=all \
    --skip-git-repo-check --json -- "$(cat instruction.md)"
```

Codex's official `PreToolUse` hook sends `Bash` / `exec_command` to the management service. `--no-daemon` uses an independent process; commands and their descendants retain App Sandbox restrictions. The adapter uses the POSIX shell that actually executes tool commands, or an explicitly supplied `METAL_SANDBOX_CODEX_SHELL`. Sessions are saved in the instance's `~/.codex/sessions`, with incremental reading in the App's Trajectory tab.

#### mini-swe-agent

The [mini-swe-agent preparation script](../examples/harnesses/mini_swe_agent_setup.sh) uses a complete local Python and dependency archive. Provide `instruction.md`, `mini_config.yaml`, and `mini_swe_agent_metal.py` in the workspace. Set `MINI_SWE_AGENT_LOCAL_BUNDLE`, `MINI_SWE_AGENT_BUNDLE_SHA256`, `MINI_SWE_AGENT_MODEL`, and the provider API key in the instance environment.

```sh
"$BIN/sandboxctl" sandbox write "$ID" setup.sh --from examples/harnesses/mini_swe_agent_setup.sh
"$BIN/sandboxctl" sandbox write "$ID" mini_config.yaml --from /path/to/mini_config.yaml
"$BIN/sandboxctl" sandbox write "$ID" mini_swe_agent_metal.py --from examples/harnesses/mini_swe_agent_metal.py
"$BIN/sandboxctl" sandbox exec "$ID" --session --timeout 7200 -- /bin/sh ./setup.sh
```

`MetalEnvironment` sends the original command to the runtime's `sandbox-shell`, preserving directory, stdout/stderr, and exit code. Its command budget begins when permission is granted. Run records are saved in the workspace at `mini_swe_agent_runs/<session>/`. Harbor exports raw trajectories and ATIF when running through Harbor.

Model clients for Claude Code, Codex, and mini-swe-agent stay on the instance's owner node. With dynamic scheduling, eligible serial tool commands in the shared workspace can move to idle nodes. Tools use the user configuration and compiler environment; the model client's private runtime directory stays on the owner. Commands depending on private files, executables, or user-specified private environments continue on the owner node.

Serial tool output reports waiting for the execution slot and the wait before permission is granted. **Waiting still counts toward Claude's Bash tool timeout**, which cancels the task on expiration. This differs from actual program-runtime timeout; set a longer tool timeout as needed. Claude generally reads these notices only after the tool returns, so they do not imply live model access while waiting.

This does not intercept arbitrary subprocesses or Metal APIs: each tool command and its descendants form one task, while unsupported harnesses or MCP tools need their own adapters. Sidebar and Overview counts include top-level tasks and integrated tool commands, whether serially queued, serially running, or parallel. One Claude session and three unfinished Bash calls display 4. Parallel tasks register lifecycle only without entering the serial FIFO; completion or cancellation removes them from the count.

### Parallel and Serial Rules

By default, tasks that can run in parallel **within the same or different sandboxes** include `sleep`, `echo`, `ls/cat/pwd`, common file operations such as `mkdir/cp/mv/rm/touch/find`, text processing such as `head/tail/grep/sed/awk/sort/wc/diff`, `git`, `curl`, archive tools, and installed `clang`/`clang++`, `metal`/`metallib`, `make`, `ninja`, and `cmake --build`. Other tasks enter the execution node's FIFO serial queue. Parallel tasks wait neither for the serial slot nor for other executions in the same instance; only serial tasks on the same node queue behind each other. Users or agents must coordinate conflicting writes to the same file. Full snapshots and external writes still require an idle instance.

No CPU/GPU command option is needed. Enter `make`, `ninja`, or `cmake --build build` directly in the console. Only matching absolute executable paths and argument prefixes allow parallel execution. `./make`, `cmake -E ...`, and `sh -c 'make && ./program'` remain serial by default.

In allowlist mode, `sh -c` / `bash -c` and compound Claude Bash tasks inspect each command. Supported syntax includes `&&`, `||`, pipes, semicolons, newlines, static quoting, and ordinary redirection. The entire task runs in parallel only when all commands match. For example, `ls && cat instruction.md` can run in parallel, while `make && ./program` runs serially.

Command paths are resolved inside the instance using its actual PATH and working directory; argument prefixes are checked individually. If an earlier PATH directory is instance-writable and could change through preceding commands, the task is serial. Explicit executable paths can match the allowlist. Execution preserves the original script and its internal order; parallel means only that it may overlap with other tasks.

Variable or command substitution, wildcards, environment assignments, commands changing shell state such as `cd`, loops, functions, background tasks, heredocs, script files, and shells with startup files make the entire task serial when it cannot be confirmed statically. Denylists match the task entry without splitting internal commands.

`sh/bash/zsh`, `env`, `xargs`, and general interpreters are not allowlisted as a whole by default. Subcommands such as `find -exec`, `awk system()`, and Git hooks follow their parent task's scheduling without being classified as CPU-only. Parallel `curl` does not change instance network permissions.

See [`default_task_policy.json`](../sources/sandbox_runtime/resources/default_task_policy.json) for the complete default rules. Updated defaults apply to new instances. Existing and restored instances retain the policy saved at creation, without overwriting custom rules automatically.

**The allowlist covers an entire task and its child processes.** Tests or Metal programs launched by a build script follow the build's parallel scheduling. Serial tasks can therefore still contend for the GPU with allowlisted tasks from other instances.

At creation, a JSON file can **replace** the instance's default scheduling policy rather than append to it:

```sh
printf '%s\n' '{"parallel":[]}' > task_policy.json
"$BIN/sandboxctl" sandbox create --count 1 --task-policy "$PWD/task_policy.json"
"$BIN/sandboxctl" sandbox inspect <id>
```
`{"parallel":[]}` puts all tasks in that instance in the serial slot without preventing other instances from using parallel tasks. Custom rule format follows; paths must be complete absolute paths to actual local tools:

```json
{"parallel":[{"executable":"/bin/ls"},{"executable":"/absolute/path/to/cmake","argumentPrefix":["--build"]}]}
```

A denylist is also supported. This configuration makes directly submitted `/bin/sh` tasks serial and other tasks parallel:

```json
{"serial":[{"executable":"/bin/sh"}]}
```

An allowlist uses `parallel`; a denylist uses `serial`. Choose one, without combining them. `{"serial":[]}` permits all ordinary tasks in the instance to run in parallel; unmatched GPU tasks may contend for the GPU. Matching applies to submitted tasks and does not intercept `/bin/sh` or other subprocesses launched internally. Both modes share the same serial slot without changing working directories or sandbox permissions.

A maximum of 128 rules and 128 KiB per file is allowed. Unknown fields, noncanonical absolute paths, and incorrect types are rejected. Omitting `argumentPrefix` accepts any arguments; a supplied value must be a string array.

`inspect` / `list` returns the saved `taskPolicy`. It is read-only after creation; editing the original JSON file does not affect existing instances. Stopping, service restart, and restoration to a new instance retain it.

`status.taskPolicy` is the **default for new instances**, not a global override for all instances. Defaults come from bundled [default_task_policy.json](../sources/sandbox_runtime/resources/default_task_policy.json), resolving toolchain placeholders to actual Mac paths and omitting unavailable optional tools. The interface and instance records display resolved JSON; users do not need to fill placeholders.

The operator can override defaults for new instances at service startup with `metal-sandboxd --allow-trusted-code --task-policy /absolute/default_policy.json`. This does not override saved policies. To make all tasks serial, every active instance should use an empty allowlist.

Rules do not change App Sandbox permissions. Claude Bash, Codex exec_command, and mini-swe-agent shell commands are scheduled separately through their adapters.

### Command Examples

```sh
"$BIN/sandboxctl" sandbox exec <id> -- echo hello
```

Ordinary `clang`/`clang++`, CMake, Ninja, Make, and project-generated programs all execute in App Sandbox. The controller fixes real compiler paths and the SDK, providing `PATH`, `CC`, `CXX`, and `SDKROOT` to child processes and shell calls. It analyzes supported shell strings only to choose scheduling class, without rewriting project scripts.

A normal development workflow can run in one command:

```sh
# When the workspace already contains a CMake project
"$BIN/sandboxctl" sandbox exec <id> --timeout 120 -- /bin/sh -c \
  'set -eu; cmake -S . -B build -G Ninja; cmake --build build; ctest --test-dir build --output-on-failure'
```

CMake `try_run`, multiple executables/helpers, and custom dynamic libraries are supported. Compiling and running retain the same physical container; `revisions` does not grow with every compilation. The system linker handles normal Mach-O signing; the infrastructure does not change build logic for the agent. Frozen publication for independent evaluation remains a separate restricted execution flow.

CMake/Ninja are not bundled in the DMG. The source provides an operator installation script that downloads pinned official releases and checks SHA-256; it does not enable networking in candidates:

```sh
python3 scripts/install_development_tools.py
# Start/restart the service afterward so new instances receive tool paths
```

Tools install in `~/Library/Application Support/MetalSandbox/development_tools`, which candidates can only read. Do not put host secrets there. Other tools require separate compatibility verification; PATH visibility alone does not establish support for arbitrary tools.

After installing Metal Toolchain and restarting the service, use `metal` / `metallib` directly in the sandbox. The control plane resolves the actual component paths instead of calling Xcode placeholder executables:

```sh
"$BIN/sandboxctl" sandbox exec <id> --timeout 120 -- /bin/sh -c \
  'set -eu; metal -c shader.metal -o shader.air; metallib shader.air -o shader.metallib'
```

The same script can continue compiling an Objective-C++ program, load that `.metallib`, and use the physical GPU.

**Remaining boundaries:** Not all Xcode IDE/xcodebuild projects are guaranteed compatible. Apple's `/usr/bin/xcrun` itself refuses to run in App Sandbox; use configured real tools such as `clang`. Files and snapshots are read and written in chunks without byte-size limits, subject to available disk space and path/entry limits. Cross-directory links and arbitrary third-party runtimes are not guaranteed compatible. Networking requires permission at creation, and interactive terminals remain unsupported.

## 4. Generic Preparation Scripts and Task Input

The existing `write` + `exec` interface needs no separate preparation API and is not tied to Claude, Codex, or another harness. `write` transfers files; `exec` executes them inside the chosen sandbox. Workspace files remain after preparation.

Run the following from the source root with the service already started. Create an instance and set `ID` to its returned ID:

```sh
BIN="$(swift build -c release --show-bin-path)"
"$BIN/sandboxctl" sandbox create --count 1
ID='sbx-replace_with_returned_id'

"$BIN/sandboxctl" sandbox write "$ID" setup.sh --from /path/to/setup.sh
"$BIN/sandboxctl" sandbox write "$ID" instruction.md --from /path/to/instruction.md
"$BIN/sandboxctl" sandbox exec "$ID" --timeout 120 -- /bin/sh ./setup.sh
```

Replace `/path/to/` with your local file paths; [whole-task import](task_packages.md) is also available. Script authors decide failure handling. With `set -eu`, ordinary command failures exit and the CLI reports failure, **without undoing previously written files**. Check each exit code before submitting the next command.

Boundaries:

- Scripts may contain arbitrary commands but remain subject to App Sandbox, path, timeout, log, and scheduling restrictions. They are not installation hooks bypassing isolation.
- New instances allow outbound networking by default. `--no_network` prevents network installation. Host credentials are not passed through; do not write operator tokens or Handles to the workspace, or put real API keys directly into recorded command arguments or output.
- Interactive stdin/PTY is unavailable, and initial stdin is `/dev/null`. Noninteractive programs may read prompt files themselves or use supported argv arguments; this cannot simulate starting an interactive CLI and entering a prompt.
- Shell environment variables do not persist across `exec`. Background subprocesses are cleaned up; scripts are not persistent session launchers. Configuration can be written to the workspace and read later.
- Newly compiled programs can start directly within scripts; CMake/helpers/versioned dylibs are supported. Task `setup.sh` installs dependencies and harnesses into the instance's private environment; arbitrary third-party CLI compatibility is not guaranteed.

See [Task Packages and Agent Startup](task_packages.md) for complete task packages and automatically solving tasks after Claude installation. Switching harnesses reuses the same transfer and execution interface with `instruction.md` as the entry. Each CLI's installation, model connection, and noninteractive startup must be verified separately. `evaluation-runner --managed-smoke` remains a fixed test without automatically consuming preparation scripts.

The instance's `PATH` includes its own `$HOME/.local/bin`, excluding the host directory of the same name. Fixed system/development tools take priority. Both `exec -- claude --version` and console `claude --version` use the instance installation. Missing installations fail explicitly without using the host CLI. Environment and configuration files persist throughout the instance's lifetime and remain in the original container after stopping, with permanent deletion removing them together. `start` preserves them. Workspace snapshots exclude `$HOME`, so `restore` clones do not copy tools, login state, or session history and require preparation again.

## 5. Logs, Snapshots, and Cancellation

```sh
"$BIN/sandboxctl" sandbox inspect <id>
"$BIN/sandboxctl" sandbox read <id> prompt.txt
"$BIN/sandboxctl" sandbox snapshot <id>
"$BIN/sandboxctl" sandbox export <id> --out /absolute/path/snapshot.zip
"$BIN/sandboxctl" sandbox import <id> --from /absolute/path/snapshot.zip
"$BIN/sandboxctl" sandbox exec <id> --detach -- /bin/sleep 10
"$BIN/sandboxctl" sandbox wait <returned_execution_id>
"$BIN/sandboxctl" sandbox cancel <execution_id>
```

`snapshot` explicitly saves a backend recovery snapshot without exporting a file or stopping the instance. Save Snapshot in Settings and Snapshots does the same. Saving or exporting a full snapshot requires no unfinished executions in that instance; stopped instances can also save.

Ordinary command completion, writes, and imports do not automatically compress the workspace. Files are stored directly on disk; snapshots are additional recovery backups. New instances retain an initial snapshot, updated by explicit saving, full export, or stopping. Edits after stopping must also be saved again to enter the snapshot used for cloning.

Snapshots save the entire workspace file state, including empty directories, rather than command lists or incremental patches. They exclude private HOME, process memory, and GPU state; command history is stored separately in the backend. After an unexpected service exit, the original workspace remains but the last snapshot may predate recent changes. Starting the original instance does not overwrite its directory with an old snapshot.

A command-runtime timeout terminates and cleans up its process group first. Successful cleanup records failure with output and the timeout reason, releases the scheduling slot, and allows the same instance and other instances to continue without manual recovery. A program returning 0 from a timeout signal handler still counts as a timeout failure. Process-group cleanup does not establish GPU drain or stable GPU performance immediately afterward.

For CLI command submission, the overall deadline is the runtime timeout plus a 300-second queue allowance. Expiration while queued fails immediately and leaves the queue without waiting for the preceding command. Because the program has not started, this does not quarantine the node. The frontend sets no additional execution deadline while waiting for results. Stop, delete, and full-snapshot operations return when the backend operation actually finishes.

Ctrl-C while waiting in the foreground requests cancellation of that execution. `enter` stays open, and after successful cleanup the next command can be entered directly. Explicit cancellation remains `cancelled` even if a signal handler returns 0. The same instance and other instances can continue without manual recovery.

Timeout, cancellation, signal termination, and output-limit failures all require confirmed process-group cleanup. Successful cleanup ends only that task without quarantining other instances. An idle Host exit marks its instance failed; stop it, then start the original instance to reuse it. Host disconnection during execution, invalid permits or critical execution records, and uncertain cleanup still require manual node recovery.

When system thermal state is `critical`, new tasks and tasks without a permit remain queued and resume automatically after cooling. Already-running tasks are not forcibly killed for this reason. Waiting does not consume the Sandbox command-runtime budget; tasks can be cancelled, files viewed, and instances stopped while waiting. Thermal suspension differs from quarantine: cooling does not clear existing quarantine records.

The state directory stores `instances/<id>.json`, `checkpoints/<id>.zip`, `executions/<execution_id>.json`, versioned bundles, and signing records. Snapshots export bytes through the restricted Host, with SHA-256 verification before restoration. Same-directory aliases for versioned dylibs are stored as ZIP symlink entries; file APIs do not follow links, and cross-directory links remain rejected. After moving to a new container, CMake caches with absolute paths may require normal cleaning and rebuilding. Logs are bounded; snapshot-size statistics are not hard disk quotas. Snapshot-save failures such as insufficient space, changed files, or unsupported entries record `checkpointError` and preserve the previous complete snapshot, without guaranteeing recovery of unsaved data. Snapshots accept only ZIP.

## 6. Stop, Start Original Instances, and Clone Snapshots

```sh
"$BIN/sandboxctl" sandbox stop <id>
"$BIN/sandboxctl" sandbox stop --all
"$BIN/sandboxctl" sandbox start <stopped_id>
"$BIN/sandboxctl" sandbox restore <stopped_id>
"$BIN/sandboxctl" sandbox shutdown
```

- `stop` attempts to save a workspace snapshot and closes the instance without deleting its container.
- `start` **starts the original instance**, preserving ID, workspace path, private HOME, installed tools, and session files with the current Host version. It does not restore snapshots or replay processes. Even if a snapshot exceeds limits, an intact original directory can still start.
- `restore` **clones from a snapshot**, verifying the saved snapshot and returning a new ID with only the workspace copied, excluding private HOME. The original instance remains.

Before starting, the service checks the original directory, ownership, and whether the old Host exited. A missing directory, unknown ownership, or quarantined node prevents startup without substituting an empty directory. If the old Host PID still exists, including reuse by another process, inspection is required; the service does not kill by historical PID. Frozen evaluation Hosts cannot restart in place as development Hosts; clone their snapshots.

Service restarts do not start instances automatically; run `start` individually. Old Handles become invalid after stopping or restarting and require new authorization.

### Delete a Sandbox

In the App, stop the instance, then choose Delete.

Permanent deletion requires explicit confirmation:

```sh
"$BIN/sandboxctl" sandbox stop <id>
# Wait for this instance's executions; other instances are not cancelled
"$BIN/sandboxctl" sandbox delete <id> --confirm
```

The target must be stopped with no unfinished executions. Running or queued commands in other instances do not prevent deletion. Eligible instances can be deleted during quarantine without changing quarantine state. Deletion removes container task files, runtime bundles, checkpoints, and list records for all registered physical versions. Separately exported artifacts, execution logs, and recovery audits remain. After clearing task data, the service attempts to remove system container shells with the fixed layout. macOS refusals appear explicitly in `warnings` and deletion audits; do not assume the whole directory disappeared. This is not secure disk erasure. Deletion is irreversible; retry using the full `sbx-UUID`.

Task-data deletion failures retain `delete-failed` and error details for retry after resolving the cause. Partially deleted instances cannot be restored. Permission failures affecting only system shells do not prevent removal of the logical instance, but return explicit residual warnings. Instance records contain all physical identities.

### Deletion and Residual Cleanup

Run with all instances stopped, an idle queue, and a healthy node. Preview does not delete; processing continues after individual errors, without automatic retries.

```sh
# Check shells only from completed deletion/cleanup audits, without restarting Hosts to delete new data
"$BIN/sandboxctl" sandbox cleanup-deleted
"$BIN/sandboxctl" sandbox cleanup-deleted --confirm

# Check unclaimed identities in trusted runtime publication records for this state directory
"$BIN/sandboxctl" sandbox cleanup-unclaimed
# Replace with the full bundleID returned by preview; --bundle-id can be repeated
"$BIN/sandboxctl" sandbox cleanup-unclaimed --bundle-id local.metal-sandbox.instance-<uuid> --confirm
```

`cleanup-unclaimed` does not scan all of `Library/Containers` to guess ownership. Incomplete ownership records prevent cleanup. Confirming selected identities permanently deletes their task data. Refused system-shell removal produces `data-removed-shell-retained`. Results are written to `cleanup_audit`; incomplete cleanup causes CLI exit code 1.

`Data/Desktop`, `Downloads`, and similar entries are standard macOS directory links, without additional authorization. Deletion only unlinks them and never follows them to delete the actual Desktop or Downloads. Shell inspection accepts only the fixed system layout; unknown files cause rejection.

macOS may refuse background deletion of container shells. `cleanup-deleted` can check and attempt cleanup again but cannot repair system permissions. The App does not elevate privileges or change system security settings automatically.

Show in Finder in the deletion result window selects that operation's confirmed container directories. The full physical bundleID in a deletion warning can also be passed to the CLI, rather than a logical `sbx-...` ID:

```sh
# Preview paths without opening Finder
"$BIN/sandboxctl" sandbox reveal-containers local.metal-sandbox.instance-<uuid> --preview
# Select in Finder; multiple complete bundleIDs are accepted
"$BIN/sandboxctl" sandbox reveal-containers local.metal-sandbox.instance-<uuid>
```

These commands only locate containers without deleting or moving them; missing directories are skipped. They do not follow symlinks to other paths and do not require stopping other instances or restarting the service.

For manual cleanup, handle only containers **already emptied and listed exactly** in deletion warnings. Verify the full name in Finder before moving that item to Trash, then use Delete Immediately on that item if needed. Do not select everything by prefix, empty unrelated Trash contents, or delete real directories targeted by links. Moving to Trash is recoverable; Delete Immediately is irreversible and still not secure disk erasure.

Service restarts do not replay processes automatically. Unfinished instance/execution records become `interrupted`. On an abnormal manager exit, the Host cancels its running subprocesses through EOF on the private pipe, retaining original active leases. PIDs are records only; historical PIDs are not used to kill processes blindly.

Confirm recovery only after manually inspecting remaining processes and GPU state. No ordinary task commands may be running during recovery; connected agent sessions and waiting commands may remain. Stop disconnected instances first:

```sh
"$BIN/sandboxctl" sandbox recover --confirm-processes-cleaned --note 'enter_actual_inspection_results'
```

During quarantine, commands from existing instances remain waiting without consuming execution budgets and can still be cancelled. Manual recovery resumes the original queue without restarting connected agent sessions. Failed commands, exited agents, and deleted instances are not replayed or rebuilt automatically.

Recovery archives invalid leases and inspection notes while retaining active leases for normal agent sessions. Ordinary scoped agents have no recovery permission. Command-result `cleanupDiagnostics` records process-group query counts and error codes from queries and termination signals.

## 7. Agent/Verifier and Scoped API

```sh
"$BIN/sandboxctl" sandbox grant <id> --operations read,write,export,exec --out /absolute/path/handle.json
"$BIN/sandboxctl" sandbox --handle /absolute/path/handle.json exec <id> -- echo scoped
```

A Handle is a management-API credential; it does not change file permissions in Finder, Terminal, or instance processes. Give it only to trusted tool adapters, without passing it to candidates. See [Task Packages and Verification](task_packages.md).

## 8. Current Limitations

See [Release Scope](../README.md#release-scope) for current features and omissions. This release does not guarantee complete cleanup of arbitrary malicious process trees or abnormal GPU work. Do not use it for untrusted tasks.

The [graphical interface](frontend.md) calls the same CLI. App/DMG builds use local ad-hoc signing without completed Developer ID notarization. Exiting the frontend does not stop the service; shut down the management service normally before uninstalling. Deleting the App does not delete instances or workspaces.

## Names

```sh
"$BIN/sandboxctl" sandbox create --count 3 --name "Poison Mushrooms"
# Names: Poison Mushrooms (1), Poison Mushrooms (2), Poison Mushrooms (3)
"$BIN/sandboxctl" sandbox rename "$ID" "My Experiment"
"$BIN/sandboxctl" sandbox rename "$ID" ""  # Clear the name
```

Names are optional display information and need not be unique; they are not IDs or directory names. `list`/`inspect` returns `name`, and `list -h` shows the full ID and name. Renaming requires no instance startup or restart of running commands. Leading and trailing whitespace is removed, and names must be single-line.

## Try Serial Scheduling

Start the service and confirm no unfinished commands, then run from the source root:

```sh
python3 examples/demo_gpu_queue.py
```

The script creates two instances, uploads the same `metal_queue.mm` to each workspace, compiles it, and submits two consecutive Metal tasks of about 20 seconds. Command Line Tools or Xcode is required, without the offline Metal Toolchain.

With no other submissions, Overview's unfinished count is **2 → 1 → 0**: A runs/B queues, then B runs, then both finish. The script verifies nonoverlapping start/end times without detecting GPU calls. Other parallel tasks and system applications may use the GPU; keep the machine idle during the demonstration.

Instances and `gpu_queue_demo/` files remain. To reuse two active instances:

```sh
python3 examples/demo_gpu_queue.py --sandbox-a sbx-AAAA --sandbox-b sbx-BBBB --seconds 20
```

Reuse overwrites matching files in the demo directory. `--cli` specifies sandboxctl installed elsewhere. Interrupting the observation script does not cancel submitted tasks; stop or delete these two instances normally afterward.
