# 原生 sandbox 使用指南

**App Sandbox 后端**仅限可信本地开发。服务不安装 launchd，不要求 root，不创建用户，不开放 TCP。

## 1. 启动管理服务

终端一：

```sh
# 在源码根目录运行
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
"$BIN/metal-sandboxd" --allow-trusted-code
```

服务在前台常驻。每 UID 只有一个管理服务；不同 state-dir 不能同时启动第二个服务。默认状态目录为 `~/Library/Application Support/MetalSandbox/native`。

可用 `--state-dir /absolute/path` 指定状态目录；CLI 同样把 `--state-dir` 放在 `sandbox` 前。管理 socket 固定在本 UID 的 `/private/tmp/metal-sandbox-<uid>/native.sock`（以 `id -u` 查看当前 UID）。每次服务启动重新生成操作员 token；不把 token 放进 sandbox 或候选环境。

## 2. 创建指定数量并进入

终端二：

```sh
BIN="$(swift build -c release --show-bin-path)"
"$BIN/sandboxctl" sandbox create --count 4
"$BIN/sandboxctl" sandbox list -h
"$BIN/sandboxctl" sandbox enter <返回的sandbox_id>
```

ID 形如 `sbx-<UUID>`，可以使用唯一前缀。单次创建 1–16 个；每个节点默认最多 32 个活动实例，可通过节点配置或单机服务的 `--max-instances N` 调整。已停止实例不占名额，容量满时 CLI 返回退出码 75。失败的批次会尝试关闭本批已创建实例，并保留失败记录。

`list -h`（或 `list --human`）按列显示完整 ID、状态、联网开关、白名单/黑名单模式和本地创建时间；空列表显示 `No sandboxes.`。不加参数的 `list` 仍输出 JSON，供脚本和前端使用。查看帮助使用 `list --help`。

新建实例默认允许出站联网；使用 `sandboxctl sandbox create --count N --no_network` 关闭。只在创建时选择，由操作员设置固定签名权限。该选项允许实例内所有程序发起出站连接（包括局域网/回环地址），不是域名白名单，不授予入站监听权限。不能对运行中的实例热切换。`inspect.networkClient` 显示选择，恢复为新实例时沿用该设置。

访达中的容器显示名为 `MetalSandboxHost-<完整 sandbox ID>`，例如 `MetalSandboxHost-sbx-…`；磁盘目录名仍为 macOS 管理的 `local.metal-sandbox.instance-…`，两者不是同一个 ID。前端和 CLI 使用相同创建流程，启动 Host 前会通过 Launch Services 登记应用名称；恢复快照使用新实例的 ID。没有逻辑 ID 的独立测试 Host 使用 `MetalSandboxHost`。

已删除实例若仍留下系统容器空壳，且对应 Host 包和名称缓存已不存在，Finder 会显示原始目录名；这不代表另一个活动 sandbox。名称登记失败不会阻止无界面的任务运行，详情会记录在服务日志中。不要手动改名或移动仍在使用的系统容器；清理方式见本页的删除与残留说明。

进入后可以输入 `pwd`、`ls`、`mkdir src`、`cd src` 等。`exit` 只退出控制台，**不会关闭 sandbox**。

**enter 是逐条提交的命令控制台，不是持久 PTY。** 每条命令按该实例保存的调度规则选择并行或串行，空闲控制台不占槽。文件与当前控制台的 cwd 保留；跨命令 shell 变量、交互式 vim/top、作业控制、交互 stdin 尚不支持。不能把 `cd` 到容器目录当作进入沙箱。

需要为单条命令指定目录或超时时，在控制台输入：

```text
:run {"line":"pwd","timeout":30,"cwd":"."}
```

`line` 为一行命令（最多 8 KiB），`timeout` 为正数秒数；省略 `cwd` 沿用控制台当前目录，指定时须为 workspace 相对路径（`.` 为根目录）。命令仍经过同一调度器，返回执行 ID 和退出码；普通命令输入和 `cd`/`exit` 保持可用。

通过只读目录接口浏览工作区（与控制台内执行 `ls` 不同）：

```sh
"$BIN/sandboxctl" sandbox ls <id>
"$BIN/sandboxctl" sandbox ls <id> src
# 返回 nextAfter 时，用其原样值加载下一页
"$BIN/sandboxctl" sandbox ls <id> src --after '<nextAfter>'
```

