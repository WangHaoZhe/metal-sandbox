# Task Packages and Preparation Scripts

**We recommend [Harbor](harbor.md) for running Agent tasks.** Harbor manages task selection, Agent startup, verification, and result collection.

This guide describes the task-package format used directly with the Metal Sandbox App or CLI, and the workflow for importing packages, running `setup.sh`, starting Agents, and verifying results.

## Task Package Format

Each task is a separate folder with `agent/` and `tests/`. Select the package root for import; compression is unnecessary:

```text
agent/
  instruction.md        Task, constraints, deliverables (nonempty UTF-8 file)
  setup.sh              Preparation script (nonempty UTF-8 file)
  public_tools.cpp      Optional public tools
  public_tools.md       Optional tool documentation
  fixtures/             Optional public inputs and reference data
tests/
  test.sh               Verification entry; tests/ may be absent or empty if verification is not provided
  ...                   Checkers and verification data
```

The App imports, displays, and runs `setup.sh` without built-in agent installation scripts or choosing a model for the package. `setup.sh` can use any tool or harness, or only prepare the environment without starting an agent. Its entry is fixed at `/bin/sh ./setup.sh`, with the workspace root as its working directory.

Import copies `agent/` contents, including hidden files, into the workspace root without retaining the `agent/` layer. It also archives `tests/` in the backend data directory, copying it into the workspace only for verification. Import neither executes scripts nor modifies the source directory. Public content must exclude existing answers, build artifacts, trajectories, account configuration, and real API keys. Links and special files are unsupported.

Task-package import accepts folders only, not ZIPs. Extract received archives yourself and select the package root containing `agent/` and `tests/`. Workspace snapshot ZIP import/export is a separate, unaffected feature.

Bundled examples include [Metal Bloom](../examples/tasks/metal_bloom/agent/instruction.md) and [fifth-order poison-mushroom Mandelbulb](../examples/tasks/metal_poison_mushroom/agent/instruction.md). The latter is an offscreen rendering task without a frame-rate threshold. Select the corresponding task-package root for import.

## Graphical Interface

1. Open Create Sandbox and choose the number of copies. Allow Outbound Networking is selected by default.
2. Click Import Task Package in the window and select the package root, such as `examples/tasks/metal_poison_mushroom`, rather than its `agent/` subdirectory.
3. The window expands and loads `agent/setup.sh`. Enter required configuration in the expandable Environment Variables table, check the script, and set the preparation timeout. Packages with `tests/test.sh` enable Automatic Verification After Completion by default, with a separate verification timeout.
4. Click Create and Run Preparation. Each copy imports the package, saves the current script, and submits execution. To import without executing, clear the preparation script and click Create. Do not modify the source directory before creation finishes.
5. View sessions in Trajectory and execution results in Activity. Verification shows automatic-verification status and results. Closing the frontend does not affect backend execution.

Existing instances can use Preparation → Import Task Package. This imports and reads files without automatic execution; click Save and Run Preparation afterward.

Load Script can select a file manually, or edit it directly. The task package determines what the script executes, how it installs tools, and where it saves logs; the frontend does not.

## CLI

With the service already running, execute from the project root:

```sh
BIN="/Applications/Metal Sandbox.app/Contents/Helpers"
"$BIN/sandboxctl" sandbox create --count 1
ID='sbx-replace_with_returned_id'
"$BIN/sandboxctl" sandbox import "$ID" --from examples/tasks/metal_bloom --task
# Configure setup.sh as required by the package, then execute:
"$BIN/sandboxctl" sandbox exec "$ID" --session --timeout 7200 -- /bin/sh ./setup.sh
```

`--task` accepts task-package directories only. Before import, it checks that `agent/instruction.md` and `agent/setup.sh` both exist, are nonempty, and are not links. Missing files are not substituted from the old workspace, and nothing is written. Only `agent/` contents are packaged in chunks by the CLI and transferred into the sandbox. The frontend does not access sandbox files directly. Ordinary snapshot import omits this option and accepts only ZIP snapshots.

Import merges and overwrites matching paths without clearing the previous answer; use a new instance for a new task. Write failures can leave partial changes without automatically undoing them. Preparation scripts cannot read the host's task-package directory directly; the control machine imports the entire package through the CLI.

## Verifying Answers

After importing a package with `tests/test.sh`, `exec --session` and frontend preparation automatically register subsequent verification. Once the preparation script and associated instance tasks exit with confirmed cleanup, the backend replaces the entire `tests/` directory and submits the test. Nonzero agent exits and timeouts with confirmed cleanup also verify existing artifacts. Explicit cancellation or stopping cancels subsequent automatic verification. Quarantine, uncertain cleanup, or unconfirmed agent exit displays a blocked state.

Tests are archived at `~/Library/Application Support/MetalSandbox/native/test_packages/<content SHA-256>/tests.zip`. Copies with identical content share the archive. Moving or modifying the original package does not affect registered tasks. Each agent execution retains its own test version and verification timeout.

Preparation can adjust Automatic Verification After Completion and its timeout; saving affects later submissions. CLI configuration:

