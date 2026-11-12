"""Read the shared release identity without requiring Swift or a built binary."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent


def literal(name):
    source = (ROOT / "sources/sandbox_core/version.swift").read_text()
    matches = re.findall(r'public static let ' + name + r' = "([^"\n]+)"', source)
    if len(matches) != 1:
        raise ValueError("missing or ambiguous release literal: " + name)
    return matches[0]


def release_version():
    value = literal("current")
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(?:(?:alpha|beta)\.[1-9][0-9]*|rc(?:\.[1-9][0-9]*)?))?", value):
        raise ValueError("expected numeric SemVer with optional alpha.N, beta.N, rc, or rc.N prerelease")
    return value


def bundle_build():
    value = literal("bundleBuild")
    if not re.fullmatch(r"[1-9][0-9]*", value):
        raise ValueError("bundle build must be a positive integer")
    return value
