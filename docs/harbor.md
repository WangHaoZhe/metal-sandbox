# Run tasks with Harbor

Harbor selects tasks, starts Agents, runs verification, and saves results. Metal Sandbox provides instances, file operations, and command scheduling. Each task run is a trial with an independent Sandbox; a Job can contain multiple trials.

Claude Code, Codex, and mini-swe-agent are supported. Harbor installs the selected harness inside each instance and schedules every shell tool command through Metal Sandbox. This guide provides installation and execution configurations for all three.

## 1. Prepare the environment

1. Install Metal Sandbox and the development tools required by your tasks using the [installation guide](installation.md).
2. Open the App and start the management service. Harbor and the service must run on the same Mac under the same user account.
3. Prepare the `harbor-metalsandbox` repository, which adapts official Harbor v0.25.0 to Metal Sandbox. Run all commands below from the **Harbor source root**.

Your terminal needs Git and uv. With Homebrew, install uv and then Harbor's dependencies:

```sh
brew install uv
cd /path/to/harbor
uv sync --no-default-groups --python 3.13
uv run --no-default-groups harbor --help
```

Replace `/path/to/harbor` with your source directory. Dependency installation requires access to the package sources configured by that repository.

Confirm the service is running:

```sh
"/Applications/Metal Sandbox.app/Contents/Helpers/sandboxctl" sandbox status
```

