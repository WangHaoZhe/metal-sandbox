"""Schema-tolerant task-contract checks, not a reference-image/color matcher.

The geometric gate is deliberately coarse: 128-square CPU silhouettes with
two-cell boundary tolerance, plus comparisons against power=8 and a disk.
It cannot certify subpixel topology, every finite-orbit boundary, or aesthetics.
"""
import json
import math
from pathlib import Path, PurePosixPath
import re
import statistics


def require(condition, message):
    if not condition:
        raise ValueError(message)


def norm(value):
    return re.sub(r"[^a-z0-9]", "", value.lower())


def read_json(path):
    def invalid(value):
        raise ValueError("Non-finite JSON number: " + value)
    with Path(path).open() as f:
        data = json.load(f, parse_constant=invalid)
    require(isinstance(data, dict), str(path) + ": expected JSON object")
    return data


MISSING = object()


def field(data, *aliases, default=MISSING):
    """Prefer immediate fields; then allow nested sections and naming conventions."""
    names = {norm(a) for a in aliases}
    if isinstance(data, dict):
        for key, value in data.items():
            if norm(key) in names:
                return value
        for value in data.values():
            if isinstance(value, dict):
                found = field(value, *aliases, default=MISSING)
                if found is not MISSING:
                    return found
    return default


def number(value):
    require(not isinstance(value, bool), "Boolean is not a numeric parameter")
    try:
        n = float(value)
    except (ValueError, TypeError):
        raise ValueError("Missing/invalid numeric parameter")
    require(math.isfinite(n), "Non-finite numeric parameter")
    return n


def close(value, expected, name, tolerance=1e-4):
    require(abs(number(value) - expected) <= tolerance, name + " must be " + str(expected))


def vector(value, expected, name):
    if isinstance(value, dict):
        value = [value.get(k) for k in ("x", "y", "z")]
    require(isinstance(value, list) and len(value) == 3, name + " must have three components")
    for actual, target in zip(value, expected):
        close(actual, target, name, 0.002)


def dimensions(data, w, h):
    width = field(data, "width", "imageWidth")
    height = field(data, "height", "imageHeight")
    if width is MISSING or height is MISSING:
        size = field(data, "dimensions", "resolution", "size")
        require(isinstance(size, list) and len(size) == 2, "Missing image dimensions")
        width, height = size
    close(width, w, "width", 0); close(height, h, "height", 0)


def present(data, name, *aliases):
    value = field(data, name, *aliases)
    require(value is not MISSING and value not in (None, "", {}, []), "Missing " + name + " metadata")
    return value


def metadata(path, w, h, degrees):
    data = read_json(path)
    dimensions(data, w, h)
    close(field(data, "power", "fractalPower", "exponent"), 5, "power")
    close(field(data, "maxFractalIterations", "maxIterations", "maxIter", "iterations", "iterationLimit"), 32, "fractal iteration limit", 0)
    close(field(data, "escapeRadius", "bailout", "bailoutRadius"), 2, "escape radius")
    camera = present(data, "camera", "view")
    a = math.radians(degrees)
    vector(field(camera, "position", "eye", "origin", "cameraPosition"),
           [3*math.cos(a)+4*math.sin(a), 3*math.sin(a)-4*math.cos(a), 2.5], "camera position")
    vector(field(camera, "target", "lookAt", "lookAtTarget"), [0,0,0], "camera target")
    vector(field(camera, "referenceUp", "worldUp", "up"), [0,0,1], "reference up")
    fov = field(data, "verticalFovDegrees", "fovYDegrees", "fovDegrees", "fovY", "fov")
    if fov is MISSING:
        fov = number(field(data, "verticalFovRadians", "fovYRadians", "fovRadians")) * 180 / math.pi
    close(fov, 35, "vertical FOV", 0.002)
    aspect = field(data, "aspect", "aspectRatio", default=None)
    if aspect is not None:
        close(aspect, w/h, "aspect ratio")
    samples = number(present(data, "samplesPerPixel", "samples", "spp", "sampleCount"))
    require(samples >= 1, "Invalid sample count")
    seed = field(data, "seed", "randomSeed")
    require(seed is not MISSING, "seed must be recorded (0 or null)")
    require(seed is None or (not isinstance(seed, bool) and number(seed) == 0), "seed must be 0 or null")
    intersection = present(data, "intersection", "rayMarching", "rayMarch", "distanceEstimator", "intersectionMethod")
    scope = intersection if isinstance(intersection, dict) else data
    if isinstance(intersection, dict):
        present(scope, "method", "type", "description", "algorithm")
    require(number(present(scope, "surfaceEpsilon", "epsilon", "hitEpsilon", "tolerance", "hitThreshold")) > 0,
            "Intersection tolerance must be positive")
    require(number(present(scope, "maxSteps", "stepLimit", "maxRaySteps", "maxMarchSteps")) > 0,
            "Intersection step limit must be positive")
    present(data, "normal", "normalMethod", "normalEstimation", "normals")
    present(data, "lighting", "lights", "light")
    present(data, "material", "materials", "albedo", "baseColor", "shading")
    present(data, "colorTransform", "colorConversion", "linearToDisplay", "linearToSRGB", "colorSpace", "gamma")
    present(data, "gpu", "gpuName", "device", "deviceName")
    present(data, "os", "macOS", "osVersion", "operatingSystem")
    present(data, "toolchain", "toolchainVersion", "compiler", "swiftVersion", "compilerVersion")
    return {"dimensions": [w, h], "angle_degrees": degrees, "power": 5, "max_iterations": 32}