每页 256 项，包含隐藏文件和大文件元数据，不跟随链接。目录按需逐层查询；单目录扫描超过 100000 项明确报错。实例执行命令或运行 Agent 时，仍可列目录、预览和下载单个文件；这些操作使用 read 权限，不占候选执行槽。浏览结果不是冻结快照，目录或文件在读取中发生变化时可能提示重试。写入、导入及整份快照导出仍与执行互斥。详细返回结构见[接口文档](api.md)。

## 3. 执行、编译和反复运行

### Agent 主会话与工具命令

准备页自动使用 `exec --session` 启动脚本；CLI 对应命令为：

```sh
"$BIN/sandboxctl" sandbox exec "$ID" --session --timeout 7200 -- /bin/sh ./setup.sh
```

`--session` 由操作员选择，让长驻 harness 主会话不占串行槽；Agent 不需要、也不应自行调用 sandboxctl。普通 `exec` 不加此选项，仍按实例策略分类。未接入适配器的会话子命令不会自动被拦截。

支持 Claude Code、Codex 和 mini-swe-agent 的受管理主会话。[三个准备脚本](../../examples/harnesses/README.md)分别配置各自的命令接口；mini 使用 Python 环境适配器，直接将工具命令交给 shell helper。

`METAL_SANDBOX_HARNESS` 选择已注册的命令适配器，支持 `claude` 和 `codex`，省略时默认 `claude`。每条工具命令通过 `sandbox-shell` 按实例规则申请许可，保留原工作目录、输出和退出码。工具安装、模型和凭据由准备脚本及实例环境配置负责；通过 Harbor 运行时由 Harbor 安装 harness，参见 [Harbor 配置](harbor.md)。

#### Claude Code

