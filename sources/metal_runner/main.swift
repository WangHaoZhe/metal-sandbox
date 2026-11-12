import Foundation
import Metal
import Darwin
import SandboxCore

let defaultShader = """
#include <metal_stdlib>
using namespace metal;
kernel void vector_add(device const float *a [[buffer(0)]],
                       device const float *b [[buffer(1)]],
                       device float *out [[buffer(2)]],
                       constant uint &count [[buffer(3)]],
                       uint tid [[thread_position_in_grid]]) {
    if (tid < count) out[tid] = a[tid] + b[tid];
}
"""

func run() throws {
    if Array(CommandLine.arguments.dropFirst()) == ["--version"] { print(MetalSandboxVersion.current); return }
    if Array(CommandLine.arguments.dropFirst()) == ["--render-smoke"] { try renderSmoke(); return }
    var args = Array(CommandLine.arguments.dropFirst())
    var options: [String: String] = [:]
    while !args.isEmpty {
        let key = args.removeFirst()
        if key == "--help" {
            print("metal-runner --input FILE --output FILE --metrics FILE --count N --iterations N --warmup N --threadgroup N [--shader FILE]")
            return
        }
        guard ["--input", "--output", "--metrics", "--count", "--iterations", "--warmup", "--threadgroup", "--shader"].contains(key),
              !args.isEmpty, options[key] == nil else { throw SandboxError("invalid or duplicate option: \(key)") }
        options[key] = args.removeFirst()
    }
    func value(_ key: String) throws -> String {
        guard let value = options[key] else { throw SandboxError("missing \(key)") }; return value
    }
    func integer(_ key: String) throws -> Int {
        guard let result = Int(try value(key)) else { throw SandboxError("invalid \(key)") }; return result
    }
    let count = try integer("--count")
    let iterations = try integer("--iterations")
    let warmup = try integer("--warmup")
    let group = try integer("--threadgroup")
    guard (1...4_194_304).contains(count), (1...1000).contains(iterations),
          (0...100).contains(warmup), (1...1024).contains(group) else {
        throw SandboxError("count 1...4194304; iterations 1...1000; warmup 0...100; threadgroup 1...1024 required")
    }
    let input = try SafeFiles.readRegular(URL(fileURLWithPath: value("--input")), limit: count * 8)
    guard input.count == count * 8 else { throw SandboxError("wrong input size") }
    guard let device = MTLCreateSystemDefaultDevice() else { throw SandboxError("no native Metal device available") }
    guard let queue = device.makeCommandQueue() else { throw SandboxError("cannot create Metal command queue") }
    let shader: String
    if let path = options["--shader"] {
        let bytes = try SafeFiles.readRegular(URL(fileURLWithPath: path), limit: 1024 * 1024)
        guard let text = String(data: bytes, encoding: .utf8) else { throw SandboxError("shader must be UTF-8") }
        shader = text
    } else { shader = defaultShader }
    let library = try device.makeLibrary(source: shader, options: nil)
    guard let function = library.makeFunction(name: "vector_add") else { throw SandboxError("shader must define vector_add") }
    let pipeline = try device.makeComputePipelineState(function: function)
    guard group <= pipeline.maxTotalThreadsPerThreadgroup else { throw SandboxError("threadgroup exceeds pipeline limit") }
    let byteCount = count * MemoryLayout<Float>.size
    let buffers: (MTLBuffer?, MTLBuffer?) = input.withUnsafeBytes { bytes in
        (device.makeBuffer(bytes: bytes.baseAddress!, length: byteCount, options: .storageModeShared),
         device.makeBuffer(bytes: bytes.baseAddress!.advanced(by: byteCount), length: byteCount, options: .storageModeShared))
    }
    guard let a = buffers.0, let b = buffers.1,
          let output = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
        throw SandboxError("Metal allocation failed")
    }
    memset(output.contents(), 0, byteCount)
    var gpuSeconds: [Double] = []
    var submissionSeconds: [Double] = []
    for iteration in 0..<(warmup + iterations) {
        try autoreleasepool {
            let started = DispatchTime.now().uptimeNanoseconds
            guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
                throw SandboxError("cannot create command buffer or encoder")
            }
            command.label = "MetalSandbox vector smoke \(iteration)"
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(a, offset: 0, index: 0)
            encoder.setBuffer(b, offset: 0, index: 1)
            encoder.setBuffer(output, offset: 0, index: 2)
            var n = UInt32(count)
            encoder.setBytes(&n, length: MemoryLayout<UInt32>.size, index: 3)
            encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: group, height: 1, depth: 1))
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else { throw SandboxError("Metal command failed: \(String(describing: command.error))") }
            if iteration >= warmup {
                submissionSeconds.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9)
                let duration = command.gpuEndTime - command.gpuStartTime
                if duration.isFinite && duration > 0 { gpuSeconds.append(duration) }
            }
        }
    }
    try SafeFiles.writeData(Data(bytes: output.contents(), count: byteCount), to: URL(fileURLWithPath: value("--output")))
    let metrics = MetalDiagnostics(device: device.name, registryID: device.registryID, count: count,
                                   iterations: iterations, warmup: warmup, threadgroupSize: group,
                                   gpuSeconds: gpuSeconds, submissionSeconds: submissionSeconds)
    try SafeFiles.write(metrics, to: URL(fileURLWithPath: value("--metrics")))
    print("Metal smoke completed on \(device.name): \(count) elements, \(iterations) iterations; not a graphics FPS result.")
}

do { try run() }
catch {
    FileHandle.standardError.write(Data("metal-runner: \(error)\n".utf8))
    exit(1)
}
