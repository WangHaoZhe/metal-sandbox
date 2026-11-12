# Public Self-Test Tools

These tools provide input generation and CPU numerical references only, without a GPU solution or independent Verifier.

## Build

```sh
clang++ -std=c++17 -O2 public_tools.cpp -o public_tools
./public_tools selftest
```

## File Format

Inputs, references, and GPU outputs for comparison are headerless little-endian RGBA float32 binaries. Pixels are row-major, with (0,0) at the top left. Each pixel contains R,G,B,A in 16 bytes, for exactly width*height*16 bytes. Input RGB is linear HDR [0,8] and alpha is 1. Floating-point output is not PNG. Remove any bytesPerRow alignment padding from Metal readback before writing files.

## Commands

```sh
# generate WIDTH HEIGHT SEED CASE OUTPUT
./public_tools generate 1920 1080 1 random input.rgba32f
# reference WIDTH HEIGHT INPUT OUTPUT
./public_tools reference 17 13 fixtures/17x13_edge_input.rgba32f expected.rgba32f
# compare WIDTH HEIGHT EXPECTED ACTUAL
./public_tools compare 17 13 expected.rgba32f gpu_output.rgba32f
```

CASE is black, constant, center, edge, or random. black is entirely black; constant is RGB=(2,1,0.5); center has one central pixel (8,6,4); edge has one top-left pixel (8,6,4); all other pixels are black. random uses deterministic gradients, bright spots, and perturbations defined in the source. Alpha is always 1. Seeds are uint32, and public cases use seed=1.

`compare` checks file length, NaN/Inf, maximum absolute RGB error <=0.002, and alpha error from 1 <=0.002. It exits 0 on pass, 2 for numerical mismatch, and 1 for input errors. Do not submit reference files as actual GPU output.

`fixtures/manifest.json` lists five case types for each of 1x1, 17x13, and 257x129. For `./run.sh verify`, read every input, execute the complete real GPU pipeline, export floating-point results, and compare every case. benchmark uses 1920x1080 random inputs with seeds 1 through 8, which may be generated before timing. Do not generate processed outputs before timing.
