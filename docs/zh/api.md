# CLI 与原生 RPC

## CLI 入口

```sh
sandboxctl --version
sandboxctl --help
sandboxctl sandbox --help
metal-sandboxd --version
metal-sandboxd --help
evaluation-runner --version
```

完整操作示例见[使用指南](native_operations.md)。CLI 和 daemon 必须来自同一构建；自定义状态目录参数置于 `sandbox` 前。

- 管理命令输出 JSON；文件 read/exec/wait 输出文件或候选 stdout/stderr。
- 前台 exec/wait：正常候选退出时传播候选退出码；管理/传输/异常执行失败为 1。Ctrl-C 请求取消对应执行。
- `--detach` 返回执行记录/ID，不等于执行成功；用 wait 或 RPC `execution` 取结果。
- `enter` 接受普通命令或 `:run {"line":"pwd","timeout":30,"cwd":"."}`。配置只用于该条命令；`cwd` 可省略，沿用控制台当前目录。超时为有限正数秒数，不设固定时长上限；配置无效时不执行该命令，控制台继续接收下一行。`:run` 输出执行 ID 和退出码，不绕过调度。
- evaluation-runner：help/version 为 0，无参数/未知模式为 2；固定验收成功为 0，异常失败为非零。
- CLI 的 ID 唯一前缀由客户端解析；底层 RPC 使用完整 ID。
- `forward`、`forward-status`、`forward-close` 使用完整实例 ID 和调用方生成的 UUID 租约 ID，要求操作员权限。`forward ID --port N --lease UUID` 将本机回环服务提供给实例所在节点；`forward-status ID UUID` 检查并续期 60 秒；`forward-close ID UUID` 释放转发。端口范围为 1024～65535，实例需允许出站联网。
- `reveal-containers BUNDLE_ID... [--preview]` 是本机 CLI 动作，不是 RPC 或候选命令。仅接受完整的 `local.metal-sandbox.instance-<uuid>`，检查当前用户容器根目录下的同名真实目录；不扫描内容、不删除、不需要管理服务运行。默认通过 `NSWorkspace` 请求访达选中目录；`--preview` 仅输出路径。JSON 含 `ok`、`paths`、`missing`、`finderRequested`、可选 `warnings`；`finderRequested` 表示已发出请求，不代表收到 Finder 确认。

## 传输与身份

- socket：`/private/tmp/metal-sandbox-<uid>/native.sock`。
- 每连接一个请求/响应：4 字节大端长度 + UTF-8 JSON；单帧最多 16 MiB；最多 32 个处理中连接。
- 服务检查 peer UID；handler 另校验 `operatorToken` 或 `handle`。管理器每次启动轮换操作员 token；实例停止/服务重启使旧 handle 失效。
- token 存在状态目录 `operator_token`，不是给 Agent 的凭据；scoped handle 仅在可信控制面保存。
- 必填 `requestID`、`operation`；响应回显 requestID、ok 及相应载荷。错误为 `ok:false,error`；非法帧可能直接断开。
- 可分支处理的错误另带 `errorCode`；`instance_inactive` 表示实例没有活动会话。不要比较 `error` 的显示文字来决定程序行为。
- **没有请求去重或自动重试保证。** 响应丢失时先检查实例/执行列表，不能盲目重新提交。集群中，管理节点向从节点中继请求失败时，只对只读查询（status、list、inspect、execution、executions、trajectory、ls、read、workspace-location）自动重试，最多 10 次，间隔 0.5～256 秒；其他操作只尝试一次。
- 例外：已完成的 `delete` 按完整实例 ID 返回删除审计，可幂等重试；CLI 不会自动重试。

## 操作

