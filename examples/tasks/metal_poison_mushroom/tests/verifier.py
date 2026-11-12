#!/usr/bin/env python3
"""Run only from the copied workspace/tests directory.

No service management, network, xcrun execution, or in-place candidate build.
This is a correctness verifier for trusted local submissions, not a hostile-code
security boundary. The managed executor remains responsible for process isolation.
All harness-managed files and candidate-relative paths are below tests/.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import time

import artifact_checks as checks
from tool_locator import configure

ROOT = Path(__file__).resolve().parent
RUNTIME = ROOT / ".runtime"
FPS_RESOLUTIONS = ((1280, 720), (1920, 1080), (2560, 1440), (3840, 2160))
FPS_WARMUP_FRAMES = 5
FPS_MEASURED_FRAMES = 60
BOUNDARIES = [
    "Automatic PASS is not a proof that every fractal/intersection/normal/shading operation ran on the GPU. Source/API signals and a cold shader-failure intervention provide evidence, not instruction-level GPU tracing.",
    "The independent CPU oracle checks coarse power-5 silhouettes, fixed camera/orbit and contrasts power-8/disk hypotheses. It does not prove exact 32nd-iteration boundary classification, strict radius equality, interior topology or absence of every NaN/Inf.",
    "Visual gating assumes a separable, approximately smooth background. Unusual legal backgrounds/materials may need manual adjudication; no reference colors or answer-specific hashes are used.",
    "Human source/visual review still covers full P5 recurrence and zero/pole handling, finite-iteration edge cases, GPU resource reuse, genuine native-resolution sampling, 3D occlusion, normal-based lighting, AA/holes/banding and full documentation truthfulness.",
    "JSON field names are not specified by the task. Common camel/snake-case/nested forms are recognized; an unrecognized but semantically complete schema may need checker adaptation, not renderer changes.",
    "Freshly regenerated deliverables are checked; original pre-rendered PNGs are deliberately not used as evidence. FPS measures run.sh wall time, including process startup, any script/build work, rendering, readback and PNG export. It is not playback FPS, pure GPU timing, a performance gate or GPU-drain certification.",
    "Work copies, environment, caches, tool wrappers and outputs are confined to tests. This is not an OS write-denial sandbox against malicious absolute-path/syscall writes; the original tree is fingerprinted for accidental changes.",
]
SKIP_DIRS = {"tests", ".git", ".build", "build", "output", "outputs", "derived_data", "DerivedData", "dist", "target", "node_modules", "__pycache__", ".cache", ".swiftpm"}
SOURCE_SUFFIXES = {".swift", ".metal", ".m", ".mm", ".c", ".cc", ".cpp", ".cxx", ".h", ".hpp", ".hh", ".inc", ".metalh", ".sh", ".bash", ".zsh", ".py", ".json", ".toml", ".yaml", ".yml", ".cmake", ".txt", ".md", ".plist", ".xcconfig", ".modulemap", ".pbxproj", ".xcworkspacedata", ".resolved"}
HOST_SUFFIXES = {".swift", ".m", ".mm", ".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp"}


def dump(path, data):
    # replace, rather than follow, a preexisting result symlink
    temp = path.with_name(path.name + ".next")
    if temp.exists() or temp.is_symlink():
        temp.unlink()
    temp.write_text(json.dumps(data, indent=2, ensure_ascii=False, allow_nan=False, default=os.fspath) + "\n")
    temp.replace(path)


def fingerprint(workspace):
    result = {}
    for base, dirs, files in os.walk(workspace, followlinks=False):
        here = Path(base)
        dirs[:] = sorted(d for d in dirs if here/d != ROOT and d != ".git")
        for name in files + dirs:
            p = here/name
            s = p.lstat()
            result[str(p.relative_to(workspace))] = [s.st_mode, s.st_size, s.st_mtime_ns, os.readlink(p) if p.is_symlink() else None]
    return result


def source_files(workspace):
    result = []
    for base, dirs, files in os.walk(workspace, followlinks=False):
        here = Path(base)
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and not d.startswith("."))
        for name in dirs + files:
            checks.require(not (here/name).is_symlink(), "Source links are not supported: " + str((here/name).relative_to(workspace)))
        for name in sorted(files):
            p = here/name
            if name.startswith(".") or name == "setup.sh":
                continue
            if p.suffix.lower() in SOURCE_SUFFIXES or not p.suffix:
                checks.require(stat.S_ISREG(p.stat().st_mode), "Not a regular source file: " + name)
                # Binary/cache artifacts cannot enter the cold source tree.
                data = p.read_bytes()
                if b"\0" in data and not p.suffix:
                    continue  # extensionless prebuilt executable
                checks.require(b"\0" not in data, "Binary data in source/config file: " + name)
                result.append(p)
    return result


def uncomment(text):
    return re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)


def source_signals(files):
    shader_files = [p for p in files if p.suffix == ".metal"]
    hosts = [p for p in files if p.suffix in HOST_SUFFIXES]
    checks.require(shader_files and hosts, "Independent .metal and native host sources are required")
    shader = uncomment("\n".join(p.read_text(errors="replace") for p in shader_files))
    host = uncomment("\n".join(p.read_text(errors="replace") for p in hosts))
    tests = {
        "metal_shader_entry": bool(re.search(r"\b(kernel|fragment|vertex)\b", shader)),
        "shader_iteration": bool(re.search(r"\b(for|while)\s*\(", shader)),
        "native_device": bool(re.search(r"MTLCreateSystemDefaultDevice|MTLCopyAllDevices|MTL::CreateSystemDefaultDevice|MTL::CopyAllDevices", host)),
        "command_queue": bool(re.search(r"(?:make|new)CommandQueue", host)),
        "pipeline": bool(re.search(r"(?:Compute|Render)Pipeline", host)),
        "gpu_dispatch_or_draw": bool(re.search(r"dispatchThread|drawPrimitives|drawIndexed|drawMesh|executeCommandsInBuffer", host)),
        "gpu_commit": bool(re.search(r"\bcommit\b", host)),
        "gpu_completion": bool(re.search(r"waitUntilCompleted|addCompletedHandler|notifyListener|sharedEvent|SharedEvent", host)),
        "gpu_error_handling": bool(re.search(r"\b(status|error)\b", host)),
    }
    checks.require(all(tests.values()), "Missing native Metal source evidence: " + ", ".join(k for k,v in tests.items() if not v))
    forbidden = r"(?:import|#\s*include)\s*[<\"]?(?:SceneKit|OpenGL|GLKit|MetalPerformanceShaders|MPSGraph)\b"
    checks.require(not re.search(forbidden, host), "Disallowed rendering framework import")
    tests["spherical_trig_signals"] = all(re.search(r"\b"+word+r"\s*\(", shader) for word in ("sin", "cos", "acos", "atan2"))
    tests["spherical_trig_signals"] = bool(tests["spherical_trig_signals"])
    return tests


def copy_sources(workspace, files, destination):
    destination.mkdir(parents=True)
    relocated = []
    for source in files:
        rel = source.relative_to(workspace)
        out = destination/rel
        out.parent.mkdir(parents=True, exist_ok=True)
        text = source.read_text()
        # Only tool locations are adapted. Mathematical/host algorithms are unchanged.
        for name in ("xcrun", "swiftc", "swift", "clang++", "clang", "metal", "metallib"):
            old = "/usr/bin/"+name
            # Longest names are processed first, and require an exact path boundary.
            pattern = re.escape(old) + r"(?=$|[\s\"';)])"
            text, count = re.subn(pattern, lambda _: str(RUNTIME/"bin"/name), text)
            if count:
                relocated.append({"file": str(rel), "tool": name, "occurrences": count})
        # Reject hard-coded scratch/workspace writes rather than silently changing them.
        if source.suffix in HOST_SUFFIXES | {".sh", ".bash", ".py", ".metal"}:
            checks.require(("/"+"tmp/") not in text and ("/private/"+"tmp/") not in text,
                           "Hard-coded external scratch path in " + str(rel) + "; use TMPDIR")
            checks.require(str(workspace) not in text, "Hard-coded original workspace path in " + str(rel))
        out.write_text(text)
        out.chmod(stat.S_IMODE(source.stat().st_mode) | stat.S_IWUSR)
    return relocated


class Verifier:
    def __init__(self):
        self.report = {"schema_version": 1, "status": "running", "checks": [],
                       "automatic_scope_only": True, "manual_review_boundaries": BOUNDARIES}
        self.metrics = {
            "schema_version": 1, "status": "running", "measurement": "end_to_end_png_export",
            "fps_formula": "measured_frames / elapsed_seconds",
            "timing_scope": "run.sh process startup through exit, including any build work, GPU rendering, readback and PNG export; output validation excluded",
            "warmup_frames": FPS_WARMUP_FRAMES, "warmup_separate_process": True,
            "measured_frames": FPS_MEASURED_FRAMES, "minimum_fps": None,
            "results": [{"width": w, "height": h, "status": "pending", "fps": None,
                         "mean_frame_ms": None, "elapsed_seconds": None} for w, h in FPS_RESOLUTIONS],
        }
        self.count = 0

    def check(self, name, action):
        try:
            detail = action()
            self.report["checks"].append({"name": name, "status": "passed", "detail": detail})
            print("[PASS] " + name, flush=True)
            return detail
        except subprocess.TimeoutExpired:
            # Stop this verifier; the managed executor owns descendant cleanup.
            raise
        except Exception as error:
            self.report["checks"].append({"name": name, "status": "failed", "error": str(error)})
            print("[FAIL] " + name + ": " + str(error), flush=True)
            return None

    def command(self, name, argv, cwd, expect_failure=False):
        self.count += 1
        log = RUNTIME/"logs"/("%02d_%s.log" % (self.count,name))
        log.parent.mkdir(parents=True, exist_ok=True)
        env = os.environ.copy()
        env.update(WORKSPACE=str(cwd), PWD=str(cwd))
        # Do not forward agent credentials, launch hooks or service-control settings.
        for key in list(env):
            if key.startswith(("ANTHROPIC_", "OPENAI_", "CLAUDE_", "METAL_SANDBOX_", "DYLD_")) or key in ("ENV", "BASH_ENV"):
                del env[key]
        print("[RUN] %s (log: %s)" % (name, log.relative_to(ROOT)), flush=True)
        seconds = float(os.environ.get("VERIFIER_COMMAND_TIMEOUT_SECONDS", "0"))
        checks.require(seconds >= 0, "Timeout must be nonnegative; 0 means no harness time limit")
        with log.open("wb") as stream:
            started = time.perf_counter()
            child = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                     stdout=stream, stderr=subprocess.STDOUT)
            try:
                code = child.wait(timeout=seconds or None)
            except BaseException:
                try:
                    # Inherit the managed process group. Never signal that whole
                    # group from here: it also contains the verifier/executor.
                    child.kill()
                except ProcessLookupError:
                    pass
                child.wait()
                raise
            elapsed = time.perf_counter() - started
        self.report.setdefault("commands", []).append({"name": name, "argv": argv,
                    "cwd": str(cwd.relative_to(ROOT)), "exit_code": code, "log": str(log.relative_to(ROOT)),
                    "elapsed_seconds": elapsed})
        if expect_failure:
            checks.require(code != 0, name + " unexpectedly returned success; see " + str(log.relative_to(ROOT)))
            checks.require(log.stat().st_size > 0, name + " failed without an error log")
        else:
            checks.require(code == 0, name + " exited " + str(code) + "; see " + str(log.relative_to(ROOT)))
        return log

    def compile_helper(self):
        exe = RUNTIME/"image_check"
        self.command("build_cpu_checker", [os.environ["SWIFTC"], "-O", "-sdk", os.environ["SDKROOT"],
                     str(ROOT/"image_check.swift"), "-o", str(exe)], ROOT)
        return exe

    def render(self, work, name, size, angle=None, frames=None):
        out = work/"verification_output"/name
        width, height = (size, size) if isinstance(size, int) else size
        args = [str(work/"run.sh"), "--width", str(width), "--height", str(height)]
        if frames is None:
            out = out.with_suffix(".png")
            args += ["--output", str(out)]
            if angle is not None:
                args += ["--angle-degrees", str(angle)]
        else:
            args += ["--frames", str(frames), "--output-dir", str(out)]
        self.command(name, args, work)
        return out

    def measure_fps(self, work, helper):
        for row in self.metrics["results"]:
            width, height = row["width"], row["height"]
            name = "fps_%dx%d" % (width, height)
            row["status"] = "running"
            dump(ROOT/"metrics.json", self.metrics)

            def measure():
                self.render(work, name+"_warmup", (width, height), frames=FPS_WARMUP_FRAMES)
                directory = self.render(work, name, (width, height), frames=FPS_MEASURED_FRAMES)
                command = self.report["commands"][-1]
                elapsed = command["elapsed_seconds"]
                checks.require(elapsed > 0, "Invalid measured duration")
                paths = checks.manifest(directory/"manifest.json", width, height, FPS_MEASURED_FRAMES)
                # Decode every measured frame without writing large RGB copies.
                # This validation is deliberately outside the measured interval.
                for path in paths:
                    checks.require(path.resolve().is_relative_to(RUNTIME), "Output escaped tests")
                plan = RUNTIME/(name+"_inspect.json")
                dump(plan, [{"input": str(p), "width": width, "height": height} for p in paths])
                self.command(name+"_validate", [str(helper), "inspect", str(plan)], ROOT)
                return {"fps": FPS_MEASURED_FRAMES/elapsed,
                        "mean_frame_ms": elapsed*1000/FPS_MEASURED_FRAMES,
                        "elapsed_seconds": elapsed, "validated_frames": len(paths),
                        "log": command["log"]}

            detail = self.check(name, measure)
            if detail is None:
                row.update(status="failed", error=self.report["checks"][-1]["error"])
            else:
                row.update(detail, status="passed")
                print("[FPS] %dx%d: %.3f (end-to-end PNG export)" % (width, height, row["fps"]), flush=True)
            dump(ROOT/"metrics.json", self.metrics)

    def decode(self, helper, rows):
        raw = RUNTIME/"decoded"
        raw.mkdir(exist_ok=True)
        plan = []
        for path,size in rows:
            checks.require(path.is_file() and not path.is_symlink(), "Missing or linked output " + str(path))
            checks.require(path.resolve().is_relative_to(RUNTIME), "Output escaped tests")
            name = hashlib.sha256(str(path).encode()).hexdigest()[:24] + ".rgb"
            plan.append({"input": str(path), "output": str(raw/name), "width": size, "height": size})
        plan_path = RUNTIME/"decode_plan.json"; dump(plan_path, plan)
        self.command("decode_pngs", [str(helper), "decode", str(plan_path)], ROOT)
        return {Path(row["input"]): Path(row["output"]) for row in plan}

    def oracles(self, helper, angles):
        folder = RUNTIME/"oracle"; folder.mkdir(exist_ok=True)
        rows = []
        result = {}
        for index,angle in enumerate(angles):
            result[angle] = []
            for power in (5,8):
                out = folder/("angle_%02d_power_%d.mask" % (index,power))
                result[angle].append(out)
                rows.append({"output": str(out), "size": 128, "angle": float(angle), "power": float(power)})
        plan = RUNTIME/"oracle_plan.json"; dump(plan, rows)
        self.command("cpu_math_oracle", [str(helper), "oracle", str(plan)], ROOT)
        return result

    def execute(self):
        workspace = ROOT.parent
        files = source_files(workspace)
        checks.require((workspace/"run.sh") in files and os.access(workspace/"run.sh", os.X_OK), "Missing executable run.sh")
        self.check("retained_readme", lambda: checks.require((workspace/"README.md").is_file() and (workspace/"README.md").stat().st_size > 0,
                                                          "README.md is required (content still needs review)"))
        evidence = self.check("native_metal_source_signals", lambda: source_signals(files))
        checks.require(evidence is not None, "Cannot proceed without native Metal source evidence")
        self.report["source_files"] = [{"path": str(p.relative_to(workspace)), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in files]
        work = RUNTIME/"work"
        self.report["tool_path_relocations"] = copy_sources(workspace, files, work)
        helper = self.compile_helper()
        images = {}
        for name,size,angle in (("mandelbulb",1024,None), ("repeat",1024,None), ("small",512,None), ("small_repeat",512,None),
                                ("angle_45",512,45), ("angle_360",512,360), ("angle_111",512,111),
                                ("angle_357",512,357), ("angle_seven",128,360/7)):
            path = self.render(work, name, size, angle)
            images[name] = (path,size,angle or 0)
            self.check("metadata_"+name, lambda p=path,s=size,a=angle: checks.metadata(p.with_suffix(".json"), s,s,a or 0))
        animations = {}
        for name,size,count in (("rotation",512,120), ("rotation_seven",128,7)):
            directory = self.render(work,name,size,frames=count)
            paths = self.check("manifest_"+name, lambda d=directory,s=size,n=count: checks.manifest(d/"manifest.json",s,s,n))
            checks.require(paths is not None, "Animation structure invalid; cannot continue image checks")
            animations[name] = (paths,size)
        rows = [(p,s) for p,s,_ in images.values()] + [(p,s) for paths,s in animations.values() for p in paths]
        decoded = self.decode(helper, rows)
        self.report["decoded_images"] = len(decoded)
        self.check("all_png_dimensions_format_alpha", lambda: {"decoded_images": len(decoded), "bit_depth": 8, "alpha": "all 255"})

        def raw(path):
            return decoded[path].read_bytes()
        for name,a,b in (("repeat_determinism_1024",images["mandelbulb"][0],images["repeat"][0]),
                         ("repeat_determinism_512",images["small"][0],images["small_repeat"][0])):
            self.check(name, lambda a=a,b=b: checks.compare_rgb(raw(a),raw(b)))
        pairs = [("angle_wrap_360",images["small"][0],images["angle_360"][0]),
                 ("animation_zero",images["small"][0],animations["rotation"][0][0]),
                 ("animation_45",images["angle_45"][0],animations["rotation"][0][15]),
                 ("animation_111",images["angle_111"][0],animations["rotation"][0][37]),
                 ("animation_last_357",images["angle_357"][0],animations["rotation"][0][119]),
                 ("adjustable_frame_count_angle",images["angle_seven"][0],animations["rotation_seven"][0][1])]
        for name,a,b in pairs:
            self.check(name, lambda a=a,b=b: checks.same_view(raw(a),raw(b)))
        for name,(paths,_) in animations.items():
            self.check("changes_and_loop_"+name, lambda paths=paths: checks.animation_changes([raw(p) for p in paths]))
        oracle_angles = [0,21,45,111,162,243,315,357,360/7]
        oracles = self.oracles(helper,oracle_angles)
        for name in ("mandelbulb", "small", "angle_45", "angle_111", "angle_357", "angle_seven"):
            p,size,angle = images[name]
            ref5,ref8 = oracles[angle]
            self.check("geometry_and_detail_"+name,
                       lambda p=p,size=size,r5=ref5,r8=ref8: checks.geometry(raw(p),size,r5.read_bytes(),r8.read_bytes()))
        for index in (7,54,81,105):
            p = animations["rotation"][0][index]
            ref5,ref8 = oracles[index*3]
            self.check("animation_geometry_%04d" % index,
                       lambda p=p,r5=ref5,r8=ref8: checks.geometry(raw(p),512,r5.read_bytes(),r8.read_bytes()))

        self.measure_fps(work, helper)

        def bad_output():
            blocker = work/"not_a_directory"; blocker.write_text("write failure probe\n")
            log = self.command("output_write_failure", [str(work/"run.sh"), "--width", "128", "--height", "128",
                              "--output", str(blocker/"bad.png")], work, expect_failure=True)
            return {"log": str(log.relative_to(ROOT))}
        self.check("output_errors_nonzero", bad_output)

        def shader_failure():
            broken = RUNTIME/"broken_shader_work"
            copy_sources(workspace, files, broken)
            marker = "VERIFIER_INTENTIONAL_METAL_SOURCE_FAILURE"
            for p in broken.rglob("*.metal"):
                p.write_text("#error " + marker + "\n" + p.read_text())
            log = self.command("cold_shader_failure", [str(broken/"run.sh"), "--width", "128", "--height", "128",
                               "--output", str(broken/"probe.png")], broken, expect_failure=True)
            checks.require(marker in log.read_text(errors="replace"), "Failure did not expose the injected shader diagnostic; shader build dependence unproven")
            return {"log": str(log.relative_to(ROOT)), "partial_output_exists": (broken/"probe.png").exists(),
                    "evidence": "cold source shader compilation is on the rendering path"}
        self.check("native_shader_cold_failure_intervention", shader_failure)


def main():
    os.umask(0o077)
    if len(sys.argv) > 1 and sys.argv[1:] != ["--self-test"]:
        print("Usage: tests/test.sh [--self-test]", file=sys.stderr); return 2
    lock = ROOT/".verifier_lock"
    try:
        lock.mkdir()
    except FileExistsError:
        print("[FAIL] Another verifier is active, or .verifier_lock survived an interrupted run. Do not remove it while a run is active.", flush=True)
        return 2
    try:
        return run_locked()
    except Exception as error:
        print("[FAIL] report/finalization: " + str(error), flush=True)
        return 1
    finally:
        # This invocation acquired the lock. Release it even if the initial or
        # final report cannot be serialized, written, or atomically replaced.
        lock.rmdir()


def run_locked():
    verifier = Verifier()
    before = None
    self_test = len(sys.argv) == 2
    report_path = ROOT/("self_test_result.json" if self_test else "result.json")
    dump(report_path, verifier.report)
    if not self_test:
        dump(ROOT/"metrics.json", verifier.metrics)
    try:
        checks.require(not RUNTIME.is_symlink(), "Runtime directory must not be a symlink")
        # Cold builds on every invocation, including HOME and module/package caches.
        for p in RUNTIME.iterdir():
            if p.is_symlink():
                p.unlink()
            elif p.is_dir():
                shutil.rmtree(p)
            else:
                p.unlink()
        for key in ("HOME", "TMPDIR", "XDG_CACHE_HOME", "CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH",
                    "SWIFTPM_MODULECACHE_OVERRIDE", "SWIFTPM_CONFIG_PATH", "SWIFTPM_SECURITY_PATH",
                    "SWIFTPM_CACHE_PATH", "MTL_SHADER_CACHE_DIR"):
            Path(os.environ[key]).mkdir(parents=True, exist_ok=True)
        verifier.report["toolchain"] = configure(RUNTIME)
        if self_test:
            from self_test import run
            run(verifier)
        else:
            before = fingerprint(ROOT.parent)
            verifier.execute()
    except BaseException as error:
        verifier.report["checks"].append({"name": "execution", "status": "failed", "error": str(error) or type(error).__name__})
        print("[FAIL] execution: " + (str(error) or type(error).__name__), flush=True)
    finally:
        if not self_test:
            for row in verifier.metrics["results"]:
                if row["status"] in ("pending", "running"):
                    row.update(status="skipped" if row["status"] == "pending" else "failed",
                               error="Measurement did not complete; see result.json")
            verifier.metrics["status"] = "completed" if all(r["status"] == "passed" for r in verifier.metrics["results"]) else "failed"
            dump(ROOT/"metrics.json", verifier.metrics)
            verifier.report["fps_metrics"] = "metrics.json"
        if before is not None:
            verifier.check("original_workspace_unchanged", lambda: checks.require(before == fingerprint(ROOT.parent), "Original workspace changed outside tests"))
        failed = sum(c["status"] == "failed" for c in verifier.report["checks"])
        verifier.report["status"] = "failed" if failed else "passed"
        verifier.report["failed_checks"] = failed
        if self_test:
            verifier.report["mode"] = "synthetic_checker_self_test_not_candidate_acceptance"
        dump(report_path, verifier.report)
    print("[RESULT] %s — %d failed check(s); %s" % (verifier.report["status"].upper(), failed, report_path), flush=True)
    print("[BOUNDARY] Automatic checks only; manual review boundaries are recorded in JSON. No FPS requirement.", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