[示例准备脚本](../../examples/harnesses/claude_setup.sh)在实例私有 HOME 安装 Node 24.19.0 和官方 Claude Code 2.1.112 npm 包。它支持提前上传安装包，详见[本地安装说明](task_packages.md#使用本地-claude-安装包)。安装完成后的启动命令如下，仍须在 `exec --session` 或 App 准备页中执行：

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

Claude 的官方 `PreToolUse` hook 按原 Bash 命令分类；并行命令在原实例执行，串行命令通过 Host 私有通道申请共享串行槽。不要使用会跳过 hook 的 `--bare`。`HOME`、Claude 配置和临时文件均位于实例内；非交互启动无需 `TERM` 和 `SHELL`。Messages API 代理地址填服务根地址，客户端添加 `/v1/messages`。

#### Codex

[Codex 准备脚本](../../examples/harnesses/codex_setup.sh)在实例私有 HOME 安装 Codex 0.162.1 及同版本 `codex-code-mode-host`。工作区需包含 `instruction.md` 和 `codex_config.toml`，实例环境配置需包含 `OPENAI_API_KEY`。模型、provider 和 Responses API 地址在 `codex_config.toml` 中指定；`CODEX_LOCAL_PACKAGE` 和 `CODEX_LOCAL_CODE_MODE_HOST` 可指定提前上传的两个原生文件。

```sh
"$BIN/sandboxctl" sandbox write "$ID" setup.sh --from examples/harnesses/codex_setup.sh
"$BIN/sandboxctl" sandbox write "$ID" codex_config.toml --from /path/to/codex_config.toml
"$BIN/sandboxctl" sandbox exec "$ID" --session --timeout 7200 -- /bin/sh ./setup.sh
```

安装后，脚本使用下面的命令启动。`codex_config.toml` 先复制到实例 `CODEX_HOME/config.toml`，认证通过实例环境传入：

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

Codex 的官方 `PreToolUse` hook 将 `Bash`／`exec_command` 交给管理服务；`--no-daemon` 使用独立进程，命令及其后代保留 App Sandbox 限制。适配器沿用实际执行工具命令的 POSIX shell，也可通过 `METAL_SANDBOX_CODEX_SHELL` 显式指定。会话保存在实例 `~/.codex/sessions`，App 轨迹页可增量读取。

#### mini-swe-agent

[mini-swe-agent 准备脚本](../../examples/harnesses/mini_swe_agent_setup.sh)使用完整的本地 Python 与依赖归档。工作区提供 `instruction.md`、`mini_config.yaml` 和 `mini_swe_agent_metal.py`，实例环境填写 `MINI_SWE_AGENT_LOCAL_BUNDLE`、`MINI_SWE_AGENT_BUNDLE_SHA256`、`MINI_SWE_AGENT_MODEL` 和供应商 API key。

```sh
"$BIN/sandboxctl" sandbox write "$ID" setup.sh --from examples/harnesses/mini_swe_agent_setup.sh
"$BIN/sandboxctl" sandbox write "$ID" mini_config.yaml --from /path/to/mini_config.yaml
"$BIN/sandboxctl" sandbox write "$ID" mini_swe_agent_metal.py --from examples/harnesses/mini_swe_agent_metal.py
"$BIN/sandboxctl" sandbox exec "$ID" --session --timeout 7200 -- /bin/sh ./setup.sh
```

`MetalEnvironment` 将命令原文交给运行时的 `sandbox-shell`，保留目录、stdout/stderr 和退出码。其命令预算从取得许可后开始；运行记录保存到工作区 `mini_swe_agent_runs/<session>/`。通过 Harbor 运行时，原始轨迹及 ATIF 由 Harbor 导出。

Claude Code、Codex 和 mini-swe-agent 的模型客户端保持在实例归属节点。开启动态调度后，共享工作区内符合条件的串行工具命令可迁移到空闲节点；工具使用用户配置和编译环境，模型客户端的私有运行目录留在归属节点。实际依赖私有文件、可执行文件或用户指定私有环境的命令继续在归属节点执行。

串行工具输出会说明正在等待执行槽，并报告取得许可前的等待时间。**等待仍计入 Claude 的 Bash 工具超时**，超时会取消任务；这与程序实际运行超时不同，可按任务需要设置更长的工具超时。Claude 通常在工具返回后才读到这些提示，不代表模型在等待期间能实时接收它们。

这不是任意子进程或 Metal API 截获：每个工具命令及其内部后代仍是一个任务，尚未接入的 harness/MCP 需要各自的适配器。侧栏和总览的待执行数包含顶层任务及已接入的工具命令，串行排队、串行执行和并行执行均计入。例如一个 Claude 主会话加三个未完成 Bash，显示 4。并行任务只登记生命周期，不进入串行 FIFO；结束或取消后移除计数。

### 并行与串行规则

默认在**同一或不同 sandbox 内**都可并行的任务：`sleep`、`echo`、`ls/cat/pwd`，常用文件操作（如 `mkdir/cp/mv/rm/touch/find`）、文本处理（如 `head/tail/grep/sed/awk/sort/wc/diff`）、`git`、`curl`、归档工具，以及已安装的 `clang`/`clang++`、`metal`/`metallib`、`make`、`ninja`、`cmake --build`。其他任务进入执行节点的 FIFO 串行队列。并行任务不等待串行槽，也不等待同实例其他执行；只有同一节点上的串行任务彼此排队。同时修改同一文件的冲突由使用者或 Agent 负责，完整快照和外部写入仍要求实例空闲。

不需要给命令添加 CPU/GPU 参数。在控制台直接输入 `make`、`ninja` 或 `cmake --build build` 即可。只有程序绝对路径和参数前缀匹配才放行；`./make`、`cmake -E ...`、`sh -c 'make && ./program'` 默认仍串行。

白名单模式下，`sh -c` / `bash -c` 和 Claude Bash 的复合任务会检查每条命令：支持 `&&`、`||`、管道、分号、换行、静态引号及普通重定向，全部命中才整项并行。例如 `ls && cat instruction.md` 可并行，`make && ./program` 串行。

命令路径在实例内按实际 PATH 与工作目录解析，参数前缀仍逐条检查。若 PATH 的前置目录位于实例可写区，可能被前面的命令改变，则按串行处理；可用明确的可执行文件路径匹配白名单。执行时保留原始脚本及内部顺序，并行仅指可与其他任务重叠。

变量/命令替换、通配符、环境赋值、`cd` 等改变 shell 状态的命令、循环、函数、后台任务、heredoc、脚本文件及有启动文件的 shell 无法静态确认时整项串行。黑名单按整项入口匹配，不拆解内部命令。

`sh/bash/zsh`、`env`、`xargs` 和通用解释器不默认整体放行；`find -exec`、`awk system()`、Git hook 等子命令随父任务调度，不代表被判定为纯 CPU。`curl` 并行不改变实例的联网权限。

完整默认规则见 [`default_task_policy.json`](../../sources/sandbox_runtime/resources/default_task_policy.json)。更新后的默认规则用于新建实例；已有实例和恢复出的实例沿用创建时保存的配置，不自动覆盖自定义规则。

**白名单覆盖整项任务及其子进程。** 构建脚本即使启动测试程序或 Metal 程序，也随构建并行。因此串行任务也可能与其他实例的白名单任务争用 GPU。

创建时可提供 JSON 文件，**替换**该实例的默认调度规则，不是追加：

```sh
printf '%s\n' '{"parallel":[]}' > task_policy.json
"$BIN/sandboxctl" sandbox create --count 1 --task-policy "$PWD/task_policy.json"
"$BIN/sandboxctl" sandbox inspect <id>
```

`{"parallel":[]}` 表示该实例的任务全部进入串行槽，不会禁止其他实例使用并行任务。自定义规则格式如下，路径必须是本机实际工具的完整绝对路径：

```json
{"parallel":[{"executable":"/bin/ls"},{"executable":"/absolute/path/to/cmake","argumentPrefix":["--build"]}]}
```

也可使用黑名单：以下配置让直接提交的 `/bin/sh` 任务串行，其余任务并行。

```json
{"serial":[{"executable":"/bin/sh"}]}
```

白名单使用 `parallel`，黑名单使用 `serial`，只能选一种，不能同时填写。`{"serial":[]}` 表示该实例所有普通任务可并行；未命中的 GPU 任务也可能争用 GPU。匹配的是提交任务，不拦截其他程序内部启动的 `/bin/sh` 等子进程。两种模式共用同一个串行槽，均不改变工作目录或沙箱权限。

最多 128 条规则，文件最多 128 KiB；未知字段、非规范绝对路径和错误类型会被拒绝。`argumentPrefix` 省略表示任意参数；填写时必须是字符串数组。

`inspect` / `list` 返回实例保存的 `taskPolicy`；创建后只读，修改原 JSON 文件不会影响已有实例。停止、服务重启与恢复为新实例都保留该策略。

`status.taskPolicy` 是**新建实例的默认配置**，不是所有实例的全局覆盖。默认规则来自随包分发的 [default_task_policy.json](../../sources/sandbox_runtime/resources/default_task_policy.json)，工具链占位符会解析为当前 Mac 的实际路径，未安装的可选工具会略过；界面和实例记录均展示解析后的 JSON，不需要填写占位符。

操作员仍可通过 `metal-sandboxd --allow-trusted-code --task-policy /absolute/default_policy.json` 在服务启动时替换新建实例的默认值；它不覆盖已有实例保存的策略。需要全部任务串行时，所有活动实例都应使用空白名单。

规则不改变 App Sandbox 权限。Claude Bash、Codex exec_command 和 mini-swe-agent shell 命令均通过各自适配器单独调度。

### 命令示例

```sh
"$BIN/sandboxctl" sandbox exec <id> -- echo hello
```

普通 `clang`/`clang++`、CMake、Ninja、Make 和项目自己生成的程序都在 App Sandbox 内执行。控制器固定真实编译器路径和 SDK，并向子进程提供 `PATH`、`CC`、`CXX`、`SDKROOT`；这些环境同样适用于 shell 内部调用。只分析受支持的 shell 命令字符串来选择调度类别，不改写项目脚本。

可在一次命令中完成正常开发流程：

```sh
# 工作区已有 CMake 项目时
"$BIN/sandboxctl" sandbox exec <id> --timeout 120 -- /bin/sh -c \
  'set -eu; cmake -S . -B build -G Ninja; cmake --build build; ctest --test-dir build --output-on-failure'
```

支持 CMake 内部 `try_run`、多个 executable/helper 和自定义动态库；编译运行保持物理容器不变，`revisions` 不随每次编译增长。系统链接器负责正常的 Mach-O 签名，基建不替 Agent 改构建逻辑。独立评测的冻结发布仍是另一条受限执行流程。

CMake/Ninja 不内置于 DMG。源码提供操作员安装脚本，下载固定官方发行包并校验 SHA-256；不是在候选中开放网络：

```sh
python3 scripts/install_development_tools.py
# 安装后启动/重启管理服务，使新实例获得工具路径
```

安装目录为 `~/Library/Application Support/MetalSandbox/development_tools`，候选只有只读权限。不要把宿主秘密放在此工具目录。其他工具须单独做兼容验收，不能把 PATH 可见等同于任意工具受支持。

安装 Metal Toolchain 并重启服务后，可直接在 sandbox 使用 `metal` / `metallib`（控制面已解析真实组件路径，不调用 Xcode 占位程序）：

```sh
"$BIN/sandboxctl" sandbox exec <id> --timeout 120 -- /bin/sh -c \
  'set -eu; metal -c shader.metal -o shader.air; metallib shader.air -o shader.metallib'
```

可以在同一脚本中继续编译 Objective-C++ 程序、加载该 `.metallib` 并使用实体 GPU。

**仍有边界：** 不保证所有 Xcode IDE/xcodebuild 项目兼容，Apple 自带 `/usr/bin/xcrun` 本身拒绝在 App Sandbox 内运行；应使用已配置的真实 `clang` 等工具。文件和快照按块读写，无字节大小上限，但仍受可用磁盘空间及路径、条目数限制；跨目录链接和任意第三方运行时不保证兼容。联网需创建时允许，交互终端尚不支持。

## 4. 通用准备脚本与题目输入

复用现有 `write` + `exec`，不需要独立的准备接口，也不绑定 Claude/Codex 等 harness。`write` 传文件，`exec` 在指定 sandbox 内执行；准备结束后工作区文件保留。

以下在源码根目录、服务已启动时执行。先创建实例，再把返回的 ID 填入 `ID`：

```sh
BIN="$(swift build -c release --show-bin-path)"
"$BIN/sandboxctl" sandbox create --count 1
ID='sbx-替换为返回的ID'

"$BIN/sandboxctl" sandbox write "$ID" setup.sh --from /path/to/setup.sh
"$BIN/sandboxctl" sandbox write "$ID" instruction.md --from /path/to/instruction.md
"$BIN/sandboxctl" sandbox exec "$ID" --timeout 120 -- /bin/sh ./setup.sh
```

把 `/path/to/` 替换为自己的本机文件路径，题包也可[整份导入](task_packages.md)。脚本的失败处理由作者决定；使用 `set -eu` 时，普通命令失败后退出，CLI 返回失败，**不回滚此前写入的文件**。调用方应检查每次退出码再提交下一条命令。

边界：

- 脚本可包含任意命令，但仍受 App Sandbox、路径、超时、日志和任务调度限制；不是绕过隔离的安装钩子。
- 新建实例默认允许出站联网；添加 `--no_network` 后不能联网安装。未提供宿主凭据透传；不要把操作员 token/handle 写入工作区，也不要把真实 API key 直接写进会被保存的命令参数或输出。
- 当前无交互 stdin/PTY，进程初始 stdin 为 `/dev/null`。非交互程序可自行读 prompt 文件，或使用其支持的 argv 参数；不能模拟“启动交互 CLI 后输入 prompt”。
- shell 内的环境变量不跨 `exec` 保留；后台子进程会被清理，脚本不是常驻会话启动器。可把配置写入工作区，下次自行读取。
- 新编译的程序可在脚本内部直接启动；支持 CMake/helper/版本化 dylib。依赖和 harness 由题包的 `setup.sh` 安装到实例私有环境，不保证任意第三方 CLI 兼容。

完整题包与 Claude 安装后自动做题的流程见[题包与 Agent 启动](task_packages.md)。切换 harness 时复用同一传输/执行接口，以 `instruction.md` 为入口；其他 CLI 的安装、模型连接及非交互启动方式需分别验证。`evaluation-runner --managed-smoke` 仍是固定测试，不会自动消费准备脚本。

实例的 `PATH` 包含自己的 `$HOME/.local/bin`，但不包含宿主同名目录；已固定的系统/开发工具优先。普通 `exec -- claude --version` 与控制台 `claude --version` 均使用实例内的安装。未安装时明确报错，不回退到宿主 CLI。环境与配置文件在该实例存续期间保留；停止后仍是原容器的数据，永久删除时一起清除。`start` 会保留这些文件；工作区快照不包含 `$HOME`，因此使用 `restore` 克隆新实例时不会复制工具、登录状态或会话历史，需要重新执行准备脚本。

## 5. 日志、快照与取消

```sh
"$BIN/sandboxctl" sandbox inspect <id>
"$BIN/sandboxctl" sandbox read <id> prompt.txt
"$BIN/sandboxctl" sandbox snapshot <id>
"$BIN/sandboxctl" sandbox export <id> --out /absolute/path/snapshot.zip
"$BIN/sandboxctl" sandbox import <id> --from /absolute/path/snapshot.zip
"$BIN/sandboxctl" sandbox exec <id> --detach -- /bin/sleep 10
"$BIN/sandboxctl" sandbox wait <返回的execution_id>
"$BIN/sandboxctl" sandbox cancel <execution_id>
```

`snapshot` 显式保存后台恢复快照，不导出文件、不停止实例；也可在「配置与快照」点击「保存快照」。保存和导出完整快照要求该实例没有待完成执行，停止的实例也可保存。

普通命令结束、文件写入或导入后不自动压缩工作区。工作区文件本身直接保存在磁盘，快照只是额外的备份恢复点。新建实例保留初始快照，之后在显式保存、完整导出或停止时更新；停止后的文件编辑同样需要重新保存，才能进入供克隆使用的快照。

保存的是整个工作区的文件状态（包括空目录），不是命令列表，也不是增量补丁。不包含私有 HOME、进程内存或 GPU 状态；命令执行历史独立保存在后端。管理服务意外退出时，原工作区仍在，但最后保存的快照可能早于最近修改；启动原实例不会用旧快照覆盖原目录。

命令运行超时后先终止并清理其进程组；清理成功时该任务记录为失败，保留输出和超时原因，释放调度槽，同一实例及其他实例可继续执行，不需要人工恢复。即使程序在超时信号处理器中返回 0，也仍是超时失败。进程组清理不等于 GPU 已清空，不保证超时后立即测得的 GPU 性能稳定。

CLI 提交命令时，总截止时间为运行超时加 300 秒排队余量。排队中到达截止时间会直接失败并退出队列，不必等前一条命令结束；程序尚未启动，不因此隔离节点。前端等待结果不另设执行期限；停止、删除和完整快照按后台操作的实际完成时间返回。

前台等待执行时 Ctrl-C 请求取消该执行；`enter` 不退出，清理成功后可直接输入下一条命令。主动取消仍记录为 `cancelled`，即使信号处理器返回 0 也不记为成功；同一实例和其他实例无需人工恢复即可继续。

超时、取消、信号终止及输出超限都以确认进程组清理成功为前提：清理成功只结束这条任务，不隔离其他实例。空闲 Host 退出时该实例显示失败，先停止它，再启动原实例即可重新使用；执行期间 Host 失联、许可/关键执行记录异常或无法确认清理时，仍需要人工恢复节点。

系统热状态为 `critical` 时，新提交及尚未获得许可的任务保持排队，降温后自动继续；已运行任务不因此被强杀。等待不消耗 Sandbox 命令执行预算，期间可以取消任务、查看文件或停止实例。热暂停与节点隔离不同：降温不会自动清除已有隔离记录。

状态目录保存：`instances/<id>.json`、`checkpoints/<id>.zip`、`executions/<execution_id>.json`、各版本 bundle 与签名记录。快照从受限 Host 导出字节，恢复前校验 SHA-256。版本化 dylib 的同目录别名按 ZIP 符号链接条目保存；文件 API 不跟随链接，跨目录链接仍拒绝。移动到新容器后，含绝对路径的 CMake 构建缓存可能需要正常清理重建。日志有界；快照大小统计不是磁盘硬配额。快照保存失败（例如磁盘空间不足、文件变化或不支持的条目）会记录 `checkpointError`，保留上一份完整快照，不承诺能恢复尚未保存的数据。快照仅接受 ZIP 格式。

## 6. 停止、启动原实例与快照克隆

```sh
"$BIN/sandboxctl" sandbox stop <id>
"$BIN/sandboxctl" sandbox stop --all
"$BIN/sandboxctl" sandbox start <已停止的id>
"$BIN/sandboxctl" sandbox restore <已停止的id>
"$BIN/sandboxctl" sandbox shutdown
```

- `stop` 尝试保存工作区快照并关闭实例，不删除容器。
- `start` **启动原实例**：保留 ID、原工作区路径、私有 HOME、已安装工具和会话文件，使用当前版本 Host。不会还原快照或重放进程；即使快照超限，原目录完整时仍可启动。
- `restore` **从快照克隆**：校验已保存快照后返回全新 ID，只复制工作区，不复制私有 HOME。原实例保留。

启动前会检查原目录、归属及旧 Host 是否退出；原目录缺失、归属不明或节点隔离时拒绝启动，不新建空目录冒充恢复。旧 Host PID 仍存在（包括 PID 被其他进程复用）时会要求检查，不根据旧 PID 杀进程。冻结评测 Host 不能作为开发 Host 原地启动，请用快照克隆。

服务重启不会自动启动实例；需要逐个执行 `start`。停止/重启后旧 Handle 均失效，需重新授权。

### 删除 Sandbox

在图形界面先停止实例，再点击红色「删除…」。

永久删除需要显式确认：

```sh
"$BIN/sandboxctl" sandbox stop <id>
# 等待目标实例的执行结束；不自动取消其他实例任务。
"$BIN/sandboxctl" sandbox delete <id> --confirm
```

目标须已停止，且该实例无待完成执行；其他实例的运行或排队命令不阻止删除。节点隔离期间也可删除符合条件的实例，隔离状态保持不变。删除该实例所有已登记物理版本的容器内任务文件、运行 bundle、检查点与列表记录。独立导出的产物、执行日志与恢复审计保留。任务数据清空后尝试删除固定布局的系统容器空壳；macOS 拒绝时在 `warnings` 和删除审计中明确列出，不能当作整个目录已消失；不是磁盘安全擦除。删除不能撤销，重试使用完整 `sbx-UUID`。

任务数据删除失败保留 `delete-failed` 和错误信息，可以修复原因后重试；不能恢复部分删除的实例。仅系统空壳权限不足不阻止移除逻辑实例，但返回明确残留警告。实例记录全部物理身份。


### 删除与残留清理

所有实例停止、队列空闲且节点健康时执行。预览不删除；逐项出错继续，无自动重试。

```sh
# 只根据已完成删除/清理审计检查空壳，不重新启动 Host 删除新出现的数据
"$BIN/sandboxctl" sandbox cleanup-deleted
"$BIN/sandboxctl" sandbox cleanup-deleted --confirm

# 检查本状态目录的可信运行发布记录中未被认领的身份
"$BIN/sandboxctl" sandbox cleanup-unclaimed
# 将下面占位符替换为预览返回的完整 bundleID；可重复 --bundle-id
"$BIN/sandboxctl" sandbox cleanup-unclaimed --bundle-id local.metal-sandbox.instance-<uuid> --confirm
```

`cleanup-unclaimed` 不扫描整个 `Library/Containers` 猜测归属；归属记录不完整时拒绝清理。确认选中后永久删除对应任务数据；系统空壳被拒绝时状态为 `data-removed-shell-retained`。清理结果写入 `cleanup_audit`，部分未完成时 CLI 返回 1。

`Data/Desktop`、`Downloads` 等是 macOS 的标准目录入口，软链接不是额外授权。删除程序只 unlink 链接，绝不沿着它删除真实桌面/下载。空壳检查仅接受固定系统布局，出现未知文件时拒绝。

macOS 可能拒绝后台删除容器空壳。`cleanup-deleted` 可以重新检查和尝试清理，但不能修复系统权限；App 不会自动提权或更改系统安全设置。

删除结果窗口的「在访达中显示」会选中该次已确认的容器目录。也可以将删除警告中的完整物理 bundleID 交给 CLI（不是 `sbx-...` 逻辑 ID）：

```sh
# 只预览路径，不打开访达
"$BIN/sandboxctl" sandbox reveal-containers local.metal-sandbox.instance-<uuid> --preview
# 在访达中选中；可同时给出多个完整 bundleID
"$BIN/sandboxctl" sandbox reveal-containers local.metal-sandbox.instance-<uuid>
```

这两个命令只定位，不删除、不移动容器；已不存在的目录会略过。不会沿软链接跳转到其他路径，且不需要停止其他实例或重启服务。

如需人工清理，只处理删除警告中**已清空且精确列明**的容器：在 Finder 中核对完整名称后移到废纸篓，再按需对该单项执行“立即删除”。不要按前缀全选删除、清空其他废纸篓内容，或删除链接指向的真实目录。仅移到废纸篓仍可恢复；“立即删除”不可撤销，也不等于磁盘安全擦除。

服务重启不自动重放进程；未完成实例/执行记录改为 `interrupted`。管理器异常退出时 Host 通过私有管道 EOF 取消自己正在执行的子进程；原活动租约保留。PID 只用于记录，不依据历史 PID 盲目杀进程。

仅在人工检查完遗留进程和 GPU 状态后确认恢复。恢复时不能有普通任务命令正在执行；正常连接的 Agent 主会话及等待中的命令可以保留。失联实例须先停止：

```sh
"$BIN/sandboxctl" sandbox recover --confirm-processes-cleaned --note '填写实际检查结果'
```

隔离期间，已有实例提交的命令保持等待，等待时间不消耗执行预算，仍可取消。人工确认恢复后按原队列继续执行，正在运行的 Agent 主会话无需重启。已经失败的命令、已经退出的 Agent 和已删除实例不会自动重放或重建。

恢复会归档失效租约及检查说明，保留正常 Agent 主会话的活动租约。普通 scoped Agent 无恢复权限。命令结果的 `cleanupDiagnostics` 记录进程组查询次数、查询和终止信号的错误码。

## 7. Agent/Verifier 与 scoped API

```sh
"$BIN/sandboxctl" sandbox grant <id> --operations read,write,export,exec --out /absolute/path/handle.json
"$BIN/sandboxctl" sandbox --handle /absolute/path/handle.json exec <id> -- echo scoped
```

Handle 是管理 API 的权限凭据，不改变 Finder、终端或实例内进程的文件权限。仅交给可信工具适配器，不传给候选程序。做题与验收见[题包与验收](task_packages.md)。

## 8. 当前限制

当前功能与缺项见[版本范围](../../README_ZH.md#本版范围)。本版不保证任意恶意进程树或异常 GPU 工作能够完整清理；不要用于不可信任务。

可通过[图形界面](frontend.md)调用同一套 CLI。App/DMG 使用本地 ad-hoc 签名，Developer ID 公证未完成。退出前端不停止服务；卸载前先正常关闭管理服务。删除 App 不会删除实例或工作区。

## 名称

```sh
"$BIN/sandboxctl" sandbox create --count 3 --name "毒蘑菇"
# 名称：毒蘑菇 (1)、毒蘑菇 (2)、毒蘑菇 (3)
"$BIN/sandboxctl" sandbox rename "$ID" "我的实验"
"$BIN/sandboxctl" sandbox rename "$ID" ""  # 清空名称
```

名称是可选显示信息，可重复，不作为 ID 或目录名。`list`/`inspect` 返回 `name`；`list -h` 同时显示完整 ID 和名称。重命名不需要启动实例，也不重启正在运行的命令。前后空白自动移除，名称须为单行。

## 体验串行调度

先启动管理服务，确认没有待完成命令，在源码根目录运行：

```sh
python3 examples/demo_gpu_queue.py
```

脚本创建两个实例，将同一份 `metal_queue.mm` 上传并在各自工作区编译，然后连续提交两条约 20 秒的 Metal 任务。需要 Command Line Tools 或 Xcode，不需要离线 Metal Toolchain。

无人提交其他任务时，总览的待完成数为 **2 → 1 → 0**：A 运行/B 排队，随后 B 运行，最后全部结束。脚本核对开始、结束时间不重叠，不检测 GPU 调用。其他并行任务和系统应用可能使用 GPU，演示期间请保持空闲。

实例及 `gpu_queue_demo/` 文件会保留。复用两个活动实例时：

```sh
python3 examples/demo_gpu_queue.py --sandbox-a sbx-AAAA --sandbox-b sbx-BBBB --seconds 20
```

复用会覆盖示例目录下的同名文件；`--cli` 可指定安装在其他位置的 sandboxctl。中断观察脚本不会取消已提交任务；结束后可正常停止或删除这两个实例。