| operation | 主要输入 | 输出 | 权限 |
|---|---|---|---|
| status / list | 无 | status / instances | 操作员 |
| create | count、name（可选）、networkClient（默认 true）、taskPolicy（可选 JSON）、environment（可选） | instances | 操作员 |
| rename | instanceID、name（空字符串清空） | instance | 操作员 |
| port-forward-open | instanceID、forwardID（UUID）、forwardPort | portForward | 操作员 |
| port-forward-status | instanceID、forwardID | portForward（续期） | 操作员 |
| port-forward-close | instanceID、forwardID | confirmed | 操作员 |
| inspect | instanceID | instance | 操作员或所属实例 read |
| restore | instanceID | instance | 操作员 |
| grant | instanceID, operations | handle | 操作员 |
| read / write | instanceID + path / file | file / 成功 | 对应实例权限 |
| ls | instanceID, path（默认 `.`）, after（可选条目名） | directory | read |
| export | instanceID | files | export |
| exec | instanceID, command | execution（异步记录） | exec |
| execution / cancel | executionID | execution | 所属实例 exec |
| stop | instanceID | instance | stop |
| delete | instanceID, confirmed=true | instance（deleted）, warnings | 仅操作员 |
| cleanup-deleted / cleanup-unclaimed | confirmed（默认 false）, bundleIDs（未认领确认时必填） | cleanup 数组 | 仅操作员 |
| recover | confirmed=true, note | status | 操作员；检查/清理后 |
| shutdown | 无 | 成功 | 操作员 |

`status.loopbackForwardingImplemented` 表示支持回环服务转发。`portForward` 包含租约 ID、实例 ID、端口、所属节点、已就绪节点、失效时间和节点连接错误。同一租约与端点的创建请求可重复查询；关闭请求可重复提交。过期租约不能通过续期恢复。

CLI `read/write/export/import` 使用 `download/upload` 分块 RPC：download 的 `path` 非空时要求 read 权限，省略时要求 export 权限；upload 要求 write 权限。先接收带 requestID 的就绪响应，再传输最多 256 KiB 的数据块，空结束块终止；upload 最后返回完成响应。文件与快照没有总字节大小上限，16 MiB 仅为单个 IPC 帧限制。快照是支持 ZIP64 的标准 ZIP 归档，使用 ZIPFoundation 0.9.20 分块读写并校验 CRC32，包含空目录；后台保存的快照另记录 SHA-256。导入先完整接收并校验，再逐文件原子替换，不删除其他文件；写盘失败可能已写入部分文件。内联 read/write/export RPC 供 Swift 会话接口和基础设施自测使用，受单帧大小限制；大文件使用分块 RPC。

`snapshot` 接受 `instanceID`，使用 export 权限，在该实例空闲时保存后台快照，并在 `instance` 返回更新后的快照摘要。停止实例需要操作员权限。服务通过 `explicitSnapshotsImplemented` 声明此能力。命令结束、写入和导入不触发快照；新建实例生成初始快照，此后仅显式保存、完整导出及停止更新。

准确字段定义以 `sources/sandbox_runtime/control_protocol.swift`、`protocol.swift` 为准。Swift 集成使用 `RemoteSandboxSession` 和 `SandboxHandle`。

CLI `sandbox import ID --from DIRECTORY --task` 只接受题包文件夹，不接受 ZIP。CLI 只打包其中的 `agent/`，校验 `agent/instruction.md` 和 `agent/setup.sh` 为非空普通文件，再将内容导入 workspace 根目录；`tests/` 不进入该归档。缺失时不上传，不能用旧工作区文件补齐。该选项复用现有上传协议，不执行脚本；不带 `--task` 时仅接受 ZIP 快照。

实例执行期间允许 `ls`、`read` 和指定单个 `path` 的 `download`，仍校验 read 权限及工作区路径。读取是实时观察，不是冻结快照；文件在传输中变化时返回可重试错误，不替换已有完整下载。`write`、`upload`、`export` 和不指定 `path` 的 `download` 仍与执行互斥。

### 数据结构

