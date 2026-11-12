# Graphical Interface

The frontend is a native SwiftUI App, not an Electron/WebView application or a separate sandbox backend.

## Installation and First Use

Open the installation DMG, drag `Metal Sandbox.app` into Applications (or your `~/Applications`), and double-click it. The App contains all project CLI and runtime components; you do not need to clone the source, install Swift packages, or configure binary paths manually.

The DMG also includes `README.md`, the `docs` documentation, and the `examples` task packages. Copy them locally to read, edit, or import them.

On first use, click Start Service, read the trusted-code notice, and confirm. If a compatible service is already running, the frontend connects through `status` and `list` without starting a second manager. Only one manager is allowed per UID; changing state-dir does not bypass this limit.

Running requires an Apple Silicon Mac and Apple Command Line Tools. If the toolchain is missing, run Apple's `xcode-select --install` yourself. The App does not download code, change the system toolchain, or require root. The declared minimum is macOS 13; Liquid Glass requires macOS 26+, while older systems use standard native controls. The alpha release does not yet guarantee compatibility with all hardware and system combinations.

Locally generated Apps use ad-hoc signing, without Developer ID signing or notarization. Transfer between machines may trigger system security checks. Do not disable Gatekeeper, remove quarantine, or re-sign system programs. Local usability does not establish certification for external distribution.

## Pages and Command Mapping

Unless otherwise noted, the following commands use `sandboxctl sandbox`. The state directory is passed to the CLI with the global `--state-dir` option.

| Page or action | Actual command |
|---|---|
| Overview, periodic refresh | `status`, `list` |
| Overview → Add Node; Connection Settings → Add Worker Node | `sandboxctl cluster-ssh scan` / `connect`; the wizard verifies the host fingerprint, passes the password through stdin, installs a public key, and saves the configuration after checking the remote service |
| Create N instances | `create --count N [--name NAME]` |
| Cluster nodes and dynamic scheduling | `create --node ID --dynamic-scheduling`; select a role, add or remove workers, and set the shared directory in Connection Settings; save and apply when idle, or display pending application while instances or tasks are active |
| Rename a single sidebar selection | `rename ID NAME`; an empty name restores the abbreviated ID |
| Instance details | `inspect ID` |
| Stop, stop all | `stop ID`, `stop --all` |
| Permanently delete after confirmation | `delete ID --confirm` |
| Deletion remnants → Show in Finder | `reveal-containers BUNDLE_ID...`, using only confirmed identities returned by that successful deletion |
| Sidebar batch stop or delete | Call `stop ID` / `delete ID --confirm` for each confirmed target |
| Single or multiple sidebar selection → Show in Finder | One `reveal-containers BUNDLE_ID...` call locates the selected instances' current physical containers without starting them; instances without a physical container are skipped with a notice |
| Start original instance | `start ID`, preserving the ID, original workspace, and private HOME |
| Clone from snapshot | `restore ID`, returning a new logical ID and copying only the workspace |
| Open in Terminal | Run `enter ID` in macOS Terminal with the same CLI and connection settings |
| Submit preparation script | `exec ID --cwd REL --timeout S --detach -- PROGRAM ARGS...` |
| Claude/Codex trajectories, session selection, incremental refresh | `trajectory ID [--session PATH] [--after CURSOR]` |
| Results, cancellation | `wait EXEC_ID`, `cancel EXEC_ID` |
| Console connection, individual commands, advanced options | `enter ID`; use `:run` for a command, timeout, and optional directory (not a PTY) |
| Workspace tree, expansion, pagination | `ls ID REL [--after NAME]` |
| File preview, download | `read` |
| Preparation script and prompt | Two `write` calls, then `exec -- /bin/sh ./setup.sh` |
| Snapshot import, export | `import`, `export` |
| Save backend snapshot without exporting a file | `snapshot ID` |
| Export a restricted Handle | `grant` |
| Advanced manual recovery | `recover --confirm-processes-cleaned --note TEXT` |
| Shut down service | `shutdown` |
| Start service | `metal-sandboxd --allow-trusted-code` |
| Instance → Verification | `verify ID [--from TASK_FOLDER] --timeout S --detach`; read history and results with `executions` / `execution` |

