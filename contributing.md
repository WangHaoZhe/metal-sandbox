# Development and release

## Conventions

- Read [AGENTS.md](AGENTS.md) and the [security boundary](docs/security.md) first. Do not bypass failures with bare-host execution or relaxed system permissions, and do not automatically confirm GPU recovery.
- Use lowercase_snake_case for manually maintained paths, preserving names required by SwiftPM, macOS, and other tools.
- The frontend is a separate Swift package using only the public CLI; it does not access backend modules, sockets, credentials, or containers.
- README and docs are for users. Test reports belong in .verification/ and are excluded from documentation and release packages.

## Directory responsibilities

| Directory | Contents |
|---|---|
| sources | Backend, CLI, runtime, and evaluation code |
| frontend | Independent native frontend and tests |
| scripts | Dependency installation, build, packaging, and checks |
| examples | Two-instance Metal scheduling demo and public packages under examples/tasks |
| tests/sandbox_core_tests | Swift unit tests and native test entry point |
| tests/integration | CLI, runtime, and harness integration regressions and helpers |
| docs | User guides, interfaces, architecture, and security documentation |

## Add an Agent harness

- Claude Code and Codex use native adapters in sources/sandbox_runtime; mini-swe-agent uses the managed shell environment in examples/harnesses/mini_swe_agent_metal.py. Preparation scripts for all three are in examples/harnesses/.
- Implement AgentHarness from sources/sandbox_runtime/agent_harness.swift and register it in AgentHarnesses.adapters. Keep generated configuration, hook input/output, shell selection, and session-log discovery in the adapter; see claude_harness.swift and codex_harness.swift.
- sandbox-shell --hook ID provides the fixed hook entry point. Scripts select an adapter with METAL_SANDBOX_HARNESS=ID. After converting tool input to its original shell command, use the shared policy and private execution bridge without changing cwd, IO, cancellation, or lease semantics. A new harness must provide a real tool channel into the bridge; registration alone does not establish scheduled child commands.
- Implement HarnessConversationDecoder in frontend/sources/frontend_core/trajectory.swift and register it with AgentConversation.makeDecoder. The trajectory API identifies formats with harness; views consume common ConversationEntry objects without parsing provider JSON.
- Installation, versions, models, credentials, and prompts stay in task setup.sh or instance environments, not the manager. Cover hook round trips, unknown providers, log-path isolation, incremental decoding, and real parallel/serial behavior. Do not change the scheduler to recognize model brands.

## Local checks

Requirements: Apple Silicon, Swift 6.0+, and Python 3.9+. Python checks use the standard library; SwiftPM uses the locked ZIPFoundation dependency.

Cluster checks start real local managers and App Sandbox Hosts with separate coordination directories and shared workspaces, using real public CLI relay processes. They cover placement, same-pool handoff, cross-pool rejection, scheduling disabled on either side, receiver pool limits, queued reselection, harness children, cancellation, and duplicate submission. Environment checks cover shared PATH, ordinary user variables, source-private paths, and direct compiler arguments. Different machines' actual tool paths still require two-Mac checks; local checks do not establish cross-machine SSH/SMB acceptance:

```sh
swift build
BIN="$(swift build --show-bin-path)"
"$BIN/sandbox-selftest" --cluster "$BIN" "$PWD/.verification/cluster_validation"
"$BIN/sandbox-selftest" --cluster-capacity "$BIN" "$PWD/.verification/capacity_validation"
"$BIN/sandbox-selftest" --cluster-index "$BIN" "$PWD/.verification/ci"
```

Output directories must not already exist. Configure real two-Mac checks using docs/cluster.md and inspect signatures, shared-directory identity, executable permissions, and queries/cancellation of the same task after reconnecting.

Read-only retry regression stops a real manager's listener and restores it before the tenth retry. It checks all backoff intervals, querying the original instance after recovery, and single submission of mutations. It takes approximately nine minutes without simulated transport:

```sh
"$BIN/sandbox-selftest" --cluster-read-retry "$BIN" "$PWD/.verification/read_retry"
```