- `doctor` 和 `status.host` 的 `modelIdentifier` 为系统 `hw.model` 原值，例如 `Mac17,2`；`productName` 来自 IOKit 的 `IODeviceTree:/product` 中的 `product-name`。前端原样显示系统产品名称，例如 `MacBook Pro (14-inch, M5)`；系统未提供名称时显示“无法读取机型”。
- `doctor` 和 `status.host.utilization`：`cpuPercent`、`gpuPercent` 为 0–100 的占用率；`memoryUsedBytes`/`memoryTotalBytes` 为已用与物理内存字节数；`storageUsedBytes`/`storageTotalBytes` 为用户数据卷的已用与总容量字节数。无法读取的项不返回数值，CPU、GPU、内存和存储分别用 `cpuError`、`gpuError`、`memoryError`、`storageError` 说明原因；旧版本服务不返回内存和存储字段。
- `WorkspaceFile`：`path`（相对路径）、`data`（Base64）、`executable`（布尔），可选 `linkTarget`（仅同目录别名，data 必须为空且 executable=false）；文件 API 不跟随链接。
- `NativeCommand`：`argv`、`cwd`（相对路径，默认 `.`）、`timeoutSeconds`、`maxLogBytes`，可选 `environment`（单次环境变量）、`deadlineUptimeNanoseconds`、`agentSession`（仅操作员可设为 true；CLI 对应 `--session`，主会话不占串行槽）。
- `WorkspaceEntry.executable`：文件是否具有执行权限，供目录下载保留文件属性；目录及特殊条目为 false。
- 管理器在准入时将 clang 等程序名解析为已安装的绝对路径，并提供 SDK 适配；Host 最终只接收绝对路径或 `./...`。
- timeout 为有限正数秒数（无固定业务上限）；日志 1 KiB–4 MiB；均不是硬件资源配额。
- `timeoutSeconds` 从获得执行许可后计时。Agent 会话的子任务全部等待调度、且没有子任务运行时，会话预算暂停；同时等待的多个子任务只扣除一次等待时间。显式 `deadlineUptimeNanoseconds` 使用本机单调时钟，不能跨机器复用。
- `status.queueTimeoutExclusionImplemented=true` 表示支持排队时间扣除；`execution.schedulerWaitSeconds` 返回累计调度等待秒数，包含正在等待的时间，供外部 harness 的阶段预算使用。
- Data 为 Base64，日期为 Unix 毫秒；`NativeResult` 保存 outcome/stdout/stderr/leaseID/queueWaitSeconds。
- `outcome.reason=launchFailed` 表示系统未能创建候选进程，`processID=0`、`launchError` 说明原因；任务失败并释放许可，无需节点恢复。已启动进程的清理不确定性仍按隔离规则处理。
- 原生状态含 `serviceVersion` 和 `protocolVersion`。协议版本 1 不等于产品版本 1.0。
- `status.taskPolicy` 返回新建实例的默认调度规则：仅含 `parallel`（白名单，命中并行）或 `serial`（黑名单，命中串行）数组，未命中走另一执行类别；两字段不能同时出现。规则使用绝对 `executable`、数组 `argumentPrefix`，空白名单全串行、空黑名单全并行。`executionSlots` 每个节点计一个串行槽；管理节点的状态汇总可用集群节点的串行槽，不包含并行任务。`status.pendingExecutions` 包含顶层任务和已登记的 harness 工具命令，不论串行或并行；排队、执行和结束清理期间均计入。
- `perInstanceTaskPolicyImplemented=true` 表示支持 `create --task-policy FILE`；创建请求中的 `taskPolicy` 替换默认值并存入实例记录。`inspect` / `list` 的 `taskPolicy` 是各实例实际使用的配置；恢复沿用。仅操作员可创建实例及指定此策略。
- `NativeExecutionRecord.scheduling` 为 `parallel` 或 `serial`。它表示整项任务的调度类别，不是检测到的 GPU 使用情况；`startedAt` 为任务取得执行许可的时间。
- 实例响应中的 `pendingExecutions` 按实例汇总相同范围：主会话加其未完成工具命令，以及其他顶层命令；不是系统进程数。`list` / `inspect` 每次从服务实时计算，空闲为 0。

### 目录列表

`sandboxctl sandbox ls ID [REL] [--after NAME]` 返回 JSON `directory: {path, entries, nextAfter?}`。每个 entry 含 `name`、`path`、`kind`（directory/file/symlink/other）、`size`（字节）、`modifiedAt`（Unix 毫秒）。每页最多 256 项，按名字排序；有 `nextAfter` 时，以它作为下一次 `--after`，没有则结束。只列直接子项，包含隐藏项；不读内容、不跟随链接。单目录扫描上限 100000，超限明确失败。动态目录可能在分页间变化，请刷新，不视为原子快照。

