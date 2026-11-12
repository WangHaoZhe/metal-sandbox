# Release notes

## 1.0.0

### Native execution and instance management

- Run Metal programs and native macOS tools inside Apple's App Sandbox with direct access to the Apple GPU.
- Manage multiple instances with separate workspaces and private HOME directories, configurable environment variables, and optional outbound network access.
- Create, start, inspect, stop, and delete instances through the desktop App or public CLI.
- Export and import workspace snapshots and restore checkpoints into new instances.

### Command scheduling and Mac clusters

- Use allowlist or denylist policies to classify complete commands for parallel or serial execution.
- Exclude queue waiting from active execution budgets and allow cancellation while commands are waiting or running.
- Connect Mac nodes through SSH and SMB shared storage for centralized instance management and load-based placement.
- Dynamically move eligible waiting serial commands between nodes in the same scheduling pool.
- Configure scheduling pools, per-node instance capacity, and participation in cross-node scheduling.
- Maintain SSH loopback forwarding for model APIs, recover interrupted forwarding connections, and retry read-only queries after communication failures.
- Clean up command process groups, retain execution results and trajectories, and quarantine nodes when cleanup cannot be confirmed.

### Agent harnesses and verification

- Support Claude Code, Codex, and mini-swe-agent, with their shell tools routed through the management service.
- Provide preparation scripts and Harbor configuration examples for all three harnesses.
- Integrate with Harbor to run task packages and collect Agent trajectories and verification results.
- Import Agent and test directories separately and run correctness checks in dedicated verifier instances.

### Desktop App, packaging, and documentation

- Provide a native SwiftUI desktop interface in Simplified Chinese and English, with English command-line and runtime messages.
- Browse workspace files, inspect Agent conversations and command timelines, run terminal commands, and manage environments, snapshots, and verification results.
- Distribute an Apple Silicon DMG containing the desktop App, CLI, and runtime tools.
- Provide English and Simplified Chinese guides for installation, dedicated-node settings, cluster setup, task packages, harnesses, and interfaces.
