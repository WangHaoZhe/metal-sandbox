# 题包与准备脚本

**建议使用 [Harbor](harbor.md) 运行 Agent 任务。** Harbor 负责选择任务、启动 Agent、运行验收和保存结果。

本文介绍直接使用 Metal Sandbox 图形界面或 CLI 时的题包格式，以及导入题包、执行 `setup.sh`、启动 Agent 和验收的流程。

## 题包格式

每道题是一个独立文件夹，分为 `agent/` 和 `tests/`。导入时选择题包根目录，不需要压缩：

```text
agent/
  instruction.md        题目、约束、交付要求（非空 UTF-8 文件）
  setup.sh              准备脚本（非空 UTF-8 文件）
  public_tools.cpp      可选公开工具
  public_tools.md       可选工具说明
  fixtures/             可选公开输入和对照数据
tests/
  test.sh               验收入口；未提供验收时 tests/ 可省略或为空
  ...                   检查器和验收数据
```

App 只负责导入、展示和执行 `setup.sh`，不内置某种 Agent 的安装脚本，也不替题包选择模型。`setup.sh` 可以使用任意工具或 harness，甚至只准备环境而不启动 Agent；执行入口固定为 `/bin/sh ./setup.sh`，工作目录为 workspace 根目录。

导入将 `agent/` 的内容（包括隐藏文件）复制到 workspace 根目录，不保留 `agent/` 这一层。`tests/` 同时存档到后端数据目录，验收时才复制进 workspace。不会执行脚本或修改源目录。公开内容不要夹带已有解答、构建产物、轨迹、账号配置或真实 API key。链接和特殊文件不支持。

题包导入只接受文件夹，不接受 ZIP。如果收到压缩文件，请先自行解压，再选择包含 `agent/` 和 `tests/` 的题包根目录。工作区快照的 ZIP 导入导出是独立功能，不受影响。

提供 [Metal Bloom](../../examples/tasks/metal_bloom/agent/instruction.md) 和[五阶毒蘑菇 Mandelbulb](../../examples/tasks/metal_poison_mushroom/agent/instruction.md) 两个题包；后者为离屏渲染题，不设帧率门槛。导入时选择对应的题包根目录。

## 图形界面

1. 打开「创建 Sandbox」，选择副本数量；「允许出站联网」默认勾选。
2. 点击窗口中直接显示的「导入题包…」，选择题包根目录，例如 `examples/tasks/metal_poison_mushroom`，不要选里面的 `agent/`。
3. 窗口自动展开并载入 `agent/setup.sh`。在可折叠的「环境变量」表格中填写题包要求的配置，检查脚本并设置准备超时。题包含 `tests/test.sh` 时默认开启「完成后自动验收」，验收超时独立设置。
4. 点击「创建并执行准备」：每个副本先导入题包，再保存当前脚本并提交执行。若只想导入，清空准备脚本后点击「创建」。创建完成前请勿修改源目录。
5. 在「轨迹」查看会话，在「操作记录」查看执行结果；「验收」显示自动验收状态和结果。关闭前端不影响后台执行。

已有实例仍可使用「准备」→「导入题包…」；此入口只导入并读取文件，不自动执行，需再点击「保存并执行准备」。

也可通过「载入脚本…」手动选择文件，或直接编辑脚本。脚本执行什么、怎样安装工具及保存日志，由题包决定，不由前端决定。

## CLI

管理服务已启动时，在项目根目录执行：

```sh
BIN="/Applications/Metal Sandbox.app/Contents/Helpers"
"$BIN/sandboxctl" sandbox create --count 1
ID='sbx-替换为返回的ID'
"$BIN/sandboxctl" sandbox import "$ID" --from examples/tasks/metal_bloom --task
# 按题包要求配置 setup.sh 后，再执行：
"$BIN/sandboxctl" sandbox exec "$ID" --session --timeout 7200 -- /bin/sh ./setup.sh
```

`--task` 只接受题包目录，在导入前校验 `agent/instruction.md` 和 `agent/setup.sh` 均存在、非空且不是链接；缺文件时不会使用旧工作区文件补齐，也不会写入任何文件。只有 `agent/` 的内容由 CLI 分块打包后传入 sandbox，前端不直接访问 sandbox 文件。普通快照导入不加该参数，只接受 ZIP 快照。

