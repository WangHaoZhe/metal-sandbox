# Node Cluster

All Sandbox operations are submitted to the manager node. The manager calls the public CLI on worker nodes through SSH; candidate programs are started by the App Sandbox Host on the execution node.

## Node Preparation

- Install the same version of Metal Sandbox and the compilers, SDKs, and dependencies required by the task on every Mac. See [Installation and best practices](installation.md) for setup steps.
- Enable macOS Remote Login on worker nodes. Configure SSH with the frontend's Add Node wizard or set up noninteractive SSH authentication yourself.
- Each node runs its own `metal-sandboxd` as a non-root user. The service does not install system accounts or background startup items automatically.
- Files for ordinary instances are stored on their owner node. With dynamic scheduling enabled, each instance's data remains on its owner node's local disk, and execution nodes in the same pool access it directly through SMB. Directories must support reading, writing, executable files, file permissions, and security scope.

macOS File Sharing can provide the SMB shared directories. Mount them beforehand; nodes do not mount them or change File Sharing settings automatically. Check permissions and execution support for network volumes on the target machines.

Configure the same `sharedRoot` on all nodes, for example `/Users/Shared/metal_cluster_nodes`. Each node's local data is under `sharedRoot/local_node_name/`. Export this subdirectory as an SMB share; other nodes in the same pool mount it at the same absolute path. Do not export the entire `sharedRoot`, which contains other nodes' mount points.

For example, an instance on `node_a` uses:

```text
/Users/Shared/metal_cluster_nodes/node_a/sbx-instance_id/workspace
/Users/Shared/metal_cluster_nodes/node_a/sbx-instance_id/home
```

These paths refer to local files on `node_a` and to an SMB mount of `node_a` on other execution nodes. Instance creation checks that the owner node's storage directory is on a local filesystem to avoid continuing to concentrate data writes on a remote node. Migration changes only the execution location; it does not move files. File traffic travels directly between the execution node and the data owner node.

## Configuration

In Overview, click Add Node next to Create Sandbox:

1. Enter the node name, host address, and login username. Advanced options include the SSH port, remote CLI path, state directory, and maximum concurrent instances.
2. Check the host fingerprint, enter the worker node's login password, and click Confirm Fingerprint and Connect. The wizard installs a public key and checks key authentication and the remote management service. Leave the password empty if dedicated key authentication is already configured.
3. Confirm the node environment and save. If the local machine has no active instances or unfinished commands, restart the management service immediately; otherwise, the configuration takes effect at the next service startup.

The password is passed through a process pipe, used only for this authentication, and is not saved in configuration or operation records. The dedicated SSH key is stored locally at `~/.ssh/metal_sandbox_cluster`, and host public keys at `~/.ssh/metal_sandbox_host_*`. Remote public-key authorization is written to that account's `~/.ssh/authorized_keys`. Connections are rejected if a saved host key changes; verify the change manually.

Overview shows the local machine's actual running role. Below the local environment, it displays other nodes' model, Metal device, memory, operating system, service version, thermal state, and load, updated by global automatic refresh. When a connection fails, the last environment information remains, and a red Node Error replaces the active-instance and unfinished-command counts. Hover over or click Node Error to open a native detail popover immediately; select the error text or click Copy. The popover stays open while the pointer is over the text or popover and closes when it leaves both. Click outside or press Esc to close it as well. Current status returns automatically when the connection recovers.

Local and worker environment panels show environment information on the left and CPU/GPU utilization and used/total Mem and Disk on the right. CPU is the system-wide utilization between two samples; GPU comes from IOKit driver statistics for the corresponding Metal device. Both range from 0–100%. Mem follows Activity Monitor's Memory Used definition. Disk reads volume-capacity statistics for the user data volume without scanning files, in decimal GB. Samples are at least one second apart and are read during global refresh. A disconnected node, an unavailable device statistic, or an outdated node service displays “—”.

Select the local role in Connection Settings → Node Cluster:

- **Standalone**: use only the local machine.
- **Manager node**: enter the local node name and open the connection wizard with Add Worker Node; existing nodes can be edited directly.
- **Worker node**: enter the local node name and cluster working directory.

Each node's Maximum Concurrent Instances limits active Sandboxes. The default is 32; larger nonnegative integers are supported. Stopping an instance releases its slot; setting the limit to 0 prevents new instances. The manager can also set an allocation limit for each worker. An empty value follows the worker's own setting; when both are set, the smaller value applies.

## Scheduling Pools

In the manager's connection settings, enter a Scheduling Pool for the local machine and each worker. Nodes with the same name form a pool, and each node belongs to one pool. An empty value uses `default`. Pool names are case-sensitive, can contain Chinese characters and spaces, and have a maximum length of 64 characters. Pools are configured by name and are not grouped automatically by machine model.

