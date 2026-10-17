import Foundation
import Darwin

/// Single serialized local connection. The daemon must authenticate as root;
/// root independently pins this connection to the live app's PID and start time.
nonisolated final class SchedulingControlClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "BatteryMonitor.scheduling-connection", qos: .utility)
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var generation = 0
    var socketPath: String { "/var/run/battery-optimizer-\(getuid())-\(getpid()).sock" }
    func exchange(_ targets: [SchedulingTarget], completion: @escaping @Sendable (Result<SchedulingReply, Error>) -> Void) {
        lock.lock(); generation += 1; let token = generation; lock.unlock()
        queue.async { [self] in
            lock.lock(); let current = generation; lock.unlock()
            guard token == current else { return }
            do { completion(.success(try send(targets))) }
            catch { disconnect(); completion(.failure(error)) }
        }
    }
    func close() { queue.async { [self] in disconnect() } }
    private func disconnect() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
    private func send(_ targets: [SchedulingTarget]) throws -> SchedulingReply {
        guard targets.count <= 16 else { throw CocoaError(.validationMissingMandatoryProperty) }
        if fd < 0 {
            fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.ENOTCONN) }
            var timeout = timeval(tv_sec: 2, tv_usec: 0), one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let path = Array(socketPath.utf8) + [0]
            guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { throw POSIXError(.ENOTCONN) }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else { throw POSIXError(.EACCES) }
        }
        var data = try JSONEncoder().encode(SchedulingRequest(targets: targets)); data.append(10)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw POSIXError(.EIO) }; offset += n
            }
        }
        var input = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while input.count <= 32768 {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw POSIXError(.ENOTCONN) }
            input.append(contentsOf: buffer.prefix(n))
            if let newline = input.firstIndex(of: 10) {
                guard newline == input.index(before: input.endIndex) else { throw POSIXError(.EPROTO) }
                return try SchedulingReply.decode(input.prefix(upTo: newline))
            }
        }
        throw CocoaError(.fileReadTooLarge)
    }
}
