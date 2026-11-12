"""Lightweight checker tests. No submission, GPU, managed service or sandbox is run."""
import copy
import json
import math
from pathlib import Path
import struct
import subprocess
import zlib

import artifact_checks as c


def rejected(action):
    try:
        action()
    except (ValueError, RuntimeError):
        return {"invalid_fixture_rejected": True}
    raise ValueError("Invalid fixture was accepted")


def png(path, width, height, pixels, color_type=2, bit_depth=8):
    def chunk(kind, payload):
        return struct.pack(">I", len(payload))+kind+payload+struct.pack(">I", zlib.crc32(kind+payload) & 0xffffffff)
    channels = 4 if color_type == 6 else 3
    raw = b"".join(b"\0"+pixels[y*width*channels:(y+1)*width*channels] for y in range(height))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR",struct.pack(">IIBBBBB",width,height,bit_depth,color_type,0,0,0)) +
                     chunk(b"IDAT",zlib.compress(raw)) + chunk(b"IEND",b""))


def synthetic_rgb(mask, n=128, flat=False):
    out = bytearray()
    for i,m in enumerate(mask):
        x,y = i%n,i//n
        if not m:
            color = (18+y//8,27+y//8,42+y//8)
        elif flat:
            color = (180,120,80)
        else:
            # Deliberately a fake surface, used only to test gates, never an answer.
            color = (int(140+60*math.sin(x/15)*math.cos(y/19)), 65+x//2, 65+y//2)
        out.extend(color)
    return bytes(out)


def report_regressions(v, root):
    """Exercise report/lock lifecycle without tools, candidate code or rendering."""
    import os
    from unittest.mock import patch
    import verifier

    def scenario(name, fail_write=None, unsupported=False):
        tests = root/name/"tests"
        runtime = tests/".runtime"
        runtime.mkdir(parents=True)
        real_dump = verifier.dump
        calls = 0

        def dump_report(path, data):
            nonlocal calls
            calls += 1
            if calls == fail_write:
                raise OSError("injected report write failure")
            real_dump(path, data)

        def execute(instance):
            instance.check("manifest_path_fixture", lambda: [tests/"frame_0000.png", {"nested": tests/"帧.json"}])
            if unsupported:
                instance.check("unsupported_value_fixture", lambda: object())

        keys = ("HOME", "TMPDIR", "XDG_CACHE_HOME", "CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH",
                "SWIFTPM_MODULECACHE_OVERRIDE", "SWIFTPM_CONFIG_PATH", "SWIFTPM_SECURITY_PATH",
                "SWIFTPM_CACHE_PATH", "MTL_SHADER_CACHE_DIR")
        with patch.object(verifier, "ROOT", tests), patch.object(verifier, "RUNTIME", runtime), \
             patch.object(verifier, "configure", return_value={}), patch.object(verifier, "fingerprint", return_value={}), \
             patch.object(verifier.Verifier, "execute", execute), patch.object(verifier, "dump", dump_report), \
             patch.object(verifier.sys, "argv", ["verifier.py"]), \
             patch.dict(os.environ, {key: str(runtime/key.lower()) for key in keys}):
            code = verifier.main()
        expected = 1 if fail_write or unsupported else 0
        c.require(code == expected, "Report lifecycle returned the wrong exit code")
        c.require(not (tests/".verifier_lock").exists(), "Report failure leaked the owned verifier lock")
        if expected == 0:
            report = json.loads((tests/"result.json").read_text())
            c.require(report["status"] == "passed", "Successful Path report did not finish")
            c.require(report["checks"][0]["detail"] == [str(tests/"frame_0000.png"), {"nested": str(tests/"帧.json")}],
                      "Nested Path values did not round-trip as JSON strings")
        return {"exit_code": code, "lock_released": True}

    v.check("report_nested_paths_round_trip", lambda: scenario("paths"))
    v.check("report_initial_write_failure_releases_lock", lambda: scenario("initial_failure", fail_write=1))
    v.check("report_final_write_failure_releases_lock", lambda: scenario("final_failure", fail_write=2))
    v.check("report_serialization_failure_releases_lock", lambda: scenario("serialization_failure", unsupported=True))


def run(v):
    root = Path(__file__).resolve().parent/".runtime"/"self_test"
    root.mkdir()
    report_regressions(v, root)
    helper = v.compile_helper()
    refs = v.oracles(helper,[0,21,45,111,162,243,315,357,360/7])
    for angle,(r5,r8) in refs.items():
        m5,m8 = r5.read_bytes(),r8.read_bytes()
        rgb = synthetic_rgb(m5)
        v.check("synthetic_power5_"+str(angle), lambda rgb=rgb,m5=m5,m8=m8: c.geometry(rgb,128,m5,m8))
        v.check("reject_power8_"+str(angle), lambda m5=m5,m8=m8: rejected(lambda: c.geometry(synthetic_rgb(m8),128,m5,m8)))
    m5,m8 = [p.read_bytes() for p in refs[0]]
    disk = bytes(int((x+0.5-64)**2+(y+0.5-64)**2 < 39**2) for y in range(128) for x in range(128))
    v.check("reject_sphere", lambda: rejected(lambda: c.geometry(synthetic_rgb(disk),128,m5,m8)))
    v.check("reject_blank", lambda: rejected(lambda: c.geometry(bytes([22]*128*128*3),128,m5,m8)))
    v.check("reject_flat_silhouette", lambda: rejected(lambda: c.geometry(synthetic_rgb(m5,flat=True),128,m5,m8)))
    # Two-dimensional 45-degree rotation must not stand in for camera orbit.
    rotated = bytearray(128*128)
    for y in range(128):
        for x in range(128):
            xx,yy = x-63.5,y-63.5
            sx,sy = round((xx+yy)/math.sqrt(2)+63.5),round((-xx+yy)/math.sqrt(2)+63.5)
            if 0 <= sx < 128 and 0 <= sy < 128:
                rotated[y*128+x] = m5[sy*128+sx]
    a5,a8 = [p.read_bytes() for p in refs[45]]
    v.check("reject_2d_rotation", lambda: rejected(lambda: c.geometry(synthetic_rgb(rotated),128,a5,a8)))
    v.check("rgb_tolerance_one", lambda: c.compare_rgb(bytes([0,10,255]),bytes([1,9,254])))
    v.check("rgb_tolerance_two_rejected", lambda: rejected(lambda: c.compare_rgb(bytes([0,10,255]),bytes([0,12,255]))))
    v.check("equivalent_view_sparse_aa", lambda: c.same_view(bytes([80]*3000),bytes([95]*30+[80]*2970)))
    v.check("equivalent_view_reject_wrong_image", lambda: rejected(lambda: c.same_view(bytes([80]*3000),bytes([110]*3000))))
    v.check("duplicate_animation_rejected", lambda: rejected(lambda: c.animation_changes([bytes([30]*300)]*7)))

    # Verify ImageIO's coordinate convention using an asymmetric colored fixture.
    rgb = synthetic_rgb(m5)
    image = root/"valid_rgb.png"; png(image,128,128,rgb)
    rgba = b"".join(rgb[i:i+3]+b"\xff" for i in range(0,len(rgb),3))
    image_rgba = root/"valid_rgba.png"; png(image_rgba,128,128,rgba,6)
    decoded = v.decode(helper,[(image,128),(image_rgba,128)])
    v.check("imageio_orientation_rgb", lambda: c.compare_rgb(rgb,decoded[image].read_bytes()))
    v.check("imageio_rgba_opaque", lambda: c.compare_rgb(rgb,decoded[image_rgba].read_bytes()))
    v.check("decoded_silhouette", lambda: c.geometry(decoded[image].read_bytes(),128,m5,m8))
    transparent = root/"transparent.png"; png(transparent,128,128,rgba[:-1]+b"\xfe",6)
    broken = root/"broken.png"; broken.write_bytes(b"not a png")
    for name,path,size in (("transparent_rejected",transparent,128), ("broken_png_rejected",broken,128), ("wrong_size_rejected",image,512)):
        plan = root/(name+".json")
        plan.write_text(json.dumps([{"input":str(path),"output":str(root/(name+".rgb")),"width":size,"height":size}]))
        v.check(name, lambda name=name,plan=plan: str(v.command(name,[str(helper),"decode",str(plan)],root,expect_failure=True)))

    meta = {"image": {"width":512,"height":512}, "fractal": {"power":5,"max_iterations":32,"escape_radius":2},
            "camera": {"position":[3,-4,2.5],"target":[0,0,0],"reference_up":[0,0,1]},
            "projection":{"vertical_fov_degrees":35,"aspect_ratio":1},"samples_per_pixel":4,"seed":None,
            "intersection":{"method":"DE","epsilon":0.001,"max_steps":400,"normal":"finite differences"},
            "lighting":{"key":[1,1,1]},"material":{"albedo":[0.6,0.4,0.2]},"color_transform":"linear to sRGB",
            "gpu":"fixture device","os":"fixture OS","toolchain":"fixture toolchain"}
    mp = root/"metadata.json"
    def check_meta(data):
        mp.write_text(json.dumps(data)); return c.metadata(mp,512,512,0)
    v.check("nested_snake_case_metadata", lambda: check_meta(meta))
    for key,value in (("power",8),("max_iterations",5),("escape_radius",4)):
        bad = copy.deepcopy(meta); bad["fractal"][key] = value
        v.check("metadata_reject_"+key,lambda bad=bad: rejected(lambda: check_meta(bad)))
    bad = copy.deepcopy(meta); bad["camera"]["position"] = [3,4,2.5]
    v.check("metadata_reject_wrong_camera",lambda: rejected(lambda: check_meta(bad)))
    missing = copy.deepcopy(meta); del missing["material"]
    v.check("metadata_reject_missing_material",lambda: rejected(lambda: check_meta(missing)))
    camel = {"".join([k.split("_")[0]]+[x.capitalize() for x in k.split("_")[1:]]):value for k,value in meta.items()}
    v.check("camel_case_metadata",lambda: check_meta(camel))

    manifest = {"width":128,"height":128,"frame_count":7,"fps":24,"axis":"+Z",
                "orbit":{"formula":"(3 cos a + 4 sin a, 3 sin a - 4 cos a, 2.5)"},
                "frames":[{"file":"frame_%04d.png"%n,"angle_degrees":360*n/7} for n in range(7)]}
    for entry in manifest["frames"]:
        (root/entry["file"]).write_bytes(b"structure fixture; decoder tested separately")
    mf = root/"manifest.json"
    def check_manifest(data):
        mf.write_text(json.dumps(data)); return [p.name for p in c.manifest(mf,128,128,7)]
    v.check("seven_frame_manifest", lambda: check_manifest(manifest))
    bad_count = copy.deepcopy(manifest); bad_count["frame_count"] = 120
    bad_path = copy.deepcopy(manifest); bad_path["frames"][1]["file"] = "../frame_0001.png"
    bad_angle = copy.deepcopy(manifest); bad_angle["frames"][-1]["angle_degrees"] = 360
    for name,bad in (("count",bad_count),("unsafe_path",bad_path),("duplicate_endpoint",bad_angle)):
        v.check("manifest_reject_"+name,lambda bad=bad: rejected(lambda: check_manifest(bad)))

    def adapter():
        import os
        binpath = Path(os.environ["VERIFIER_TOOL_BIN"])
        found = subprocess.check_output([str(binpath/"xcrun"),"--sdk","macosx","--find","swiftc"],text=True).strip()
        c.require(found == str(binpath/"swiftc"), "Tool adapter returned an unexpected path")
        sdk = subprocess.check_output([str(binpath/"xcrun"),"--show-sdk-path"],text=True).strip()
        c.require(sdk == os.environ["SDKROOT"], "Tool adapter ignored SDKROOT")
        return {"local_adapter":True,"system_xcrun_called":False}
    v.check("local_tool_locator",adapter)

    def isolation():
        import os
        import verifier
        original = root/"source_fixture"; original.mkdir()
        (original/"run.sh").write_text('#!/bin/sh\n/usr/bin/xcrun --find swiftc\n')
        (original/"run.sh").chmod(0o700)
        (original/"main.swift").write_text("// source fixture, never compiled or executed\n")
        for name in ("build", "output", "tests"):
            (original/name).mkdir(); (original/name/"stale.swift").write_text("cached artifact\n")
        (original/"cached.png").write_bytes(b"cached artifact")
        (original/".env").write_text("ignored fixture configuration\n")
        before = verifier.fingerprint(original)
        files = verifier.source_files(original)
        c.require({p.name for p in files} == {"run.sh", "main.swift"}, "Cold-copy selection included generated/hidden data")
        destination = root/"copied_fixture"
        changes = verifier.copy_sources(original,files,destination)
        c.require(len(changes) == 1 and '/usr/bin/xcrun' not in (destination/"run.sh").read_text(), "Tool relocation failed")
        c.require(before == verifier.fingerprint(original), "Source copy modified its original")
        for key in ("HOME", "TMPDIR", "CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH", "XDG_CACHE_HOME", "CC", "CXX"):
            c.require(Path(os.environ[key]).resolve().is_relative_to(verifier.ROOT), key+" escaped tests")
        # Exercise a real child shell, but not a submission/renderer.
        v.command("isolated_shell_fixture", ["/bin/sh","-c", 'test "$PWD" = "$WORKSPACE" && printf ok > "$HOME/fixture_marker"'],destination)
        c.require((Path(os.environ["HOME"])/"fixture_marker").read_text() == "ok", "Child did not use isolated HOME")
        (original/"linked.swift").symlink_to(original/"main.swift")
        rejected(lambda: verifier.source_files(original))
        return {"original_unchanged": True, "cached_artifacts_excluded": True, "symlinks_rejected": True,
                "isolated_child_environment": True, "relocated_tool_calls": changes}
    v.check("source_copy_and_child_write_isolation",isolation)
