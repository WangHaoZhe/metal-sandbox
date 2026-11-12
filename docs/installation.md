# Installation and Best Practices

The runtime requires an Apple Silicon Mac and Apple Command Line Tools or full Xcode. The declared minimum is macOS 13; see [release scope](../README.md#release-scope) for compatibility limits.

## Requirements and development tools

For C/C++ development, either Command Line Tools or full Xcode is sufficient. Compiling standalone `.metal` files requires full Xcode and the Metal Toolchain.

### Command Line Tools

If full Xcode is not installed:

```sh
xcode-select --install
```

Complete installation in the system dialog. A full Xcode installation does not require a second CLT installation.

### Xcode

```sh
# Open Xcode in the Mac App Store and choose Get/Install.
open 'macappstore://apps.apple.com/app/id497799835'

# Open the installed App, accept the license, and complete first launch.
open /Applications/Xcode.app

# Select the toolchain for this command without changing global xcode-select.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version
```

App Store installation and initial license acceptance require user interaction; `open` does not download and install Xcode in the background.

### Metal Toolchain (Xcode 27)

After opening Xcode for the first time:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -downloadComponent MetalToolchain

# Locate the actual component compiler rather than the placeholder binary.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun --find metal
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun metal --version
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun --find metallib
```

Run these installation and inspection commands in a host terminal as the administrator. The component download requires networking.

### CMake and Ninja

From the source repository root:

```sh
python3 scripts/install_development_tools.py

# Verify the installed tools.
TOOLS="$HOME/Library/Application Support/MetalSandbox/development_tools"
"$TOOLS/cmake/CMake.app/Contents/bin/cmake" --version
"$TOOLS/ninja/ninja" --version
```

The script installs pinned official versions, CMake 4.4.3 and Ninja 1.13.2, and verifies SHA-256 after downloading. It requires neither Homebrew nor root and does not change the system PATH. **Restart the management service normally after installation.** New instances automatically use these read-only tool paths. If you have only the DMG, obtain the installation script from this repository; CMake and Ninja are not bundled with the DMG.

## Install the App

1. Open `metal_sandbox_<version>_arm64.dmg` and drag `Metal Sandbox.app` into Applications.
2. Open **Metal Sandbox**, choose Start Service, and confirm that only trusted code will be run.
3. Choose Create Sandbox and select the instance count. Advanced Options lets you select allowlist or denylist mode and edit the instance's scheduling-rule JSON. Select an instance in the sidebar.
4. Use Preparation, Terminal, and Files to run scripts, develop, and inspect results. Verification runs a task package's `tests/test.sh` and shows results and historical logs. Settings and Snapshots displays scheduling mode and rules and manages snapshots.

If macOS blocks the downloaded App on first launch, use **System Settings > Privacy & Security > Open Anyway** to allow it, then reopen the App.

The installation package includes both frontend and backend; no source download or `swift build` is required. New instances enable outbound networking by default. Task preparation scripts install harnesses, configure models, and start Agent work. Claude Code, Codex, and mini-swe-agent support noninteractive tasks and separately scheduled tool commands. See [harness examples](../examples/harnesses/README.md) or [Harbor](harbor.md).

**Quitting the frontend does not stop the service.** Use Service Actions > Shut Down Service to stop it. See the [frontend guide](frontend.md).

Instances can be named during creation; batches append `(1)`, `(2)`, and so on. Right-click a single selected sidebar instance to rename it in place: Enter saves, Escape cancels, and an empty name restores the abbreviated ID. Naming does not change the instance ID, directories, or command arguments.

## Update the App

1. Wait for current tasks to finish and confirm that the unfinished command count is zero.
2. In the upper-right menu, choose Shut Down Service, wait for shutdown, and quit the App.
3. Open the new DMG, drag `Metal Sandbox.app` into its existing installation directory, and choose Replace.
4. Open the updated App from the installation directory, start the service, and start existing Sandbox instances as needed.

Frontend and backend update together. Existing instances, workspaces, environment variables, and snapshots are retained. Quitting the App alone does not stop the management service.

## Configure a cluster

Install Metal Sandbox and the required development tools on every Mac. Use the same service version and compatible compilers, SDKs, and task dependencies across nodes.

### Remote Login and SSH

1. On each cluster node, open **System Settings > General > Sharing**, click the Info button next to **Remote Login**, and enable **Remote Login**. Allow the account that will run Metal Sandbox to log in.
2. Choose one Mac as the manager. In **Connection Settings > Node Cluster**, choose **Manager node** and assign a unique node name. Choose **Worker node** on the other Macs and give each a unique name. Save the settings and restart each idle management service so the selected role takes effect.
3. On the manager, use **Add Worker Node** to enter the worker address and username, confirm its SSH host fingerprint, and configure key authentication. Leave the password empty when dedicated key authentication is already configured. The wizard checks the remote service; start it on the worker first.
4. Verify a noninteractive SSH request from the manager. Replace `node_user` and `node_address` with the worker account and address:

```sh
ssh -o BatchMode=yes -o ConnectTimeout=8 node_user@node_address \
  '"/Applications/Metal Sandbox.app/Contents/Helpers/sandboxctl" --version'
```

5. Save the manager cluster settings and restart its service while it is idle. Confirm that Overview shows every worker as connected. The CLI can also query the running cluster:

```sh
"/Applications/Metal Sandbox.app/Contents/Helpers/sandboxctl" sandbox status
```

See [node configuration](cluster.md#configuration) for SSH keys, host fingerprints, and advanced connection options.

### File Sharing and SMB mounts

Dynamic scheduling requires nodes in the same scheduling pool to access instance directories on other nodes through SMB. Configure sharing and mounts before enabling it.

1. Choose the same `sharedRoot` on all nodes, for example `/Users/Shared/metal_cluster_nodes`. Create a local subdirectory for each node. For a node named `node_a`:

```sh
mkdir -p /Users/Shared/metal_cluster_nodes/node_a
```

2. On that Mac, open **System Settings > General > Sharing**, click the Info button next to **File Sharing**, and enable **File Sharing**. Add `sharedRoot/node_a` to **Shared Folders** and grant the account used for SMB **Read & Write** permission. In **Options**, turn on **Share files and folders using SMB** and enable the account used to connect. Export only the local subdirectory for this node; the shared root also contains mount points for other nodes.
3. On every other node in the same pool, mount this share at the same absolute path. Use the actual SMB share name shown in File Sharing settings. For the `node_a` share:

```sh
mkdir -p /Users/Shared/metal_cluster_nodes/node_a
/sbin/mount_smbfs //node_user@node_address/node_a \
  /Users/Shared/metal_cluster_nodes/node_a
```

Enter the SMB password when prompted. Repeat for each peer. The owner accesses its own directory locally; other nodes access it through SMB. A four-node pool needs each node to mount the other three shares.

4. Configure the same `sharedRoot` in cluster settings on every node. Check mounted shares with `/usr/bin/smbutil statshares -a`, then verify reading and writing a file across the nodes. Confirm that the mounts support the file permissions and executable files required by the tasks.
5. Configure the scheduling pool and enable dynamic scheduling on its participating nodes. Start the services and confirm the manager reports all expected nodes as connected before submitting tasks.

Metal Sandbox does not mount SMB shares automatically. After a reboot, restore the required mounts before starting tasks. See [node preparation](cluster.md#node-preparation) and [dynamic scheduling](cluster.md#dynamic-scheduling) for storage layout and scheduling requirements.

## Start the CLI from source

Requirements: Swift 6.0+ and Python 3.9+ for checks and packaging, in addition to the development tools above.

Run in a normal user terminal from the source root:

```sh
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
"$BIN/sandboxctl" --version
"$BIN/metal-sandboxd" --allow-trusted-code
```

The service stays in the foreground. In another terminal, from the same source directory:

```sh
BIN="$(swift build -c release --show-bin-path)"
"$BIN/sandboxctl" sandbox create --count 4
"$BIN/sandboxctl" sandbox list -h   # Readable table; omit -h for JSON.
# Replace sbx-... with a returned ID or unique prefix.
"$BIN/sandboxctl" sandbox enter sbx-...
```

`exit` leaves the console without stopping the instance. `enter` is a per-command console, **not a PTY**. It does not support vim, top, job control, or shell variables carried between commands.

```sh
"$BIN/sandboxctl" sandbox exec sbx-... -- echo hello
"$BIN/sandboxctl" sandbox stop sbx-...
"$BIN/sandboxctl" sandbox shutdown
```

**Starting the service requires explicit `--allow-trusted-code`.** Public execution goes through the App Sandbox Host; no bare-host fallback is provided. This does not imply that every other application launch path is fully constrained.

Upload `setup.sh` and `instruction.md` with `sandbox write`, then start a harness session with `sandbox exec ID --session -- /bin/sh ./setup.sh`. Ordinary scripts may omit `--session`. See [generic preparation scripts](native_operations.md#4-generic-preparation-scripts-and-task-input) for complete commands and networking/interaction limits.

**Note:** New instances allow outbound connections without domain restrictions. Disable them with `--no_network` or the creation dialog's outbound-networking option; this cannot change live. Uploads, downloads, and workspace snapshots have no byte-size limit. Snapshots use standard chunked ZIP/ZIP64 archives and require enough disk space. Snapshots contain only the workspace, **not tools and sessions in private HOME**. A clone made with `sandbox restore ID` must prepare its environment again; `sandbox start ID` retains the original workspace and private HOME. Claude supports noninteractive multi-round work and parallel main sessions.

## Best practices

### Disable Spotlight indexing on dedicated nodes

Large task workspaces and rollout logs can produce substantial Spotlight indexes. On Macs dedicated to running tasks, disable indexing to reduce background disk activity and index growth. Run on each node in a host terminal:

```sh
sudo /usr/bin/mdutil -a -i off
/usr/bin/mdutil -a -s
```

`-a` applies to all volumes. Confirm that each reports `Indexing disabled`. This affects file search in Spotlight and Finder; the Spotlight interface remains available. Disabling indexing does not erase existing indexes.

To restore indexing:

```sh
sudo /usr/bin/mdutil -a -i on
```

### Use stable network addresses and disable Wi-Fi

Use wired networking and configure a fixed IP address for each node. Either configure DHCP reservations on the network equipment or enter a manual address assigned by the network administrator:

1. Open **System Settings > Network**, select the wired connection (such as **Ethernet**), and click **Details > TCP/IP**. Set **Configure IPv4** to **Manually**, then enter the **IP address**, **Subnet mask**, and **Router**.
2. In **DNS**, enter the DNS server addresses supplied by the network administrator. Save the settings and verify that the wired connection can reach the other nodes and the internet.
3. Open **System Settings > Wi-Fi** and turn off **Wi-Fi**.

After a reboot, check SSH connectivity, SMB mounts, and service status before resuming jobs. See Apple's instructions for [manual IP addresses](https://support.apple.com/en-us/guide/mac-help/mchlp2718/mac) and [Wi-Fi connections](https://support.apple.com/en-us/guide/mac-help/mchlp1180/mac).

### Disable automatic software updates

During batch runs, open **System Settings > General > Software Update**, click the Info button next to **Automatic Updates**, and turn off **Download new updates when available**, **Install macOS updates**, and **Install system data files and security updates**. Older versions call the last option **Install Security Responses and system files**. Schedule system and toolchain updates when the nodes are idle. See Apple's [Software Update settings](https://support.apple.com/en-us/guide/mac-help/mchla7037245/mac).

### Prevent sleep and automatic screen locking

Use the following settings on dedicated desktop Macs:

| Location in System Settings | Setting | Recommended value |
|---|---|---|
| Energy | Prevent automatic sleeping when the display is off | On |
| Energy | Wake for network access | On |
| Lock Screen | Turn display off when inactive | Never |
| Lock Screen | Require password after screen saver begins or display is turned off | Never |

Some models label the display option **Turn display off on power adapter when inactive**. See Apple's [sleep and wake settings](https://support.apple.com/en-us/guide/mac-help/mchle41a6ccd/mac) and [Lock Screen settings](https://support.apple.com/en-us/guide/mac-help/mh11784/mac).

### Keep GPU measurements comparable

Use compatible toolchains and dependencies across nodes. During performance measurements, avoid unrelated GPU workloads and concurrent jobs submitted through other management services. Separate services have separate queues, so their GPU work can overlap on the same Mac.

### Manage task outputs and disk usage

For batch runs with Harbor, use `environment.delete: true` to delete each trial Sandbox after completion. Harbor job outputs, including results and trajectories under `jobs_dir`, are retained separately; manage their retention independently. See [Harbor configuration](harbor.md).

Check for residual instances and delete them through Metal Sandbox. Keep Harbor outputs outside the SMB instance directories so deleting an instance does not mix with job retention. See [deletion and cleanup](native_operations.md#deletion-and-residual-cleanup).
