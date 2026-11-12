#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <time.h>

static double monotonicSeconds() {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1e9;
}

static NSString *timestamp() {
    return [[[NSISO8601DateFormatter alloc] init] stringFromDate:[NSDate date]];
}

static void emit(NSDictionary *record) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static int fail(const char *message, NSError *error = nil) {
    fprintf(stderr, "%s%s%s\n", message, error ? ": " : "", error ? error.description.UTF8String : "");
    return 1;
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 3) return fail("Usage: metal_queue LABEL SECONDS (5..60)");
    char *end = nullptr;
    const double seconds = strtod(argv[2], &end);
    if (!end || *end || !std::isfinite(seconds) || seconds < 5 || seconds > 60)
        return fail("SECONDS must be between 5 and 60");
    NSString *label = [NSString stringWithUTF8String:argv[1]];
    if (!label || label.length == 0 || label.length > 64) return fail("Invalid label");

    const double started = monotonicSeconds();
    NSString *startedAt = timestamp();
    emit(@{@"event": @"started", @"label": label, @"at": startedAt, @"monotonic_s": @(started)});
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return fail("No Metal device");
    // Runtime shader compilation: no offline metal/metallib build is needed.
    NSString *shader = [NSString stringWithUTF8String:R"(
        #include <metal_stdlib>
        using namespace metal;
        kernel void queue_work(device uint *values [[buffer(0)]],
                               uint i [[thread_position_in_grid]]) {
            uint x = values[i];
            for (uint round = 0; round < 64; ++round)
                x = (x ^ (x >> 16)) * 0x45d9f3bu;
            values[i] = x;
        }
    )"];
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:shader options:nil error:&error];
    if (!library) return fail("Metal shader compilation failed", error);
    id<MTLFunction> function = [library newFunctionWithName:@"queue_work"];
    if (!function) return fail("Missing Metal function");
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
    if (!pipeline) return fail("Metal pipeline creation failed", error);
    id<MTLCommandQueue> queue = [device newCommandQueue];
    const NSUInteger count = 262144;
    id<MTLBuffer> buffer = [device newBufferWithLength:count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
    if (!queue || !buffer) return fail("Metal allocation failed");
    auto *values = static_cast<uint32_t *>(buffer.contents);
    for (NSUInteger i = 0; i < count; ++i) values[i] = uint32_t(i + 1);
    const NSUInteger group = MIN(NSUInteger(256), pipeline.maxTotalThreadsPerThreadgroup);
    const double workStarted = monotonicSeconds();
    uint64_t dispatches = 0;
    double gpuSeconds = 0;
    // Real GPU dispatches, not sleep. Only one short command buffer is in flight.
    do { @autoreleasepool {
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        if (!command || !encoder) return fail("Command allocation failed");
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:buffer offset:0 atIndex:0];
        [encoder dispatchThreads:MTLSizeMake(count, 1, 1) threadsPerThreadgroup:MTLSizeMake(group, 1, 1)];
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted) return fail("Metal execution failed", command.error);
        if (command.GPUStartTime > 0 && command.GPUEndTime >= command.GPUStartTime)
            gpuSeconds += command.GPUEndTime - command.GPUStartTime;
        ++dispatches;
    }} while (monotonicSeconds() - workStarted < seconds);

    // Check readback against CPU arithmetic, without running the workload on CPU.
    const NSUInteger checks[] = {0, count / 2, count - 1};
    for (NSUInteger i : checks) {
        uint32_t expected = uint32_t(i + 1);
        for (uint64_t round = 0; round < dispatches * 64; ++round)
            expected = (expected ^ (expected >> 16)) * 0x45d9f3bu;
        if (values[i] != expected) return fail("GPU readback mismatch");
    }
    const double finished = monotonicSeconds();
    emit(@{@"event": @"finished", @"label": label, @"device": device.name,
           @"started_at": startedAt, @"finished_at": timestamp(),
           @"start_monotonic_s": @(started), @"end_monotonic_s": @(finished),
           @"elapsed_s": @(finished - started), @"gpu_s": @(gpuSeconds),
           @"dispatches": @(dispatches), @"correctness": @"PASS"});
    return 0;
}}
