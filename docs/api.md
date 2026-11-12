# CLI and native RPC

## CLI entry points

```sh
sandboxctl --version
sandboxctl --help
sandboxctl sandbox --help
metal-sandboxd --version
metal-sandboxd --help
evaluation-runner --version
```

See the [operations guide](native_operations.md) for complete examples. The CLI and daemon must come from the same build. Place custom state-directory options before `sandbox`.

- Management commands output JSON; file read, exec, and wait output file data or candidate stdout/stderr.
- Foreground exec/wait propagates the candidate's exit code after normal exit. Management, transport, and abnormal execution failures return 1. Ctrl-C requests cancellation of the corresponding execution.
- `--detach` returns an execution record/ID, not a success result. Use wait or the `execution` RPC to obtain the result.
- `enter` accepts ordinary commands or `:run {"line":"pwd","timeout":30,"cwd":"."}`. Settings apply only to that command. Omit `cwd` to use the console's current directory. Timeout is a finite positive number of seconds without a fixed upper duration limit. Invalid settings prevent that command from executing; the console continues accepting input. `:run` prints execution ID and exit code without bypassing scheduling.
- evaluation-runner returns 0 for help/version, 2 for no arguments or unknown modes, 0 for successful fixed verification, and nonzero for failures.
- The CLI resolves unique ID prefixes; RPC uses complete IDs.
- `forward`, `forward-status`, and `forward-close` require complete instance IDs, caller-generated UUID lease IDs, and administrator permission. `forward ID --port N --lease UUID` makes a local loopback service available on the instance's node. `forward-status ID UUID` checks and renews the lease for 60 seconds; `forward-close ID UUID` releases it. Ports must be 1024–65535 and the instance must permit outbound networking.
- `reveal-containers BUNDLE_ID... [--preview]` is a local CLI action, not an RPC or candidate command. It accepts only complete `local.metal-sandbox.instance-<uuid>` identities and checks matching real directories under the current user's container root. It does not scan contents, delete files, or require the service. By default NSWorkspace requests Finder selection; `--preview` only prints paths. JSON contains `ok`, `paths`, `missing`, `finderRequested`, and optional `warnings`. `finderRequested` indicates a request was sent, without confirming Finder's response.

## Transport and identity

- Socket: `/private/tmp/metal-sandbox-<uid>/native.sock`.
- One request/response per connection: a 4-byte big-endian length followed by UTF-8 JSON. Frames are limited to 16 MiB, with up to 32 requests being handled.
- The service checks peer UID; handlers additionally validate `operatorToken` or `handle`. Each service start rotates the administrator token. Stopping an instance or restarting the service invalidates old handles.
- The token is stored in `operator_token` under the state directory and is not an Agent credential. Scoped handles remain in the trusted control plane.
- `requestID` and `operation` are required. Responses echo requestID and include ok and the relevant payload. Errors use `ok:false,error`; invalid frames may close the connection.
- Errors that clients can handle by category also include `errorCode`; `instance_inactive` means the instance has no active session. Do not use the displayed `error` text to determine program behavior.
- **There is no general request deduplication or automatic retry guarantee.** If a response is lost, inspect instance/execution lists before resubmitting. Cluster relays retry read-only requests only: status, list, inspect, execution, executions, trajectory, ls, read, and workspace-location. Other operations are attempted once. See [cluster query retries](cluster.md) for retry intervals and response deadlines.
- Exception: a completed `delete` returns its deletion audit for the full instance ID and can be retried idempotently. The CLI does not automatically retry it.

## Operations

| operation | Main input | Output | Permission |
|---|---|---|---|
| status / list | None | status / instances | Administrator |
| create | count, optional name, networkClient (default true), optional taskPolicy JSON and environment | instances | Administrator |
| rename | instanceID, name (empty clears) | instance | Administrator |
| port-forward-open | instanceID, forwardID (UUID), forwardPort | portForward | Administrator |
| port-forward-status | instanceID, forwardID | portForward (renews lease) | Administrator |
| port-forward-close | instanceID, forwardID | confirmed | Administrator |
| inspect | instanceID | instance | Administrator or instance read |
| restore | instanceID | instance | Administrator |
| grant | instanceID, operations | handle | Administrator |
| read / write | instanceID and path / file | file / success | Corresponding instance permission |
| ls | instanceID, path (default `.`), optional entry name after | directory | read |
| export | instanceID | files | export |
| exec | instanceID, command | execution (asynchronous record) | exec |
| execution / cancel | executionID | execution | Owning instance exec |
| stop | instanceID | instance | stop |
| delete | instanceID, confirmed=true | instance (deleted), warnings | Administrator only |
| cleanup-deleted / cleanup-unclaimed | confirmed (default false), bundleIDs required for unclaimed confirmation | cleanup array | Administrator only |
| recover | confirmed=true, note | status | Administrator after inspection/cleanup |
| shutdown | None | success | Administrator |