- Assign four M3 Max machines to `M3 Max` and four M2 Pro machines to `M2 Pro`; serial commands are scheduled only within their respective four-node groups.
- Turning off Allow Cross-Node Scheduling on a node prevents both outgoing and incoming command migration. The node can still create instances and execute local commands.
- Instances must also enable Allow Dynamic Scheduling of Serial Commands. Cross-node scheduling requires both the node and instance settings to allow it.
- A new Sandbox can select a pool for automatic allocation by load within that pool. All Scheduling Pools keeps cluster-wide allocation. Nodes with cross-node scheduling disabled can still belong to a pool used for instance creation.
- Workers can disable cross-node scheduling in their own connection settings or restrict incoming work with Allowed Scheduling Pools. Leaving it empty adds no restriction. The manager cannot override a worker's local restrictions.

The manager uses `schedulingPool` for its local membership and `nodes[].schedulingPool` for each worker. `crossNodeSchedulingEnabled: false` disables scheduling in both directions for the corresponding node; omission allows it. Save and Apply activates pool configuration with the other service settings. All nodes should run the same service version with scheduling-pool support.

All pools use the configured cluster working directory, and instance records retain the data owner node. A pool limits execution nodes without changing the workspace location or instance ID. Initial selection, reselection after queuing, and execution-permit requests on the receiving node all enforce pool restrictions. Commands that have already started continue until their original results return.

The cluster working directory can be empty. To enable dynamic scheduling, enter the same absolute path on all nodes and configure mounts for other nodes' subdirectories within the pool. Load Configuration imports existing settings into the form. Save As chooses a destination, defaulting to `~/Library/Application Support/MetalSandboxUI/cluster.json`.

Save and Apply restarts an idle service to load the configuration. If active instances or unfinished commands exist, it only saves the configuration and displays Not Applied. Stop the instances, wait for commands to finish, and click Apply Configuration. Saving settings unrelated to service configuration, such as the refresh interval, does not restart the service. Workers must also select Worker Node and apply it in their local connection settings; the default data directory is sufficient.

The manager's `cluster.json`:

```json
{
  "localNodeID": "manager",
  "maxConcurrentInstances": 4,
  "schedulingPool": "M3 Max",
  "crossNodeSchedulingEnabled": false,
  "sharedRoot": "/Volumes/metal_shared",
  "nodes": [
    {
      "id": "worker",
      "maxConcurrentInstances": 8,
      "schedulingPool": "M2 Pro",
      "sshDestination": "worker_user@worker.local",
      "cliPath": "/Applications/Metal Sandbox.app/Contents/Helpers/sandboxctl",
      "stateDirectory": "/Users/worker_user/Library/Application Support/MetalSandbox/native"
    }
  ]
}
```

`sharedRoot` is optional; without it, instances can be allocated but dynamic scheduling cannot be enabled. JSON does not store SSH passwords or private keys. Nodes added through the wizard also save `sshPort`, `identityFile`, `knownHostsFile`, and `hostKeyAlias` to specify the port, SSH files, and confirmed host-key name. The same host key is verified after an IP change, and a changed key causes rejection. Manual configurations can omit these fields and use system SSH settings.

After selecting Worker Node and saving in the frontend, you can also start the service from a terminal with its configuration:

```sh
BIN="/Applications/Metal Sandbox.app/Contents/Helpers"
"$BIN/metal-sandboxd" --allow-trusted-code --bin-dir "$BIN" \
  --cluster-config "$HOME/Library/Application Support/MetalSandboxUI/cluster.json"
```

Start the service on the manager:

```sh
BIN="/Applications/Metal Sandbox.app/Contents/Helpers"
"$BIN/metal-sandboxd" --allow-trusted-code --bin-dir "$BIN" \
  --cluster-config /absolute/path/cluster.json
```

The frontend loads the selected configuration file automatically. Save and Apply activates changes to the same service's node roles, addresses, and capacity. Before changing the CLI or state directory, wait for tasks to finish and shut down the original service.

## Creation and Execution

```sh
"$BIN/sandboxctl" sandbox cluster
"$BIN/sandboxctl" sandbox create --count 4
"$BIN/sandboxctl" sandbox create --count 1 --dynamic-scheduling
"$BIN/sandboxctl" sandbox create --count 1 --node worker --dynamic-scheduling
"$BIN/sandboxctl" sandbox create --count 4 --pool 'M2 Pro' --dynamic-scheduling
"$BIN/sandboxctl" sandbox list -h
```

Automatic allocation prefers available nodes with fewer active instances; batch creation includes reserved instances in its counts. Stopped instances do not count as active load. The frontend's creation window can select a scheduling pool, automatic allocation, or a specific node, and enable Allow Dynamic Scheduling of Serial Commands. When both pool and node are specified, the node must belong to that pool. An unknown pool is an error. Instance information shows the owner node; Overview shows each node's pool, cross-node scheduling status, and load.

Creation, restarting an existing instance, and cloning from a snapshot are all subject to capacity limits; the CLI returns exit code 75 when full. A creation batch exceeding current remaining capacity is rejected. Standalone services can also set the limit with `metal-sandboxd --max-instances N`. Serial execution slots and instance capacity are independent; a temporary execution Host for dynamic scheduling does not create a new logical Sandbox instance.