MINI_METAL_TEST_BUNDLE adds a real uploaded mini runtime to cluster checks, verifying that LiteLLM caches and private Python packages remain on the owner, ordinary tools migrate, and explicit private dependencies stay local:

```sh
MINI_METAL_TEST_BUNDLE=/path/to/mini_swe_agent_darwin_arm64.tar.gz \
  "$BIN/sandbox-selftest" --cluster "$BIN" "$PWD/.verification/hc"
```

Cleanup/recovery regression uses real App Sandbox execution, background children, and termination. Recovery checks that Agent processes and shell helpers stay alive, queued commands resume, and cancellation remains effective:

```sh
"$BIN/sandbox-selftest" --native-cleanup "$BIN" "$PWD/.verification/native_cleanup"
"$BIN/sandbox-selftest" --native-recovery "$BIN" "$PWD/.verification/native_recovery"
"$BIN/sandbox-selftest" --native-shell-disconnect "$BIN" "$PWD/.verification/native_shell_disconnect"
```

```sh
python3 -B scripts/check_release.py
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
"$BIN/sandbox-selftest"
python3 -B tests/integration/task_setup_tests.py
python3 -B scripts/check_release.py --bin-dir "$BIN"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
swift build --package-path frontend -c release --sdk "$SDK" \
  -Xlinker -platform_version -Xlinker macos -Xlinker 13.0 -Xlinker "$SDK_VERSION"
FRONTEND_BIN="$(swift build --package-path frontend -c release --show-bin-path)"
```

Frontend state and CLI integration checks use a real management service. Shut down your normal service and start a test service with separate state:

```sh
mkdir -p .verification/frontend
export METAL_SANDBOX_TEST_BIN="$BIN"
export METAL_SANDBOX_TEST_STATE_DIR="$PWD/.verification/frontend/state"
"$BIN/metal-sandboxd" --allow-trusted-code --bin-dir "$BIN" \
  --state-dir "$METAL_SANDBOX_TEST_STATE_DIR"
```

Keep it running and use another terminal with the same environment variables:

```sh
swift test --package-path frontend -c release --sdk "$SDK"
"$FRONTEND_BIN/frontend-selftest" --live "$BIN" \
  --state-dir "$METAL_SANDBOX_TEST_STATE_DIR" --output .verification/frontend/cli_results
"$BIN/sandboxctl" --state-dir "$METAL_SANDBOX_TEST_STATE_DIR" sandbox shutdown
```

Restore the normal service afterward. macOS 26+ glass controls require both SDK and linker metadata to specify that SDK version. Do not use the minimum deployment version as the SDK version; this produces compatibility appearance. The packaging script supplies these parameters, and verify_app.py checks SDK and minimum runtime versions.

The real CLI, App Sandbox, and frontend history reader in tests/integration/execution_regressions.swift cover launch failures, terminal quoting/comments, and final task states after more than 100 records. After the builds above, stop the normal service and start an empty dedicated test service with --state-dir:

```sh
mkdir -p .verification/execution_regressions
swiftc -parse-as-library -I "$FRONTEND_BIN" \
  tests/integration/execution_regressions.swift frontend/sources/frontend_app/execution_history.swift \
  "$FRONTEND_BIN/FrontendCore.o" -o .verification/execution_regressions/check
.verification/execution_regressions/check "$BIN" /absolute/test_state .verification/execution_regressions/results
```

The test rejects nonempty instance lists and deletes only its own instances. Stop the test service afterward and restore the normal service.

Automatic-verification integration uses real App Sandbox, compilers, and processes without model access. Shut down the same user's manager before running:

```sh
python3 tests/integration/automatic_verification_acceptance.py --bin-dir "$BIN" --output .verification/automatic_verification_test
```

The output directory must not exist. The test stops its own service; restart your normal service afterward.

Run the complete native regression in a dedicated idle environment with a new output directory:

```sh
./scripts/test.sh .verification/new_validation
```

It starts a test manager, compiles and runs trusted programs on the real GPU, and tests timeout/crash behavior. **Do not run it alongside a normal service under the same UID.** Preserve leases and recovery evidence on failure rather than cleaning up unknown processes or confirming GPU drain automatically.

Claude integration regressions download a separate CLI, use simulated model responses, and neither read host account configuration nor call a real model:

