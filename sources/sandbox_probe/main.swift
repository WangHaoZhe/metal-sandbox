import Foundation
import Darwin
import SandboxCore

// Owned helper: signed with app-sandbox + inherit by the bundle assembler.
// It reports only access results/errno, never the contents of a denied canary.
struct Access: Codable { var allowed: Bool; var error: Int32 }
struct Probe: Codable {
    var home = NSHomeDirectory()
    var pid = getpid()
    var uid = getuid()
    var files: [String: Access] = [:]
    var connect: Access?
    var connections: [String: Access] = [:]
    var extraDescriptors: [Int32] = []
}
func run() throws {
    var args = Array(CommandLine.arguments.dropFirst()), result = Probe()
    for fd: Int32 in 3..<256 { if fcntl(fd, F_GETFD) >= 0 { result.extraDescriptors.append(fd) } }
    while !args.isEmpty {
        let option = args.removeFirst()
        guard !args.isEmpty else { throw SandboxError("missing probe argument") }
        let value = args.removeFirst()
        switch option {
        case "--file":
            for (mode, flags) in [("read", O_RDONLY), ("write", O_WRONLY)] {
                let fd = open(value, flags | O_NOFOLLOW | O_CLOEXEC)
                result.files[mode + ":" + value] = Access(allowed: fd >= 0, error: fd >= 0 ? 0 : errno)
                if fd >= 0 { close(fd) }
            }
        case "--port":
            guard let port = UInt16(value), port > 0 else { throw SandboxError("invalid loopback port") }
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            if fd < 0 { result.connect = Access(allowed: false, error: errno); continue }
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let success = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            result.connect = Access(allowed: success == 0, error: success == 0 ? 0 : errno)
        case "--unix":
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { result.connections["unix"] = Access(allowed: false, error: errno); continue }
            defer { close(fd) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bytes = Array(value.utf8) + [0]
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SandboxError("unix probe path too long") }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let rc = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            result.connections["unix"] = Access(allowed: rc == 0, error: rc == 0 ? 0 : errno)
        case "--ipv6-port", "--udp-port":
            guard let port = UInt16(value), port > 0 else { throw SandboxError("invalid port") }
            let ipv6 = option == "--ipv6-port"
            let fd = socket(ipv6 ? AF_INET6 : AF_INET, ipv6 ? SOCK_STREAM : SOCK_DGRAM, 0)
            let label = ipv6 ? "ipv6" : "udp"
            guard fd >= 0 else { result.connections[label] = Access(allowed: false, error: errno); continue }
            defer { close(fd) }
            let rc: Int32
            if ipv6 {
                var address = sockaddr_in6()
                address.sin6_family = sa_family_t(AF_INET6); address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                address.sin6_port = port.bigEndian; address.sin6_addr = in6addr_loopback
                rc = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            } else {
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_port = port.bigEndian; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
                var byte: UInt8 = 0
                rc = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Int32(sendto(fd, &byte, 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))) }
                }
            }
            result.connections[label] = Access(allowed: rc >= 0, error: rc >= 0 ? 0 : errno)
        default: throw SandboxError("unknown probe option")
        }
    }
    FileHandle.standardOutput.write(try JSON.data(result))
    FileHandle.standardOutput.write(Data([10]))
}
do { try run() }
catch {
    FileHandle.standardError.write(Data("sandbox-probe: \(error)\n".utf8))
    exit(1)
}
