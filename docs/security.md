# Security boundary

**This release is for trusted local development only. It is not a production service for multiple tenants or malicious code.**

## Execution and permissions

| Area | Current behavior |
|---|---|
| App Sandbox | Enabled on the Host; helpers have fixed inherit entitlements |
| Files | Separate application containers, restricted file APIs, necessary system and SDK access |
| Networking | Outbound client access enabled by default; `--no_network` disables it; no server entitlement |
| Management IPC | Same-UID peer validation plus administrator token or scoped capability |
| Task scheduling | Allowlist matches run in parallel; denylist matches run serially; no GPU-call detection or exclusivity guarantee |
| Intended use | Trusted local development |

One manager may run per UID. Public execution uses the restricted Host without a bare-host fallback.

**Known risk:** Reports show that candidates launching other applications through LaunchServices may escape inherited Host restrictions and access host files. This risk remains unresolved; do not use this release for untrusted code.

Administrators configure allowlists and denylists by exact executable path and argument prefix. Rules cover entire tasks and their children without independently intercepting every descendant. In sessions with the Claude Bash adapter, each Bash call is a separate task boundary; parallel main sessions receive no additional filesystem or network permissions. In denylist mode, unmatched programs, including unknown GPU programs, run in parallel. An empty denylist permits all ordinary tasks in parallel. `make`, `ninja`, and `cmake --build` are parallel by default, but builds can launch tests or GPU programs. Program-name allowlists are neither a security boundary nor formal performance isolation. Parallel builds may also affect non-allowlisted serial tasks. To serialize all managed commands, use an empty allowlist for every active instance and route main-session execution through an adapter. Other macOS applications remain outside scheduler control.

The desktop frontend is a trusted administrator control plane and **does not itself enable the candidate App Sandbox**. It launches bundled or user-selected CLIs with argument arrays and reads public CLI output and user-selected files, without directly accessing management credentials, internal state, or containers. The Host's fixed signature and backend implement sandbox policy. Do not select an untrusted CLI directory.

## Native filesystem boundary

- The OS boundary includes the application container and system resources permitted by App Sandbox, **not only the workspace directory**. Candidates can write their container and permitted temporary/cache locations; HOME is a convenience path.
- Ordinary restricted processes cannot freely access other instances or host directories. Necessary system, framework, and SDK reads remain available. Applications launched through LaunchServices have the escape risk described above.
- File APIs use directory descriptors and openat, rejecting path traversal, link following, hard links, and special files. Snapshots can preserve and restore dylib aliases pointing only to names in the same directory without reading their targets. Cross-directory symbolic links are rejected. Files and snapshots have no byte-size ceiling or hard disk quota; reserve disk space for workspaces, temporary archives, and saved snapshots.
- Arbitrary user-selected file read/write and application-group entitlements are not granted. Agents cannot submit custom signing policies. Administrators select outbound networking only at creation. Development permissions are specified below.
- Tokens, control-pipe descriptors, and hidden reference values are not passed to candidates by design. This does not guarantee host credentials remain inaccessible after an escape. Agent tool adapters are trusted control-plane components exposing only the owning instance's operations, without host shell access.

## Native development policy

The Host uses `app-sandbox` with the following public Apple entitlements:

- `files.user-selected.executable`: enables generated executable programs within authorized directory scopes.
- `files.bookmarks.app-scope`: creates and activates security-scoped bookmarks only for the container's workspace, isolated home, and tmp directories. Host bookmarks are not accepted from Agents.
- `network.client`: included by default and omitted for `create --no_network`. It permits the instance and its descendants to initiate outbound connections, including loopback and LAN connections. It provides no domain filtering, proxy isolation, or credential management. `network.server` is not included. Existing instances retain their creation-time networking choice, with no live switching.
- `temporary-exception.files.absolute-path.read-only`: the controller fixes paths by instance identity to the three directories above, administrator-specific CMake/Ninja directories, and the concrete read-only Metal `.xctoolchain` directory resolved by `xcrun`. This Apple exception also allows execution from those directories. Instance directories already permit reads and writes; tool directories are read-only, without granting access to host HOME, all of `/var/run`, or other instances. Metal cryptex paths use `realpath`; restart the service after system updates or remounts to resolve them again.
- Dynamic-scheduling instances additionally use `temporary-exception.files.absolute-path.read-write`, granting only their workspace and home within the configured shared root. Other instances and the entire shared root are not authorized. The management service initiates SSH; candidates receive no SSH credentials or management token. Execution nodes use their own restricted Hosts and serial permits.