导入是合并操作，会覆盖同路径文件，但不会清除上次解答；建议新题使用新实例。写入失败可能部分完成，不自动回滚。准备脚本不能直接读取宿主的题包目录；由控制端通过 CLI 整包导入。

## 验收答案

导入含 `tests/test.sh` 的题包后，`exec --session` 和前端执行准备会自动登记后续验收。准备脚本结束、实例内关联任务退出且清理确认后，后端替换整个 `tests/` 并提交测试。Agent 的非零退出及已确认清理的超时也会验收现有产物；主动取消或停止实例会取消后续自动验收。节点隔离、清理不确定或无法确认 Agent 退出时显示受阻。

tests 存档位置为 `~/Library/Application Support/MetalSandbox/native/test_packages/<内容 SHA-256>/tests.zip`；相同内容的副本共用存档。原题包随后被移动或修改，不影响已登记的任务。每次 Agent 执行保留独立的测试版本与验收超时。

「准备」页可调整「完成后自动验收」和超时，保存后作用于后续提交。CLI 配置：

```sh
"$BIN/sandboxctl" sandbox verification "$ID"
"$BIN/sandboxctl" sandbox verification "$ID" --enabled true --timeout 600
"$BIN/sandboxctl" sandbox verification "$ID" --enabled false
```

在「验收」页也可手动点击「运行验收」，使用已保存的 tests。点击「选择题包…」可以为本次验收指定另一份测试。

CLI 使用相同流程：

```sh
# 指定本次验收题包；省略 --from 优先使用已保存的 tests
"$BIN/sandboxctl" sandbox verify "$ID" --from examples/tasks/metal_poison_mushroom --timeout 600 --detach
# 使用返回的 execution.id 查看结果或取消
"$BIN/sandboxctl" sandbox wait EXECUTION_ID
"$BIN/sandboxctl" sandbox cancel EXECUTION_ID
# 给尚未登记验收的 Agent 执行追加自动验收
"$BIN/sandboxctl" sandbox verify "$ID" --after AGENT_EXECUTION_ID --detach
```

执行入口为 `/bin/bash ./test.sh`，工作目录为 `workspace/tests`。退出码 0 表示该测试通过，非零表示失败；超时、取消或执行错误不计为通过。去掉 `--detach` 会等待完成并返回测试的退出码。验收固定进入执行节点的串行队列，验收超时从实际执行开始计算；从安装 tests 到保存结果期间，当前实例只允许读取，其他实例可继续执行并行命令。手动运行需要实例已经启动且空闲。

Agent 与验收具有独立执行 ID、状态、退出码及 stdout/stderr。测试生成的 `tests/metrics.json` 另存到后端的 `verification_results/<验收执行 ID>.zip`。重开 App 后可在验收页继续查看记录，也可在操作记录中按 Sandbox ID 筛选。

服务重启后，已确认 Agent 完成、尚未提交的验收会继续处理；已提交的验收不会重复启动。中断的执行保留中断状态，需要人工检查。测试结束后保留实例和工作区。

`agent/` 是做题输入，`tests/` 是验收输入，两条导入路径互不混用。普通工作区快照仍完整保留已有文件，因此用含 tests 的快照克隆做题环境前应自行清理测试目录。推迟注入能避免提前暴露，但同实例验收仍不是防篡改隔离。

**测试脚本约定：** 原答案只读，工作副本、编译产物、临时目录、缓存和结果全部放在 `tests/` 内；不要直接运行会在原答案目录生成文件的构建脚本。毒蘑菇题包遵循此约定。框架不会把任意脚本自动变为只读程序；同实例验收不提供抵抗恶意答案的独立隔离。

## Metal Bloom 题包示例

[Metal 高斯模糊 + Bloom](../../examples/tasks/metal_bloom/agent/instruction.md) 包含 15 组公开输入及对照结果，要求原生 Metal compute 和离屏 render，无需显示器，在 1920×1080 分辨率下测量并优化吞吐和帧时。

