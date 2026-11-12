# 使用 Harbor 运行任务

Harbor 负责选择题目、启动 Agent、运行验收和保存结果；Metal Sandbox 提供实例、文件操作和命令调度。每次题目运行称为一个 trial，对应一个独立 Sandbox；一次 Job 可以包含多个 trial。

支持 Claude Code、Codex 和 mini-swe-agent。Harbor 在每个实例内安装所选 harness，并将每条 shell 工具命令交给 Metal Sandbox 调度。本文分别给出三者的安装与运行配置。

## 1. 准备环境

1. 按[安装指南](installation.md)安装 Metal Sandbox 和题目需要的开发工具。
2. 打开 App，启动管理服务。Harbor 与管理服务需要使用同一台 Mac、同一个用户账号。
3. 准备基于 Harbor 官方 v0.25.0 适配 Metal Sandbox 的 `harbor-metalsandbox` 仓库。下文命令均在 **Harbor 源码根目录**执行。

终端需要 Git 和 uv。使用 Homebrew 时可这样安装 uv，再安装 Harbor 依赖：

```sh
brew install uv
cd /path/to/harbor
uv sync --no-default-groups --python 3.13
uv run --no-default-groups harbor --help
```

将 `/path/to/harbor` 替换为源码目录。安装依赖需要访问该 Harbor 仓库配置的软件源。

确认服务已经启动：

```sh
"/Applications/Metal Sandbox.app/Contents/Helpers/sandboxctl" sandbox status
```