def manifest(path, w, h, count):
    data = read_json(path)
    dimensions(data, w, h)
    entries = field(data, "frames", "images", "sequence")
    require(isinstance(entries, list) and len(entries) == count, "Manifest must enumerate every frame in order")
    close(field(data, "totalFrames", "frameCount", "numFrames", "count"), count, "frame count", 0)
    require(number(present(data, "suggestedFps", "fps", "frameRate", "playbackFps", "suggestedFrameRate")) > 0,
            "Playback rate must be positive; it is NOT a render-performance gate")
    axis = present(data, "rotationAxis", "axis")
    if isinstance(axis, str):
        require(norm(axis) in ("z", "worldz", "positivez", "001"), "Rotation axis must be +Z")
        require(not axis.strip().startswith("-"), "Rotation axis must be +Z")
    else:
        vector(axis, [0,0,1], "rotation axis")
    present(data, "orbitFormula", "cameraOrbit", "orbit", "trajectory", "cameraFormula")
    angles = field(data, "anglesDegrees", "frameAngles", "angles", default=[])
    paths = []
    for n, entry in enumerate(entries):
        if isinstance(entry, str):
            name = entry
            require(len(angles) == count, "String frame lists need a matching angles list")
            angle = angles[n]
        else:
            require(isinstance(entry, dict), "Invalid frame entry")
            name = field(entry, "path", "file", "filename", "image", "relativePath")
            angle = field(entry, "angleDegrees", "degrees", "angle", "cameraAngleDegrees")
            radians = field(entry, "angleRadians", default=None)
            if angle is MISSING and radians is not None:
                angle = number(radians) * 180 / math.pi
            index = field(entry, "index", "frameIndex", default=n)
            close(index, n, "frame index", 0)
        require(isinstance(name, str) and "\\" not in name, "Frame path must be a relative portable path")
        relative = PurePosixPath(name)
        require(not relative.is_absolute() and ".." not in relative.parts, "Unsafe manifest path")
        require(str(relative) == "frame_%04d.png" % n, "Expected frame_%04d.png in manifest order" % n)
        close(angle, 360*n/count, "frame angle", 0.002)
        image = path.parent / str(relative)
        require(image.is_file() and not image.is_symlink(), "Missing/non-regular frame " + name)
        paths.append(image)
    actual = {p.name for p in path.parent.glob("frame_*.png")}
    require(actual == {p.name for p in paths}, "Extra or missing numbered animation frames")
    return paths


def compare_rgb(a, b, tolerance=1):
    require(len(a) == len(b), "RGB buffer lengths differ")
    maximum = max((abs(x-y) for x,y in zip(a,b)), default=0)
    require(maximum <= tolerance, "Decoded RGB max difference %d exceeds %d" % (maximum, tolerance))
    return {"max_channel_difference": maximum}


def same_view(a, b):
    """Different CLI modes may use different deterministic AA/jitter sequences.

    Only identical-parameter repeat tests impose the task's max-channel <=1 rule.
    Equivalent-angle/mode comparisons tolerate sparse AA/numerical differences.
    """
    require(len(a) == len(b), "View RGB buffer lengths differ")
    histogram = [0]*256
    for x,y in zip(a,b):
        histogram[abs(x-y)] += 1
    mean = sum(i*n for i,n in enumerate(histogram))/max(1,len(a))
    large_fraction = sum(histogram[25:])/max(1,len(a))
    require(mean <= 4 and large_fraction <= 0.035,
            "Equivalent angle/mode views differ: mean=%.3f, fraction >24=%.4f" % (mean,large_fraction))
    return {"mean_channel_difference": mean, "fraction_channel_difference_over_24": large_fraction}


def frame_change(a, b):
    # A regular subsample is enough for the change/seam sanity check, NOT equality.
    values = [abs(a[i]-b[i]) for i in range(0, len(a), 39)]
    return sum(values)/len(values)


def animation_changes(buffers):
    changes = [frame_change(buffers[i], buffers[(i+1) % len(buffers)]) for i in range(len(buffers))]
    require(min(changes) > 0.015, "Adjacent/loop-end frames are identical or effectively frozen")
    require(changes[-1] <= max(changes[:-1])*4 + 1, "Loop seam is implausibly larger than interior steps")
    # Non-adjacent duplicates are legal: P5 has rotational symmetries.
    return {"min_adjacent_mean_difference": min(changes), "max_adjacent_mean_difference": max(changes),
            "loop_mean_difference": changes[-1]}


