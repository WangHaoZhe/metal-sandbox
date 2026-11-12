# 节点集群

所有 Sandbox 操作提交到管理节点。管理节点通过 SSH 调用从节点的公开 CLI；候选程序由执行节点的 App Sandbox Host 启动。

## 节点准备

- 每台 Mac 安装同版本 Metal Sandbox 及任务所需的编译器、SDK、依赖。具体步骤见[安装与最佳实践](installation.md)。
- 从节点启用 macOS“远程登录”。可以使用前端添加节点向导配置 SSH，也可以自行配置非交互 SSH 认证。
- 各节点运行自己的 `metal-sandboxd`，使用非 root 用户。服务不自动安装系统账号或后台启动项。
- 普通实例的文件保存在所属节点。启用动态调度后，每个实例的数据仍保存在所属节点的本地磁盘，同池执行节点通过 SMB 直接访问它。目录应支持读写、可执行文件、文件权限和 security scope。

SMB 可通过 macOS 文件共享提供共享目录。需要事先挂载；节点不会自动挂载或修改文件共享设置。网络卷的权限与执行支持需要在目标机器上检查。

各节点配置相同的 `sharedRoot`，例如 `/Users/Shared/metal_cluster_nodes`。每台节点的
本地数据位于 `sharedRoot/本机节点名称/`，将这个子目录作为 SMB 共享导出；同池其他
节点将该共享挂载到相同绝对路径。不要导出包含其他节点挂载点的整个 `sharedRoot`。

例如，节点 `node_a` 的实例使用：

```text
/Users/Shared/metal_cluster_nodes/node_a/sbx-实例ID/workspace
/Users/Shared/metal_cluster_nodes/node_a/sbx-实例ID/home
```

这些路径在 `node_a` 上对应本地文件，在其他执行节点上对应访问 `node_a` 的 SMB 挂载。
新建实例会检查所属节点的存储目录位于本地文件系统，避免继续把数据集中写入远端。
迁移只改变执行位置，不移动文件；文件流量直接往返执行节点与数据所属节点。

## 配置

在总览点击“创建 Sandbox”右侧的“添加节点”：

1. 填写节点名称、主机地址及登录用户名。高级选项可设置 SSH 端口、远端 CLI 路径、状态目录和最大并发实例数。
2. 核对主机指纹，输入从节点的登录密码，点击“确认指纹并连接”。向导安装公钥，并检查密钥认证及远端管理服务。已有专用密钥认证时，密码可留空。
3. 确认节点环境并保存。本机没有活动实例及待完成命令时，可立即重新启动管理服务；其他情况下，配置在下次启动服务时生效。

密码通过进程管道传递，仅用于本次认证，不保存在配置和操作记录中。专用 SSH 密钥位于本机 `~/.ssh/metal_sandbox_cluster`，主机公钥保存在 `~/.ssh/metal_sandbox_host_*`；远端公钥授权写入该账号的 `~/.ssh/authorized_keys`。已保存的主机密钥发生变化时，连接会被拒绝，需要人工核实。

总览显示本机实际运行的角色，并在本机环境下方显示其他节点的机型、Metal 设备、内存、系统、服务版本、热状态及负载，随全局自动刷新更新。连接失败时保留最近读取的环境信息，底部以红色“节点异常”替换活跃实例和待完成命令数量。鼠标移入或点击“节点异常”会立即打开原生详情浮窗，可选择错误文本或点击“复制”。鼠标在文字或浮窗内时保持打开，离开两者后自动关闭；也可点击外部或按 Esc 关闭。恢复连接后自动显示当前状态。

本机和从节点环境框左半侧显示环境信息，右半侧显示 CPU、GPU 占用率及 Mem、Disk 的已用/总量。CPU 为两次系统采样之间的全机使用比例，GPU 为对应 Metal 设备的 IOKit 驱动统计，范围均为 0–100%；Mem 与活动监视器的“已使用内存”口径一致；Disk 读取用户数据卷的卷容量统计，不扫描文件，单位为十进制 GB。采样间隔至少 1 秒，页面随全局刷新读取。节点断线、设备无法提供统计或节点服务尚未更新时显示“—”。

