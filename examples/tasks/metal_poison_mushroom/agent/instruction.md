# Poison-Mushroom Rendering: Fifth-Order Mandelbulb (Native Metal)

## 1. Goal and Environment

Render a three-dimensional **power=5 Mandelbulb** on the GPU with native Metal, automatically rotating it and producing offscreen static PNGs and an animation frame sequence. This defines the task's fifth-order poison mushroom, rather than five iterations, five model layers, or a manually assembled mushroom cap and stem.

- Environment: macOS and Apple Silicon. Host code may use Swift, Objective-C, Objective-C++, or C++; shaders use Metal Shading Language.
- No windows, App bundles, mouse, screenshots, display, or GUI interaction are needed. Build, render, and save files from the command line.
- Do not implement a webpage, HTTP/WebSocket service, or other frontend in this task. Retain angle-control and frame-sequence interfaces for a separate future frontend.
- **There is no frame-rate requirement.** Prioritize algorithm, visual quality, and reproducibility.
- No reference implementation or standard answer image is supplied. Verification uses the mathematical definition, source, and actual rendered outputs below.

## 2. Mathematical Definition

Use this spherical-coordinate power convention, with all angles in radians. For v=(x,y,z), when r=||v||>0:

```text
theta = acos(clamp(z / r, -1, 1))    # Polar angle measured from world +Z
phi   = atan2(y, x)                 # XY azimuth; defined as 0 when x=y=0

P5(v) = r^5 * (sin(5*theta)*cos(5*phi),
               sin(5*theta)*sin(5*phi),
               cos(5*theta))
```

Define P5(0,0,0)=(0,0,0) separately to avoid division by zero or undefined angles. For each world-space sample point p:

```text
v_0 = (0,0,0)
v_(k+1) = P5(v_k) + p
```

The set of points with bounded orbits under infinite iteration is the Mandelbulb used here. Render this fixed finite approximation:

- **power=5**, without substitution by the common power=8 or any other power.
- Maximum **32** iterations: compute v_1 through v_32 in order and check escape after every update.
- Escape radius **2.0**: stop iteration once ||v_k||>2.0. Equality to 2.0 does not escape.
- Points not escaping within 32 iterations belong to the finite approximate solid. Render its exterior surface, not only a 2D slice or escape-count plane.

Distance estimation, ray marching, or other native Metal intersection methods with numerical tolerance are allowed. Explain approximation, intersection tolerance, iteration/step limits, and normal computation. Do not substitute the target by changing the power, reducing the specified fractal iteration limit, smoothing into a sphere, or adding a mushroom model. No CPU reference solver or large verification framework is required.

## 3. Fixed Scene and Visual Output

The default static verification image uses these settings. Animation automatically follows the fixed orbit in the next section without scaling the model:

| Item | Requirement |
| --- | --- |
| Image | 1024×1024 PNG, 8-bit RGB or RGBA; alpha, if present, is always 255 |
| World coordinates | Fractal origin (0,0,0), without extra rotation, translation, or scaling; +Z is up |
| Camera position | (3.0,-4.0,2.5) |
| Target | (0,0,0) |
| Camera reference up | (0,0,1), orthogonalized to make world up appear upward in the image, without additional roll |
| Projection | Perspective, vertical field of view 35°, aspect ratio from actual output width/height |
| Randomness | Fix seed=0 for jitter, random sampling, or random colors; do not depend on current time |

- Show the entire subject without cropping, with recognizable 3D volume, repeated lobes, and multiscale surface details. Blank images, flat silhouettes, ordinary spheres, or planar textures are insufficient.
- Materials and colors are flexible but require surface-normal-based lighting to make relief and depth clear. Distinguish background from subject without extra models, text, or UI obscuring it.
- Choose, fix, and record lighting, material, sample count, and tone mapping. Explain conversion from linear color to PNG display color, avoiding obvious aliasing, holes, banding, or overexposure hiding structure.
- Antialiasing and higher-resolution sampling are allowed, but do not enlarge a lower-resolution render to impersonate the required resolution.

### Automatic Rotation

Rotate by orbiting the camera around world +Z while leaving the fractal's mathematical definition unchanged. For angle a in radians:

```text
camera(a) = (3*cos(a) + 4*sin(a), 3*sin(a) - 4*cos(a), 2.5)
target = (0,0,0), reference_up = (0,0,1)
```

Support static `--angle-degrees`, defaulting to 0 and the original camera in the table. Provide an automatic animation mode that updates camera parameters in one program run and rerenders every frame through Metal. Deliver **512×512, 120 frames, one full 360°** rotation, with frame n at `360*n/120` degrees (n=0…119). Do not repeat the first frame at the end; the sequence must loop.

