# 安全边界

**只允许可信本地开发，不是生产级多租户或恶意代码执行服务。**

## 执行与权限

| 项目 | 本版行为 |
|---|---|
| App Sandbox | Host 已启用；helper 固定 inherit entitlement |
| 文件 | 独立应用容器；受限侧文件 API；必要系统/SDK 访问 |
| 网络 | 默认允许 client 出站；--no_network 关闭，无 server 权限 |
| 管理 IPC | same-UID peer + 操作员 token/scoped capability |
| 任务调度 | 白名单命中并行，黑名单命中串行；不是 GPU 检测，不保证 GPU 独占 |
| 适用范围 | 可信本地开发 |

每 UID 只能运行一个管理器。公开执行入口通过受限 Host 启动，不提供裸机 fallback。

**当前已知风险：** 已有报告指出候选借助 LaunchServices 另起应用时可能脱离 Host 的继承限制，访问宿主文件。该风险尚未封堵，因此不能将本版用于不可信代码。

黑白名单均由操作员按精确工具路径及参数前缀配置，涵盖每项任务及其子进程，不单独拦截任意后代。配置了 Claude Bash 适配器的会话中，每次 Bash 调用是独立任务边界；主会话并行并不授予额外文件或网络权限。黑名单模式下，未匹配的程序（包括未知 GPU 程序）默认并行；空黑名单允许全部普通任务并行。`make`、`ninja`、`cmake --build` 默认并行，但构建可运行任意测试或 GPU 程序；不要把名称白名单当成安全边界或正式性能隔离。非白名单串行任务也可能被并行构建影响。需要所有受管理命令串行时，所有活动实例均须采用空白名单，且主会话中的执行必须接入适配器，仍无法控制其他 macOS 应用负载。

桌面前端属于可信操作员控制面，**自身不启用候选 App Sandbox**，不应被当作隔离层。它仅以参数数组启动内置/用户选择的 CLI，读取 CLI 的公开输出和用户选定的文件；不直接读取管理凭据、内部状态或容器。真正的沙箱策略仍由 Host 的固定签名和后端实施。不要将 CLI 目录指向不可信程序。

## 原生模式文件边界

- OS 边界是应用容器及 App Sandbox 允许的系统资源，**不是仅 workspace 一棵目录**。候选可写自己的容器、允许的临时/缓存位置；HOME 只是便利路径。
- 普通受限进程不能任意访问其他实例或宿主目录，系统/framework/SDK 的必要读取仍可用。通过 LaunchServices 启动的应用存在上述越界风险。
- 文件 API 使用目录 FD/openat，拒绝路径穿越、链接跟随、硬链接和特殊文件；快照可以保存并恢复仅指向同目录名字的 dylib 别名，不读取其目标。跨目录符号链接仍拒绝。文件和快照没有字节大小上限，不提供磁盘硬配额；应预留工作区、临时归档和已保存快照的磁盘空间。
- 不授予用户选择任意文件的 read/write 或应用组权限；Agent 不能提交自己的签名策略。出站联网只能由操作员创建时选择；开发专用权限精确范围见下节。
- 设计上不向候选传入 token、控制管道 FD 或隐藏真值；这不构成对越界后读取宿主凭据的保证。Agent 工具适配器属于可信控制面，只向模型暴露所属实例操作，不暴露宿主 shell。

## 原生开发策略

Host 使用 `app-sandbox` 加以下 Apple 公开 entitlement：

- `files.user-selected.executable`：配合已授权的目录 scope，允许生成可直接运行的程序。
- `files.bookmarks.app-scope`：仅为自己容器内 `workspace`、隔离 `home`、`tmp` 创建并激活 security-scoped bookmark；不从 Agent 接收宿主 bookmark。
- `network.client`：新建实例默认加入；操作员使用 `create --no_network` 时不加入。允许该实例及其后代发起出站连接（含回环/局域网），不是域名过滤、代理隔离或凭据管理；不加入 `network.server`。既有实例保持原联网选择，不能热切换。
- `temporary-exception.files.absolute-path.read-only`：路径由控制器按实例身份固定到上述三个目录，以及操作员专属 CMake/Ninja 目录和 `xcrun` 解析出的具体 Metal `.xctoolchain` 只读目录。该 Apple 例外同时允许从这些目录执行。三个实例目录原本已可读写；工具目录只读，不增加宿主 Home、整个 `/var/run` 或其他实例的授权。Metal cryptex 用 `realpath` 固定实际目录；系统更新/重新挂载后须重启服务重新解析。
- 集群动态调度实例加入 `temporary-exception.files.absolute-path.read-write`，仅授权配置的共享根目录内该实例的 `workspace/` 与 `home/`。其他实例及共享根目录整体不加入权限。SSH 由管理服务发起，候选不接收 SSH 凭据或管理 token；执行节点使用自己的受限 Host 和串行许可。

Host 启动时激活 scope，失败拒绝运行；签名校验比较**全部 entitlement 的精确键值与目录**，不只是检查 `app-sandbox=true`。打包 helper 仍仅有 `app-sandbox + inherit`。普通直接启动的子进程继承父进程 sandbox；LaunchServices 另起应用不能套用这个保证。策略不依赖逐条命令名判断安全。