```sh
"$BIN/sandboxctl" sandbox verification "$ID"
"$BIN/sandboxctl" sandbox verification "$ID" --enabled true --timeout 600
"$BIN/sandboxctl" sandbox verification "$ID" --enabled false
```

Run Verification in the Verification tab manually runs saved tests. Choose Task Package can specify a different test package for that run.

The CLI uses the same flow:

```sh
# Specify the package for this verification; omit --from to prefer saved tests
"$BIN/sandboxctl" sandbox verify "$ID" --from examples/tasks/metal_poison_mushroom --timeout 600 --detach
# Use returned execution.id to view results or cancel
"$BIN/sandboxctl" sandbox wait EXECUTION_ID
"$BIN/sandboxctl" sandbox cancel EXECUTION_ID
# Add automatic verification to an agent execution without registered verification
"$BIN/sandboxctl" sandbox verify "$ID" --after AGENT_EXECUTION_ID --detach
```

The entry is `/bin/bash ./test.sh`, with `workspace/tests` as the working directory. Exit code 0 means this test passed; nonzero means failure. Timeout, cancellation, and execution errors do not pass. Omitting `--detach` waits and returns the test's exit code. Verification always enters the execution node's serial queue, with timeout counting from actual execution. From test installation through result saving, the instance permits reads only; other instances may continue parallel commands. Manual verification requires a started, idle instance.

Agent and verification executions have separate IDs, states, exit codes, and stdout/stderr. Generated `tests/metrics.json` is saved separately in backend `verification_results/<verification execution ID>.zip`. Records remain viewable after reopening the App, including Sandbox ID filtering in Activity.

After a service restart, verification whose agent completion was confirmed but which has not yet been submitted continues processing. Already-submitted verification does not start twice. Interrupted executions retain that state and require manual inspection. Tests leave the instance and workspace intact.

`agent/` is task input and `tests/` is verification input; their import paths are separate. Ordinary workspace snapshots retain all existing files, so clean the test directory before cloning a task environment from a snapshot containing tests. Deferred injection avoids early exposure, but verification in the same instance does not provide tamper-resistant isolation.

**Test-script convention:** Keep the original answer read-only. Put working copies, build artifacts, temporary directories, caches, and results under `tests/`. Do not run build scripts that create files in the original answer directory directly. The poison-mushroom package follows this convention. The framework does not transform arbitrary scripts into read-only programs; same-instance verification does not provide independent isolation against malicious answers.

## Metal Bloom Task Package Example

[Metal Gaussian Blur + Bloom](../examples/tasks/metal_bloom/agent/instruction.md) includes 15 public input/reference sets and requires native Metal compute and offscreen rendering without a display, measuring and optimizing throughput and frame time at 1920×1080.

Its [setup.sh](../examples/tasks/metal_bloom/agent/setup.sh) installs Node 24.19.0 and the official Claude Code 2.1.112 npm package in private HOME, passing the complete `instruction.md` as the prompt through stdin. The poison-mushroom package uses the same script. Edit or replace it when changing harnesses; imported instances can load and save an updated script in Preparation.

Enter these variables in the creation window or Settings and Snapshots; the script need not be edited:

| Key | Value |
| --- | --- |
| ANTHROPIC_API_KEY | Your API key |
| ANTHROPIC_BASE_URL | `https://api.anthropic.com`, or your service URL |
| ANTHROPIC_MODEL | Actual model name, for example `claude-opus-4-8` |
| CLAUDE_LOCAL_PACKAGE | Optional uploaded official Claude npm `.tgz`, for example `vendor/claude.tgz` |
| CLAUDE_NODE_BINARY | Optional uploaded macOS arm64 Node native executable, for example `vendor/node` |

The script preserves injected values and uses Claude's default model if the model field is empty. It does not load user settings, only the runtime-provided command-scheduling hook configuration. Without a key, it installs tools and asks you to set environment variables without starting an agent. Rerunning reuses correctly versioned installations but starts a new session without automatically continuing the previous one.

**Environment configuration is excluded from workspace snapshots. If you write a key into the script yourself, it will still be exported in snapshots and must be removed before sharing.** Do not use `set -x` or print credentials.

Preparation timeout includes installation and the entire task session; allow enough time. The script uses `--dangerously-skip-permissions` to disable Claude tool confirmations without removing macOS App Sandbox restrictions, only for authorized trusted local development.

