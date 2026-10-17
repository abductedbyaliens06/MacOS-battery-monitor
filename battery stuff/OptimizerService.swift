import AppKit
import Combine
import CoreGraphics
import UniformTypeIdentifiers

@MainActor
final class OptimizerService: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var context = OptimizerContext()
    @Published private(set) var records: [ManagedJobRecord] = []
    @Published private(set) var message: String?
    @Published private(set) var preview: [String] = []
    @Published var limit = 1
    @Published var showDraft = false
    @Published var draftLabel = ""
    @Published var draftArguments = ""
    @Published var draftPriority: ManagedJobPriority = .flexible
    @Published private(set) var draftInterpreter: URL?
    @Published private(set) var draftScript: URL?
    @Published private(set) var draftDirectory: URL?
    var requestPopover: (() -> Void)?
    private weak var battery: BatteryService?
    private weak var study: UsageStudyService?
    private var auditWritable = true
    private let archiveURL: URL
    private var configurations: [UUID: ManagedPythonJob] = [:]
    private var executions: [UUID: ManagedPythonExecution] = [:]
    private var starts: [UUID: Double] = [:]
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false
    private var powerWindow = OptimizerPowerWindow()
    private var lastCompletion = -Double.infinity
    var runningCount: Int { executions.count }
    var hasPending: Bool { records.contains { $0.state == .queued } }

    init(battery: BatteryService?, study: UsageStudyService?, archiveURL: URL? = nil, startAutomatically: Bool = true) {
        self.battery = battery; self.study = study
        self.archiveURL = archiveURL ?? BatteryDataLocations.directory.appendingPathComponent("optimizer-runs-v1.json")
        if FileManager.default.fileExists(atPath: self.archiveURL.path) {
            do {
                let data = try Data(contentsOf: self.archiveURL)
                guard data.count < 256_000 else { throw CocoaError(.fileReadTooLarge) }
                let saved = try JSONDecoder().decode([ManagedJobRecord].self, from: data)
                guard saved.count <= 100, Set(saved.map(\.id)).count == saved.count,
                      saved.allSatisfy({ record in
                          !record.label.isEmpty && record.label.count <= 80
                          && record.added.timeIntervalSince1970.isFinite
                          && (record.duration.map { $0.isFinite && $0 >= 0 } ?? true)
                      }) else { throw CocoaError(.fileReadCorruptFile) }
                records = saved.filter { $0.state != .queued }.map {
                    var record = $0
                    if record.state == .running { record.state = .untracked; record.reason = "Prior run ended without a recorded completion. Never restarted automatically." }
                    return record
                }
            } catch {
                auditWritable = false
                message = "Saved optimizer summaries could not be read and are preserved. Clear finished summaries to reset this separate run log."
            }
        }
        guard startAutomatically else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = true; self?.tick() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = false; self?.tick() }
        })
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
    deinit {
        task?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    func enqueue(label: String, priority: ManagedJobPriority, configuration: ManagedPythonJob) {
        guard records.filter({ $0.state == .queued }).count < 20 else { message = "Queue limit reached (20 jobs)."; return }
        do {
            try configuration.validate()
            let name = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            guard !name.isEmpty else { throw ManagedJobError.invalid("Give this job a descriptive name.") }
            let record = ManagedJobRecord(label: name, priority: priority)
            configurations[record.id] = configuration
            records.insert(record, at: 0); trim(); message = "Job queued. Starting the queue requires a separate action."
            // Adding a job never executes it, even if the queue was already enabled.
            pause()
        } catch { message = error.localizedDescription }
    }
    func startQueue() { enabled = true; message = nil; tick() }
    func pause() { enabled = false; updateQueuedReasons() }
    func remove(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id && $0.state == .queued }) else { return }
        records[index].state = .removed; records[index].reason = "Removed before launch."
        configurations[id] = nil
    }
    func setPriority(_ priority: ManagedJobPriority, for id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id && $0.state == .queued }) else { return }
        records[index].priority = priority; updateQueuedReasons()
    }
    func output(for id: UUID) -> String { executions[id]?.output.text ?? completedOutput[id] ?? "" }
    private var completedOutput: [UUID: String] = [:]
    func clearFinished() {
        records.removeAll { $0.state != .running && $0.state != .queued }
        completedOutput = [:]; auditWritable = true; saveAudit()
    }
    func prepareForQuit() { pause(); saveAudit() }

    func chooseInterpreter() { choose(kind: 0) }
    func chooseScript() { choose(kind: 1) }
    func chooseDirectory() { choose(kind: 2) }
    private func choose(kind: Int) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = kind != 2; panel.canChooseDirectories = kind == 2
        panel.allowsMultipleSelection = false
        if kind == 1, let type = UTType(filenameExtension: "py") { panel.allowedContentTypes = [type] }
        panel.message = kind == 0 ? "Choose the Python interpreter for this trusted script (venv interpreters supported; no shell shims)." : (kind == 1 ? "Choose a Python script you trust. It will not run until you start the queue." : "Choose the script's working folder.")
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            switch kind {
            case 0: self.draftInterpreter = url
            case 1:
                self.draftScript = url
                self.draftDirectory = url.deletingLastPathComponent()
                if self.draftLabel.isEmpty { self.draftLabel = url.deletingPathExtension().lastPathComponent }
            default: self.draftDirectory = url
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150)); self?.requestPopover?()
            }
        }
    }
    func enqueueDraft() {
        guard let interpreter = draftInterpreter, let script = draftScript, let directory = draftDirectory else {
            message = "Choose an interpreter, a .py script and a working folder first."; return
        }
        let arguments = draftArguments.isEmpty ? [] : draftArguments.components(separatedBy: "\n")
        enqueue(label: draftLabel, priority: draftPriority,
                configuration: ManagedPythonJob(interpreter: interpreter, script: script, directory: directory, arguments: arguments))
    }
    private func tick() {
        guard let battery, let study else { return }
        let snapshot = battery.snapshot
        let uptime = ProcessInfo.processInfo.systemUptime
        let fresh = study.lastSample.map { Date().timeIntervalSince($0) >= 0 && Date().timeIntervalSince($0) <= 15 } ?? false
        let power: OptimizerPower
        switch snapshot.powerState {
        case .discharging: power = .battery
        case .charging, .fullyCharged, .pluggedInHolding, .desktopAC: power = .adapter
        case .unknown: power = .unknown
        }
        let watts: Double? = fresh && !sleeping && power == .battery && snapshot.powerReadingAvailable && snapshot.liveWatts <= 0 ? -snapshot.liveWatts : nil
        powerWindow.observe(time: uptime, watts: watts, source: snapshot.powerReadingSource)
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~UInt32(0))!)
        let next = OptimizerContext(power: power, away: idle >= 120, fresh: fresh && study.recording,
                                    sleeping: sleeping, thermal: ProcessInfo.processInfo.thermalState.rawValue,
                                    sustainedWatts: powerWindow.average(at: uptime),
                                    demanding: [.tests, .editing].contains(study.workload))
        var advice: [String] = []
        for group in study.report.groups.prefix(30) {
            switch study.labels[group.id] ?? .unclassified {
            case .urgent: advice.append("Protect \(group.name): you are waiting for results.")
            case .flexible where group.awayCPUSeconds >= 30:
                advice.append("\(group.name): a candidate for a future worker-count experiment. No change applied.")
            default: break
            }
            if advice.count >= 5 { break }
        }
        evaluate(next, advice: advice)
    }
    func evaluate(_ next: OptimizerContext, advice: [String] = []) {
        if context != next { context = next }
        if preview != advice { preview = advice }
        updateQueuedReasons()
        guard enabled else { return }
        let candidates = records.filter { $0.state == .queued }.sorted {
            $0.priority.rank == $1.priority.rank ? $0.added < $1.added : $0.priority.rank < $1.priority.rank
        }
        for candidate in candidates {
            let decision = decision(for: candidate)
            if decision.mayStart { launch(candidate.id) }
        }
        updateQueuedReasons()
    }
    private func decision(for record: ManagedJobRecord) -> OptimizerDecision {
        OptimizerPolicy.decision(priority: record.priority, context: context, enabled: enabled,
                                 running: runningCount, configuredLimit: limit,
                                 coolingDown: ProcessInfo.processInfo.systemUptime - lastCompletion < 15)
    }
    private func updateQueuedReasons() {
        var next = records
        var changed = false
        for index in next.indices where next[index].state == .queued {
            let reason = decision(for: next[index]).reason
            if next[index].reason != reason { next[index].reason = reason; changed = true }
        }
        if changed { records = next }
    }
    private func launch(_ id: UUID) {
        guard let configuration = configurations[id], let index = records.firstIndex(where: { $0.id == id && $0.state == .queued }) else { return }
        let execution = ManagedPythonExecution()
        do {
            let pid = try execution.start(configuration) { [weak self] status in
                Task { @MainActor [weak self] in self?.finished(id, status: status) }
            }
            executions[id] = execution; starts[id] = ProcessInfo.processInfo.systemUptime
            records[index].pid = pid; records[index].started = Date(); records[index].state = .running
            records[index].reason = "Explicitly launched script; no priority or hardware settings changed."
            configurations[id] = nil
            saveAudit()
        } catch {
            records[index].state = .failed; records[index].finished = Date()
            records[index].reason = "Launch failed. Check the interpreter, script and folder permissions."
            configurations[id] = nil; enabled = false; message = "Queue paused after a launch failure."
            saveAudit()
        }
    }
    private func finished(_ id: UUID, status: Int32) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        completedOutput[id] = executions[id]?.output.text
        executions[id] = nil
        records[index].state = status == 0 ? .completed : .failed
        records[index].finished = Date(); records[index].exitCode = status
        records[index].duration = starts[id].map { max(0, ProcessInfo.processInfo.systemUptime - $0) }; starts[id] = nil
        records[index].reason = "Root script exited with status \(status). Energy savings and performance retention have not been established."
        lastCompletion = ProcessInfo.processInfo.systemUptime
        if status != 0 { enabled = false; message = "Queue paused because a script failed. Review its output before continuing." }
        trim(); saveAudit(); updateQueuedReasons()
    }
    private func trim() {
        let keep = Set(records.filter { $0.state == .queued || $0.state == .running }.map(\.id))
        var completed = 0
        records = records.filter { record in
            if keep.contains(record.id) { return true }
            completed += 1; return completed <= 50
        }
        let ids = Set(records.map(\.id)); completedOutput = completedOutput.filter { ids.contains($0.key) }
    }
    private func saveAudit() {
        guard auditWritable else { enabled = false; message = "Queue paused: unreadable run summaries are preserved. Clear finished summaries to reset the run log."; return }
        do {
            let saved = Array(records.filter { $0.state != .queued && $0.state != .removed }.prefix(100))
            try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: archiveURL, options: .atomic)
        } catch { enabled = false; message = "Queue paused because run summaries could not be saved. Running jobs continue; no job restarts automatically." }
    }
}