活动实例使用现有 `read` 权限；停止实例只允许操作员通过受限文件维护 Host 访问，不复活旧 Handle。拒绝冲突及越界路径。`status.directoryListingImplemented=true` 表示服务实现此接口。目录名与选项同名时使用 `ls ID -- REL [--after NAME]` 明确指定路径。

### Agent 轨迹（只读）

`trajectory ID` 返回 `trajectory.sessions`：`id`（供 `--session` 使用）、`sessionID`、`source`、`harness`、`modifiedAt`。列出最近 256 个会话；超过时返回 `sessionsTruncated=true`。`trajectory ID --session PATH [--after CURSOR]` 返回 `trajectory.harness`（解析器标识为 `claude` 或 `codex`）和 `trajectory.page`：`data`（Base64，最多 256 KiB）、`nextAfter`、`reset`、`atEnd`。将 `nextAfter` 原样传回继续读取；`reset=true` 时丢弃旧缓存。字节块不保证在 UTF-8 或 JSON 行边界结束；客户端应按 harness 选择解析器并缓冲到换行后解析。`atEnd` 只表示暂时读到文件尾，不表示会话已结束。

服务能力 `trajectoryImplemented=true`。RPC 操作 `trajectory` 使用 `instanceID`、可选 `path`（会话 ID）和 `after`。需要实例 `read` 权限，在执行期间可用，不提交命令、不排队。只读取已注册的 Claude 和 Codex 适配器认可的会话日志；拒绝其他路径及链接、硬链接、特殊文件，不提供任意 HOME 读取接口。mini-swe-agent 轨迹保存在工作区的 `mini_swe_agent_runs/<session>/trajectory.json`，可通过文件页或 CLI 导出读取。日志包含对话及工具输出，分享前注意敏感内容。

### 停止实例的文件操作

`stoppedFileAccessImplemented=true` 表示停止实例也支持目录、文件、准备文件、题包导入、快照导入导出和轨迹读取。实例状态不变，不启动 Agent，不占执行槽。由相同容器身份的受限 `--files-only` Host 完成，禁止 exec；闲置维护进程自动回收，启动或删除实例前先关闭。写入直接保存工作区；快照通过显式保存、完整导出或停止更新。管理服务仍需在线，旧 Handle 不会因文件访问而重新有效。

`reveal-file ID REL [--preview]` 先通过 Host 校验真实工作区文件/目录，再由 CLI 请求 Finder 选中；`--preview` 只返回目标，不打开 Finder。RPC `workspace-location` 只允许操作员，返回 `workspaceLocation`。能力字段为 `workspaceRevealImplemented=true`。

### 执行历史

`executions [--instance ID] [--limit N] [--before EXEC_ID]` 返回轻量 `executions`、所有未完成的 `pendingExecutions` 和可选 `nextExecutionCursor`，不包含参数全文或输出。`execution EXEC_ID` 返回完整命令、状态和已有结果。按执行 ID 合并，已删除实例的执行记录仍保留。需要操作员权限；能力字段为 `executionHistoryImplemented=true`。

### 实例环境配置

`create --env-file FILE` 读取字符串键值 JSON，与该批实例分别绑定。RPC 创建请求使用可选 `environment` 对象；省略时为空，不从管理器环境中复制凭据。

`env ID` 只返回 `environmentKeys`；`env ID --show-values` 显式读取 `environment`；`env ID --from FILE` 整体替换配置，传 `{}` 清空。RPC 为 `environment` 操作，使用 `instanceID`、可选 `environment`，或读取时设置 `revealEnvironment=true`。这些接口只允许操作员使用，无需启动目标实例。能力字段为 `environmentImplemented=true`。

配置值不加入 `list`、`inspect` 或执行记录，也不在命令行参数里逐项传递；临时输入文件应设为 0600。值仍可被实例内程序读取，程序主动输出不属于日志脱敏保证。删除实例同时删除私有环境配置。