本题的 [setup.sh](../../examples/tasks/metal_bloom/agent/setup.sh) 在实例私有 HOME 安装 Node 24.19.0 和 Claude Code 2.1.112 官方 npm 包，通过标准输入将 `instruction.md` 原文作为 prompt 传入。毒蘑菇题包使用相同脚本。更换 harness 时修改或替换脚本；已导入实例可在「准备」页载入更新后的脚本并保存。

在创建窗口或「配置与快照」的环境变量表格中填写，不必改脚本：

| 键名 | 键值 |
| --- | --- |
| ANTHROPIC_API_KEY | 你的 API key |
| ANTHROPIC_BASE_URL | `https://api.anthropic.com`，或实际服务地址 |
| ANTHROPIC_MODEL | 实际模型名称，例如 `claude-opus-4-8` |
| CLAUDE_LOCAL_PACKAGE | 可选，已上传的官方 Claude npm `.tgz`，例如 `vendor/claude.tgz` |
| CLAUDE_NODE_BINARY | 可选，已上传的 macOS arm64 Node 原生文件，例如 `vendor/node` |

脚本保留注入值，模型留空时使用 Claude 默认模型。它不加载用户 settings，只显式加载运行时提供的命令调度 hook 配置。缺少 key 时只安装工具并提示设置环境变量，不启动 Agent。再次执行复用已安装的正确版本，但开启新会话，不自动继续上一轮。

**环境配置不写入工作区快照；如果自行把 key 写进脚本，则仍会随快照导出，分享前必须移除。**不要使用 `set -x` 或打印凭据。

准备超时包含安装和整轮做题，建议预留足够时间。此脚本使用 `--dangerously-skip-permissions` 关闭 Claude 工具确认，但不解除 macOS App Sandbox；仅用于已授权的可信本地开发。

