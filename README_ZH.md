# Metal Sandbox

**原生 macOS sandbox 管理与 Agent/Verifier 基础设施**

同一 Mac、同一 UID 下管理多个 App Sandbox 实例，候选程序直接使用实体 Apple GPU。默认白名单允许常用文件查看、编译、`make`、`ninja`、`cmake --build` 并行，其余串行。复合 shell 任务中所有命令均命中白名单时可并行，否则整项串行；也可选择黑名单，让命中任务串行、其余并行。串行任务共用一个 FIFO 槽。

## 安装

App 安装、更新、开发工具和源码启动步骤见[安装与最佳实践](docs/zh/installation.md)。指南也包含集群配置：开启远程登录、配置 SSH 认证、开启 SMB 文件共享并挂载，以及关闭 Spotlight 索引等专用节点使用建议。

## 本版范围

支持多实例原生开发、Claude Code/Codex/mini-swe-agent 非交互 rollout、轨迹查看、题包验收与工作区快照。当前版本有以下限制：

| 领域 | 限制 |
|---|---|
| 安全 | 仅可信本地开发；LaunchServices 越界风险未封堵，无完整 CPU/内存/进程树/磁盘硬配额 |
| GPU | 不分区、不检测 GPU 调用，不保证独占或可信 drain；其他应用与并行任务可能干扰测量 |
| 工具与终端 | 系统 xcrun 拒绝在 App Sandbox 内运行，使用已解析的真实工具；不保证任意 xcodebuild 项目兼容；enter 不是 PTY |
| 快照 | 只包含 workspace，不包含私有 HOME、会话或运行进程；存在条目数、深度与链接类型限制 |
| 网络与凭据 | 出站权限覆盖整个实例；没有域名过滤、凭据撤销或普遍日志脱敏，环境配置为私有明文文件 |
| Harness | 已适配 Claude Bash、Codex exec_command 和 mini-swe-agent shell；其他 harness/MCP 不会自动接入调度 |
| 分发 | ad-hoc 签名、未公证；硬件、macOS 组合及长期稳定性覆盖有限 |

服务是 `metal-sandboxd`，不是系统的 `/usr/libexec/sandboxd`；正常使用不创建系统账号、不安装 launchd、不更改防火墙，也不运行 root 服务。

## 示例

- [Metal Bloom](examples/tasks/metal_bloom/agent/instruction.md) 和[五阶毒蘑菇](examples/tasks/metal_poison_mushroom/agent/instruction.md)：包含 agent/tests 分区的题包，选择对应题包根目录导入。
- [双实例 Metal 调度演示](examples/demo_gpu_queue.py)：服务已启动且空闲时，在源码目录运行 `python3 examples/demo_gpu_queue.py`，观察待完成命令数 2 → 1 → 0。[运行说明](docs/zh/native_operations.md#体验串行调度)。

## 文档

- [安装与最佳实践](docs/zh/installation.md)
- [图形界面](docs/zh/frontend.md) · [CLI 使用指南](docs/zh/native_operations.md)
- [题包导入与 Agent 启动](docs/zh/task_packages.md) · [Sandbox 删除与清理](docs/zh/native_operations.md#删除-sandbox)
- [使用 Harbor 运行任务](docs/zh/harbor.md)
- [节点集群与动态调度](docs/zh/cluster.md)
- [CLI/RPC 接口](docs/zh/api.md) · [架构](docs/zh/architecture.md)
- [安全边界](docs/zh/security.md) · [故障排查](docs/zh/troubleshooting.md)
- [发行说明](changelog.md) · [开发与发布](contributing.md)
