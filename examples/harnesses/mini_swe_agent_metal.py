import os
import subprocess
from typing import Any

from minisweagent.environments.local import LocalEnvironment


class MetalEnvironment(LocalEnvironment):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        if os.environ.get("METAL_SANDBOX_AGENT_SESSION") != "1":
            raise RuntimeError("Mini MetalEnvironment requires a managed agent session")
        self._helper = os.environ["METAL_SANDBOX_SHELL_HELPER"]
        if not os.path.isabs(self._helper) or not os.access(self._helper, os.X_OK):
            raise RuntimeError("Metal Sandbox shell helper is unavailable")
        for key in self.config.env:
            if key in {"HOME", "TMPDIR", "WORKSPACE"} or key.startswith(
                "METAL_SANDBOX_"
            ):
                raise ValueError(f"Reserved runtime environment variable: {key}")

    def _tool_environment(self) -> dict[str, str]:
        environment = os.environ | self.config.env
        runtime = environment.pop("METAL_SANDBOX_MINI_RUNTIME", None)
        if runtime:
            packages = runtime + "/packages"
            if "PYTHONPATH" in environment and "PYTHONPATH" not in self.config.env:
                entries = environment["PYTHONPATH"].split(":")
                environment["PYTHONPATH"] = ":".join(
                    p for p in entries if p != packages
                )
                if not environment["PYTHONPATH"]:
                    environment.pop("PYTHONPATH")
            keys = [
                "UV_INSTALL_DIR",
                "UV_TOOL_BIN_DIR",
                "UV_TOOL_DIR",
                "UV_PYTHON_INSTALL_DIR",
                "UV_CACHE_DIR",
            ]
            if "CUSTOM_TIKTOKEN_CACHE_DIR" not in environment:
                keys.append("TIKTOKEN_CACHE_DIR")
            for key in keys:
                value = environment.get(key, "")
                if key not in self.config.env and (
                    value == runtime or value.startswith(runtime + "/")
                ):
                    environment.pop(key)
        return environment

    def execute(
        self, action: dict, cwd: str = "", *, timeout: int | None = None
    ) -> dict[str, Any]:
        command = action.get("command", "")
        limit = self.config.timeout if timeout is None else timeout
        started_read, started_write = os.pipe()
        try:
            try:
                process = subprocess.Popen(
                    [self._helper, "--notify-start", str(started_write), command],
                    cwd=cwd or self.config.cwd or os.getcwd(),
                    env=self._tool_environment(),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    start_new_session=True,
                    pass_fds=(started_write,),
                )
            finally:
                os.close(started_write)
            # 取得调度许可后才开始计算命令执行时间。
            os.read(started_read, 1)
        finally:
            os.close(started_read)
        timed_out = False
        try:
            stdout, stderr = process.communicate(timeout=limit)
        except subprocess.TimeoutExpired:
            timed_out = True
            process.terminate()
            try:
                stdout, stderr = process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
                raise RuntimeError(
                    "Metal shell helper did not confirm timeout cleanup"
                ) from None
        output = {
            "output": stdout,
            "returncode": -1 if timed_out else process.returncode,
            "exception_info": f"Command timed out after {limit} seconds"
            if timed_out
            else "",
        }
        # 提交标记只从 stdout 读取，避免混入调度提示。
        self._check_finished(output)
        output["output"] += stderr
        if timed_out:
            output["extra"] = {"exception_type": "TimeoutError"}
        return output