这些权限用于支持原生开发。没有调用私有 sandbox API、修改系统 profile、手动删除 quarantine、授权整个 Home 或给每个候选伪造 entitlement。Apple 的 temporary-exception 不保证跨 macOS 版本兼容。

准备脚本只在所选实例内运行。私有 `$HOME/.local` 可保存较大的 CLI 安装，`$HOME/.claude` 等工具配置不来自宿主 Home，也不纳入当前 workspace 快照。启用网络的程序能够发送其可读数据；不要在未审查的脚本中放入真实凭据。安装示例不导入宿主账号或 keychain 登录，不自动配置模型 API key。

机制依据：[Apple App Sandbox entitlement 说明](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html)、[Apple 临时文件访问例外](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html)。

## 永久删除边界

仅操作员可提交 `delete --confirm`。管理器要求目标不活动、该实例无待完成执行；其他实例的运行或排队命令不阻止删除，也不会被自动停止。节点隔离期间可删除符合条件的实例，删除不会解除隔离。按已记录身份创建固定签名的维护 Host，由其在自己的 App Sandbox 内删除容器任务文件，不从非沙箱管理器遍历任务内容，也不启动旧候选程序。目录 FD / openat / unlinkat 不跟随 symlink，不截断 hardlink，不跨挂载点；保留两个目标严格校验的系统安全偏好别名。

成功后删除工作区、检查点、运行 bundle 和实例列表记录；独立产物、执行日志、物理会话审计、恢复记录和删除审计保留。Host 正常退出后，控制器仅校验并尝试删除固定布局的空壳：容器元数据、普通 `.DS_Store`、Data/Library/Preferences 和两个精确目标的系统链接。使用固定根目录、目录 FD、O_NOFOLLOW、inode/device 校验；不接受候选提供的宿主路径。未知条目拒绝，权限不足明确返回残留警告，不绕过 macOS 保护。这不是 SSD 安全擦除或所有系统临时/缓存的取证清理。

删除要求完整且无冲突的物理归属记录，缺失时拒绝操作。残留清理默认预览，范围仅来自本状态目录的删除审计或未认领的可信 publication；确认时精确选择身份，不按 Containers 前缀全删。

## 未覆盖的威胁

- App Sandbox 不是 VM：与宿主共享内核、Metal 驱动、物理内存和 GPU。
- 任意脱离进程组/双 fork 后代、所有 Mach IPC、fork bomb、完整资源硬配额尚未验证或完成。
- 同 UID 的**其他非沙箱宿主进程**仍可能读取管理状态/token、篡改记录。不能抵御已控制宿主账号的攻击者。
- 文件哈希用于完整性校验，不是可信签名/防篡改审计；原子文件写入不等于掉电事务一致性。
- 队列不控制其他应用，不支持 GPU 切片或可信 drain；不得把样例 GPU 时间作为训练奖励。

## 强制终止与恢复

运行超时、主动取消、信号终止或输出超限且进程组确认清理后，仅将该任务记为失败或取消并释放租约，允许可信开发继续，不自动隔离节点。**这不是 GPU drain 认证：CPU 子进程退出不证明 GPU 工作已清空。** 失败任务不能算作通过，其后的 GPU 性能测量也不能据此认为没有残留影响。

Host 在没有执行任务时退出，只标记该实例不可用；停止该实例后可启动原实例，不影响其他实例。执行期间 Host 失联、管理器崩溃留下的执行标记、不确定清理、许可错乱或关键执行记录无法保存，仍保留节点隔离和人工恢复。

系统热状态为 `critical` 时，未获许可的任务等待降温，不新建隔离标记、不强杀已运行任务，也不把已经完成的任务改判失败。热状态恢复为非 `critical` 后继续按原队列与策略执行；等待不消耗 Sandbox 命令执行预算，期间可取消。降温不会解除已有的节点隔离。

操作员须核对实际进程身份、残留任务、GPU/系统稳定状态；必要时重启机器。不要依据旧 PID 盲目发信号，不要删除 `active-lease.json`、`parallel_leases` 中的租约或在训练循环中自动确认恢复。随后按[使用指南](native_operations.md)带检查说明恢复。恢复要求没有普通任务命令正在执行；正常连接的 Agent 主会话可以保留，失联实例须先停止。等待中的命令在隔离期间不执行，恢复后继续等待许可，已失败的命令不自动重放。

`recovery_history` 是恢复审计，不是活动锁或垃圾，不能为了重新测试而清除。

## 运行纪律

普通用户、专用开发环境、无生产凭据；不创建系统账号、不安装 launchd、不改防火墙、不运行 root daemon。禁止通过修改系统工具签名、移除候选 quarantine、未经说明扩大目录/网络权限或裸机 fallback 来“修复”失败。固定开发策略的任何后续变更都须记录边界并重跑拒绝测试。

若发现越界：停止提交、保留证据、隔离节点；排查后再恢复。与项目所有者私下共享最小复现和日志摘要，不公开 token、用户数据或隐藏测试。当前未设置公开安全响应渠道。
