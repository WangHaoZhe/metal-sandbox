#!/usr/bin/env python3
"""Offline task setup checks with a fake harness; no model/candidate execution."""
from pathlib import Path
import subprocess
import tempfile
import shutil


def test_setup_prompt():
    project = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="task_prompt_") as tmp:
        root = Path(tmp)
        home = root / "private home"
        tools = home / ".local/bin"
        tools.mkdir(parents=True)
        scratch = root / "tmp"
        scratch.mkdir()
        claude = tools / "claude"
        claude.write_text('''#!/bin/sh
if [ "$1" = --version ]; then printf '2.1.209 (fixture)\\n'; exit 0; fi
/bin/cat > "$HOME/captured_prompt"
printf '%s' "$METAL_SANDBOX_HARNESS" > "$HOME/captured_harness"
printf '%s\\0' "$@" > "$HOME/captured_args"
exit "$FIXTURE_EXIT_CODE"
''')
        claude.chmod(0o700)
        # A regression must never fall back to downloading a real harness.
        curl = tools / "curl"
        curl.write_text("#!/bin/sh\necho 'Unexpected download in offline test' >&2\nexit 99\n")
        curl.chmod(0o700)
        settings = root / "settings.json"
        settings.write_text("{}")
        env = {"PATH": str(tools) + ":/usr/bin:/bin", "HOME": str(home),
               "TMPDIR": str(scratch) + "/", "LANG": "en_US.UTF-8",
               "ANTHROPIC_API_KEY": "offline-fixture-not-a-real-key",
               "ANTHROPIC_BASE_URL": "https://fixture.invalid", "ANTHROPIC_MODEL": "fixture",
               "METAL_SANDBOX_SHELL_HELPER": str(tools / "sandbox-shell"),
               "METAL_SANDBOX_CLAUDE_SETTINGS": str(settings)}
        prompt = root / "instruction.md"
        captured = home / "captured_prompt"
        edge = "\n--starts-with-option\n中文 'quote' \"quote\" `touch must_not_run` $(touch must_not_run)\n\n".encode()
        for name in ("metal_bloom", "metal_poison_mushroom"):
            task = project / "examples/tasks" / name / "agent"
            for contents, exit_code in (((task / "instruction.md").read_bytes(), 0), (edge, 7)):
                prompt.write_bytes(contents)
                env["FIXTURE_EXIT_CODE"] = str(exit_code)
                run = subprocess.run(["/bin/sh", str(task / "setup.sh")], cwd=root, env=env,
                                     stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
                assert run.returncode == exit_code, (name, run.stderr)
                assert captured.read_bytes() == contents, name + ": prompt must be exact instruction bytes"
                assert (home / "captured_harness").read_text() == "claude", "setup selects its harness adapter"
                args = (home / "captured_args").read_bytes().split(b"\0")[:-1]
                assert args[-4:] == [b"--print", b"--output-format", b"stream-json", b"--verbose"], args
                assert not (root / "must_not_run").exists(), "prompt must not be evaluated as shell code"
            captured.unlink()
            prompt.write_bytes(b"")
            run = subprocess.run(["/bin/sh", str(task / "setup.sh")], cwd=root, env=env,
                                 stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
            assert run.returncode == 2 and not captured.exists(), "empty instruction must not start a rollout"
            prompt.write_bytes(b"Installation-only fixture\n")
            run = subprocess.run(["/bin/sh", str(task / "setup.sh")], cwd=root,
                                 env={**env, "ANTHROPIC_API_KEY": ""},
                                 stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
            assert run.returncode == 2 and b"No Agent has started." in run.stderr and not captured.exists(), "no API key must stop after installation"
    print("PASS setup prompt: both tasks use exact instruction stdin, no appended prompt, literal special characters, empty-file rejection and exit-code propagation")


def test_setup_local_package():
    project = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="task_local_install_") as tmp:
        root = Path(tmp)
        source = root / "fake_claude.c"
        source.write_text(r'''#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--version")) { puts(VERSION " (fixture)"); return 0; }
    const char *path = getenv("FIXTURE_PROMPT");
    if (!path) return 91;
    FILE *out = fopen(path, "wb"); if (!out) return 92;
    int c; while ((c = getchar()) != EOF) fputc(c, out); fclose(out);
    puts("{\"type\":\"result\",\"result\":\"offline fixture\"}");
    return 0;
}
''')
        packages = {}
        for version in ("2.1.209", "2.1.208"):
            binary = root / ("claude-" + version)
            subprocess.run(["/usr/bin/clang", "-arch", "arm64", '-DVERSION="' + version + '"',
                            str(source), "-o", str(binary)], check=True, capture_output=True)
            packages[version] = binary
        tools = root / "tools"
        tools.mkdir()
        installer = tools / "official_install_fixture.sh"
        installer.write_text('''#!/bin/sh
set -eu
printf '%s' "$1" > "$HOME/installer_version"
mkdir -p "$HOME/.local/bin"
cp "$FIXTURE_PACKAGE" "$HOME/.local/bin/claude"
chmod 700 "$HOME/.local/bin/claude"
''')
        curl = tools / "curl"
        curl.write_text('''#!/bin/sh
set -eu
touch "$HOME/curl_called"
test "${FIXTURE_ALLOW_DOWNLOAD:-0}" = 1 || exit 99
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then cp "$FIXTURE_INSTALLER" "$2"; exit 0; fi
    shift
done
exit 98
''')
        curl.chmod(0o700)

        for name in ("metal_bloom", "metal_poison_mushroom"):
            script = project / "examples/tasks" / name / "agent/setup.sh"
            def fixture(case):
                work = root / name / case
                home = work / "private home"
                scratch = work / "tmp"
                home.mkdir(parents=True); scratch.mkdir()
                (work / "instruction.md").write_text("Exact offline task\n")
                env = {"HOME":str(home), "TMPDIR":str(scratch) + "/", "LANG":"en_US.UTF-8",
                       "PATH":str(tools) + ":/usr/bin:/bin", "ANTHROPIC_API_KEY":"",
                       "METAL_SANDBOX_SHELL_HELPER":str(tools / "sandbox-shell"),
                       "METAL_SANDBOX_CLAUDE_SETTINGS":str(work / "bridge.json"),
                       "FIXTURE_INSTALLER":str(installer), "FIXTURE_PACKAGE":str(packages["2.1.209"]),
                       "FIXTURE_PROMPT":str(home / "captured_prompt")}
                return work, home, env
            def run(work, env):
                return subprocess.run(["/bin/sh", str(script)], cwd=work, env=env,
                                      stdin=subprocess.DEVNULL, capture_output=True, timeout=15)

            for absolute in (False, True):
                work, home, env = fixture("absolute" if absolute else "relative")
                package = work / "vendor" / "local claude"
                package.parent.mkdir(); shutil.copyfile(packages["2.1.209"], package); package.chmod(0o600)
                original = package.read_bytes()
                env["CLAUDE_LOCAL_PACKAGE"] = str(package if absolute else package.relative_to(work))
                result = run(work, env)
                installed = home / ".local/bin/claude"
                assert result.returncode == 2 and b"No Agent has started." in result.stderr, (name, result.stderr)
                assert installed.read_bytes() == original and package.read_bytes() == original
                assert package.stat().st_mode & 0o777 == 0o600 and installed.stat().st_mode & 0o777 == 0o700
                assert not (home / "curl_called").exists(), "local installation must not call the downloader"
                assert not list(installed.parent.glob(".claude_install.*")), "staging cleanup"
                # Reuse the correct installed version, even if the source is no longer present.
                env["CLAUDE_LOCAL_PACKAGE"] = "missing-after-install"
                env["ANTHROPIC_API_KEY"] = "offline-fixture-not-a-key"
                result = run(work, env)
                assert result.returncode == 0, result.stderr
                assert (home / "captured_prompt").read_bytes() == (work / "instruction.md").read_bytes()
                assert not (home / "curl_called").exists()

            for invalid in ("missing", "directory", "install_script", "wrong_version"):
                work, home, env = fixture(invalid)
                installed = home / ".local/bin/claude"
                installed.parent.mkdir(parents=True)
                shutil.copy2(packages["2.1.208"], installed)
                previous = installed.read_bytes()
                package = work / "package"
                if invalid == "directory": package.mkdir()
                if invalid == "install_script": package.write_text('#!/bin/sh\ncurl https://must-not-run.invalid\n')
                if invalid == "wrong_version": shutil.copy2(packages["2.1.208"], package)
                env["CLAUDE_LOCAL_PACKAGE"] = str(package)
                result = run(work, env)
                assert result.returncode != 0, invalid
                assert installed.read_bytes() == previous, "failed install preserves existing CLI"
                assert not (home / "curl_called").exists(), "invalid local package must not fall back to download"
                assert not list(installed.parent.glob(".claude_install.*")), "failure cleans staging file"

            for setting in (None, ""):
                work, home, env = fixture("unset" if setting is None else "empty")
                if setting is not None: env["CLAUDE_LOCAL_PACKAGE"] = setting
                env["FIXTURE_ALLOW_DOWNLOAD"] = "1"
                result = run(work, env)
                assert result.returncode == 2 and b"No Agent has started." in result.stderr, result.stderr
                assert (home / "curl_called").exists() and (home / "installer_version").read_text() == "2.1.209"
            work, home, env = fixture("unmanaged")
            env.pop("METAL_SANDBOX_SHELL_HELPER")
            env["CLAUDE_LOCAL_PACKAGE"] = str(packages["2.1.209"])
            assert run(work, env).returncode != 0 and not (home / ".local/bin/claude").exists()
    print("PASS local install: both tasks, native arm64 fixtures, relative/absolute paths with spaces, no source mutation/download, version pinning, reuse, rollback and online fallback")


if __name__ == '__main__':
    test_setup_prompt()
    test_setup_local_package()