`exec ID --env-file FILE` 为单条命令提供字符串键值 JSON；`--env-file -` 从 stdin 读取。
RPC 使用 `command.environment`，覆盖本次执行的同名实例变量，并参与 shell 调度分类。
这些值不写入实例配置、执行历史或快照；命令主动输出、写文件仍可能暴露其值。
并发执行各自使用自己的环境。能力字段为 `commandEnvironmentImplemented=true`。
保留变量 `HOME`、`TMPDIR`、`WORKSPACE` 和 `METAL_SANDBOX_*` 不接受覆盖。

### 实例与执行状态

`status`、`list` 和 `inspect` 的实例对象提供 `executionCounts`：

```json
{"parallelRunning":2,"parallelWaiting":0,"serialRunning":1,"serialWaiting":3}
```

分别表示并行执行中、并行等待中、串行执行中、串行等待中；同一响应内四项之和等于 `pendingExecutions`。每个节点最多运行一条串行任务。执行中从获得调度许可起计算，直到执行及清理返回；等待中包括派发、串行排队和过热暂停。Agent 主会话与经适配器提交的 Bash 子任务分别计数，普通后代进程不额外计数。实例对象为该实例的计数；`status` 汇总本节点计数，在管理节点上调用时则汇总可用集群节点的计数。这是任务统计，不是 GPU 空闲证明。

`status.networkClientImplemented=true` 表示支持创建时可选出站联网。CLI 默认联网，使用 `create --count N --no_network` 关闭；RPC 创建请求省略 `networkClient` 为 true，显式 false 关闭；`NativeInstanceRecord.networkClient` 返回选择。权限覆盖整个实例及其子进程，不是按域名授权；运行中无修改接口，恢复新实例沿用该选择。

实例可能处于 starting/active/publishing/stopped/interrupted/failed/cleanup-failed 等状态；恢复创建新逻辑 ID，不重放旧进程。执行为 queued/running，终态为 succeeded/failed/cancelled/interrupted。业务正确性不等同于进程退出码 0。

实例响应中的 `availableActions` 列出当前可用入口：`start`、`stop`、`delete`、`restore`、`files`。客户端据此显示操作，而不是从状态文字推断；例如仍有活动会话的失败实例可停止，历史失败实例则没有停止入口。提交时服务仍重新检查权限、队列和目录归属。

`appSandboxBackend=true` 表示原生 App Sandbox 后端已启用。范围见[README](../../README_ZH.md#本版范围)。

删除要求目标实例不活动且其自身没有未完成命令；不要求其他实例的队列空闲，也不取消其他实例的任务。删除状态为 `deleting` / `delete-failed`；成功后只在 `deleted_instances` 中保留 `deleted` 审计，不再出现在 list。失败状态不能恢复检查点。`ownedBundleIDs` 包括所有分配过的物理版本（含失败发布）；归属缺失、不完整或冲突时拒绝删除。系统空壳权限不足保存在 `cleanupWarnings` 并返回 `warnings`，不等于整个容器目录已消失。`status.permanentDeletionImplemented=true` 表示支持删除接口，不是安全认证。

### 残留清理结果

`cleanup` 元素为 `bundleID, source, state, error?`；state 为 `planned`、`removed`、`data-removed-shell-retained` 或 `failed`。确认后逐项继续，无自动重试；CLI 在残留或失败时返回 1，RPC 仍返回完整数组。未认领清理须选择精确身份；默认仅预览。所有实例须停止，队列须空闲，节点须健康。

`containerShellDeletionImplemented` 表示接口支持，不保证 macOS 授权删除系统空壳。

### 实例名称

`create --name NAME` 为可选显示名称；一次创建多个实例时加 ` (1)`、` (2)` 等后缀。`rename ID NAME` 对应 RPC `rename`，只允许操作员修改 `name`；空字符串清空名称。名称可重复，去掉前后空白，拒绝内部控制字符。支持运行中或停止实例，修改只更新元数据，不启动 Host 或修改工作目录。`list` / `inspect` 返回可选 `name`；CLI 操作始终使用 ID。
