# Metal Offscreen Gaussian Blur and Bloom Postprocessing

## 1. Goal

Implement Gaussian blur and Bloom postprocessing for HDR images with native Metal. Perform real GPU computation and offscreen rendering without windows, displays, or mouse input, export images, and optimize throughput and frame time.

The suggested time budget is 60 minutes. Prioritize correct implementation and reproducible execution. Report unfinished work honestly; do not fabricate performance to obtain a result.

## 2. Environment and Public Attachments

- Native macOS and Apple Silicon. Test on the actual machine and record GPU model, macOS, and toolchain versions.
- Host code may use Swift, Objective-C, Objective-C++, or C++; shaders use Metal Shading Language.
- No App bundle, window, interactive controls, or physical display is required.
- The public attachment public_tools.cpp provides a deterministic HDR input generator and a small-size CPU numerical reference. See public_tools.md for usage. Both are public self-test attachments; the agent need not design additional data or reference algorithms.
- Input uses linear-color RGBA float32, with RGB in [0, 8] and alpha 1. The generator accepts dimensions and an integer seed, with dark backgrounds, gradients, bright spots, and reproducible perturbations. Identical dimensions and seeds must produce identical inputs.
- Public correctness cases include black, constant, center/edge bright pixels, and fixed-seed inputs at sizes including 1×1, 17×13, and 257×129.

## 3. Required Algorithm

Let the original linear HDR image be I. Compute each RGB channel independently:

### Bright-Pass Extraction

B(x, y) = max(I(x, y) - 1.0, 0)

### Gaussian Blur

Fixed radius R = 15 and standard deviation sigma = 5.0. Discrete weights:

w(k) = exp(-k*k / (2*sigma*sigma)) / sum(exp(-j*j / (2*sigma*sigma)), j=-15…15)

Compute horizontally, then vertically:

H(x, y) = sum(w(k) * B(clamp(x+k), y), k=-15…15)

V(x, y) = sum(w(k) * H(x, clamp(y+k)), k=-15…15)

clamp clips coordinates to valid image boundaries; do not substitute wraparound or zero padding.

### Composition and Tone Mapping

C(x, y) = I(x, y) + 0.8 * V(x, y)

O(x, y) = C(x, y) / (1 + C(x, y))

Output alpha is 1. Numerical comparison uses floating-point O. Preview PNG RGB is round(255 * clamp(O, 0, 1)); do not include PNG quantization error in floating-point correctness checks.

## 4. GPU and Correctness Requirements

- Perform bright-pass extraction and blur in Metal compute shaders.
- Perform final composition and tone mapping through a Metal render pass into an offscreen texture; window presentation cannot substitute for the offscreen entry.
- The CPU may generate inputs, compute references, configure resources, and save files, but must not replace the measured pipeline's main computation.
- Do not call MPS, Core Image, vImage, or ready-made third-party filters as substitutes for the algorithm.
- Maximum absolute per-channel RGB error against the CPU reference must not exceed 0.002. NaN/Inf are forbidden, and dimensions must be correct.
- Optimize thread organization, memory layout, weight caching, texture access, and pass organization. Half precision is allowed if numerical requirements are met.
- Do not reduce resolution, radius, or frame counts, compute only some pixels, or cache processed outputs to skip repeated frames.

## 5. Command-Line Entry

Provide an executable run.sh. The first invocation may build; failures must return nonzero and preserve real compiler logs.

```sh
./run.sh verify
./run.sh render --width 1920 --height 1080 --seed 1 --output output/render
./run.sh benchmark --width 1920 --height 1080 --warmup 120 --frames 600 --output output/benchmark
```

- verify: run public small-size comparisons, report maximum error, and exit nonzero on failure.
- render: process one frame and output the input preview, final PNG, and result metadata. Numerical comparisons read GPU floating-point results rather than screenshots.
- benchmark: follow the fixed measurement procedure below and output per-frame data and summaries.
- The same algorithm must support the different sizes above. Do not output precomputed answers for specific seeds or filenames.

## 6. Performance Measurement

- Use fixed 1920×1080 resolution and execute the entire pipeline at full resolution.
- Generate and upload eight inputs with seeds 1…8 beforehand and cycle through them in order. Every frame must execute the complete processing again without reusing previous output.
- Compilation, pipeline creation, weight calculation, input upload, and resource allocation may finish before measurement. These one-time costs are excluded from steady-state frame time.
- Warm up for 120 frames, then measure 600 frames. Only one benchmark may use this project's sandbox execution resources during the test.
- To keep the initial measurement simple and comparable, allow only one frame in flight. Record end-to-end frame time with a monotonic clock, from before encoding GPU commands until after waiting for the whole frame to finish. Start the next frame only after the previous one completes.
- Save total measurement wall time. Equivalent FPS = actually completed frames / measured wall seconds; CPU submission frequency is not a substitute.
- Read GPU start/end timestamps from completed command buffers and record GPU duration separately. Explain the measurement definition for multiple buffers. If fields are unavailable, use null and explain rather than substituting CPU time.
- PNG export, disk logging, and CPU numerical checks are outside the timed interval. Do not precompute measured frames' processed outputs.
- Run benchmark at least three times and report every run, not only the fastest.

Optimization goal: after correctness passes, increase throughput and reduce end-to-end frame time, reporting real measurements for each iteration.

These measurements describe local offscreen-processing throughput and frame time.

## 7. Deliverables and Verification

Deliver:

- Host code, Metal shaders, run.sh, and required build configuration.
- Correctness results: dimensions, seed/case, maximum absolute error, and pass/fail.
- Rendered output: input-preview and Bloom-output PNGs.
- frames.jsonl: frame index, input seed, resolution, end-to-end frame time, and GPU duration.
- summary.json: environment, warmup/completed frames, measured wall time, equivalent FPS, frame-time median/p95/max, and correctness results.
- README: building and running from a clean directory, known limitations, and at least one actually attempted optimization with before/after measurements. Report optimizations without improvement honestly; do not invent unexecuted results.

Verification order: builds and runs → numerically correct GPU output → actual offscreen images → valid measurement methodology → performance and optimization process.

A full GUI, real-time interaction, network service, physical simulation, or complex visual design is unnecessary. Do not change algorithm parameters, tolerances, resolution, or measurement rules to meet requirements. Source and artifacts must exclude API keys and personal configuration.