def dilate(mask, n, radius=2):
    out = bytearray(len(mask))
    for i, v in enumerate(mask):
        if v:
            x,y = i % n, i // n
            for yy in range(max(0,y-radius), min(n,y+radius+1)):
                for xx in range(max(0,x-radius), min(n,x+radius+1)):
                    out[yy*n+xx] = 1
    return out


def iou(a, b):
    return sum(bool(x and y) for x,y in zip(a,b)) / max(1, sum(bool(x or y) for x,y in zip(a,b)))


def solve(matrix, rhs):
    a = [list(row)+[v] for row,v in zip(matrix,rhs)]
    for i in range(len(a)):
        j = max(range(i,len(a)), key=lambda j: abs(a[j][i]))
        a[i],a[j] = a[j],a[i]
        require(abs(a[i][i]) > 1e-9, "Cannot estimate smooth background")
        scale = a[i][i]; a[i] = [v/scale for v in a[i]]
        for j in range(len(a)):
            if i != j:
                scale = a[j][i]; a[j] = [x-scale*y for x,y in zip(a[j],a[i])]
    return [row[-1] for row in a]


def silhouette(rgb, width, n):
    pixels = []
    basis = []
    for y in range(n):
        for x in range(n):
            # Average a small patch to reduce AA/quantization, without rescaling a candidate output.
            cx,cy = int((x+0.5)*width/n), int((y+0.5)*width/n)
            points = [((max(0,min(width-1,cy+dy))*width+max(0,min(width-1,cx+dx)))*3) for dx,dy in ((0,0),(-1,0),(0,-1),(-1,-1))]
            pixels.append(tuple(sum(rgb[p+c] for p in points)/4 for c in range(3)))
            xx,yy = (x+0.5)/n, (y+0.5)/n
            basis.append((1,xx,yy,xx*xx,xx*yy,yy*yy))
    border = [y*n+x for y in range(n) for x in range(n) if x < 3 or y < 3 or x >= n-3 or y >= n-3]
    matrix = [[sum(basis[i][j]*basis[i][k] for i in border) for k in range(6)] for j in range(6)]
    coeff = [solve(matrix, [sum(basis[i][j]*pixels[i][c] for i in border) for j in range(6)]) for c in range(3)]
    residual = [max(abs(p[c]-sum(v*k for v,k in zip(basis[i],coeff[c]))) for c in range(3)) for i,p in enumerate(pixels)]
    median = statistics.median(residual[i] for i in border)
    mad = statistics.median(abs(residual[i]-median) for i in border)
    threshold = max(7, median + 7*mad + 3)
    require(threshold <= 35, "Background not reliably separable by the automatic smooth-background estimator; needs visual review")
    mask = bytearray(int(d > threshold) for d in residual)
    return mask, pixels, threshold


def geometry(rgb, width, ref5, ref8, n=128):
    mask, pixels, threshold = silhouette(rgb, width, n)
    area = sum(mask)
    require(0.06*n*n < area < 0.8*n*n, "Blank, tiny, or frame-filling subject")
    expanded_ref, expanded_mask = dilate(ref5,n), dilate(mask,n)
    precision = sum(bool(a and b) for a,b in zip(mask,expanded_ref))/max(1,area)
    recall = sum(bool(a and b) for a,b in zip(ref5,expanded_mask))/max(1,sum(ref5))
    score5,score8 = iou(mask,ref5),iou(mask,ref8)
    require(precision >= 0.90 and recall >= 0.90 and score5 >= 0.82,
            "Power-5/camera silhouette mismatch: IoU=%.3f precision=%.3f recall=%.3f" % (score5,precision,recall))
    # Negative hypotheses prevent a merely plausible rounded fractal from passing.
    require(score5 >= score8 + 0.018, "Geometry does not distinguish power=5 from power=8: %.3f vs %.3f" % (score5,score8))
    disk_score = 0
    for radius in range(n//6, n//2):
        disk = [(x+0.5-n/2)**2+(y+0.5-n/2)**2 < radius*radius for y in range(n) for x in range(n)]
        disk_score = max(disk_score, iou(mask,disk))
    require(score5 >= disk_score + 0.018, "Subject silhouette is not distinguishable from an ordinary sphere/disk")
    rim = sum(mask[y*n+x] for y in range(n) for x in range(n) if x < 2 or y < 2 or x >= n-2 or y >= n-2)
    require(rim <= 0.005*area, "Subject appears clipped at image border")
    foreground = [p for p,m in zip(pixels,mask) if m]
    colors = {tuple(int(v)//4 for v in p) for p in foreground}
    luminance = sorted(0.2126*p[0]+0.7152*p[1]+0.0722*p[2] for p in foreground)
    spread = luminance[int(0.95*(len(luminance)-1))]-luminance[int(0.05*(len(luminance)-1))]
    require(len(colors) >= 32 and spread >= 12, "Subject lacks measurable shading/color detail (flat silhouette or washed out)")
    return {"iou_power5": score5, "iou_power8": score8, "best_disk_iou": disk_score,
            "tolerant_precision": precision, "tolerant_recall": recall,
            "foreground_fraction": area/(n*n), "background_threshold": threshold,
            "quantized_foreground_colors": len(colors), "luminance_90pct_range": spread}