`status.loopbackForwardingImplemented` reports support for loopback forwarding. `portForward` contains lease ID, instance ID, port, owner node, ready nodes, expiry, and node connection errors. Opening the same lease/endpoint can be repeated to query it; close requests can be repeated. Renewal cannot revive an expired lease.

CLI read/write/export/import use chunked download/upload RPC. Download with a nonempty `path` requires read permission; without it, export permission is required. Upload requires write permission. A ready response with requestID precedes chunks of at most 256 KiB; an empty final chunk ends transfer. Upload returns a final completion response. Files and snapshots have no total byte-size limit; 16 MiB limits only an individual IPC frame. Snapshots are standard ZIP/ZIP64 archives, written/read in chunks with ZIPFoundation 0.9.20 and CRC32 checking, including empty directories. Backend snapshots also record SHA-256. Import receives and checks the complete archive before atomically replacing individual files without deleting other files; disk errors may leave some files already written. Inline read/write/export RPC serve Swift sessions and infrastructure self-tests and are limited to one frame. Use chunked RPC for large files.

`snapshot` takes `instanceID`, requires export permission, saves a backend snapshot while the instance is idle, and returns updated snapshot metadata in `instance`. Stopping an instance requires administrator permission. `explicitSnapshotsImplemented` advertises this capability. Command completion, write, and import do not trigger snapshots. Creation produces an initial snapshot; subsequent updates occur only on explicit save, full export, or stop.

Exact fields are defined in `sources/sandbox_runtime/control_protocol.swift` and `protocol.swift`. Swift clients use `RemoteSandboxSession` and `SandboxHandle`.

CLI `sandbox import ID --from DIRECTORY --task` accepts a task directory, not a ZIP. It archives only `agent/`, checks that `agent/instruction.md` and `agent/setup.sh` are nonempty regular files, then imports files into the workspace root. Tests are excluded from that Agent archive. Missing required files prevent upload and cannot be supplied from an old workspace. This option uses the existing upload protocol and does not execute scripts; without `--task`, import accepts only ZIP snapshots.

During execution, ls, read, and download of a single named path remain available, subject to read permission and workspace checks. Reads observe live files rather than frozen snapshots. A file changing during transfer produces a retryable error without replacing a previously complete download. Write, upload, export, and download without a path remain mutually exclusive with execution.

### Data structures

- `doctor` and `status.host` use the raw system `hw.model` for `modelIdentifier`, such as `Mac17,2`. `productName` comes from `product-name` in IOKit's `IODeviceTree:/product`. The frontend displays the system product name, such as `MacBook Pro (14-inch, M5)`, or indicates that the model could not be read.
- `doctor` and `status.host.utilization`: `cpuPercent` and `gpuPercent` are 0–100% utilization; `memoryUsedBytes`/`memoryTotalBytes` describe used/physical memory in bytes; `storageUsedBytes`/`storageTotalBytes` describe used/total capacity of the user's data volume in bytes. Unavailable values are omitted, with `cpuError`, `gpuError`, `memoryError`, or `storageError` explaining why. Older services do not return memory/storage fields.
- `WorkspaceFile`: relative `path`, Base64 `data`, boolean `executable`, and optional `linkTarget`. Links must be same-directory aliases with empty data and executable=false; file APIs do not follow links.
- `NativeCommand`: `argv`, relative `cwd` (default `.`), `timeoutSeconds`, `maxLogBytes`, optional per-command `environment`, `deadlineUptimeNanoseconds`, and `agentSession`. Only administrators can set agentSession=true; CLI uses `--session`. Main sessions do not occupy the serial slot.
- `WorkspaceEntry.executable` preserves executable file permissions for directory downloads; directories and special entries return false.
- At admission, the manager resolves programs such as clang to installed absolute paths and supplies SDK adaptation. The Host ultimately receives only absolute paths or `./...`.
- Timeouts are finite positive seconds with no fixed application limit; logs are limited to 1 KiB–4 MiB. Neither is a hardware resource quota.
- `timeoutSeconds` begins after an execution permit is obtained. Agent budgets pause while all child tasks are waiting for scheduling and none is running. Overlapping child waits are deducted once. Explicit `deadlineUptimeNanoseconds` uses the local monotonic clock and cannot be reused across machines.
- `status.queueTimeoutExclusionImplemented=true` advertises queue-wait exclusion. `execution.schedulerWaitSeconds` returns accumulated scheduling wait, including ongoing waits, for external harness phase budgets.
- Data is Base64 and dates are Unix milliseconds. `NativeResult` stores outcome/stdout/stderr/leaseID/queueWaitSeconds.
- `outcome.reason=launchFailed` means the OS could not create the candidate process, with `processID=0` and `launchError` giving the reason. The failed task releases its permit without requiring node recovery. Uncertain cleanup for processes that did start still follows quarantine rules.
- Native status includes `serviceVersion` and `protocolVersion`. Protocol version 1 does not mean product version 1.0.
- `status.taskPolicy` returns defaults for new instances, containing either a `parallel` allowlist or a `serial` denylist. Unmatched tasks use the other class, and both fields cannot coexist. Rules use absolute `executable` paths and `argumentPrefix` arrays. An empty allowlist makes everything serial; an empty denylist makes everything parallel. `executionSlots` counts one serial slot per node; management-node status aggregates slots from available cluster nodes. Parallel tasks are excluded. `status.pendingExecutions` includes top-level tasks and registered harness tool commands in either class, through queuing, execution, and final cleanup.
- `perInstanceTaskPolicyImplemented=true` advertises `create --task-policy FILE`. Creation's `taskPolicy` replaces defaults and is saved in the instance record. `inspect` / `list` return each instance's actual policy, retained on restoration. Only administrators can create instances and specify this policy.
- `NativeExecutionRecord.scheduling` is `parallel` or `serial`: the whole task's scheduling class, not detected GPU usage. `startedAt` is the time scheduling permission was obtained.
- Instance `pendingExecutions` uses the same scope: main sessions and their unfinished tool commands, plus other top-level commands, rather than system process counts. `list` / `inspect` recompute it live from the service; idle instances show 0.

