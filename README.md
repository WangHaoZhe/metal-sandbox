# Metal Sandbox

[简体中文](README_ZH.md)

**Native macOS sandbox management and Agent/verifier infrastructure**

Manage multiple App Sandbox instances on the same Mac under the same UID, with candidates using the physical Apple GPU directly. The default allowlist permits common file inspection, compilation, `make`, `ninja`, and `cmake --build` in parallel; other commands run serially. A compound shell task runs in parallel only when every command matches the allowlist; otherwise the entire task is serial. A denylist mode instead serializes matching tasks and allows other tasks in parallel. Serial tasks share one FIFO slot.

## Installation

See [Installation and best practices](docs/installation.md) for App installation, updates, development tools, and source startup. The guide also covers cluster setup: Remote Login, SSH authentication, SMB File Sharing and mounts, and dedicated-node recommendations such as disabling Spotlight indexing.

## Release scope

This release supports multiple native development instances, noninteractive Claude Code/Codex/mini-swe-agent rollouts, trajectory viewing, task verification, and workspace snapshots, with these limitations:

| Area | Limitations |
|---|---|
| Security | Trusted local development only; unresolved LaunchServices escape risk; no comprehensive hard CPU, memory, process-tree, or disk quotas |
| GPU | No partitioning or GPU-call detection; no exclusivity or certified drain; other applications and parallel tasks may affect measurements |
| Tools and terminal | System xcrun rejects execution in App Sandbox; use resolved tools. Arbitrary xcodebuild projects are not guaranteed to work; enter is not a PTY |
| Snapshots | Workspace only; excludes private HOME, sessions, and running processes; limits on entry count, depth, and link types |
| Networking and credentials | Outbound permission applies to the whole instance; no domain filtering, credential revocation, or general log redaction; environment settings are private plaintext files |
| Harnesses | Claude Bash, Codex exec_command, and mini-swe-agent shell are adapted; other harnesses and MCP tools are not automatically scheduled |
| Distribution | Ad-hoc signatures, no notarization, limited hardware/OS and long-term stability coverage |

The service is `metal-sandboxd`. Do not interfere with macOS `/usr/libexec/sandboxd`. Normal usage creates no system accounts, installs no launchd jobs, changes no firewall settings, and runs no root services.

## Examples

- [Metal Bloom](examples/tasks/metal_bloom/agent/instruction.md) and [poison mushroom](examples/tasks/metal_poison_mushroom/agent/instruction.md): task packages with separate Agent and test directories; import the corresponding package root.
- [Two-instance Metal scheduling demo](examples/demo_gpu_queue.py): with an idle running service, run `python3 examples/demo_gpu_queue.py` from the source directory and observe unfinished commands changing from 2 to 1 to 0. See [running the demo](docs/native_operations.md#try-serial-scheduling).

## Documentation

- [Installation and best practices](docs/installation.md)
- [Desktop frontend](docs/frontend.md) · [CLI guide](docs/native_operations.md)
- [Task packages and Agent startup](docs/task_packages.md) · [Sandbox deletion and cleanup](docs/native_operations.md#delete-a-sandbox)
- [Run tasks with Harbor](docs/harbor.md)
- [Node clusters and dynamic scheduling](docs/cluster.md)
- [CLI/RPC interfaces](docs/api.md) · [Architecture](docs/architecture.md)
- [Security boundary](docs/security.md) · [Troubleshooting](docs/troubleshooting.md)
- [Release notes](changelog.md) · [Development and release](contributing.md)