Buttons do not call private RPC, open container directories directly, start candidate binaries, or operate the GPU. Local file selection supplies only CLI input and output. Frontend temporary files, preferences, and publicly exported results are separate from backend internal state.

The Pending Commands count in Overview and the sidebar includes top-level tasks and integrated Bash subtasks, both serial and parallel: one Claude session and three unfinished Bash calls display 4. Completion or cancellation removes them from the count. This is neither a system process count nor GPU activity. The Serial Execution Slots count excludes parallel tasks. The [two-Sandbox Metal example](native_operations.md#try-serial-scheduling) shows non-allowlisted tasks changing from 2 → 1 → 0.

The sidebar displays each Sandbox's unfinished command count, including running and queued serial/parallel tasks, rather than child process counts. It updates with list refresh. Idle instances show 0; temporarily unavailable counts show “—”.

Drag selection, Cmd/Shift selection, and Cmd+A select only Sandboxes. Passing over or adding clicks on Overview, Activity, or Connection Settings preserves existing Sandbox selection and the current page. An ordinary single click on those navigation entries still switches pages.

## Common Workflows

### Create, Edit, and Execute Commands

Instance tabs appear in this order: Overview → Preparation → Trajectory → Verification → Terminal → Files → Settings and Snapshots.

1. Click Create Sandbox and choose 1–16. Active instances are limited by Maximum Concurrent Instances in Connection Settings, defaulting to 32 per node. Expand Advanced Options to select an allowlist (matches run in parallel; others serially) or denylist (matches run serially; others in parallel) and edit JSON. The service configuration is the default; first switching to another mode provides an empty list, and switching back and forth preserves each draft. Allowlists use parallel and denylists use serial; they cannot be combined. Invalid JSON or a mismatch with the selected mode prevents creation. An empty denylist allows all tasks to run concurrently across instances. The dialog grows when Advanced Options expands and shrinks when collapsed; its size and internal layout update together, and the form scrolls.
2. The creation window provides Import Task Package. Select a folder containing `agent/` and `tests/`. Selection loads `agent/setup.sh` and expands the preparation editor so configuration can be entered before creation. Each copy imports only `agent/`, saves the edited script, and submits execution. An empty script imports without executing. Do not modify the source task package before creation finishes.
   You can also enter a custom script without choosing a package. Copies use the same creation settings and do not wait for the previous task to finish. An import failure prevents that copy's script from running without blocking other copies. There is no automatic retry or instance deletion, and other instances' workspaces or HOME directories are not copied.
3. Select an instance and browse, preview, or download project files in Files.
4. Enter project commands in Terminal and press Return.
5. Modify files based on the output or execute the next command.

Compile and run according to the project's build instructions. The CLI parses commands; shells and candidate programs execute inside the sandbox without expansion by the host shell.

Start, stop, clone from snapshot, and delete appear on the left side of the upper-right toolbar, followed by refresh, create, and more; search is at the far right. Buttons show only icons with hover descriptions. Instance actions target the instance shown on the main page and are enabled according to its state.

Search uses the native toolbar control and adjusts its width to available window space. It remains usable with the sidebar collapsed. Search filters only the sidebar without switching the current instance or tab; clearing search restores the current instance's sidebar highlight. Clicking outside or changing windows ends editing focus while preserving text and filters. The sidebar toggle and instance actions use circular glass controls; refresh, create, and more share a native glass group. Instance tabs fill the content area with equal widths.

### Starting and Cloning

Start Original Instance preserves the ID, original workspace, private HOME, and installed tools without replaying old processes. Old Handles require new authorization. Clone from Snapshot creates a new ID and copies only the saved workspace, excluding HOME. A quarantined node must first follow the recovery procedure; starting cannot bypass quarantine.

### Trajectory

The Trajectory tab after Preparation displays Claude/Codex text, reasoning, tool calls, results, and errors as conversation cards rather than raw JSON. Sessions can be selected and long content expanded; automatic refresh and scrolling are enabled by default. Reading does not occupy the execution queue and is available while an agent runs. Session completion means only that the harness exited, not that the task passed verification.

Supported Claude logs in private HOME are `~/.claude/rollouts/<session>/events.jsonl` and official `~/.claude/projects/<project>/<session>.jsonl`. For the same session, the official file is preferred, including resumed-session records; rollout output logs are used when it is absent. Codex uses `~/.codex/sessions/**/*.jsonl`. Missing logs show an empty state; trajectories remain readable for stopped instances without starting an agent. Workspace snapshots exclude these HOME logs. The mini-swe-agent preparation script stores records in the workspace at `mini_swe_agent_runs/<session>/`, viewable through Files. All three harnesses run through Harbor can also be viewed in Harbor Viewer.

Save and Run Preparation displays Preparation Task Submitted / Task Submitted to Backend only after backend acceptance. This does not mean the script has finished; failed saving or submission does not show the success dialog.

### Terminal

The instance page has one Terminal command entry. It starts the public `sandboxctl sandbox enter ID` automatically. Enter one line and press Return or ⌘Return. `cd src` preserves this console's current directory; `:help` shows help, and `exit` leaves only the console. Connections, input drafts, settings, and output persist across tab or instance changes. Disconnect, reconnect, and clear the screen manually when needed.

Open in Terminal calls `sandboxctl sandbox enter ID` in macOS Terminal with the same connection settings. This is an independent console without shared current directory, input, or output history. `exit` leaves it without stopping the instance. It retains the individual-command and non-PTY restrictions below.

Automatic Scrolling is enabled by default and scrolls new output only to the bottom. Horizontal positioning starts at the left and is controlled manually; automatic scrolling does not change it. Turn it off to keep viewing earlier output.

Advanced Options includes working directory, timeout, and command templates. An empty directory uses the console's current directory; `.` means the workspace root. Another workspace-relative path overrides only that command's directory without replacing the directory saved by `cd`. Timeout is a positive duration in seconds, defaulting to 30. Templates include only Print Working Directory and Read Task; they fill the command without executing or changing the timeout. Expanding or collapsing Advanced Options does not change execution settings.

Output shows the execution ID, stdout/stderr, and exit code. To continue waiting or cancel, enter the execution ID in Activity. Disconnecting Terminal does not cancel execution.

This is an individual-command console, **not a PTY terminal emulator**. Each command defaults to 30 seconds, and stdout/stderr return after it finishes. vim/top, interactive stdin, job control, and shell variables across commands are unsupported. One line is limited to 8 KiB; multiline paste is rejected. Save multiline tasks as scripts before running them. The display keeps the latest 256 KiB. An idle console occupies no slot; the service selects parallel or FIFO serial scheduling according to the instance's policy.

Disconnecting, exiting the frontend, or changing connection settings stops only the frontend's CLI observation process, without stopping the Sandbox or cancelling submitted commands. Submitted commands may continue. Stopping or deleting an instance disconnects its console.

### Browsing the Workspace

Entering a page reads its data again: instance pages refresh details, Files refreshes the directory and selected preview, Preparation rereads entry files, and Trajectory and Verification read current records. Expanding environment variables or folders also rereads them. Unsaved environment variables, preparation scripts, and task drafts are not overwritten automatically. Read failures display an explicit error and do not report cached data as a successful read.

Files is a read-only browser. The left side shows a workspace tree with hidden files, empty directories, binaries, and large files. Pages contain 256 entries with Load More. The right side shows selected file metadata and preview, with refresh, full download, and Show in Finder in the context menu. Modify files using Terminal, an agent, or a preparation script.

UTF-8 text and source code display directly, showing at most the first 4 MiB; downloads have no size limit. Images, PDFs, audio, video, RTF, and other formats use macOS Quick Look. Actual support depends on the system and installed preview extensions; not all formats are guaranteed to display, and audio/video does not autoplay.

Previews are downloaded through the CLI into a private temporary directory, retaining their extensions and set read-only. System preview components receive only the copies without direct container access or writing changes back to the workspace. Switching files or exiting releases the temporary copies. Previews do not synchronize live; click Refresh Preview after changes.

Directory listing reads no file contents and does not follow symbolic links. Links and special files show metadata only. Pagination is a live observation rather than a snapshot; refresh after concurrent renaming or additions. A single directory scan is limited to 100000 entries, and backend path restrictions remain. Limit violations and permission failures are reported explicitly. Stopped instances remain browsable, previewable, and downloadable without starting them or occupying command slots.

### Instance Environment Variables

Environment Variables in the creation window can be expanded to add key/value rows; copies in a batch each save the same configuration. After creation, edit them in Settings and Snapshots → Environment Variables, including for stopped instances. Values are passed literally without `$VAR`, command substitution, or shell expansion. `HOME`, `TMPDIR`, `WORKSPACE`, and `METAL_SANDBOX_*` cannot be overridden.

Variables apply to preparation scripts, console commands, exec, and child processes that inherit their environment normally. Saving affects subsequently submitted commands without changing running processes. Restart Claude after changing model configuration. Programs overriding or clearing variables follow normal macOS behavior.

The backend saves variables by instance ID in private files with mode 0600, without encryption. The frontend excludes values from operation records, and workspace ZIPs exclude the configuration. Starting the original instance preserves it; cloning from a snapshot in the same service copies the source instance's environment configuration. A program printing variables or writing them into the workspace may expose them in logs and snapshots.

Task scripts should read injected variables rather than override them with hardcoded `export KEY=...`. The bundled packages use this approach.

### Preparing the Environment and Task

Preparation reads the workspace's actual `setup.sh` and `instruction.md` through the CLI. Missing files are reported without filling in examples. Drafts are kept per instance and survive page changes; re-entering rereads unedited content without overwriting edited drafts. Reread discards a draft and refreshes it.

Load Script selects a local script, or edit directly; these actions affect only drafts. Save writes the current content, while Save and Run Preparation saves and then executes `/bin/sh ./setup.sh`. Any write failure prevents subsequent execution without undoing files already written. An absent script shows an empty editor, without built-in harness options.

Import Task Package accepts only a task-package root and calls `sandbox import ID --from DIRECTORY --task`. It verifies that `agent/instruction.md` and `agent/setup.sh` are nonempty regular files before importing; either missing file prevents workspace writes. The CLI packages only `agent/`, including hidden files, into the workspace root; `tests/` is injected for verification later. Successful import rereads both entry files without executing. Import merges the workspace and may overwrite matching files and discard drafts, requiring confirmation. See [Task Packages and Agent Startup](task_packages.md) for format and commands.

The task package determines its preparation script, which may install tools, configure the environment, or start any harness. The App does not determine whether it uses Claude, Codex, or another program. Model configuration can also use `export` in the script, but API keys then remain in plaintext in the workspace and exported snapshots and must be removed before sharing. Use private HOME configuration when supported by the tool.

Allow Outbound Network Access is selected by default during creation; deselecting it is equivalent to CLI `--no_network`, without hot switching after creation. Preparation timeout accepts text and arrow controls, defaults to 3600 seconds, and allows any positive number of seconds, including the script's entire execution. Running is noninteractive without a PTY; view results in Activity. Script exit does not close the sandbox; conversation and artifact locations are determined by the script.

Starting the original instance preserves private HOME. Cloning from a snapshot excludes HOME installations, configurations, and sessions, requiring preparation again. Preparation-file editing previews are limited to 4 MiB; larger files report an error without saving a truncated version and can still be edited completely through Terminal.

### Settings and Snapshots

This page displays the allowlist/denylist mode and JSON saved at instance creation, read-only in a fixed-height scrollable, selectable box. It remains viewable after stopping and is retained on starting or cloning. Snapshot operations and Handle authorization are available here.

Save Snapshot updates the backend recovery point without selecting an export file. A snapshot contains all workspace files and empty directories, excluding command history, private HOME, process memory, and GPU state. Snapshot File Count and Snapshot Size in Overview refer to the latest saved snapshot, not current workspace size.

File changes are saved directly on disk. Ordinary commands, writes, and imports do not create snapshots. Explicit saving, full export, or stopping updates them; a new instance retains its initial snapshot. Save edits made after stopping again before cloning. Saving requires the instance to be idle and does not interrupt running tasks.

Snapshots export as standard ZIP/ZIP64 archives in chunks, without per-file or total byte limits. Import validates the archive, then merges and overwrites matching paths. Disk-write failures may leave partial changes; the whole operation is not transactional. Restoring creates a new ID without replaying execution.

An exported Handle is a credential whose contents the frontend does not read. Give it only to trusted tool adapters, without uploading it into a candidate sandbox. The original backend verifies permissions.

## Results, Cancellation, and Errors

Activity synchronizes backend-submitted top-level executions, including GUI, CLI, and preparation tasks, deduplicated by execution ID. Queued and running states update with refresh. Initially it loads recent records and all unfinished tasks; earlier executions can be loaded. Selection reads the complete command and result. View Claude Bash subtasks in Trajectory. Ordinary frontend actions, such as directory refresh, are recorded only in the current frontend session.

Right-click a regular file or folder in the file tree to Show in Finder; the workspace heading provides the same entry. The frontend calls `reveal-file`, and the backend validates the relative path without starting files, following links, or opening special files.

### Permanent Deletion

Stop the target and wait for its commands to finish, then click the red Delete button at the upper right and confirm. An unavailable action uses the system disabled appearance. Running or queued commands in other instances do not prevent deletion and are not cancelled. Deletion removes task files, snapshots, registered physical versions' runtime programs, and the instance-list record. Separately exported artifacts, execution logs, and recovery audits remain. The emptied container shell is removed when the system permits; insufficient permissions list exact remnants in the result window without claiming complete cleanup. This is not secure disk erasure.

Failures show Deletion Failed and preserve records for diagnosis and retry. Incomplete or conflicting ownership prevents deletion. Residual cleanup is available through the CLI; the frontend does not read containers directly. See the [Usage Guide](native_operations.md).

### Execution Results

- Waiting for Result means only that submission succeeded, without identifying queuing or execution. The CLI emits candidate logs on completion; the frontend does not fabricate live logs.
- Activity can filter by Sandbox ID and shows all records by default. Service operations and records with unknown ownership appear under Service / Unassigned Records. Batch-creation records appear under each related instance, and cloning links source and new instances. Existing records in the current frontend session remain filterable after deletion. Changing filters performs no backend operation.
- Preparation results show stdout/stderr, exit code, timeout or cancellation reasons, and execution ID. Rerunning preparation submits a new execution without resuming an earlier conversation automatically. The display shows at most the first 256 Ki characters; the backend enforces actual log limits. Result text and rule JSON start at the upper left and support manual scrolling in both directions.
- Network or CLI wait failures can leave the result unknown. Mutating operations are not automatically retried, commands are not resubmitted, and state is not cleared.
- A command timeout with successful process-group cleanup shows only task failure. The same instance and other instances can continue, without automatic quarantine. CLI wait timeout differs from backend command-runtime timeout.
- Cancellation calls only `cancel`, without killing candidates from the frontend. Successful process-group cleanup marks the task cancelled while keeping the instance usable; failed or uncertain cleanup retains quarantine.
- Recovery requires external confirmation of process and GPU state and stopping disconnected instances. The frontend collects explicit confirmation and inspection notes but cannot prove GPU drain automatically.
- Verification runs the package's `tests/test.sh`; importing only tests/ is supported, with pass/fail, exit codes, and saved historical logs. Stopped instances can show history; running verification requires starting the instance. This is not an independent anti-cheating judge. See [Task Verification](task_packages.md#verifying-answers) for script conventions and CLI usage.

## Multiple Selection and Batch Operations

Hold **⌘** to select individual Sandboxes in the sidebar, or **⇧** to select a range. Multiple selection keeps the previous main page without displaying a selection count or switching to a batch overview. Overview and tool pages retain single-page navigation.

After clicking the sidebar, **⌘A** selects all Sandboxes. With search active, only matching Sandboxes are selected, excluding Overview and tool entries. In search, input fields, and editors, **⌘A** still selects text.

Right-click selected rows for batch stop or permanent deletion; right-clicking an unselected row targets only that row. Confirmation lists the count and complete IDs; cancellation submits nothing. If any selected item is ineligible, the entire action is disabled without silently skipping it. Before deletion, stop the targets; the backend checks unfinished commands for each instance without requiring the node's queue to be idle.

Confirmation fixes targets and connection settings, then calls the CLI sequentially. A failed, timed-out, or invalid response records its cause and processing continues for other instances. Each item is attempted once without automatic retries, undoing changes, or stopping before deleting. A scrollable, copyable result window lists the success count and separately identifies failures and unknown results with reasons. Failures can leave partial changes; unknown results do not imply no execution, so refresh to check. Backend safety restrictions apply to every item. Each command appears in Activity. Rows hidden by search or removed by refresh are removed from the selection.

## Appearance, Lifecycle, and Settings

Navigation, toolbars, menus, dialogs, and key buttons use native system appearance. Upper-right buttons are uniformly sized circular icons, using native Liquid Glass on macOS 26+. Delete is red, while content retains clear system text/list backgrounds. Materials follow system light/dark appearance and accessibility settings without custom glass textures.

The toolbar attaches to the entire navigation split. A system API hides its separate background so the window background continues to the top bar, preserving the native sidebar and existing fixed-viewport constraints.

Global automatic refresh defaults to every five seconds and is configurable in Connection Settings. Visible windows refresh even when the App is not foreground, with immediate refresh on return. The toolbar refresh button also works manually. Exiting the frontend does not stop the service or submitted tasks; exiting during performance measurement can reduce its own GPU interference. Note execution IDs that you need to continue waiting for before exiting.

The Overview Pending Commands card shows the total on the left and two detail rows on the right, vertically centered with margins: Parallel Tasks: x running + x waiting, and Serial Tasks: x running + x waiting. Each instance's details appear at the right of its page heading across tab changes; the sidebar displays only its total. Data comes directly from the backend scheduler, and the four counts sum to the unfinished total, including agent sessions and Bash subtasks submitted through adapters.

Connection Settings can select other CLI directories, state directories, and refresh intervals. An empty CLI directory uses the App's `Contents/Helpers`. A CLI/service version or protocol mismatch disables mutations without automatically replacing the service.

Frontend preferences are stored separately in `UserDefaults`. Service logs for frontend startup are in `~/Library/Application Support/MetalSandboxUI/service_logs`. Backend state remains CLI-managed; the frontend does not read tokens, internal state databases, or system containers. Deleting the App does not remove backend state or recovery audits. See [Security Boundaries](security.md) and [Stopping and Cleanup](native_operations.md).

### Instance Names

Creation accepts a name; multiple instances display Name (1), Name (2), and so on. Empty names show the first 12 ID characters. Right-click a single sidebar selection → Rename to edit the name in place. Return, Tab, or loss of focus saves; Esc cancels. Clearing and saving restores the abbreviated ID without a dialog. Names can contain Chinese characters and spaces and need not be unique. Search supports names and IDs. Names survive service restarts. The main page always displays the complete sandbox ID; renaming moves no directories and interrupts no execution.