### Directory listing

`sandboxctl sandbox ls ID [REL] [--after NAME]` returns JSON `directory: {path, entries, nextAfter?}`. Each entry contains `name`, `path`, `kind` (directory/file/symlink/other), `size` in bytes, and `modifiedAt` in Unix milliseconds. Pages contain at most 256 entries sorted by name. Pass `nextAfter` as the next `--after`; its absence ends pagination. Only direct children are listed, including hidden entries, without reading contents or following links. A single-directory scan is limited to 100000 entries and fails explicitly when exceeded. Directories can change between pages; refresh rather than treating this as an atomic snapshot.

Active instances use existing `read` permission. Stopped instances allow only administrators to access files through a restricted maintenance Host, without revalidating old Handles. Conflicting and out-of-bounds paths are rejected. `status.directoryListingImplemented=true` advertises this interface. For directory names matching options, use `ls ID -- REL [--after NAME]` to specify the path explicitly.

### Agent trajectories (read-only)

`trajectory ID` returns `trajectory.sessions`: `id` for `--session`, `sessionID`, `source`, `harness`, and `modifiedAt`. It lists the latest 256 sessions; larger lists return `sessionsTruncated=true`. `trajectory ID --session PATH [--after CURSOR]` returns `trajectory.harness` (parser identifier, `claude` or `codex`) and `trajectory.page`: Base64 `data` up to 256 KiB, `nextAfter`, `reset`, and `atEnd`. Pass `nextAfter` back unchanged to continue; `reset=true` means discard old cached content. Chunks may end inside UTF-8 sequences or JSON lines. Clients choose the parser by harness and buffer until a newline before parsing. `atEnd` means only the current end of file, not session completion.

Capability is `trajectoryImplemented=true`. RPC operation `trajectory` takes `instanceID`, optional session `path`, and `after`. It requires instance `read` permission and works during execution without submitting or queuing a command. It reads only session logs accepted by the registered Claude and Codex adapters. Other paths, symlinks, hard links, and special files are rejected; it is not an arbitrary HOME-read interface. mini-swe-agent trajectories are stored in the workspace at `mini_swe_agent_runs/<session>/trajectory.json`, accessible through Files or CLI export. Logs contain conversation and tool output; check for sensitive content before sharing.

### File operations on stopped instances

`stoppedFileAccessImplemented=true` advertises directory/file access, preparation files, task import, snapshot import/export, and trajectory reading for stopped instances. State is unchanged, agents are not started, and no execution slot is occupied. A restricted `--files-only` Host with the same container identity handles access and forbids exec. Idle maintenance processes are reclaimed automatically and closed before instance startup or deletion. Writes save directly to the workspace; snapshots update on explicit saving, full export, or stopping. The service must remain online; file access does not revalidate old Handles.

`reveal-file ID REL [--preview]` validates the actual workspace file/directory through the Host before the CLI requests Finder selection. `--preview` returns only the target without opening Finder. RPC `workspace-location` is administrator-only and returns `workspaceLocation`. Capability is `workspaceRevealImplemented=true`.

### Execution history