```sh
python3 -B tests/integration/claude_install_acceptance.py --bin-dir "$BIN" --output .verification/claude_install --allow-download
python3 -B tests/integration/claude_scheduling_acceptance.py --bin-dir "$BIN" --output .verification/claude_scheduling
```

Stop the development service normally first and restart it afterward. See evaluation-runner --help for fixed Agent/verifier checks.

Loopback-forwarding tests use real TCP services, public CLI, and App Sandbox. Stop your normal service first and use a short output path. --ssh starts a normal-user OpenSSH process bound only to a high loopback port, accepting only a temporary test key without changing system SSH settings:

```sh
python3 tests/integration/loopback_forward_acceptance.py --bin-dir "$BIN" --output .verification/forward_check --ssh
```

If the OS prevents normal-user sshd, preserve logs and continue on a node providing real SSH.

## Build and package

For each version bump, review all commits from the previous release tag to the current release branch. Summarize their features, fixes, and usage changes in the new changelog.md section, grouping related commits by topic and covering only changes present on the release branch.

Update the version source, build number, version tests, and changelog together. Build packages afterward and check their versions against the release notes.

The single version source is sources/sandbox_core/version.swift. Frontend builds require macOS SDK 26+. Full App packaging requires Xcode 27+ with first launch completed to compile Apple's layered icon. package_app.py calls build_app_icon.py automatically.

```sh
# The output directory must be new.
python3 -B scripts/package_app.py --output /path/to/new_app_output
python3 -B scripts/package_release.py --output /path/to/new_source_output
python3 -B scripts/verify_app.py '/Applications/Metal Sandbox.app' --report /path/to/app_check.json
```

The App contains all project runtimes. DMG and local source archives include SHA-256 files; source archives exclude build caches, runtime state, credentials, user containers, and .verification/. Signatures are local ad-hoc, without Developer ID notarization. Distribution requires owner approval of licensing terms; source visibility alone is not an open-source license.

Stop your normal management service before packaging. package_app.py starts its own test service, runs frontend state and real CLI integration checks, then stops it. Logs and state are saved under .verification/app_validation_*. Packaging stops on failure.

Before release, complete static checks, regressions, and actual use of the installed App. Bundle existence or a valid signature does not establish GUI acceptance, all-hardware compatibility, or security guarantees. Put final deliverables under dist/ without mixing in test packages.

Generate `docs/architecture.png` with `swift scripts/render_architecture.swift --language en`; add `--runtime-flow` for `docs/runtime_flow.png`. Use `--language zh` to generate the corresponding figures in `docs/zh/`. Both languages share the same layout and colors. Keep figures and text in sync when architecture or flow changes.

## Publish a GitLab Release

Choose the release commit and confirm that the packages and release notes match its version. Push that commit to the intended release branch before publishing. If the local branch contains later commits, push the selected commit explicitly.

- Use `v<version>` for the tag and `MetalSandbox <version>` for the release title.
- Copy the selected version's entry from `changelog.md`, retaining the `# Release notes` heading, version heading, topic headings, and wording. Pass it directly through `--notes`. Documentation links should point to files at the release tag.
- Upload `dist/metal_sandbox_<version>_arm64.dmg` and its matching `.sha256` file with `--use-package-registry`. GitLab provides the source archives automatically.

Replace the placeholders below with the version, commit, branch, repository URL, and release notes. Verify the DMG checksum before running the publishing commands:

```sh
(cd dist && shasum -a 256 -c "metal_sandbox_<version>_arm64.sha256")
```

```sh
git push --no-follow-tags origin "<release_commit>:refs/heads/<release_branch>"

glab release create "v<version>" \
  "dist/metal_sandbox_<version>_arm64.dmg" \
  "dist/metal_sandbox_<version>_arm64.sha256" \
  --repo "<repository_url>" \
  --ref "<release_commit>" \
  --name "MetalSandbox <version>" \
  --use-package-registry \
  --notes '# Release notes

## <version>

### <topic>

- <release notes from changelog.md>'
```

After publishing, verify the release tag's commit, title, description, and both uploaded attachments on GitLab.
