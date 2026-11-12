# Troubleshooting

Preserve state and logs when diagnosing failures. Do not delete active leases or weaken sandbox policy.

| Symptom | Checks and remedies |
|---|---|
| Missing daemon, token, or socket | Confirm the service was started with `--allow-trusted-code` and that the CLI and daemon use the same state directory. |
| A second service cannot start | Only one execution scheduler is permitted per UID; a different state directory does not bypass this restriction. Shut down your existing service normally first. |
| SIGABRT or App Sandbox not activated | Check signatures, container identity, and the launch environment. An outer system sandbox may interfere with SwiftPM or Host activation. Reproduce in a normal user terminal without disabling the App Sandbox under test. |
| `/usr/bin/clang` or xcrun rejected | Use top-level `sandbox exec ID -- clang ...` so tool adaptation resolves the compiler and SDK. Check `xcode-select -p` and `xcrun --find clang`. |
| Objective-C++ linking fails | Use clang++ and check required frameworks and linker flags. Compilation and execution can occur in the same script. |
| A program compiled by a script cannot start | Use current helpers and a newly created instance; build in its workspace, HOME, or TMPDIR. Do not remove quarantine attributes. The executor does not clear existing attributes, and other directories do not automatically receive execution authorization. |
| Workspace or checkpoint saving fails | Files and snapshots have no byte-size limit. Check available disk space, unsupported links or special files, and limits of 1,000 entries and 32 levels. `checkpointError` means the current save failed; partial output does not overwrite the last complete snapshot. |
| `node quarantined` or recoveryReason | Check actual processes and GPU state; restart if necessary. Stop all instances before explicitly recovering the node using the operations guide. |
| Thermal state `critical` and tasks stay queued | Wait for the machine to cool. Tasks resume automatically after the state leaves `critical`. Waiting does not consume command execution budgets; tasks remain cancelable. Manual node recovery is unnecessary. |
| An idle instance's Host exits | Stop and restart that instance. Other instances are not quarantined when no execution is unfinished. If recoveryReason is present, follow the node recovery procedure. |
| Handles become invalid after restart | This is expected. Restart the original instance and authorize again; old processes are not replayed. If its directories are unavailable, clone from a valid snapshot. |
| vim or top does not work in enter | `enter` is not a PTY. Use file read/write and individual exec commands. |
| Recovery history appears after testing | recovery_history is an audit record, not an active lock. Do not clear it; check whether an active lease remains. |

## Reporting issues

Include the product `--version`, macOS and Swift versions, chip model, operating mode, minimal reproduction, exit code, and relevant log excerpts. Remove tokens, handle capabilities, private username paths, input data, and hidden reference values before sharing.

The system `/usr/libexec/sandboxd` is unrelated to this project. Never use `pkill sandboxd` for cleanup. Stop the native service normally with `sandboxctl sandbox shutdown`. If the outcome is uncertain, preserve evidence and follow the [recovery procedure](native_operations.md).