`executions [--instance ID] [--limit N] [--before EXEC_ID]` returns lightweight `executions`, all unfinished `pendingExecutions`, and optional `nextExecutionCursor`, excluding full arguments and output. `execution EXEC_ID` returns the complete command, status, and available result. Merge records by execution ID; records remain after instance deletion. Administrator permission is required; capability is `executionHistoryImplemented=true`.

### Instance environment

`create --env-file FILE` reads a string-to-string JSON object independently bound to every created instance. RPC create takes optional `environment`; omission means empty settings without copying credentials from the manager's environment.

`env ID` returns only `environmentKeys`; `env ID --show-values` explicitly returns `environment` values. `env ID --from FILE` replaces all settings; `{}` clears them. RPC operation is `environment` with `instanceID` and optional `environment`, or `revealEnvironment=true` for reading values. Administrators only; the target need not be started. Capability is `environmentImplemented=true`.

Values are excluded from `list`, `inspect`, and execution records and are not passed individually as command-line arguments. Temporary input files should use 0600 permissions. Programs inside the instance can read values, and deliberately printed values are not covered by log-redaction guarantees. Deleting the instance deletes its private environment settings.

`exec ID --env-file FILE` sets one command's string-to-string JSON environment; `--env-file -` reads stdin.
RPC uses `command.environment`, overriding same-named instance settings for that execution and participating in shell classification.
Values do not enter instance settings, history, or snapshots, though commands may print or write them.
Concurrent executions have separate environments. Capability is `commandEnvironmentImplemented=true`.
Reserved `HOME`, `TMPDIR`, `WORKSPACE`, and `METAL_SANDBOX_*` variables cannot be overridden.

### Instance and execution status

Instance objects from `status`, `list`, and `inspect` include `executionCounts`:

```json
{"parallelRunning":2,"parallelWaiting":0,"serialRunning":1,"serialWaiting":3}
```

These count parallel running/waiting and serial running/waiting tasks; their sum equals `pendingExecutions` within the same response. At most one serial task runs per node. Running spans permit acquisition through execution and cleanup; waiting includes dispatch, serial queuing, and thermal pauses. Agent main sessions and adapter-submitted Bash children count separately; ordinary descendants do not. Instance objects contain their own counts; `status` totals the local node, or the available cluster nodes when called on the management node. These are task statistics, not proof of GPU idleness.

`status.networkClientImplemented=true` advertises creation-time outbound networking. CLI enables it by default; `create --count N --no_network` disables it. RPC defaults omitted `networkClient` to true, with explicit false disabling it. `NativeInstanceRecord.networkClient` returns the choice. Permission applies to the instance and descendants, not selected domains. No live update is available; restored instances retain the choice.

Instance states include starting/active/publishing/stopped/interrupted/failed/cleanup-failed. Restore creates a new logical ID without replaying processes. Execution states are queued/running, followed by succeeded/failed/cancelled/interrupted. Exit code zero does not establish task correctness.

`availableActions` lists current `start`/`stop`/`delete`/`restore`/`files` operations. Clients use it rather than infer actions from state strings. A failed instance with active sessions can be stopped, while a historical failed instance has no stop action. The service rechecks permissions, queues, and directory ownership on submission.

`appSandboxBackend=true` indicates the native backend is enabled. See [release scope](../README.md#release-scope).

Deletion requires an inactive target with no unfinished commands of its own; it neither requires other queues to be idle nor cancels their tasks. States are `deleting`/`delete-failed`. Success retains only a `deleted` audit in `deleted_instances`, removing the active list entry. Failed deletion cannot restore checkpoints. `ownedBundleIDs` includes every allocated physical version, including failed publications. Missing, incomplete, or conflicting ownership rejects deletion. Insufficient permissions on system shells are saved in `cleanupWarnings` and returned as `warnings`; this does not mean the entire container disappeared. `status.permanentDeletionImplemented=true` indicates API support, not security certification.

### Residual cleanup results

Each `cleanup` element contains `bundleID, source, state, error?`. State is `planned`, `removed`, `data-removed-shell-retained`, or `failed`. Confirmed cleanup continues through all items without automatic retries. Residual or failed cleanup returns CLI code 1 while RPC returns the complete array. Unclaimed cleanup requires exact identities and previews by default. Stop all instances, ensure queues are idle, and confirm node health first.

`containerShellDeletionImplemented` reports API support without guaranteeing that macOS permits removal of container shells.

### Instance names

`create --name NAME` sets an optional display name. Batches append ` (1)`, ` (2)`, and so on. `rename ID NAME` uses RPC `rename` and permits only administrators to change `name`; empty strings clear it. Names may repeat. Surrounding whitespace is stripped and internal control characters are rejected. Active and stopped instances can be renamed; only metadata changes, without starting a Host or moving directories. `list` / `inspect` return optional `name`; CLI operations always use IDs.
