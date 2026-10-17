import Foundation
import Darwin

@main struct SchedulingPeerCheck {
    static func main() throws {
        guard getuid() != 0 else { fatalError("Run this authentication test without administrator privileges") }
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("battery-peer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("fake.sock").path
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { fatalError("Cannot create test listener") }
        defer { Darwin.close(listener) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 1) == 0 else { fatalError("Cannot bind test listener") }
        let finished = DispatchSemaphore(value: 0), accepted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { fatalError("No client connection") }
            defer { Darwin.close(fd); accepted.signal() }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var byte: UInt8 = 0
            guard Darwin.read(fd, &byte, 1) == 0 else { fatalError("Client sent data to a non-root peer") }
        }
        let client = SchedulingControlClient(testPath: path)
        client.exchange([.init(pid: 12345, started: 99)]) { result in
            guard case .failure(let error) = result, (error as? POSIXError)?.code == .EACCES else { fatalError("A non-root server must be rejected") }
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 5) == .success, accepted.wait(timeout: .now() + 5) == .success else { fatalError("Authentication check timed out") }
        client.close()
        print("Scheduling IPC: a spoofed unprivileged server is rejected before receiving any target data.")
    }
}
