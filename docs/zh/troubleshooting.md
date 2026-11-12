# 故障排查

遇到故障先保留状态与日志，不删除活动租约或放宽沙箱策略。

| 现象 | 检查/处理 |
|---|---|
| 找不到 daemon/token/socket | 确认已用 `--allow-trusted-code` 启动；CLI 和 daemon 使用同一 state-dir |
| 第二个服务启动失败 | 每 UID 只允许一个执行调度器，换 state-dir 不能绕过；先正常关闭自己的服务 |
| SIGABRT / App Sandbox 未激活 | 检查签名、容器身份与启动环境；外层系统沙箱可能干扰 SwiftPM/Host 激活。在普通用户终端复现，不关闭被测 App Sandbox |
| `/usr/bin/clang`/xcrun 被拒绝 | 使用顶层 `sandbox exec ID -- clang ...`，由工具适配解析真实 clang/SDK；检查 `xcode-select -p`、`xcrun --find clang` |
| Objective-C++ 链接失败 | 使用 clang++，检查所需 framework 和链接参数；可在同一脚本内编译和运行 |
| 脚本中编译出的程序不能启动 | 确认使用本版 helpers 并创建新实例，在工作区/实例 HOME/TMPDIR 中构建；不要删除 quarantine。执行器不会主动清除既有文件的隔离标记，其他目录也不自动获得执行授权 |
| workspace/checkpoint 保存失败 | 文件和快照无字节大小上限；检查可用磁盘空间、不支持的链接或特殊文件、1000 项及 32 层限制。`checkpointError` 表示本次未保存成功，上一份完整快照不会被半成品覆盖 |
| `node quarantined` / recoveryReason | 检查实际进程与 GPU 状态，必要时重启；停止全部实例后按操作指南明确恢复 |
| 热状态 `critical`，任务保持排队 | 等待降温；恢复为非 `critical` 后自动继续。等待不消耗 Sandbox 命令执行预算，可以取消；不需要手动恢复节点 |
| 空闲实例的 Host 退出 | 停止该实例，再启动原实例。没有未完成执行时不隔离其他实例；若存在 recoveryReason 则仍按节点恢复流程处理 |
| restart 后 handle 失效 | 这是预期行为；启动原实例后重新授权，不重放旧进程；原目录不可用时可从有效快照克隆 |
| enter 中 vim/top 不工作 | 当前不是 PTY，使用文件 read/write 和逐命令 exec |
| 测试后出现恢复历史 | recovery_history 是审计，不是活动锁，不清除；检查 active-lease 是否仍存在 |

## 报告问题

提供产品 `--version`、macOS/Swift/芯片型号、模式、最小复现、退出码和相关日志摘要。删除 token、handle capability、用户名私有路径、输入数据与隐藏真值后再分享。

系统 `/usr/libexec/sandboxd` 不属于本项目，绝不以 `pkill sandboxd` 清理。原生服务正常停止：`sandboxctl sandbox shutdown`；若结果不确定，保留证据并按[恢复流程](native_operations.md)处理。
