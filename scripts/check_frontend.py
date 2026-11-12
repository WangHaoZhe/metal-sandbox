#!/usr/bin/env python3
"""Guard the CLI-only frontend architecture; not a sandbox/security certification."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent


def check():
    package = (ROOT / "frontend/Package.swift").read_text()
    if ".package(" in package or any(name in package for name in ("SandboxRuntime", "SandboxCore", "SandboxManagement", "EvaluationCore", "linkedFramework")):
        raise ValueError("frontend must remain an independent package without backend dependencies")
    allowed = {"SwiftUI", "Foundation", "Darwin", "AppKit", "FrontendCore", "QuickLookUI", "UniformTypeIdentifiers"}
    for path in (ROOT / "frontend/sources").rglob("*.swift"):
        source = path.read_text()
        imports = set(re.findall(r"^import\s+(\w+)", source, re.MULTILINE))
        if imports - allowed:
            raise ValueError(f"unexpected frontend import in {path}: {imports - allowed}")
        code = "\n".join(line.split("//", 1)[0] for line in source.splitlines())
        if re.search(r"\b(socket|connect|posix_spawn|execv|dlopen|MTLCreateSystemDefaultDevice)\s*\(", code):
            raise ValueError("frontend bypasses CLI: " + str(path))
        if "Process()" in code and path.name != "cli_client.swift":
            raise ValueError("process execution must stay in the CLI adapter: " + str(path))
        if any(value in code for value in ("operator_token", "active-lease.json", "native.sock", "Library/Containers")):
            raise ValueError("frontend must not access backend internals: " + str(path))
    views = (ROOT / "frontend/sources/frontend_app/instance_view.swift").read_text()
    files_view = views.split("struct FilesView: View {", 1)[1].split("struct PreparationView:", 1)[0]
    browser = (ROOT / "frontend/sources/frontend_app/workspace_browser.swift").read_text()
    if "TextEditor(" in files_view or re.search(r'\[\s*"write"|\bwriteText\s*\(', files_view + browser):
        raise ValueError("workspace file browser must remain read-only")
    print("PASS: independent frontend package, allowed imports, CLI-only process boundary")


if __name__ == "__main__":
    check()