The Host activates scopes at startup and refuses execution if activation fails. Signature validation compares **all entitlement keys, values, and directories exactly** rather than checking only app-sandbox=true. Helpers use only `app-sandbox` and `inherit`, with no shared application groups or additional permissions. Direct descendants inherit kernel restrictions, while full coverage of other launch paths remains incomplete.

References: [Apple App Sandbox entitlements](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html) and [temporary file-access exceptions](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html).

## Permanent deletion boundary

Only administrators may submit `delete --confirm`. The target must be inactive and have no unfinished executions. Other instances' running or queued commands neither prevent deletion nor get stopped. Eligible instances can be deleted while the node is quarantined; deletion does not clear quarantine. Using recorded identities, the manager creates a fixed-signature maintenance Host that deletes container task files inside its own App Sandbox. The unsandboxed manager does not traverse task contents or launch old candidates. Directory descriptors, openat, and unlinkat avoid symlink following, hard-link truncation, and mount-point traversal; two strictly validated system security-preference aliases are retained.

Successful deletion removes the workspace, checkpoints, runtime bundles, and instance list record. Independent artifacts, execution logs, physical-session audits, recovery records, and deletion audits remain. After normal Host exit, the controller validates and attempts to remove only an empty fixed-layout container shell: metadata, ordinary `.DS_Store`, Data/Library/Preferences, and two system links with exact targets. It uses fixed roots, directory descriptors, O_NOFOLLOW, and inode/device validation, accepting no candidate-supplied host paths. Unknown entries are rejected and insufficient permissions produce explicit residual warnings without bypassing macOS protection. Deletion does not provide secure SSD erasure or forensic removal of every system temporary/cache file.

Complete, nonconflicting physical ownership records are required. Residual cleanup previews by default and includes only deletion audits from this state directory or unclaimed trusted publications. Confirmation selects exact identities rather than deleting by Containers prefix.

## Uncovered threats

- App Sandbox shares the host kernel, Metal drivers, physical memory, and GPU; it is not a VM.
- Arbitrary process-group escapes, double-fork descendants, all Mach IPC, fork bombs, and complete hard resource quotas remain unverified or unfinished.
- **Other unsandboxed host processes under the same UID** can read management state/tokens or alter records. This release cannot resist an attacker controlling the host account.
- File hashes verify integrity but are not trusted signatures or tamper-proof audits. Atomic writes do not guarantee transactional consistency through power failure.
- Queues do not control other applications or support GPU partitioning or certified drain. Do not use example GPU timings as training rewards.

## Forced termination and recovery

After a timeout, cancellation, signal termination, or output-limit failure, confirmed process-group cleanup marks only that task failed or canceled and releases its lease, allowing trusted development to continue without automatic node quarantine. **This is not GPU-drain certification: CPU child exit does not prove GPU work has cleared.** Failed tasks cannot count as passes, and subsequent GPU measurements cannot assume the absence of residual effects.

An idle Host exit makes only its instance unavailable. Stop and restart that instance without affecting others. Host disconnection during execution, stale execution markers after manager crashes, uncertain cleanup, permit corruption, or inability to save critical execution records retain node quarantine and require manual recovery.

A `critical` thermal state makes tasks without permits wait for cooling. It creates no new quarantine marker, does not forcibly stop running tasks, and does not change completed tasks to failures. Tasks resume under their existing queues and policy after the state leaves `critical`. Waiting does not consume command budgets and remains cancelable. Cooling does not clear existing quarantine.

Administrators must verify actual process identities, residual tasks, and GPU/system stability, restarting machines if necessary. Do not signal stale PIDs blindly, delete leases from `active-lease.json` or `parallel_leases`, or automatically confirm recovery in a training loop. Recover with inspection notes using the [operations guide](native_operations.md). Recovery requires no ordinary task command running; connected Agent main sessions can remain, while disconnected instances must first stop. Queued commands wait for permits after recovery; failed commands are not replayed.

`recovery_history` is an audit, not an active lock or disposable data. Do not clear it to rerun tests.

## Operating discipline

Use a normal user and dedicated development environment without production credentials. Do not create system accounts, install launchd jobs, change firewalls, or run a root daemon. Do not repair failures by changing system-tool signatures, removing candidate quarantine attributes, silently expanding directory/network permissions, or adding bare-host execution fallbacks. Document boundaries and rerun rejection tests after any change to fixed development policy.

If an escape is discovered, stop submissions, preserve evidence, and quarantine the node before investigation and recovery. Share a minimal reproduction and log excerpts privately with the project owner without exposing tokens, user data, or hidden tests. No public security response channel is currently configured.
