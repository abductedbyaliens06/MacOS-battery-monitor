import AppKit
import SwiftUI

@main struct OptimizerIntegrationCheck {
    @MainActor static func check(_ value: Bool, _ message: String) {
        guard value else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    @MainActor static func wait(_ condition: @escaping () -> Bool) async {
        let end = ProcessInfo.processInfo.systemUptime + 6
        while !condition(), ProcessInfo.processInfo.systemUptime < end { try? await Task.sleep(for: .milliseconds(25)) }
        check(condition(), "Owned fixture jobs must finish within the test deadline")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let python = URL(fileURLWithPath: CommandLine.arguments[1])
        let preview = URL(fileURLWithPath: CommandLine.arguments[2])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("optimizer-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fixture.py")
        try Data("import sys,time,json\nprint(json.dumps(sys.argv[1:]),flush=True)\ntime.sleep(0.4)\nprint('FINAL-OUTPUT',flush=True)\n".utf8).write(to: script)
        let marker = directory.appendingPathComponent("should-not-exist")
        let args = ["hello world", "$(touch \(marker.path))", "; touch \(marker.path)", "-c", "private-argument-marker"]
        let configuration = ManagedPythonJob(interpreter: python, script: script, directory: directory, arguments: args)
        try configuration.validate()
        let bad = ManagedPythonJob(interpreter: URL(fileURLWithPath: "/bin/sh"), script: script, directory: directory, arguments: [])
        do { try bad.validate(); check(false, "Shell executables must be rejected") } catch {}
        var tooMany = configuration; tooMany.arguments = Array(repeating: "a", count: 257)
        do { try tooMany.validate(); check(false, "Oversized argument arrays must fail") } catch {}
        var nul = configuration; nul.arguments = ["bad\0arg"]
        do { try nul.validate(); check(false, "NUL arguments must fail") } catch {}

        let audit = directory.appendingPathComponent("audit.json")
        let optimizer = OptimizerService(battery: nil, study: nil, archiveURL: audit, startAutomatically: false)
        let adapter = OptimizerContext(power: .adapter, fresh: true)
        for name in ["Owned job A", "Owned job B", "Owned job C"] {
            optimizer.enqueue(label: name, priority: .urgent, configuration: configuration)
        }
        check(!optimizer.enabled && optimizer.runningCount == 0, "Enqueue never executes code")
        optimizer.limit = 2
        optimizer.startQueue(); optimizer.evaluate(adapter)
        check(optimizer.runningCount == 2, "Adapter concurrency cap applies to actual child launches")
        optimizer.pause()
        await wait { optimizer.runningCount == 0 }
        check(optimizer.records.filter { $0.state == .queued }.count == 1, "Pausing prevents another job from launching")
        check(optimizer.records.filter { $0.state == .completed }.count == 2, "Pausing lets running scripts finish")
        for record in optimizer.records where record.state == .completed {
            let output = optimizer.output(for: record.id)
            check(output.contains("FINAL-OUTPUT") && output.contains("private-argument-marker") && output.contains("$(touch"), "Output drains completely and arguments remain literal")
        }
        check(!FileManager.default.fileExists(atPath: marker.path), "Arguments never undergo shell expansion")
        optimizer.startQueue(); optimizer.evaluate(adapter)
        await wait { optimizer.runningCount == 0 }
        check(optimizer.records.allSatisfy { $0.state == .completed }, "Remaining explicit job completes")
        let saved = String(decoding: try Data(contentsOf: audit), as: UTF8.self)
        check(!saved.contains(script.path) && !saved.contains("private-argument-marker") && !saved.contains("FINAL-OUTPUT"), "Run archive excludes paths, arguments and output")

        let noisy = directory.appendingPathComponent("noisy.py")
        try Data("import sys\nprint('x'*100000,flush=True)\nsys.stderr.write('stderr finished\\n')\n".utf8).write(to: noisy)
        optimizer.enqueue(label: "Bounded output", priority: .urgent, configuration: .init(interpreter: python, script: noisy, directory: directory, arguments: []))
        optimizer.startQueue(); optimizer.evaluate(adapter)
        await wait { optimizer.runningCount == 0 }
        let noisyRecord = optimizer.records.first!
        let output = optimizer.output(for: noisyRecord.id)
        check(output.utf8.count < 33000 && output.contains("Additional output omitted"), "Verbose jobs cannot grow output storage unboundedly")
        check(noisyRecord.state == .completed, "Output capping must continue draining pipes")

        let failure = directory.appendingPathComponent("failure.py")
        try Data("import sys,time\ntime.sleep(0.1)\nsys.exit(7)\n".utf8).write(to: failure)
        optimizer.enqueue(label: "Expected fixture failure", priority: .urgent, configuration: .init(interpreter: python, script: failure, directory: directory, arguments: []))
        optimizer.enqueue(label: "Must remain queued", priority: .normal, configuration: configuration)
        optimizer.limit = 1; optimizer.startQueue(); optimizer.evaluate(adapter)
        await wait { optimizer.runningCount == 0 }
        check(!optimizer.enabled && optimizer.records.contains { $0.exitCode == 7 && $0.state == .failed }, "A failing script pauses dispatch")
        check(optimizer.records.contains { $0.label == "Must remain queued" && $0.state == .queued }, "Failure does not dispatch the next job")
        optimizer.startQueue()
        var stale = adapter; stale.fresh = false
        optimizer.evaluate(stale)
        check(optimizer.runningCount == 0, "Stale context never launches actual code")
        optimizer.pause()
        let restarted = OptimizerService(battery: nil, study: nil, archiveURL: audit, startAutomatically: false)
        check(!restarted.enabled && !restarted.hasPending && restarted.runningCount == 0, "Restart restores summaries only, never a running queue")
        let unknown = directory.appendingPathComponent("interrupted.json")
        try JSONEncoder().encode([ManagedJobRecord(label: "Prior interrupted run", priority: .urgent, state: .running)]).write(to: unknown)
        let recovered = OptimizerService(battery: nil, study: nil, archiveURL: unknown, startAutomatically: false)
        check(recovered.records.first?.state == .untracked && recovered.runningCount == 0 && !recovered.enabled, "An interrupted run is never adopted, signaled or rerun")

        let corruptURL = directory.appendingPathComponent("corrupt-run-log.json")
        let corruptBytes = Data("invalid audit".utf8); try corruptBytes.write(to: corruptURL)
        let corrupt = OptimizerService(battery: nil, study: nil, archiveURL: corruptURL, startAutomatically: false)
        corrupt.prepareForQuit()
        check(try Data(contentsOf: corruptURL) == corruptBytes, "Unreadable run logs are preserved")
        corrupt.clearFinished()
        check(try JSONDecoder().decode([ManagedJobRecord].self, from: Data(contentsOf: corruptURL)).isEmpty, "Explicit clear recovers an unreadable run log")

        let suite = "Optimizer.UI.\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let study = UsageStudyService(battery: nil, defaults: defaults, url: directory.appendingPathComponent("study.sqlite"), startAutomatically: false)
        optimizer.evaluate(adapter, advice: ["Editor: foreground work is protected; no changes applied."])
        for scheme in [ColorScheme.light, .dark] {
            let content = OptimizerView(optimizer: optimizer, study: study).padding(20)
                .frame(width: 440).fixedSize(horizontal: false, vertical: true)
                .frame(height: 1400, alignment: .top).clipped()
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: content); renderer.scale = 2
            guard let image = renderer.cgImage, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                check(false, "Optimizer layout must render"); return
            }
            try png.write(to: preview.appendingPathComponent(scheme == .dark ? "optimizer-dark.png" : "optimizer-light.png"))
        }
        print("Optimizer integration: explicit launch, concurrency, pause, failure, literal arguments, bounded output, audit privacy, restart and light/dark rendering passed. Only temporary fixture scripts ran.")
    }
}