本题脚本已接入 [Claude Bash 命令调度](native_operations.md#agent-主会话与工具命令)：主会话并行，每次 Bash 调用单独按实例黑白名单选择直执行或串行。不是自动检测 GPU；其他题包需在自己的脚本中配置适配器。

完整轨迹保存在实例私有 `$HOME/.claude/rollouts/<session>/events.jsonl`，同目录还有 `stderr.log` 和 `exit.json`；路径由脚本输出。Claude 自身的会话仍在 `$HOME/.claude/`。私有 HOME 不在 workspace 快照内，需要保留时另行保存。Agent 退出后 sandbox 保留。

### 使用本地 Claude 安装包

下载及 SHA-256 校验命令见题包内的 `agent/vendor/README.md`：
[Metal Bloom](../../examples/tasks/metal_bloom/agent/vendor/README.md)、
[毒蘑菇](../../examples/tasks/metal_poison_mushroom/agent/vendor/README.md)。

本地安装使用 Claude Code 2.1.112 官方 npm `.tgz` 和 Node 24.19.0 的 macOS arm64 原生文件。Node 先解压，上传其中的 `bin/node` 普通文件。

1. 将两个文件放入题包的 `agent/vendor/claude.tgz` 和 `agent/vendor/node`，然后导入题包。
2. 设置实例环境变量 `CLAUDE_LOCAL_PACKAGE=vendor/claude.tgz` 和 `CLAUDE_NODE_BINARY=vendor/node`。
3. 执行准备脚本。脚本校验实际版本，将工具安装到实例私有 `$HOME/.local/share/claude_code/2.1.112_node_24.19.0/`，使用 Node 启动 `cli.js`。

已有实例可通过 CLI 上传：

```sh
"$BIN/sandboxctl" sandbox write "$ID" vendor/claude.tgz --from /path/to/claude_code_2.1.112.tgz
"$BIN/sandboxctl" sandbox write "$ID" vendor/node --from /path/to/node-v24.19.0-darwin-arm64/bin/node
# 在实例配置中设置上述两个变量，再执行准备脚本。
```

路径支持带空格的绝对路径或相对 workspace 的路径，按原样读取，不展开 `~` 或 `$HOME`。宿主文件需先上传，环境变量本身不授予宿主目录访问权限。

未指定某个本地文件时，脚本下载该组件的官方固定版本；指定文件无效或版本不符会立即报错。已有正确版本时复用私有安装，源安装包保留。工作区内的包会进入快照；私有 HOME 中的工具随实例删除。模型调用仍需要网络和凭据。

## 选择 Harness 准备脚本

[Harness 示例目录](../../examples/harnesses/README.md)提供三种准备脚本，均复制为题包的 `agent/setup.sh`，通过 App 准备页或 `exec --session` 运行：

| Harness | 脚本 | 附件与配置 |
|---|---|---|
| Claude Code | [claude_setup.sh](../../examples/harnesses/claude_setup.sh) | `instruction.md`，可选本地 Claude npm 包与 Node |
| Codex | [codex_setup.sh](../../examples/harnesses/codex_setup.sh) | `instruction.md`、`codex_config.toml`，可选本地两个原生文件 |
| mini-swe-agent | [mini_swe_agent_setup.sh](../../examples/harnesses/mini_swe_agent_setup.sh) | `instruction.md`、`mini_config.yaml`、`mini_swe_agent_metal.py`、Python 和依赖归档 |

通过 Harbor 运行时，三者均由 Harbor 安装，不需要复制这些脚本，见 [Harbor 配置](harbor.md)。

## 使用 Codex 准备脚本

将 [codex_setup.sh](../../examples/harnesses/codex_setup.sh) 保存为题包 `agent/setup.sh`，同时提供 `instruction.md` 和 `codex_config.toml`。后者配置模型、provider、Responses API 地址和 `env_key = "OPENAI_API_KEY"`；在实例环境中填写 `OPENAI_API_KEY`。

脚本使用 Codex 0.162.1。提前上传两个解压后的原生文件，并设置 `CODEX_LOCAL_PACKAGE` 和 `CODEX_LOCAL_CODE_MODE_HOST`，即可在实例内安装；未指定时下载官方固定版本。工具保存在 `$HOME/.local/share/codex/0.162.1/`，会话保存在实例 `~/.codex/sessions`，可通过 App「轨迹」查看。具体命令见 [Codex 启动](native_operations.md#codex)。

## 使用 mini-swe-agent 准备脚本

将 [mini_swe_agent_setup.sh](../../examples/harnesses/mini_swe_agent_setup.sh) 保存为题包 `agent/setup.sh`，同时提供 [mini_config.yaml](../../examples/harnesses/mini_config.yaml)、[mini_swe_agent_metal.py](../../examples/harnesses/mini_swe_agent_metal.py) 和 `instruction.md`。上传 mini-swe-agent 2.4.6 的完整 Python 与依赖归档，设置 `MINI_SWE_AGENT_LOCAL_BUNDLE`、`MINI_SWE_AGENT_BUNDLE_SHA256`、`MINI_SWE_AGENT_MODEL` 及供应商 API key。

模型地址和采样参数放在 `mini_config.yaml`。工具在实例本地私有目录安装，shell 命令通过 `MetalEnvironment` 交给管理服务；日志和原始轨迹保存在工作区 `mini_swe_agent_runs/<session>/`。归档格式见 [Harness 示例说明](../../examples/harnesses/README.md#mini-swe-agent)。

## 产物与记录

| 数据 | 获取方式 |
|---|---|
| 源码、渲染结果、tests 输出 | workspace；通过「文件」页或 CLI read/export 获取 |
| Claude/Codex 会话 | 实例私有 HOME；通过「轨迹」页查看 |
| mini-swe-agent 会话 | 工作区 `mini_swe_agent_runs/<session>/trajectory.json`；通过「文件」页或 CLI 导出 |
| 命令状态、退出码与输出 | 后端 executions 记录；「操作记录」或 CLI executions/execution |
| 工作区恢复点 | 「保存快照」或 CLI snapshot，保存为 ZIP |

环境变量按实例保存，不进入工作区快照；脚本主动打印或写入的凭据仍可能进入日志或快照。

启动原实例保留 ID、工作区和私有 HOME；快照克隆只复制 workspace，需要重新准备 HOME 中的工具。用户单独导出的 ZIP 不随实例删除。