在前端“连接设置 → 节点集群”选择本机角色：

- **单机**：只使用本机。
- **管理节点**：填写本机节点名称，通过“添加从节点”打开连接向导；已有节点可直接编辑。
- **从节点**：填写本机节点名称及集群工作目录。

每个节点可设置“最大并发实例数”，限制同时活跃的 Sandbox 数量，默认 32，可设置更大的非负整数。停止实例会释放名额；设置为 0 后不接收新实例。管理节点还可为每个从节点设置分配上限，留空则跟随从节点自身设置；两处都有设置时取较小值。

## 调度池

在管理节点的连接设置中，为本机及各从节点填写“调度池”。相同名称的节点组成一个池，每个节点属于一个池；未填写时使用 `default`。池名称区分大小写，可以包含中文和空格，最长 64 个字符。池按名称配置，不会自动根据机型分组。

- 将四台 M3 Max 填为 `M3 Max`，四台 M2 Pro 填为 `M2 Pro`，串行命令就只在各自的四台节点之间调度。
- 关闭某个节点的“允许跨节点调度”后，该节点既不调出，也不接收其他节点的命令；该节点仍可创建实例并执行本地命令。
- 实例还需要开启“允许动态调度串行命令”。节点开关和实例开关同时允许，才会进行跨节点调度。
- 新建 Sandbox 可以选择调度池，在池内按负载自动分配；选择“所有调度池”时沿用全群分配。关闭跨节点调度的节点仍可属于创建目标池。
- 从节点可以在自己的连接设置中关闭跨节点调度，或填写“允许的调度池”限制接收范围；留空不额外限制。管理节点不能越过从节点的本机限制。

管理节点使用 `schedulingPool` 设置本机归属，使用 `nodes[].schedulingPool` 设置各从节点归属。`crossNodeSchedulingEnabled: false` 关闭对应节点的双向调度；省略时允许。池配置同其他服务配置一起通过“保存并应用”生效。各节点应运行支持调度池的同版本服务。

所有池使用已配置的集群工作目录，实例记录保存数据所属节点。池限制执行节点范围，不改变工作区的位置或实例 ID。首次选择、排队后的重新选择和接收端申请执行许可都会检查池限制；已开始执行的命令继续等待原结果。

集群工作目录可留空；启用动态调度时，各节点填写相同绝对路径，并配置同池节点子目录的挂载。已有配置可通过“载入配置”导入表单。“另存为”可选择保存位置，默认保存在 `~/Library/Application Support/MetalSandboxUI/cluster.json`。

点击“保存并应用”后，空闲服务会重新启动以载入配置。有活动实例或待完成命令时仅保存，页面显示“尚未应用”；停止实例并等待命令结束后，点击“应用配置”。保存刷新间隔等不涉及服务配置的设置不会重启服务。从节点也需在本机的连接设置中选择“从节点”并应用，使用默认数据目录即可。

管理节点的 `cluster.json`：

```json
{
  "localNodeID": "manager",
  "maxConcurrentInstances": 4,
  "schedulingPool": "M3 Max",
  "crossNodeSchedulingEnabled": false,
  "sharedRoot": "/Volumes/metal_shared",
  "nodes": [
    {
      "id": "worker",
      "maxConcurrentInstances": 8,
      "schedulingPool": "M2 Pro",
      "sshDestination": "worker_user@worker.local",
      "cliPath": "/Applications/Metal Sandbox.app/Contents/Helpers/sandboxctl",
      "stateDirectory": "/Users/worker_user/Library/Application Support/MetalSandbox/native"
    }
  ]
}
```

