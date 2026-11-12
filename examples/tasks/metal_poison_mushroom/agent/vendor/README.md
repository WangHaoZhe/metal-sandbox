# Preparing Local Claude and Node Installation Files

Versions: Claude Code 2.1.112 and Node 24.19.0, macOS Apple Silicon.

Copy the task package into a writable directory, then run these commands in the `vendor` directory containing this README:

```sh
curl --fail --location --proto '=https' --proto-redir '=https' \
  --output claude.tgz \
  https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-2.1.112.tgz &&
printf '%s  claude.tgz\n' '84379969ea53a0e5fd231a8f77debe4c7cb17dd971f4809d10d33f9aeca5de09' |
  shasum -a 256 --check
```

```sh
curl --fail --location --proto '=https' --proto-redir '=https' \
  --output node.tar.gz \
  https://nodejs.org/dist/v24.19.0/node-v24.19.0-darwin-arm64.tar.gz &&
tar -xzf node.tar.gz &&
cp node-v24.19.0-darwin-arm64/bin/node node &&
printf '%s  node\n' '27db838bb204ef7c21df2931f5656e4c8fb32e6e947f363a402b49714d32b5b1' |
  shasum -a 256 --check
```

After both files pass verification, import the package and set these instance variables:

- `CLAUDE_LOCAL_PACKAGE=vendor/claude.tgz`
- `CLAUDE_NODE_BINARY=vendor/node`

The preparation script installs them into private HOME and uses Node to execute `cli.js` in the official package. Required local files are the npm `.tgz` and the extracted regular Node executable. Rerunning reuses correct versions; deleting the instance removes its internal installation.

If local-file variables are omitted, the script downloads the corresponding pinned official components. Installation files in the task workspace also occupy snapshot space.
