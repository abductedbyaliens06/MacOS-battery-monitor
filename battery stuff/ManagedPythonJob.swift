import Foundation

nonisolated struct ManagedPythonJob: Sendable {
    var interpreter: URL
    var script: URL
    var directory: URL
    var arguments: [String]
    func validate() throws {
        let manager = FileManager.default
        let resolved = interpreter.resolvingSymlinksInPath()
        let name = resolved.lastPathComponent.lowercased()
        guard name.range(of: "^python(3([.][0-9]+)*)?$", options: .regularExpression) != nil,
              manager.isExecutableFile(atPath: interpreter.path),
              (try resolved.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw ManagedJobError.invalid("Choose an executable Python interpreter, not a shell, command string or shim.")
        }
        let file = try FileHandle(forReadingFrom: resolved); defer { try? file.close() }
        let magic = Array(try file.read(upToCount: 4) ?? Data())
        let binaries: [[UInt8]] = [[0xcf,0xfa,0xed,0xfe], [0xfe,0xed,0xfa,0xcf], [0xca,0xfe,0xba,0xbe], [0xbe,0xba,0xfe,0xca], [0xca,0xfe,0xba,0xbf], [0xbf,0xba,0xfe,0xca]]
        guard binaries.contains(magic), script.pathExtension.lowercased() == "py",
              (try script.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
              manager.isReadableFile(atPath: script.path),
              (try directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
              arguments.count <= 256, arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4096 }),
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 65536 else {
            throw ManagedJobError.invalid("Select a native Python interpreter, readable .py script and working folder. Arguments must be literal strings within the size limit.")
        }
    }
    var launchArguments: [String] { ["-u", "--", script.path] + arguments }
}
nonisolated enum ManagedJobError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let text): return text } }
}

/// Bounded draining prevents a verbose child from blocking on a full pipe or
/// growing the menu bar app's memory. Output is never persisted or exported.
nonisolated final class ManagedJobOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var omitted = 0
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        let available = max(0, 32768 - bytes.count)
        bytes.append(data.prefix(available)); omitted += max(0, data.count - available)
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        let result = String(decoding: bytes, as: UTF8.self)
        return result + (omitted > 0 ? "\n[Additional output omitted]" : "")
    }
}

nonisolated private final class ManagedJobCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var closed: Set<Int> = []
    private var status: Int32?
    private var delivered = false
    private let completion: @Sendable (Int32) -> Void
    init(_ completion: @escaping @Sendable (Int32) -> Void) { self.completion = completion }
    func update(closed stream: Int? = nil, status: Int32? = nil) {
        lock.lock()
        if let stream { closed.insert(stream) }
        if let status { self.status = status }
        let result = !delivered && closed.count == 2 ? self.status : nil
        if result != nil { delivered = true }
        lock.unlock()
        if let result { completion(result) }
    }
}

/// No shells, hardware APIs, priority changes, process adoption or signals.
/// Only a user-selected Python script can be launched by this executor.
nonisolated final class ManagedPythonExecution: @unchecked Sendable {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    let output = ManagedJobOutput()
    func start(_ job: ManagedPythonJob, completion: @escaping @Sendable (Int32) -> Void) throws -> Int32 {
        try job.validate()
        process.executableURL = job.interpreter
        process.arguments = job.launchArguments
        process.currentDirectoryURL = job.directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout; process.standardError = stderr
        let output = output
        let completed = ManagedJobCompletion(completion)
        for (index, pipe) in [stdout, stderr].enumerated() {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; completed.update(closed: index) } else { output.append(data) }
            }
        }
        process.terminationHandler = { process in completed.update(status: process.terminationStatus) }
        do { try process.run() }
        catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        return process.processIdentifier
    }
}