Harbor's Metal Sandbox integration handles exit code 75: excess trials wait for capacity on the client. Waiting does not consume the environment-preparation budget, and cancelling the wait does not create an instance. There is no need to lower `n_concurrent_trials` manually to the cluster capacity; later trials start after instances finish and stop. `delete: false` retains stopped instances without occupying capacity. During separate verification in multi-step jobs, the original agent instance is stopped temporarily to release capacity, then restarted after verification with its workspace and HOME preserved.

Use the existing execution, file, preparation, trajectory, verification, snapshot, and stop commands through the manager. The manager saves the node ownership of instance and execution IDs.

Each service startup clears the command index `cluster/executions.json` while preserving the instance index, command results, and trajectory files. Execution IDs returned by new commands and historical queries are written into the index again. After a restart, to query a remote command by an old execution ID alone, first query the instance's execution history to rebuild the command's node ownership.

Read-only status, instance, execution, trajectory, and file queries retry SSH communication failures up to ten times, at intervals of 0.5, 1, 2, 4, 8, 16, 32, 64, 128, and 256 seconds: eleven attempts including the initial request. The intervals total 511.5 seconds, excluding connection time. The CLI waits up to 1,920 seconds for these query responses. Mutating operations such as creation, command submission, and stopping remain single submissions.

## Loopback Service Forwarding

The machine running Harbor can make its local loopback service available to instances on worker nodes. Metal Sandbox maintains a separate connection using the existing node SSH address, key, and host-verification configuration. The server must allow remote port forwarding and use `GatewayPorts no` or `clientspecified` to keep the binding on loopback.

```sh
LEASE=$(uuidgen)
sandboxctl sandbox forward "$INSTANCE_ID" --port "$PROXY_PORT" --lease "$LEASE"
sandboxctl sandbox forward-status "$INSTANCE_ID" "$LEASE"
sandboxctl sandbox forward-close "$INSTANCE_ID" "$LEASE"
```

`INSTANCE_ID` must be a full ID, and the service port must already be listening on the caller's management-service host. The instance accesses the service at the same `127.0.0.1:PROXY_PORT`, without needing permission to listen on a network port. Each port has one lease; port conflicts and connection failures are reported explicitly.

Renew leases within 60 seconds. Expiration or management-service shutdown releases the SSH forward. If the forwarding process to the owner node exits unexpectedly, the manager rebuilds it in the background without changing the lease ID. Failed rebuilds are retried every ten seconds. During rebuilding, `readyNodeIDs` in `forward-status` excludes the owner node, and `nodeErrors` explains why. Stopping and restarting an instance preserves forwarding dependencies; deleting an instance removes its leases.

## Dynamic Scheduling

- Each node retains one serial execution slot; parallel tasks continue on the instance's owner node.
- When an instance enables dynamic scheduling, serial tasks that have not started can move to an idle node. The target reserves its execution slot first and starts the process only after the source confirms the transfer.
- Nodes are rechecked throughout waiting. An idle source is preferred; another node becoming idle earlier can be selected again. Before switching, revoke the previous target's start permission and confirm cleanup. If the previous target has started, continue waiting for its result. If a node is unreachable and execution state cannot be confirmed, retain the task identity and continue handling it after communication recovers.
- Quarantined nodes receive no new execution permits, and subsequent commands from existing instances remain waiting. Once an administrator confirms recovery, the original queue resumes and connected agent sessions can remain. Failed commands are not replayed automatically.
- Workspace and HOME use shared paths. TMPDIR and execution logs belong to the execution node. stdout, stderr, and the exit result return to the original task.
- Cross-node tasks use the execution node's own toolchain. Default PATH tool directories and values such as CC, CXX, SDKROOT, and DEVELOPER_DIR are resolved on the target. Executable paths for directly invoked registered compilers, Metal tools, CMake, and Ninja are also resolved there. Ordinary user environment variables, custom shared PATH entries, and their order are preserved; shell script text is not rewritten.
- A command remains on the source node if its arguments or environment variables explicitly reference a source-private directory. Source-private PATH entries follow the same rule. Private files, processes, and local services read implicitly inside a script cannot be identified from command text alone; disable dynamic scheduling for instances depending on them.
- The manager transfers commands only to nodes supporting toolchain environment conversion. Update all node services together when updating the cluster.
- Scheduled Claude Bash subtasks and tasks submitted through the public CLI use the same transfer mechanism. Subtasks outside the shared workspace remain on the source node.
- Instances depending on a loopback service carry the forwarding lease identity with each task. Forwarding on the target is prepared in the background, and the target becomes eligible only when ready. Nodes with port conflicts or failed forwarding are temporarily excluded from that task's selection. Unknown or expired leases are not treated as usable connections.
- Running processes and Metal resources remain on the execution node and cannot migrate. Commands depending on local GUI, processes, sockets, unshared files, or specific absolute paths must run on their original node; disable dynamic scheduling for such tasks.
- Connection interruption preserves task identity. Reconnection queries the original task without starting a duplicate. Cancellation reaches the execution node, and the source waits for cleanup results. An execution-node restart or uncertain cleanup retains the manual inspection requirement.

A shared directory does not guarantee application correctness when multiple commands modify the same file. Tasks must coordinate file writes themselves; node installations and shared paths must remain consistent.