`sharedRoot` 可省略；此时只能分配实例，无法开启动态调度。JSON 中不保存 SSH 密码或私钥。
向导添加的节点还会保存 `sshPort`、`identityFile`、`knownHostsFile` 和 `hostKeyAlias`，指定端口、SSH 文件及已确认的主机密钥名称。修改 IP 后仍校验同一主机密钥，主机密钥变化时拒绝连接。手工配置可以省略这些字段，使用系统 SSH 配置。

在前端选择“从节点”并保存后，也可以用其正式配置从终端启动服务：

```sh
BIN="/Applications/Metal Sandbox.app/Contents/Helpers"
"$BIN/metal-sandboxd" --allow-trusted-code --bin-dir "$BIN" \
  --cluster-config "$HOME/Library/Application Support/MetalSandboxUI/cluster.json"
```

在管理节点启动服务：

```sh
BIN="/Applications/Metal Sandbox.app/Contents/Helpers"
"$BIN/metal-sandboxd" --allow-trusted-code --bin-dir "$BIN" \
  --cluster-config /absolute/path/cluster.json
```

前端会自动载入已选择的配置文件。同一服务的节点角色、地址和容量通过“保存并应用”生效。切换 CLI 目录或状态目录前，先等待任务结束并关闭原服务。

## 创建与执行

```sh
"$BIN/sandboxctl" sandbox cluster
"$BIN/sandboxctl" sandbox create --count 4
"$BIN/sandboxctl" sandbox create --count 1 --dynamic-scheduling
"$BIN/sandboxctl" sandbox create --count 1 --node worker --dynamic-scheduling
"$BIN/sandboxctl" sandbox create --count 4 --pool 'M2 Pro' --dynamic-scheduling
"$BIN/sandboxctl" sandbox list -h
```

自动分配优先选择活动实例数量较少的可用节点，批量创建会计入已预约的实例。停止的实例不计入活动负载。前端新建窗口可以选择调度池、自动分配或指定节点，并设置“允许动态调度串行命令”。同时指定池和节点时，节点必须属于该池；未知池会直接报错。实例信息显示所属节点；总览显示各节点的池、跨节点调度状态及负载。

创建、启动原实例和从快照克隆都受上限约束，满载时 CLI 返回退出码 75；同一批创建超出当前剩余名额时拒绝提交。单机服务也可通过 `metal-sandboxd --max-instances N` 设置上限。串行执行槽与实例名额独立；动态调度的临时执行 Host 不创建新的逻辑 Sandbox 实例。

Harbor 的 Metal Sandbox 接入会处理退出码 75：多余 trial 在客户端等待名额，等待不消耗环境准备预算，取消等待不会创建实例。无需把 `n_concurrent_trials` 手工调低到集群容量；实例结束并停止后，后续 trial 继续启动。`delete: false` 会保留已停止实例，但不占名额。多步骤独立验收期间会暂时停止 Agent 的原实例、释放名额，验收结束后启动原实例继续执行，保留工作区和 HOME。

随后通过管理节点使用原有 `exec`、文件、准备、轨迹、验收、快照及停止命令。管理节点保存实例与执行 ID 的节点归属。

服务每次启动时清空命令索引 `cluster/executions.json`，保留实例索引、命令结果和轨迹文件。新命令及历史查询返回的执行 ID 会重新写入索引。重启后若要仅凭旧执行 ID 查询远端命令，须先查询该实例的执行历史，重新建立命令的节点归属。

状态、实例、执行记录、轨迹及文件的只读查询遇到 SSH 通信失败时，最多重试十次，
间隔为 0.5、1、2、4、8、16、32、64、128、256 秒；初次请求计入后共十一次尝试。
这些间隔合计 511.5 秒，连接本身的耗时另计。CLI 等待这类查询回复的上限为
1,920 秒。创建、命令提交及停止等修改操作保持单次提交。

## 回环服务转发

