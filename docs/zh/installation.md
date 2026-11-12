# 安装与最佳实践

运行环境需要 Apple Silicon Mac，以及 Apple Command Line Tools 或完整 Xcode。声明最低 macOS 13；兼容性限制见[本版范围](../../README_ZH.md#本版范围)。

## 环境要求与依赖安装

只开发 C/C++ 时，Command Line Tools 和完整 Xcode 二选一。要编译独立 `.metal` 文件，安装完整 Xcode 和 Metal Toolchain。

### Command Line Tools

不安装完整 Xcode 时执行：

```sh
xcode-select --install
```

按系统弹窗完成安装。已安装完整 Xcode 时不必重复安装 CLT。

### Xcode

```sh
# 打开 Xcode 的 Mac App Store 页面，点击“获取/安装”
open 'macappstore://apps.apple.com/app/id497799835'

# 安装完成后打开，确认许可协议并完成首次启动
open /Applications/Xcode.app

# 仅本条命令指定工具链，不修改全局 xcode-select
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version
```

App Store 安装和首次许可需要用户确认；`open` 不会在后台下载安装 Xcode。

### Metal Toolchain（Xcode 27）

完成 Xcode 首次启动后执行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -downloadComponent MetalToolchain

# 查找并运行真正的组件编译器
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun --find metal
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun metal --version
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun --find metallib
```

这些安装和检查命令由管理员在宿主终端执行，组件下载需要联网。

### CMake / Ninja

在本项目源码根目录执行：

```sh
python3 scripts/install_development_tools.py

# 验证安装
TOOLS="$HOME/Library/Application Support/MetalSandbox/development_tools"
"$TOOLS/cmake/CMake.app/Contents/bin/cmake" --version
"$TOOLS/ninja/ninja" --version
```

脚本安装固定官方版本（CMake 4.4.3、Ninja 1.13.2），下载后核对 SHA-256，无需 Homebrew/root，不修改系统 PATH。**安装后正常重启管理服务**，新实例自动使用这些只读工具路径。如果只有 DMG，需要先取得本项目源码中的安装脚本；CMake/Ninja 目前不随 DMG 分发。

## 安装 App

1. 打开 `metal_sandbox_<version>_arm64.dmg`，将 `Metal Sandbox.app` 拖入 Applications。
2. 打开 **Metal Sandbox**，点击「启动服务」并确认仅运行可信代码。
3. 点击「创建 Sandbox」选择数量；可在「高级选项」选择白名单或黑名单，并编辑本实例的调度规则 JSON，再在侧边栏选择实例。
4. 使用「准备」「终端」「文件」页面执行脚本、开发并查看结果；「验收」运行题包的 `tests/test.sh`，显示结果和历史日志；「配置与快照」可查看实例调度模式、规则和管理快照。

如果 macOS 在首次启动时阻止下载的 App，可在 **系统设置 → 隐私与安全性 → 仍要打开** 中允许启动，再重新打开 App。

安装包已包含前端和后端，无需下载源码或运行 `swift build`。创建实例默认允许出站联网，并通过题包准备脚本安装 harness、配置模型和启动做题。支持 Claude Code、Codex 和 mini-swe-agent 的非交互任务与独立工具命令调度，三者的脚本见 [Harness 示例](../../examples/harnesses/README.md)，也可通过 [Harbor](harbor.md)运行。

**退出前端不会停止服务。** 需要结束服务时，选择工具栏「服务操作 → 关闭服务」。详细操作见[图形界面指南](frontend.md)。

创建时可填写名称，批量创建自动加 `(1)`、`(2)`；侧栏单选右键可原位重命名，回车保存、Esc 取消，留空恢复 ID 简称。名称不改变实例 ID、目录或命令参数。

## 更新 App

1. 等待当前任务完成，确认待完成命令数为 0。
2. 在右上角「…」菜单选择「关闭服务…」，等待服务关闭，再退出 App。
3. 打开新版 DMG，将 `Metal Sandbox.app` 拖到原安装目录，选择「替换」。
4. 从安装目录打开新版 App，点击「启动服务」，再按需选择已有 Sandbox 并点击「启动实例」。

前后端随 App 一起更新，已有实例、工作区、环境变量和快照保留。退出 App 本身不会关闭管理服务。

## 配置集群

每台 Mac 都需要安装 Metal Sandbox 和任务所需的开发工具。各节点使用同版本服务，以及兼容的编译器、SDK 和任务依赖。

### 远程登录与 SSH

1. 在各节点打开 **系统设置 → 通用 → 共享**，点击 **远程登录** 旁边的信息按钮，启用 **远程登录**，允许运行 Metal Sandbox 的账号登录。
2. 选择一台 Mac 作为管理节点。在 **连接设置 → 节点集群** 中选择 **管理节点**，填写唯一的节点名称；其他 Mac 选择 **从节点**，分别填写唯一名称。保存配置后，在服务空闲时重新启动管理服务，使角色设置生效。
3. 在管理节点使用 **添加从节点**，填写从节点地址和用户名，核对 SSH 主机指纹并配置密钥认证。已有专用密钥认证时密码可留空。向导会检查远端服务，因此先在从节点启动服务。
4. 从管理节点验证非交互 SSH 请求。将 `node_user` 和 `node_address` 替换为从节点的账号和地址：

```sh
ssh -o BatchMode=yes -o ConnectTimeout=8 node_user@node_address \
  '"/Applications/Metal Sandbox.app/Contents/Helpers/sandboxctl" --version'
```

5. 保存管理节点的集群配置，在服务空闲时重新启动，确认总览显示各从节点已连接。也可用 CLI 查询运行中的集群：

```sh
"/Applications/Metal Sandbox.app/Contents/Helpers/sandboxctl" sandbox status
```

SSH 密钥、主机指纹和连接高级选项见[节点配置](cluster.md#配置)。

### 文件共享与 SMB 挂载

动态调度要求同一调度池的节点通过 SMB 访问其他节点的实例目录。启用动态调度前，先配置共享和挂载。

1. 各节点选择相同的 `sharedRoot`，例如 `/Users/Shared/metal_cluster_nodes`，并创建本机的本地子目录。节点名为 `node_a` 时：

```sh
mkdir -p /Users/Shared/metal_cluster_nodes/node_a
```

2. 在这台 Mac 打开 **系统设置 → 通用 → 共享**，点击 **文件共享** 旁边的信息按钮，启用 **文件共享**。将 `sharedRoot/node_a` 加入 **共享文件夹**，给 SMB 登录账号设置 **读与写** 权限。在 **选项** 中启用 **使用 SMB 来共享文件和文件夹**，并启用用于连接的账号。只导出本机的本地子目录；共享根目录还包含其他节点的挂载点。
3. 在同池其他节点，将该共享挂载到相同的绝对路径。共享名使用文件共享设置中实际显示的名称。以 `node_a` 共享为例：

```sh
mkdir -p /Users/Shared/metal_cluster_nodes/node_a
/sbin/mount_smbfs //node_user@node_address/node_a \
  /Users/Shared/metal_cluster_nodes/node_a
```

按提示输入 SMB 密码，并为每个同池节点重复配置。所属节点通过本地目录访问自己的数据，其他节点通过 SMB 访问。四节点调度池中，每台节点需要挂载其他三台的共享。

4. 在每台节点的集群配置中填写相同的 `sharedRoot`。用 `/usr/bin/smbutil statshares -a` 查看挂载，再验证跨节点读取和写入文件，并确认挂载支持任务要求的文件权限和可执行文件。
5. 配置调度池，在参与节点上启用动态调度。启动服务后，确认管理节点显示所有预期节点已连接，再提交任务。

Metal Sandbox 不会自动挂载 SMB 共享。重启后应恢复必要的挂载，再开始任务。存储布局和调度要求见[节点准备](cluster.md#节点准备)与[动态调度](cluster.md#动态调度)。

## 从源码启动 CLI

除上述开发工具外，还需要 Swift 6.0+ 和用于检查、打包的 Python 3.9+。

在源码根目录，使用普通用户终端：

```sh
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
"$BIN/sandboxctl" --version
"$BIN/metal-sandboxd" --allow-trusted-code
```

服务前台运行；另开终端，在同一源码目录：

```sh
BIN="$(swift build -c release --show-bin-path)"
"$BIN/sandboxctl" sandbox create --count 4
"$BIN/sandboxctl" sandbox list -h   # 易读列表；不加 -h 则输出 JSON
# 把 sbx-... 替换为上一步返回的 ID（或唯一前缀）
"$BIN/sandboxctl" sandbox enter sbx-...
```

`exit` 只退出控制台，不关闭实例。`enter` 是逐命令控制台，**不是 PTY**，不支持 vim/top、作业控制和跨命令 shell 变量。

```sh
"$BIN/sandboxctl" sandbox exec sbx-... -- echo hello
"$BIN/sandboxctl" sandbox stop sbx-...
"$BIN/sandboxctl" sandbox shutdown
```

**必须显式传入 `--allow-trusted-code` 才能启动服务。** 公开执行入口通过 App Sandbox Host 启动，不提供裸机回退；这不代表其他应用启动路径已被完整约束。

需要准备环境或传入题目时，复用 `sandbox write` 上传 `setup.sh` / `instruction.md`，再用 `sandbox exec ID --session -- /bin/sh ./setup.sh` 启动 harness 会话；普通脚本可不加 `--session`。完整命令与网络、交互限制见[通用准备脚本](native_operations.md#4-通用准备脚本与题目输入)。

**注意：** 新建实例默认允许出站连接，不限域名；使用 `--no_network` 或取消前端「允许出站联网」勾选可关闭；创建后不能热切换。文件上传、下载和工作区快照不设字节大小上限，快照使用标准 ZIP/ZIP64 分块归档，需要充足磁盘空间。当前快照只保存 workspace，**不包含私有 HOME 中的工具和会话**，用 `sandbox restore ID` 从快照克隆后需重新准备环境；`sandbox start ID` 启动原实例则保留工作区和私有 HOME。Claude 支持非交互多轮做题及主会话并行。

## 最佳实践

### 在专用节点关闭 Spotlight 索引

大量任务工作区和 rollout 日志可能产生较大的 Spotlight 索引。专门运行任务的 Mac 建议关闭索引，减少后台磁盘活动和索引增长。在每台节点的宿主终端执行：

```sh
sudo /usr/bin/mdutil -a -i off
/usr/bin/mdutil -a -s
```

`-a` 表示应用到所有卷，确认每个卷均返回 `Indexing disabled`。这会影响 Spotlight 和 Finder 的文件搜索，Spotlight 界面仍然可以打开。关闭索引不会删除已有索引。

需要恢复索引时执行：

```sh
sudo /usr/bin/mdutil -a -i on
```

### 固定网络地址与关闭 Wi-Fi

使用有线网络，为每台节点配置固定 IP 地址。可以在网络设备中配置 DHCP 地址保留，或在 Mac 上填写管理员分配的手动地址：

1. 打开 **系统设置 → 网络**，选择有线连接（如 **以太网**），点击 **详细信息 → TCP/IP**。将 **配置 IPv4** 设为 **手动**，填写 **IP 地址**、**子网掩码**和**路由器**。
2. 在 **DNS** 中填写网络管理员提供的 DNS 服务器地址，保存设置，确认有线连接能够访问其他节点和互联网。
3. 打开 **系统设置 → Wi-Fi**，关闭 **Wi-Fi**。

重启后检查 SSH 连接、SMB 挂载和服务状态，再恢复任务。苹果操作说明见[手动 IP 地址](https://support.apple.com/zh-cn/guide/mac-help/mchlp2718/mac)和[Wi-Fi 连接](https://support.apple.com/zh-cn/guide/mac-help/mchlp1180/mac)。

### 关闭自动软件更新

批量运行任务期间，在 **系统设置 → 通用 → 软件更新** 中点击 **自动更新** 旁边的信息按钮，关闭 **下载可用的更新**、**安装 macOS 更新**及**安装系统数据文件和安全性更新**。较旧版本将最后一项称为 **安装安全响应和系统文件**。任务空闲时，由管理员统一安排系统和工具链更新。苹果操作说明见[软件更新设置](https://support.apple.com/zh-cn/guide/mac-help/mchla7037245/mac)。

### 防止睡眠与自动锁屏

专用台式 Mac 建议使用以下设置：

| 系统设置位置 | 设置 | 建议值 |
|---|---|---|
| 能源 | 显示器关闭时，防止自动进入睡眠 | 打开 |
| 能源 | 唤醒以供网络访问 | 打开 |
| 锁定屏幕 | 不活跃时关闭显示器 | 永不 |
| 锁定屏幕 | 屏幕保护程序启动或显示器关闭后需要密码 | 永不 |

部分机型将显示器选项写为 **使用电源适配器供电且不活跃时关闭显示器**。苹果操作说明见[睡眠与唤醒设置](https://support.apple.com/zh-cn/guide/mac-help/mchle41a6ccd/mac)和[锁定屏幕设置](https://support.apple.com/zh-cn/guide/mac-help/mh11784/mac)。

### 保持 GPU 计时条件一致

各节点使用兼容的工具链和依赖。测量性能时，避免其他 GPU 工作负载，以及通过其他管理服务提交的并发任务。不同服务拥有各自的队列，GPU 任务可能在同一台 Mac 上同时运行。

### 管理任务产物与磁盘占用

使用 Harbor 批量运行任务时，设置 `environment.delete: true`，在 trial 结束后删除对应的 Sandbox。Harbor 的 job 输出独立保留，包括 `jobs_dir` 下的结果和轨迹，需要单独管理保留期限。配置方式见 [Harbor](harbor.md)。

定期检查残留实例，通过 Metal Sandbox 删除。将 Harbor 输出放在 SMB 实例目录之外，分别管理实例删除和 job 保留。操作方式见[删除与清理说明](native_operations.md#删除与残留清理)。
