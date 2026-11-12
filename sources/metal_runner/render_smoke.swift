import Foundation
import Metal
import SandboxCore

/// Offscreen correctness/compatibility probe, deliberately not an FPS benchmark.
func renderSmoke() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        throw SandboxError("native Metal device/queue unavailable")
    }
    let shader = """
    #include <metal_stdlib>
    using namespace metal;
    vertex float4 full_screen(uint id [[vertex_id]]) {
        const float2 p[] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
        return float4(p[id],0,1);
    }
    fragment float4 solid_color() { return float4(1,0,0.25,1); }
    """
    let library = try device.makeLibrary(source: shader, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "full_screen")
    descriptor.fragmentFunction = library.makeFunction(name: "solid_color")
    descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
    let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    let textureSpec = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 32, height: 32, mipmapped: false)
    textureSpec.storageMode = .shared; textureSpec.usage = .renderTarget
    guard let texture = device.makeTexture(descriptor: textureSpec) else { throw SandboxError("render texture allocation failed") }
    var timingSamples = 0
    for _ in 0..<1000 {
        try autoreleasepool {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            guard let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                throw SandboxError("render encoding failed")
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            guard command.status == .completed else { throw SandboxError("render command failed") }
            var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
            pixels.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: 32 * 4, from: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0)
            }
            for pixel in stride(from: 0, to: pixels.count, by: 4) {
                guard Array(pixels[pixel..<pixel+4]) == [255, 0, 64, 255] else { throw SandboxError("render readback mismatch") }
            }
            if command.gpuEndTime > command.gpuStartTime && command.gpuStartTime > 0 { timingSamples += 1 }
        }
    }
    struct Report: Codable {
        var device: String; var registryID: UInt64; var frames: Int; var timingSamples: Int
        var readbackCorrect: Bool
    }
    print(try JSON.string(Report(device: device.name, registryID: device.registryID, frames: 1000,
                               timingSamples: timingSamples, readbackCorrect: true)))
}