Do not rotate, translate, or distort a static image in 2D as a substitute for 3D rotation, duplicate frames, or use prerecorded animation. Reuse the GPU device, queue, and pipelines during animation. The suggested playback rate is 24 frames/second for a future player timeline, **not a rendering-performance threshold**; real-time rendering at that rate is unnecessary.

## 4. GPU Implementation Boundaries

- Fractal iteration, surface intersection/generation, normals, and subject shading must execute in your own Metal shaders. Compute or offscreen render pipelines are allowed without a fixed number of passes.
- The CPU handles parameters, building, resource/command organization, synchronization, readback, and PNG encoding. It must not render the main fractal on the CPU and use Metal only to copy or display the result.
- Do not replace the core algorithm with OpenGL, WebGL, software renderers, SceneKit, third-party engines, ready-made fractal renderers, or premade meshes/images. Do not use MPS or Core Image for the core rendering. System ImageIO/CoreGraphics may encode PNGs.
- Every run must execute GPU rendering again. Do not read cached finished images, download images, or deliver screenshots. Building and rendering depend only on retained source and system SDKs, without online services or interactive input.
- Wait for GPU completion and check command errors before readback. Do not silently accept failed or uninitialized results or NaN/Inf as successful images.

## 5. Command-Line Entry and Deliverables

Provide executable `run.sh`, runnable directly in the task workspace. First invocation may build automatically without the full Xcode GUI. Support at least these commands; `--output` is a PNG path whose parent directory must be created if absent:

```sh
./run.sh --width 1024 --height 1024 --output output/mandelbulb.png
./run.sh --width 1024 --height 1024 --output output/repeat.png
./run.sh --width 512 --height 512 --output output/small.png
./run.sh --width 512 --height 512 --angle-degrees 45 --output output/angle_45.png
./run.sh --width 512 --height 512 --frames 120 --output-dir output/rotation
```

Use the same algorithm and camera parameters across resolutions. Compiler, GPU execution, or file-write failures must return nonzero and preserve or emit real error logs. `run.sh` is the renderer entry, not a way to restart the task environment's agent.

Animation outputs `frame_0000.png` through `frame_0119.png` and `output/rotation/manifest.json`. The manifest includes at least dimensions, frame count, suggested playback rate, rotation axis and orbit formula, ordered relative image paths, and every frame's angle. Avoid machine-specific absolute paths so exported results can integrate with a frontend. `--frames N` must support variable counts and a full rotation at `360*n/N`. Do not restart the process or recompile shaders for each frame.

Retain and deliver:

- Host source, separate `.metal` shader source, `run.sh`, and necessary build configuration, not binaries or PNGs alone.
- The four static PNGs above, matching JSON metadata for each, and the complete animation sequence and manifest, such as `output/mandelbulb.json` and `output/rotation/manifest.json`.
- JSON records at least actual dimensions, power, maximum fractal iterations, escape radius, camera parameters, sample count, seed (null if randomness is unused), intersection method and tolerance/limits, lighting/material/color-conversion parameters, GPU model, macOS, and toolchain versions.
- `README.md`: source build/run instructions, GPU pipeline and mathematical conventions, static-angle/automatic-rotation interfaces, numerical approximations and limitations, actual completion, and repeated-render comparison results. Actual rendering duration may be recorded but establishes no performance threshold. Do not fabricate unexecuted data.

Source, logs, documentation, and output must exclude API keys, account configuration, and personal credentials.

## 6. Verification and Reproducibility

Verify in this order, without subjective similarity to an unknown reference image:

1. **Independent reproduction:** run the commands above from retained source without GUI interaction, producing correctly sized, decodable PNGs and corresponding metadata.
2. **Algorithm and native GPU:** inspect source and actual execution to confirm power=5, spherical-coordinate convention, 32 iterations/radius 2.0 escape rules, and GPU fractal/shading computation. Metadata cannot replace implementation evidence.
3. **Visual results:** check complete composition, 3D fractal structure, lighting, and detail against Section 3. A mushroom-like appearance alone does not establish algorithm correctness. No fixed colors or traditional cap/stem shape are required.
4. **Repeatability:** render twice on the same machine with the same build and parameters. Maximum absolute difference in each decoded RGB channel must not exceed one 8-bit level. PNG compression bytes and metadata times need not match. Pixelwise equality across GPUs or toolchains is unnecessary.
5. **Automatic rotation:** all 120 frames exist and loop in manifest order. Camera parameters follow the orbit, with changing 3D structure and occlusion. Verify that different angles execute Metal again rather than copying images or rotating in 2D. The 45° single-frame interface also works independently.
6. **Completeness:** 512×512 output must also be freshly rendered. Source, static PNGs, animation, metadata, and documentation are complete, and known defects are reported honestly. No FPS, benchmark, webpage, or other GUI deliverables are required.