运行 Harbor 的主机可以将本机回环服务提供给从节点上的实例。Metal Sandbox 使用现有节点的 SSH 地址、密钥与主机校验配置，为转发保持独立连接。服务端 SSH 需允许远程端口转发，并使用 `GatewayPorts no` 或 `clientspecified` 保持回环绑定。

```sh
LEASE=$(uuidgen)
sandboxctl sandbox forward "$INSTANCE_ID" --port "$PROXY_PORT" --lease "$LEASE"
sandboxctl sandbox forward-status "$INSTANCE_ID" "$LEASE"
sandboxctl sandbox forward-close "$INSTANCE_ID" "$LEASE"
```

`INSTANCE_ID` 使用完整 ID；服务端口需已在调用方管理服务所在主机监听。实例通过相同的 `127.0.0.1:PROXY_PORT` 访问服务，不需要实例获得监听网络端口的权限。每个端口只关联一个租约，端口冲突或连接失败会明确报告。

租约需在 60 秒内续期。过期或管理服务关闭时释放 SSH 转发。到实例所属节点的转发进程意外退出时，管理节点在后台原地重建，租约 ID 不变；重建失败后每 10 秒重试。重建期间 `forward-status` 的 `readyNodeIDs` 不含所属节点，`nodeErrors` 说明原因。实例停止再启动会保留转发依赖，删除实例会清理所属租约。

## 动态调度

- 每个节点保留一个串行执行槽，并行任务继续在实例所属节点执行。
- 实例开启动态调度后，尚未开始的串行任务可以转交空闲节点。目标节点先预约执行槽，原节点确认移交后，目标节点才启动进程。
- 等待期间持续重新检查节点。原节点空闲时优先返回原节点；其他节点更早空闲时可重新选择。切换前撤销旧目标的启动许可并确认清理完成；旧目标已经开始执行时继续等待原任务结果。节点失联且无法确认执行状态时保留任务身份，恢复通信后继续处理。
- 节点隔离时不再接收新的执行许可，已有实例后续提交的命令保持等待。操作员确认恢复后继续原队列，正常连接的 Agent 主会话可以保留；已经失败的命令不自动重放。
- 工作区和 HOME 使用共享路径，TMPDIR 与执行日志属于执行节点。stdout、stderr、退出结果回传原任务。
- 跨节点任务使用执行节点自己的工具链。默认 PATH 中的工具目录及 CC、CXX、SDKROOT、DEVELOPER_DIR 等对应值按目标节点解析；直接调用已登记的编译器、Metal 工具、CMake 或 Ninja 时，其可执行路径也按目标节点解析。用户普通环境变量、自定义共享 PATH 及顺序保留，shell 脚本文本不改写。
- 命令参数或环境变量显式引用源节点私有目录时，命令留在源节点执行。源节点私有 PATH 也遵循此规则。脚本内部隐式读取的私有文件、进程和本地服务无法仅靠命令文本识别，依赖这些资源的实例应关闭动态调度。
- 管理节点仅向支持工具链环境转换的节点移交命令；更新集群时须同步更新各节点服务。
- Claude 的受调度 Bash 子任务和通过公开 CLI 提交的任务使用同一移交机制。共享工作区以外的子任务保留在原节点。
- 依赖回环服务的实例向任务携带转发租约身份。目标节点的转发在后台准备，就绪后才可接收该任务；端口冲突或转发失效的节点暂不参与该任务的选择。未知或过期租约不会被当作可用连接。
- 运行中的进程与 Metal 资源保持在执行节点，无法迁移。依赖本地 GUI、进程、socket、未共享文件或特定绝对路径的命令需要在原节点执行；此类任务应关闭动态调度。
- 连接中断后保留任务身份，重新连接查询原任务，不自动重复启动。取消请求传到执行节点，原节点等待清理结果。执行节点重启或清理不确定时保留人工检查要求。

共享目录不能保证多条命令修改同一文件时的应用正确性。任务需要自行协调文件写入；节点安装和共享路径必须保持一致。