The script integrates [Claude Bash Command Scheduling](native_operations.md#agent-sessions-and-tool-commands): the main session runs in parallel, and each Bash call follows the instance allowlist/denylist to execute directly or serially. This does not detect GPU usage automatically. Other packages must configure the adapter in their own scripts.

Complete trajectories are stored in private `$HOME/.claude/rollouts/<session>/events.jsonl`, alongside `stderr.log` and `exit.json`; the script prints this path. Claude's own sessions remain in `$HOME/.claude/`. Private HOME is excluded from workspace snapshots; save separately if needed. The sandbox remains after agent exit.

### Using Local Claude Installation Files

Download and SHA-256 verification commands are in the package's `agent/vendor/README.md`:
[Metal Bloom](../examples/tasks/metal_bloom/agent/vendor/README.md),
[Poison Mushrooms](../examples/tasks/metal_poison_mushroom/agent/vendor/README.md).

Local installation uses the official Claude Code 2.1.112 npm `.tgz` and the macOS arm64 native Node 24.19.0 executable. Extract Node first and upload its regular `bin/node` file.

1. Place both files at `agent/vendor/claude.tgz` and `agent/vendor/node` in the package, then import it.
2. Set instance variables `CLAUDE_LOCAL_PACKAGE=vendor/claude.tgz` and `CLAUDE_NODE_BINARY=vendor/node`.
3. Run preparation. The script checks actual versions, installs into private `$HOME/.local/share/claude_code/2.1.112_node_24.19.0/`, and starts `cli.js` with Node.

Upload files to existing instances through the CLI:

```sh
"$BIN/sandboxctl" sandbox write "$ID" vendor/claude.tgz --from /path/to/claude_code_2.1.112.tgz
"$BIN/sandboxctl" sandbox write "$ID" vendor/node --from /path/to/node-v24.19.0-darwin-arm64/bin/node
# Set the two instance variables above, then run preparation
```

Paths may be absolute paths with spaces or workspace-relative paths. They are read literally without expanding `~` or `$HOME`. Upload host files first; environment variables themselves do not grant access to host directories.

If a local file is omitted, the script downloads that component's pinned official version. Invalid files or mismatched versions fail immediately. Existing correct versions reuse the private installation and retain source installation files. Workspace packages enter snapshots; tools in private HOME are removed with the instance. Model calls still require networking and credentials.

## Choosing a Harness Preparation Script

The [Harness Examples](../examples/harnesses/README.md) provide three scripts. Copy the chosen script to task `agent/setup.sh` and run through the App's Preparation tab or `exec --session`:

| Harness | Script | Attachments and configuration |
|---|---|---|
| Claude Code | [claude_setup.sh](../examples/harnesses/claude_setup.sh) | `instruction.md`; optional local Claude npm package and Node |
| Codex | [codex_setup.sh](../examples/harnesses/codex_setup.sh) | `instruction.md`, `codex_config.toml`; optional two local native files |
| mini-swe-agent | [mini_swe_agent_setup.sh](../examples/harnesses/mini_swe_agent_setup.sh) | `instruction.md`, `mini_config.yaml`, `mini_swe_agent_metal.py`, Python and dependency archive |

When running through Harbor, Harbor installs all three, without copying these scripts. See [Harbor Configuration](harbor.md).

## Using the Codex Preparation Script

Copy [codex_setup.sh](../examples/harnesses/codex_setup.sh) to task `agent/setup.sh` and provide `instruction.md` and `codex_config.toml`. The latter configures model, provider, Responses API URL, and `env_key = "OPENAI_API_KEY"`. Set `OPENAI_API_KEY` in the instance environment.

The script uses Codex 0.162.1. Upload two extracted native files and set `CODEX_LOCAL_PACKAGE` and `CODEX_LOCAL_CODE_MODE_HOST` for instance installation; omitted files are downloaded from the pinned official release. Tools are stored at `$HOME/.local/share/codex/0.162.1/`, sessions at the instance's `~/.codex/sessions`, viewable in the App's Trajectory tab. See [Codex Startup](native_operations.md#codex) for commands.

## Using the mini-swe-agent Preparation Script

Copy [mini_swe_agent_setup.sh](../examples/harnesses/mini_swe_agent_setup.sh) to task `agent/setup.sh` and provide [mini_config.yaml](../examples/harnesses/mini_config.yaml), [mini_swe_agent_metal.py](../examples/harnesses/mini_swe_agent_metal.py), and `instruction.md`. Upload a complete Python and dependency archive for mini-swe-agent 2.4.6. Set `MINI_SWE_AGENT_LOCAL_BUNDLE`, `MINI_SWE_AGENT_BUNDLE_SHA256`, `MINI_SWE_AGENT_MODEL`, and the provider API key.

Model URLs and sampling parameters belong in `mini_config.yaml`. Tools install into the instance's private directory, and `MetalEnvironment` submits shell commands to the management service. Logs and raw trajectories are saved in workspace `mini_swe_agent_runs/<session>/`. See [Harness Examples](../examples/harnesses/README.md#mini-swe-agent) for archive format.

## Artifacts and Records

| Data | Access |
|---|---|
| Source, rendered output, test output | Workspace; use Files or CLI read/export |
| Claude/Codex sessions | Private HOME; view through Trajectory |
| mini-swe-agent sessions | Workspace `mini_swe_agent_runs/<session>/trajectory.json`; use Files or CLI export |
| Command status, exit codes, output | Backend executions; use Activity or CLI executions/execution |
| Workspace recovery point | Save Snapshot or CLI snapshot, saved as ZIP |

Environment variables are stored per instance and excluded from workspace snapshots. Credentials explicitly printed or written by a script can still enter logs or snapshots.

Starting the original instance preserves ID, workspace, and private HOME. Snapshot cloning copies only the workspace, requiring preparation of HOME tools again. Separately exported ZIPs are not removed with the instance.