The service must support per-command environment variables and queue-wait exclusion; Harbor checks these before creating instances. Follow the [update instructions](installation.md#update-the-app) when updating the App.

## 2. Prepare a Harbor task package

Place tasks in `datasets/`, with one directory per task, such as `datasets/my_metal_task/`:

| Path | Contents |
|---|---|
| `instruction.md` | Task instructions read by Harbor and passed to the Agent |
| `task.toml` | OS, working directory, time budgets, artifacts, and verification settings |
| `environment/` | Public files uploaded at instance creation; may be empty |
| `environment/work/` | Initial code and attachments for the configuration below |
| `environment/setup.sh` | Optional environment initialization script executed at the workspace root |
| `tests/test.sh` | Verification entry point, uploaded and run after the Agent phase |
| Other files in `tests/` | Verification dependencies and data |

Create the directories:

```sh
mkdir -p configs datasets/my_metal_task/environment/work datasets/my_metal_task/tests
```

Example `task.toml`:

```toml
schema_version = "1.3"

[[artifacts]]
source = "work"
destination = "workspace"

[task]
name = "local/my_metal_task"

[environment]
os = "macos"
network_mode = "public"
workdir = "work"
build_timeout_sec = 600

[agent]
timeout_sec = 3600

[verifier]
timeout_sec = 3600
environment_mode = "shared"
```

- `workdir = "work"` places the Agent in the workspace's `work/` subdirectory. Omit it to use the workspace root.
- `artifacts` selects exported files; this example saves `work/` as `artifacts/workspace/` in the trial. Omitting it does not automatically export the entire workspace.
- `environment/` is uploaded to the workspace root. Its initialization script prepares only the task environment; Harbor installs and starts the Agent.
- `network_mode = "public"` permits tool installation and model access.
- `shared` verifies in the original instance. `separate` creates a verification instance while retaining the Agent workspace and HOME and releasing its active slot. Configure artifacts explicitly when using separate verification.

To reuse a [Metal Sandbox task package](task_packages.md), put `agent/instruction.md` at the Harbor task root, public code and attachments under `environment/work/`, and keep tests at the task root. Adjust paths and reward output as described below. Do not copy the task's harness installation/startup script; retain only necessary environment preparation in `environment/setup.sh`.

### Verification script

`tests/test.sh` checks the implementation and writes a numeric reward to `$HARBOR_VERIFIER_DIR/reward.txt` or a metrics dictionary to reward.json. It can write 1 for success or 0 for failure. An exit code without a reward file is considered incomplete output by Harbor.

| Variable | Purpose |
|---|---|
| `HARBOR_WORKSPACE_DIR` | Workspace root; Agent artifacts in this example are in its work subdirectory |
| `HARBOR_TESTS_DIR` | Uploaded verification files |
| `HARBOR_VERIFIER_DIR` | Rewards, metrics, and verifier logs |

Tests are uploaded only during verification. Harbor disables Metal Sandbox's automatic verification and controls verification timing and records itself.

## 3. Set API keys

Create `.env` at the Harbor root and edit its contents:

```sh
touch .env
chmod 600 .env
```

```dotenv
ANTHROPIC_API_KEY="your API key"
ANTHROPIC_BASE_URL="https://your-model-service"
OPENAI_API_KEY="your API key"
OPENAI_BASE_URL="https://your-model-service/v1"
```

Claude uses the Messages API, Codex uses the Responses API, and mini-swe-agent selects its protocol from model_name's provider and configuration. Fill only the credentials and endpoint used by your selected harness.

Exclude .env from Git; the Harbor source repository already ignores it. Keep API keys in .env rather than tasks, preparation scripts, or mini configuration.

### Harness installation

Claude Code and Codex examples use `runtime_source: uploaded_bundle`, with absolute paths, SHA-256, and versions of files prepared on the controller in runtime_artifacts. The mini-swe-agent example specifies only version; Harbor downloads and installs that version and a Python runtime inside the instance. All three install in private instance directories. Deleting the instance removes the tools without changing host installations. Replace `/path/to/...` with actual paths; kwargs do not expand `${VAR}`.

| Harness | Artifact keys, each with darwin_arm64 | File |
|---|---|---|
| Claude Code | runtime_bundle, node_bundle | Official Claude npm .tgz and extracted macOS arm64 Node executable |
| Codex | runtime_bundle, code_mode_host | Extracted macOS arm64 Codex and matching Code Mode companion |

Check digests with `shasum -a 256 /path/to/file`. Update version and SHA-256 together when replacing Claude or Codex packages; Claude also requires node_version. Changing mini-swe-agent version selects its installation version.

## 4. Configure the Agent and Job

### mini-swe-agent

Save as `configs/mini.yaml`:

```yaml
agent:
  step_limit: 0
  cost_limit: 1000
environment:
  timeout: 600
model:
  model_kwargs:
    num_retries: 30
    timeout: 5000
    thinking:
      type: adaptive
    output_config:
      effort: max
    max_tokens: 128000
```

Save as `configs/rollout.yaml`:

```yaml
jobs_dir: jobs
n_attempts: 1
timeout_multiplier: 16.0
n_concurrent_trials: 8
quiet: true

retry:
  max_retries: 0
  preserve_failed_attempts: false
  exclude_exceptions:
    - VerifierOutputParseError
    - RewardFileNotFoundError
    - AgentTimeoutError
    - RewardFileEmptyError
    - VerifierTimeoutError

environment:
  type: metal-sandbox
  force_build: false
  delete: false
  kwargs:
    cli_path: /Applications/Metal Sandbox.app/Contents/Helpers/sandboxctl

agents:
  - name: mini-swe-agent
    model_name: anthropic/claude-opus-4-8
    env:
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY}
    kwargs:
      version: "2.4.6"
      config_file: configs/mini.yaml
      cost_limit: "1000"
      litellm_model_registry:
        claude-opus-4-8:
          supports_reasoning: true
          supports_adaptive_thinking: true
          supports_output_config: true
          supports_max_reasoning_effort: true
          supports_xhigh_reasoning_effort: true

datasets:
  - path: .
```

Change model endpoints and names to match your service. Thinking, output_config, max_tokens, and capability declarations must also match the selected model.

With environment.kwargs.dynamic_scheduling enabled, shared-workspace tool commands from Claude Code, Codex, and mini-swe-agent can migrate under cluster policy. Model clients and private dependencies stay on their owner node. User tool environments are retained; commands depending on private files or programs remain on their owner node.

### Claude Code

Use the Job, environment, and task settings above and replace the complete agents section with:

```yaml
agents:
  - name: claude-code
    model_name: claude-opus-5
    env:
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY}
      ANTHROPIC_BASE_URL: ${ANTHROPIC_BASE_URL}
    kwargs:
      version: "2.1.112"
      node_version: "24.19.0"
      runtime_source: uploaded_bundle
      runtime_artifacts:
        runtime_bundle:
          darwin_arm64:
            path: /path/to/runtimes/claude_code_2.1.112.tgz
            sha256: 84379969ea53a0e5fd231a8f77debe4c7cb17dd971f4809d10d33f9aeca5de09
            version: "2.1.112"
        node_bundle:
          darwin_arm64:
            path: /path/to/runtimes/node
            sha256: 27db838bb204ef7c21df2931f5656e4c8fb32e6e947f363a402b49714d32b5b1
            version: "24.19.0"
```

### Codex

Use the same Job, environment, and task settings and replace the complete agents section with:

```yaml
agents:
  - name: codex
    model_name: openai/gpt-6-astra
    env:
      OPENAI_API_KEY: ${OPENAI_API_KEY}
      OPENAI_BASE_URL: ${OPENAI_BASE_URL}
    kwargs:
      version: "0.162.1"
      runtime_source: uploaded_bundle
      runtime_artifacts:
        runtime_bundle:
          darwin_arm64:
            path: /path/to/runtimes/codex
            sha256: 74c6a6d263f40d65f99c27a815275f5b4ed0bcc2baecc396b4cf3255498bdfc0
            version: "0.162.1"
        code_mode_host:
          darwin_arm64:
            path: /path/to/runtimes/codex-code-mode-host
            sha256: 0960435a104cf926e18bb938b8f6f8fcdf7e27be0c8d88e1911bc22a1de7d3e6
            version: "0.162.1"
      disable_code_mode: true
      web_search: disabled
```

Harbor provides complete single-task configurations in examples/configs/claude_metal_job.yaml, codex_metal_job.yaml, and mini_swe_agent_metal_job.yaml. Set model names to your service's actual identifiers.

### Concurrency, attempts, and time budgets

| Setting | Meaning |
|---|---|
| n_concurrent_trials | Maximum simultaneous trials; 8 here |
| n_attempts | Independent runs of each task; 1 here, so three tasks yield three trials |
| datasets[].task_names | Optional task directory names; omission runs all tasks in the directory |
| task.toml agent.timeout_sec | Base Agent budget; 3,600 seconds here, or 16 hours after scaling |
| task.toml verifier.timeout_sec | Independent verifier budget; 16 hours after scaling in this example |
| timeout_multiplier | Harbor phase-budget multiplier; 16.0 here |
| mini.yaml environment.timeout | Individual shell-command execution budget; 600 seconds here, unaffected by the multiplier |
| step_limit: 0 | No Agent step limit; other budgets remain active |

Metal Sandbox deducts scheduling waits; actual execution and model waiting still consume the corresponding phase budget. Main Agent sessions can overlap; shell tools follow each instance's allowlist or denylist.

Retries have two levels: num_retries controls mini model-client retries; retry.max_retries controls whole-trial retries. This example uses 30 and 0 respectively.

## 5. Start the Job

Run from the Harbor source root. `--path datasets` replaces the configured task path with datasets/. The .env, configs, and jobs directories are all at that source root:

```sh
uv run --no-default-groups harbor run \
  --env-file .env \
  --config configs/rollout.yaml \
  --path datasets \
  --job-name "metal_$(date +%Y%m%d_%H%M%S)" \
  --yes
```

Harbor creates instances, uploads environment files, installs and starts the Agent, then verifies and exports results. The App sidebar displays instances named after their trials; no separate Run Preparation action is needed.

Delete=false stops and retains instances after trials; select Start Instance in the App to inspect them. Delete=true removes instances after result collection. Incomplete instances from initialization failures are cleaned up.

Press Ctrl+C in the Harbor terminal to stop this Job manually. Do not shut down the shared Metal Sandbox service.

## 6. Results and trajectories

Jobs are stored under `jobs/<job-name>/`, with separate trial subdirectories:

| File or directory | Contents |
|---|---|
| Job-root result.json | Batch statistics |
| Trial result.json | Phase times, exceptions, and verification results |
| agent/claude-code.txt | Claude Code output |
| agent/codex.txt | Codex output |
| agent/mini-swe-agent.txt | Readable Agent output |
| agent/mini-swe-agent.trajectory.json | Native mini conversation and tool calls |
| verifier/ | Rewards, verifier output, and metrics |
| artifacts/workspace/ | Code and artifacts exported by the artifacts configuration |

The Metal Sandbox App's Trajectory page reads Claude/Codex sessions. View mini trajectories in the log files above.

Reward meaning is defined by tests/test.sh. For example, smoke_pass:1 indicates only that the script's smoke checks passed. Assessing the full task requires corresponding verification coverage.
