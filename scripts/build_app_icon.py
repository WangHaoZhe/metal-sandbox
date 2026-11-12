#!/usr/bin/env python3
"""Compile and verify the official Icon Composer resource; never flatten it ourselves."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from release_metadata import ROOT

ICON_NAME = "app_icon"
SOURCE = ROOT / "frontend/resources/app_icon.icon"
GROUPS = ("stack_01_back", "stack_02_middle", "stack_03_front")
APPEARANCES = {"light": "NSAppearanceNameAqua", "dark": "NSAppearanceNameDarkAqua"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def source_hashes():
    document = json.loads((SOURCE / "icon.json").read_text())
    require(document["supported-platforms"] == {"squares": ["macOS"]}, "macOS icon platform")
    require([g["name"] for g in document["groups"]] == list(reversed(GROUPS)), "three front-to-back groups")
    expected = {"icon.json", *[f"Assets/{name}.svg" for name in GROUPS]}
    files = {str(p.relative_to(SOURCE)): p for p in SOURCE.rglob("*") if p.is_file() and p.name != ".DS_Store"}
    require(files.keys() == expected, "unexpected or missing Icon Composer source")
    for name in GROUPS:
        # These SVGs contain only opaque silhouettes. Effects belong to Icon Composer.
        svg = ET.parse(files[f"Assets/{name}.svg"]).getroot()
        require(svg.get("viewBox") == "0 0 1024 1024", "1024-point icon canvas")
        require(all(e.tag.rsplit("}", 1)[-1] in {"svg", "path"} for e in svg.iter()), "vector silhouettes only")
        require(all(not ({"filter", "opacity", "fill-opacity", "stroke"} & e.attrib.keys()) for e in svg.iter()),
                "do not bake glass, highlights or shadows into artwork")
    return {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in sorted(files.items())}


def inspect_assets(catalog):
    assets = json.loads(subprocess.check_output(["/usr/bin/assetutil", "--info", str(catalog)], text=True))
    stacks = {a.get("Appearance"): a for a in assets
              if a.get("AssetType") == "IconImageStack" and a.get("Name") == ICON_NAME}
    expected_groups = {f"{ICON_NAME}/{name}" for name in GROUPS}
    summary = {}
    for label, appearance in APPEARANCES.items():
        require(appearance in stacks, f"missing {label} layered icon")
        stack = stacks[appearance]
        require(stack.get("LayerCount") == 4, "icon must retain background + three groups")
        require((stack.get("CanvasWidth"), stack.get("CanvasHeight")) == (1024, 1024), "compiled canvas")
        layers = [a for a in stack["Layers"] if a.get("AssetType") == "IconGroup" and a.get("Appearance") == appearance]
        require({a["Name"] for a in layers} == expected_groups and len(layers) == 3, "three independent glass groups")
        require([a["Name"] for a in layers] == [f"{ICON_NAME}/{name}" for name in GROUPS], "compiled back-to-front order")
        require(all(a.get("LayerHasSpecular") is True and a.get("LayerTranslucency", 0) > 0
                    and a.get("LayerBlurStrength", 0) > 0 for a in layers), "native material properties missing")
        groups = [a for a in assets if a.get("AssetType") == "IconGroup" and a.get("Appearance") == appearance
                  and a.get("Name") in expected_groups]
        require(len(groups) == 3 and all(a.get("LayerCount") == 1 for a in groups), "vector group contents")
        require(all(g["Layers"][0].get("AssetType") == "Vector" and
                    g["Layers"][0].get("LayerHasLightingEffects") is True for g in groups), "native vector lighting")
        background = next((a.get("Color components") for a in stack["Layers"] if a.get("AssetType") == "Color"), None)
        require(background is not None and len(background) == 4, "solid background")
        require(background == [1, 1, 1, 1] if label == "light" else max(background[:3]) < 0.2,
                f"incorrect {label} background")
        summary[label] = {"appearance": appearance, "background": background, "foreground_groups": 3,
                          "native_glass": True, "vector_layers": True}
    return summary


def build_icon(output, developer_dir=None):
    hashes = source_hashes()
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    names = ("Assets.car", "app_icon.icns", "icon_build.json")
    require(not any((output / n).exists() for n in names), "icon outputs already exist; choose a fresh directory")
    env = os.environ.copy()
    if developer_dir:
        env["DEVELOPER_DIR"] = str(developer_dir)
    # xcrun observes the user's Xcode licensing/setup state; never bypass it.
    version = subprocess.check_output(["/usr/bin/xcodebuild", "-version"], env=env, text=True).strip()
    match = re.match(r"Xcode (\d+)", version)
    require(match is not None and int(match[1]) >= 27, "release icon requires Xcode 27+; use --developer-dir")
    with tempfile.TemporaryDirectory(prefix="metal_sandbox_icon_") as temporary:
        partial = Path(temporary) / "icon_info.plist"
        subprocess.run(["/usr/bin/xcrun", "actool", str(SOURCE), "--compile", str(output),
                        "--platform", "macosx", "--target-device", "mac", "--minimum-deployment-target", "13.0",
                        "--app-icon", ICON_NAME, "--output-partial-info-plist", str(partial),
                        "--output-format", "human-readable-text", "--warnings", "--notices"], env=env, check=True)
        info = plistlib.loads(partial.read_bytes())
    require(info.get("CFBundleIconName") == ICON_NAME and info.get("CFBundleIconFile") == ICON_NAME,
            "actool icon registration")
    require((output / "app_icon.icns").read_bytes()[:4] == b"icns", "Apple-generated legacy fallback")
    appearances = inspect_assets(output / "Assets.car")
    report = {"format": "icon_composer", "compiler": version, "source_sha256": hashes, "info_plist": info,
              "appearances": appearances, "legacy_fallback": "actool-generated icns",
              "compiled_sha256": {n: hashlib.sha256((output / n).read_bytes()).hexdigest() for n in names[:2]}}
    (output / "icon_build.json").write_text(json.dumps(report, indent=2) + "\n")
    return info


def verify_icon(resources, info):
    report = json.loads((resources / "icon_build.json").read_text())
    require(report.get("format") == "icon_composer", "official icon build provenance")
    require(info.get("CFBundleIconName") == ICON_NAME and info.get("CFBundleIconFile") == ICON_NAME,
            "bundle must select the layered asset, not only the icns")
    require(report.get("source_sha256") == source_hashes(), "packaged icon does not match release source")
    require(set(report["compiled_sha256"]) == {"Assets.car", "app_icon.icns"}, "compiled icon file set")
    for name, digest in report["compiled_sha256"].items():
        require(hashlib.sha256((resources / name).read_bytes()).hexdigest() == digest, "compiled icon hash: " + name)
    require((resources / "app_icon.icns").read_bytes()[:4] == b"icns", "legacy icns fallback")
    appearances = inspect_assets(resources / "Assets.car")
    require(appearances == report["appearances"], "compiled icon material metadata")
    return {"format": "icon_composer", "compiler": report["compiler"], "appearances": appearances,
            "legacy_fallback": "actool-generated icns"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--developer-dir", type=Path, help="process-local full Xcode Developer directory")
    parser.add_argument("--check-source", action="store_true")
    args = parser.parse_args()
    if args.check_source:
        print(json.dumps(source_hashes(), indent=2))
    elif args.output:
        build_icon(args.output, args.developer_dir)
        print("PASS official layered icon: native glass, light/dark variants and legacy fallback")
    else:
        parser.error("provide --output or --check-source")
