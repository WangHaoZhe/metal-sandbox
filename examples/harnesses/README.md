# Harness Preparation Scripts

Copy the selected script to `agent/setup.sh` in your task package and provide `instruction.md` in the same directory. Run it through the App's Preparation tab or the public CLI with `exec --session`. All three scripts install tools inside the instance and execute tool commands through the Metal Sandbox management service.

| Harness | Preparation script | Configuration in the same directory | Instance environment variables |
|---|---|---|---|
| Claude Code | [claude_setup.sh](claude_setup.sh) | No additional configuration | `ANTHROPIC_API_KEY`; optional `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL` |
| Codex | [codex_setup.sh](codex_setup.sh) | [codex_config.toml](codex_config.toml) | `OPENAI_API_KEY` |
| mini-swe-agent | [mini_swe_agent_setup.sh](mini_swe_agent_setup.sh) | [mini_config.yaml](mini_config.yaml), [mini_swe_agent_metal.py](mini_swe_agent_metal.py) | `MINI_SWE_AGENT_MODEL`, provider API key, local archive path and SHA-256 |

## Claude Code

The script uses Claude Code 2.1.112 and Node 24.19.0. Upload the official Claude npm `.tgz` and the extracted macOS arm64 Node executable to the instance beforehand, and set `CLAUDE_LOCAL_PACKAGE` and `CLAUDE_NODE_BINARY`. If no local files are provided, the script downloads the corresponding pinned versions from their official sources. Sessions are saved in the instance's `~/.claude/` and can be viewed through the App's Trajectory tab.

## Codex

The script uses Codex 0.162.1. Upload the extracted macOS arm64 `codex` and matching `codex-code-mode-host` to the instance beforehand, and set `CODEX_LOCAL_PACKAGE` and `CODEX_LOCAL_CODE_MODE_HOST`. If they are not provided, the script downloads the pinned official version. Set the model and provider URL in `codex_config.toml`. Sessions are saved in the instance's `~/.codex/` and can be viewed through the App's Trajectory tab.

## mini-swe-agent

The script uses mini-swe-agent 2.4.6. Prepare a macOS arm64 `.tar.gz` beforehand: `python/` at the archive root must contain a complete relocatable Python standalone distribution, and `packages/` must contain the installed mini-swe-agent and all its dependencies. Python in an ordinary virtual environment may reference host paths and cannot be used directly as a runtime archive.

On a macOS arm64 control machine, place the complete Python standalone distribution in `/path/to/python_standalone` and prepare the archive with uv:

```sh
mkdir -p mini_runtime/python mini_runtime/packages
cp -R /path/to/python_standalone/. mini_runtime/python/
uv pip install --python "$PWD/mini_runtime/python/bin/python3" \
  --target "$PWD/mini_runtime/packages" 'mini-swe-agent==2.4.6' 'litellm[mcp]==1.106.4'
PYTHONPATH="$PWD/mini_runtime/packages" mini_runtime/python/bin/python3 \
  -c 'import importlib.metadata; print(importlib.metadata.version("mini-swe-agent"))'
tar -czf mini_swe_agent_2.4.6_darwin_arm64.tar.gz -C mini_runtime python packages
shasum -a 256 mini_swe_agent_2.4.6_darwin_arm64.tar.gz
```

After uploading the archive, set `MINI_SWE_AGENT_LOCAL_BUNDLE` to its path inside the instance, `MINI_SWE_AGENT_BUNDLE_SHA256` to its actual SHA-256, and `MINI_SWE_AGENT_MODEL` to `provider/model_name`, and set the provider's API key. Put the model URL and sampling parameters in `mini_config.yaml`, without credentials. Run records are saved in the workspace under `mini_swe_agent_runs/<session>/`, including `trajectory.json`, stdout, stderr, and the exit code. View or export them through the App's Files tab or the CLI.

mini's `MetalEnvironment` calls the shell helper provided by the runtime directly and starts counting the command timeout after scheduling permission is granted. It integrates through a Python environment interface and does not need the PreToolUse hook used by Claude and Codex.

When running through Harbor, Harbor installs and starts all three harnesses; task packages do not need to copy these preparation scripts. See the [Harbor documentation](../../docs/harbor.md) for their installation settings.