服务需要支持单次命令环境变量和排队时间扣除；Harbor 会在创建实例前检查。需要更新 App 时，按[更新说明](installation.md#更新-app)操作。

## 2. 准备 Harbor 题包

将题包放入 `datasets/`，每道题一个文件夹。例如 `datasets/my_metal_task/`：

| 路径 | 内容 |
|---|---|
| `instruction.md` | 题目正文，Harbor 读取后传给 Agent |
| `task.toml` | 系统、工作目录、时间预算、产物和验收设置 |
| `environment/` | 创建实例时上传的公开文件，可以为空 |
| `environment/work/` | 使用下方配置时，放置 Agent 的初始代码和附件 |
| `environment/setup.sh` | 可选的环境初始化脚本，在工作区根目录执行 |
| `tests/test.sh` | 验收入口，Agent 阶段结束后才上传和执行 |
| `tests/` 中的其他文件 | 验收依赖和测试数据 |

创建必要目录：

```sh
mkdir -p configs datasets/my_metal_task/environment/work datasets/my_metal_task/tests
```

`task.toml` 示例：

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

- `workdir = "work"` 让 Agent 在工作区的 `work/` 子目录工作。省略时使用工作区根目录。
- `artifacts` 指定导出的文件；上述配置会把 `work/` 保存到 trial 的 `artifacts/workspace/`。省略它不会自动导出整个工作区。
- `environment/` 内容上传到工作区根目录。初始化脚本只准备任务环境；Agent 的安装和启动由 Harbor 负责。
- `network_mode = "public"` 允许安装工具和访问模型服务。
- `shared` 在原实例验收；`separate` 会创建验收实例，期间保留 Agent 实例的工作区和 HOME 并释放其活跃槽位。采用 `separate` 时需明确配置产物，供验收使用。

复用 [Metal Sandbox 题包](task_packages.md)时，将 `agent/instruction.md` 放到 Harbor 题包根目录，公开代码和附件放到 `environment/work/`，`tests/` 保留在题包根目录并按下文调整目录与奖励输出。题包中安装并启动 Agent 的 `setup.sh` 不需要复制；只将必要的环境准备操作保留到 `environment/setup.sh`。

### 验收脚本

`tests/test.sh` 负责实际检查实现，并向 `$HARBOR_VERIFIER_DIR/reward.txt` 写入数值奖励，或向 `reward.json` 写入指标字典。验收成功后可写入 `1`，失败时写入 `0`；只有脚本退出码，没有奖励文件，会被 Harbor 视为结果不完整。

脚本可通过以下变量访问目录：

| 变量 | 用途 |
|---|---|
| `HARBOR_WORKSPACE_DIR` | 工作区根目录；上述 Agent 产物位于其 `work/` 子目录 |
| `HARBOR_TESTS_DIR` | 上传后的验收文件目录 |
| `HARBOR_VERIFIER_DIR` | 奖励、指标和验收日志目录 |

测试仅在验收阶段上传。Harbor 创建的实例会关闭 Metal Sandbox 自带的自动验收，由 Harbor 控制验收时机和记录。

## 3. 填写 API key

在 Harbor 根目录创建 `.env`，用文本编辑器填写内容：

```sh
touch .env
chmod 600 .env
```

```dotenv
ANTHROPIC_API_KEY="填入你的 API key"
ANTHROPIC_BASE_URL="https://你的模型服务"
OPENAI_API_KEY="填入你的 API key"
OPENAI_BASE_URL="https://你的模型服务/v1"
```

Claude 使用 Messages API；Codex 使用 Responses API；mini-swe-agent 按 `model_name` 的 provider 和模型配置选择协议。只需填写所选 harness 使用的凭据与地址。

`.env` 应排除在 Git 之外；Harbor 源码仓库已忽略此文件。API key 放在 `.env`，避免写入题目、准备脚本或 mini 配置。

### Harness 安装

Claude Code 和 Codex 的示例使用 `runtime_source: uploaded_bundle`，`runtime_artifacts` 填写控制端已准备文件的绝对路径、SHA-256 和版本。mini-swe-agent 的示例只指定 `version`，由 Harbor 在实例内自动下载并安装对应版本及 Python 运行时。三者均安装在实例私有目录，删除实例时同时删除工具，不修改宿主安装。下方 `/path/to/...` 须替换为实际路径，配置的 `kwargs` 不展开 `${VAR}`。

| Harness | 制品键（均含 `darwin_arm64`） | 文件 |
|---|---|---|
| Claude Code | `runtime_bundle`、`node_bundle` | 官方 Claude npm `.tgz`、解压后的 macOS arm64 Node 文件 |
| Codex | `runtime_bundle`、`code_mode_host` | 解压后的 macOS arm64 Codex 和同版本 Code Mode companion |

用 `shasum -a 256 /path/to/file` 核对校验值。替换 Claude 或 Codex 安装包时，同时修改版本和 SHA-256；Claude 还需修改 `node_version`。mini-swe-agent 修改 `version` 即可选择安装版本。

## 4. 配置 Agent 和 Job

### mini-swe-agent

保存以下内容为 `configs/mini.yaml`：

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

保存以下内容为 `configs/rollout.yaml`：

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

模型地址和名称按实际服务修改；`thinking`、`output_config`、`max_tokens` 和能力声明也需要符合所选模型。

开启 `environment.kwargs.dynamic_scheduling` 后，Claude Code、Codex 和 mini-swe-agent 的共享工作区工具命令可按集群策略迁移。模型客户端及其私有依赖留在实例归属节点；用户指定的工具环境继续保留，依赖私有文件或程序的命令在归属节点执行。

### Claude Code

使用上面的 Job、环境和题包设置，将整个 `agents` 项替换为：

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

使用同一套 Job、环境和题包设置，将整个 `agents` 项替换为：

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

Harbor 仓库的 `examples/configs/claude_metal_job.yaml`、`codex_metal_job.yaml`、`mini_swe_agent_metal_job.yaml` 提供三者各自完整的单题配置。按服务实际标识修改模型名称。

### 并发、重复次数与时间预算

| 设置 | 含义 |
|---|---|
| `n_concurrent_trials` | 最多同时运行多少个 trial；当前为 `8` |
| `n_attempts` | 每道题独立运行多少次；当前为 `1`，三道题共生成 3 个 trial |
| `datasets[].task_names` | 可选的题目文件夹名称列表；省略时运行该目录中所有题目 |
| `task.toml` 的 `[agent].timeout_sec` | 单个 Agent 阶段的基础预算；上例 3600 秒，乘以倍率后为 16 小时 |
| `task.toml` 的 `[verifier].timeout_sec` | 验收基础预算，与 Agent 分别计时；上例乘以倍率后为 16 小时 |
| `timeout_multiplier` | Harbor 阶段预算的倍率；当前为 `16.0` |
| `mini.yaml` 的 `environment.timeout` | 单条 shell 工具命令的执行预算；上例 600 秒，不受上述倍率影响 |
| `step_limit: 0` | 不限制 Agent 步数，其他预算仍然生效 |

Metal Sandbox 扣除调度等待时间，实际执行和模型等待仍会消耗相应的阶段预算。Agent 主会话可以并行工作；shell 工具命令按各实例的白名单或黑名单调度。

重试分两层：`num_retries` 控制 mini 模型客户端重试；`retry.max_retries` 控制整个 trial 重试。上例的配置分别为 30、0。

## 5. 开始运行

在 Harbor 源码根目录执行，`--path datasets` 将配置中的题目路径覆盖为 `datasets/`；`.env`、`configs/` 和 `jobs/` 均位于 Harbor 源码根目录：

```sh
uv run --no-default-groups harbor run \
  --env-file .env \
  --config configs/rollout.yaml \
  --path datasets \
  --job-name "metal_$(date +%Y%m%d_%H%M%S)" \
  --yes
```

Harbor 自动创建实例、上传环境文件、安装并启动所选 Agent，然后运行验收并导出结果。App 侧边栏会显示以 trial 名称命名的实例，无需另行点击「执行准备」。

`delete: false` 会在 trial 结束后停止并保留实例，可在 App 中选择「启动实例」继续查看。`delete: true` 会在收集结果后删除实例。初始化失败的未完成实例会被清理。

需要手动结束本次 Job 时，在运行 Harbor 的终端按 `Ctrl+C`；不要直接关闭共享的 Metal Sandbox 管理服务。

## 6. 查看结果和轨迹

Job 目录位于 `jobs/<job-name>/`，每个 trial 有独立子目录：

| 文件或目录 | 内容 |
|---|---|
| Job 根目录的 `result.json` | 整批任务的统计 |
| trial 的 `result.json` | 阶段时间、异常和验收结果 |
| `agent/claude-code.txt` | Claude Code 的 Agent 输出 |
| `agent/codex.txt` | Codex 的 Agent 输出 |
| `agent/mini-swe-agent.txt` | 可直接阅读的 Agent 输出 |
| `agent/mini-swe-agent.trajectory.json` | mini 原始对话和工具调用 |
| `verifier/` | 奖励文件、验收输出和指标 |
| `artifacts/workspace/` | 按上方 `artifacts` 配置导出的代码和产物 |

Metal Sandbox App 的「轨迹」页当前读取 Claude/Codex 会话，mini 的轨迹使用上面的日志文件查看。

验收奖励的含义由 `tests/test.sh` 决定。例如 `smoke_pass: 1` 只表示该脚本定义的基础检查通过，完整题目要求是否满足，需要相应的验收覆盖。
