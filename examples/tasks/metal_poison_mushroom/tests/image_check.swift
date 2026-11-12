// CPU-only verifier helper: ImageIO decoding and an independent geometric oracle.
// It never loads candidate code, creates a Metal device, or writes outside argv paths.
import Foundation
import CoreGraphics
import ImageIO
import simd

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}
func loadJSON(_ path: String) throws -> [[String: Any]] {
    guard let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [[String: Any]] else {
        fail("Expected a JSON array")
    }
    return rows
}

func decode(_ row: [String: Any], inspectOnly: Bool = false) throws {
    guard let input = row["input"] as? String,
          let w = row["width"] as? Int, let h = row["height"] as? Int else { fail("Bad decode request") }
    let output = row["output"] as? String
    guard inspectOnly || output != nil else { fail("Missing decode output") }
    let data = try Data(contentsOf: URL(fileURLWithPath: input))
    let b = [UInt8](data.prefix(33))
    guard b.count == 33, Array(b[0..<8]) == [137,80,78,71,13,10,26,10],
          Array(b[12..<16]) == [73,72,68,82], b[24] == 8, [2,6].contains(b[25]) else {
        fail("Not an 8-bit RGB/RGBA PNG: \(input)")
    }
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(src) == 1,
          let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: true] as CFDictionary),
          img.width == w, img.height == h else { fail("PNG decode/size failure: \(input)") }
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    let ok = rgba.withUnsafeMutableBytes { bytes -> Bool in
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: bytes.baseAddress, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
        ctx.setBlendMode(.copy)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { fail("Cannot create decode context") }
    var rgb = [UInt8]()
    if !inspectOnly { rgb.reserveCapacity(w * h * 3) }
    for i in stride(from: 0, to: rgba.count, by: 4) {
        guard rgba[i+3] == 255 else { fail("Non-opaque alpha in \(input)") }
        if !inspectOnly { rgb.append(contentsOf: rgba[i..<i+3]) }
    }
    if !inspectOnly, let output { try Data(rgb).write(to: URL(fileURLWithPath: output)) }
}

// Finite orbit: v0=0, update then check >2; exactly 32 updates allowed.
// Distance estimation only accelerates ray marching; no candidate formulas used.
func distance(_ p: SIMD3<Double>, _ power: Double) -> Double {
    var v = SIMD3<Double>(repeating: 0), derivative = 1.0, r = 0.0
    for _ in 0..<32 {
        if r == 0 {
            v = p; derivative = 1
        } else {
            let theta = acos(min(1, max(-1, v.z / r)))
            let phi = (v.x == 0 && v.y == 0) ? 0 : atan2(v.y, v.x)
            let radial = pow(r, power)
            derivative = power * pow(r, power - 1) * derivative + 1
            v = radial * SIMD3<Double>(sin(power*theta)*cos(power*phi),
                                       sin(power*theta)*sin(power*phi), cos(power*theta)) + p
        }
        r = simd_length(v)
        if r > 2 { return max(0, 0.5 * log(r) * r / derivative) }
    }
    return 0
}

func oracle(_ row: [String: Any]) throws {
    guard let output = row["output"] as? String, let n = row["size"] as? Int,
          let degrees = row["angle"] as? Double, let power = row["power"] as? Double else { fail("Bad oracle request") }
    let a = degrees * .pi / 180
    let eye = SIMD3<Double>(3*cos(a)+4*sin(a), 3*sin(a)-4*cos(a), 2.5)
    let forward = simd_normalize(-eye)
    let right = simd_normalize(simd_cross(forward, SIMD3<Double>(0,0,1)))
    let up = simd_cross(right, forward), f = tan(35 * Double.pi / 360)
    var mask = [UInt8](repeating: 0, count: n*n)
    for y in 0..<n {
        for x in 0..<n {
            let u = (2*(Double(x)+0.5)/Double(n)-1)*f
            let v = (1-2*(Double(y)+0.5)/Double(n))*f
            let ray = simd_normalize(forward + u*right + v*up)
            let b = simd_dot(eye, ray), c = simd_dot(eye, eye)-4
            let discriminant = b*b-c
            if discriminant < 0 { continue }
            var t = max(0, -b-sqrt(discriminant))
            let end = -b+sqrt(discriminant)
            for _ in 0..<768 {
                let d = distance(eye+t*ray, power)
                if d < 0.0007 { mask[y*n+x] = 1; break }
                t += max(0.0001, d*0.8)
                if t > end { break }
            }
        }
    }
    try Data(mask).write(to: URL(fileURLWithPath: output))
}

do {
    guard CommandLine.arguments.count == 3 else { fail("Usage: image_check decode|inspect|oracle plan.json") }
    for row in try loadJSON(CommandLine.arguments[2]) {
        switch CommandLine.arguments[1] {
        case "decode": try decode(row)
        case "inspect": try decode(row, inspectOnly: true)
        case "oracle": try oracle(row)
        default: fail("Unknown operation")
        }
    }
} catch { fail("\(error)") }
