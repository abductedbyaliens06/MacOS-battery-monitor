import AppKit
import Combine
import CoreGraphics
import UniformTypeIdentifiers

nonisolated struct StudyWorkerResult: Sendable {
    var report: StudyReport?
    var scanMS: Double
    var readable: Int
    var denied: Int
    var monitorCPU: Double?
    var monitorFootprint: UInt64?
    var truncated: Bool
    var discoveryLimited: Bool
}

/// A single utility queue owns the database, process baselines and incremental writes.
nonisolated final class UsageStudyWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "BatteryMonitor.usage-study", qos: .utility)
    private let url: URL
    private var store: UsageStudyStore?
    private var accumulator = StudyAccumulator()
    private var lastSave = Date.distantPast
    private var previousSelf: (uptime: Double, cpu: UInt64)?
    init(url: URL) { self.url = url }
    private func database() throws -> UsageStudyStore {
        if let store { return store }
        let opened = try UsageStudyStore(url: url); store = opened; return opened
    }
    func flush() throws {
        guard !accumulator.pending.isEmpty else { return }
        try database().save(accumulator.pending, now: Date())
        accumulator.didSave(); lastSave = Date()
    }
    func boundary() throws { accumulator.breakContinuity(); previousSelf = nil; try flush() }
    func clear() throws {
        if let store { try store.clear() }
        else {
            // Only an explicit Clear action may remove an unreadable study store.
            try UsageStudyStore.erase(at: url)
            _ = try database()
        }
        accumulator.reset(); previousSelf = nil
    }
    func report(hours: Double, labels: [String: StudyImportance]) throws -> StudyReport {
        try flush()
        return try database().report(since: Date().addingTimeInterval(-hours * 3600), now: Date(), labels: labels)
    }
    func export(to url: URL, labels: [String: StudyImportance]) throws {
        try flush(); try database().export(to: url, labels: labels, now: Date())
    }
    func sample(context: StudyContext, battery: Double?, source: String, temperature: Double?,
                apps: [Int32: StudyApp], labels: [String: StudyImportance], reportHours: Double?) throws -> StudyWorkerResult {
        let started = ProcessInfo.processInfo.systemUptime
        let scan = UsageProcessCollector.scan()
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        let scanMS = (uptime - started) * 1000
        let frame = StudyFrame(date: now, uptime: uptime, context: context, batteryDraw: battery,
                               batterySource: source, temperature: temperature, processes: scan.processes,
                               apps: apps, attempted: scan.attempted, denied: scan.denied, scanMS: scanMS, discoveryLimited: scan.discoveryLimited)
        accumulator.record(frame, labels: labels)
        if now.timeIntervalSince(lastSave) >= 60 { try flush() }
        let own = scan.processes.first { $0.pid == getpid() }
        var cpu: Double?
        if let own, let previousSelf, uptime > previousSelf.uptime, own.cpuNS >= previousSelf.cpu {
            cpu = Double(own.cpuNS - previousSelf.cpu) / 1e9 / (uptime - previousSelf.uptime) * 100
        }
        if let own { previousSelf = (uptime, own.cpuNS) }
        return StudyWorkerResult(report: try reportHours.map { try report(hours: $0, labels: labels) }, scanMS: scanMS,
                                 readable: scan.processes.count, denied: scan.denied, monitorCPU: cpu,
                                 monitorFootprint: own?.footprint, truncated: scan.truncated, discoveryLimited: scan.discoveryLimited)
    }
}

@MainActor
final class UsageStudyService: ObservableObject {
    @Published private(set) var recording: Bool
    @Published private(set) var report = StudyReport()
    @Published private(set) var message: String?
    @Published private(set) var readableProcesses = 0
    @Published private(set) var unavailableProcesses = 0
    @Published private(set) var scanMS: Double = 0
    @Published private(set) var monitorCPU: Double?
    @Published private(set) var monitorFootprint: UInt64?
    @Published private(set) var truncated = false
    @Published private(set) var discoveryLimited = false
    @Published private(set) var lastSample: Date?
    @Published private(set) var labels: [String: StudyImportance]
    @Published var workload: StudyWorkload { didSet { defaults.set(workload.rawValue, forKey: "study.workload.v1") } }
    @Published var hours: Double = 24 { didSet { refreshReport() } }
    private let defaults: UserDefaults
    private let worker: UsageStudyWorker
    private weak var battery: BatteryService?
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false
    private var screenOff = false
    private var reportVisible = false
    private var lastReport = Date.distantPast
    private var generation = UUID()

    init(battery: BatteryService?, defaults: UserDefaults = .standard, url: URL? = nil,
         startAutomatically: Bool = true, initialReport: StudyReport? = nil) {
        self.battery = battery; self.defaults = defaults
        recording = defaults.object(forKey: "study.recording.v1") as? Bool ?? true
        workload = StudyWorkload(rawValue: defaults.string(forKey: "study.workload.v1") ?? "") ?? .unclassified
        if let data = defaults.data(forKey: "study.labels.v1"), data.count < 1_000_000,
           let saved = try? JSONDecoder().decode([String: StudyImportance].self, from: data), saved.count <= 5000 { labels = saved }
        else { labels = [:] }
        let directory = BatteryDataLocations.directory
        worker = UsageStudyWorker(url: url ?? directory.appendingPathComponent("usage-study-v1.sqlite"))
        if let initialReport { report = initialReport }
        guard startAutomatically else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = true; self?.flushBoundary() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = false }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenOff = true }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenOff = false }
        })
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.recording, !self.sleeping { await self.sample() }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
    deinit {
        task?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    func setRecording(_ enabled: Bool) {
        recording = enabled; defaults.set(enabled, forKey: "study.recording.v1")
        generation = UUID(); flushBoundary()
        if !enabled { message = nil }
    }
    func setVisible(_ visible: Bool) { reportVisible = visible; if visible { refreshReport() } }
    func setImportance(_ importance: StudyImportance, for key: String) {
        guard labels.count < 5000 || labels[key] != nil else { message = "Label limit reached. Clear the study to start a new collection."; return }
        labels[key] = importance
        if let data = try? JSONEncoder().encode(labels) { defaults.set(data, forKey: "study.labels.v1") }
        refreshReport()
    }
    func refreshReport() {
        let hours = hours, labels = labels, generation = generation
        worker.queue.async { [worker, weak self] in
            do {
                let result = try worker.report(hours: hours, labels: labels)
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation, self.hours == hours else { return }
                    self.report = result; self.lastReport = Date()
                }
            } catch { Task { @MainActor [weak self] in self?.message = "Could not read the usage study. Existing data is preserved; export or clear it to recover." } }
        }
    }
    private func flushBoundary() {
        worker.queue.async { [worker, weak self] in
            do { try worker.boundary() }
            catch { Task { @MainActor [weak self] in self?.message = "Could not save recent usage observations." } }
        }
    }
    func terminate() { worker.queue.sync { try? worker.boundary() } }
    func clear() {
        generation = UUID()
        worker.queue.async { [worker, weak self] in
            do {
                try worker.clear()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.labels = [:]; self.defaults.removeObject(forKey: "study.labels.v1")
                    self.report = StudyReport(); self.message = nil; self.refreshReport()
                }
            } catch { Task { @MainActor [weak self] in self?.message = "Could not finish clearing the study. Check local storage and try again." } }
        }
    }
    func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Battery-Usage-Study.json"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let labels = self.labels
            self.worker.queue.async { [worker = self.worker, weak self] in
                do {
                    try worker.export(to: url, labels: labels)
                    Task { @MainActor [weak self] in self?.message = "Study exported. The file includes app identities and activity patterns; review it before sharing." }
                } catch { Task { @MainActor [weak self] in self?.message = "Could not export the usage study." } }
            }
        }
    }
    private func sample() async {
        guard let snapshot = battery?.snapshot else { return }
        let foreground = NSWorkspace.shared.frontmostApplication
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~UInt32(0))!)
        let activity: StudyActivity = screenOff ? .screenOff : (idle >= 120 ? .away : .active)
        var apps: [Int32: StudyApp] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bundle = app.bundleIdentifier else { continue }
            apps[app.processIdentifier] = StudyApp(key: "app:\(bundle)", name: String((app.localizedName ?? bundle).prefix(100)))
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        let displayResult = CGGetOnlineDisplayList(16, &ids, &count)
        let rates = displayResult == .success ? ids.prefix(Int(count)).compactMap { id -> Double? in
            guard let mode = CGDisplayCopyDisplayMode(id), mode.refreshRate > 0 else { return nil }; return mode.refreshRate
        } : []
        var pressure: Int32 = 0, size = MemoryLayout<Int32>.size
        let memoryPressure: Int? = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0) == 0 ? Int(pressure) : nil
        let context = StudyContext(activity: activity, foregroundKey: foreground?.bundleIdentifier.map { "app:\($0)" } ?? "unknown",
                                   foregroundName: String((foreground?.localizedName ?? "Unknown").prefix(100)), workload: workload,
                                   onBattery: snapshot.hasBattery && snapshot.powerState == .discharging,
                                   lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                   thermal: ProcessInfo.processInfo.thermalState.rawValue, displayCount: Int(count),
                                   refreshRates: rates, memoryPressure: memoryPressure)
        let batteryDraw = snapshot.powerReadingAvailable && snapshot.liveWatts <= 0 ? -snapshot.liveWatts : nil
        let reportHours: Double? = reportVisible && Date().timeIntervalSince(lastReport) >= 30 ? hours : nil
        let labels = labels, generation = generation
        let result: Result<StudyWorkerResult, Error> = await withCheckedContinuation { continuation in
            worker.queue.async { [worker] in
                continuation.resume(returning: Result { try worker.sample(context: context, battery: batteryDraw,
                                                                          source: snapshot.powerReadingSource, temperature: snapshot.temperatureCelsius,
                                                                          apps: apps, labels: labels, reportHours: reportHours) })
            }
        }
        guard generation == self.generation else { return }
        switch result {
        case .success(let result):
            readableProcesses = result.readable; unavailableProcesses = result.denied
            scanMS = result.scanMS; monitorCPU = result.monitorCPU; monitorFootprint = result.monitorFootprint
            truncated = result.truncated; discoveryLimited = result.discoveryLimited; lastSample = Date()
            if let report = result.report { self.report = report; lastReport = Date() }
        case .failure:
            recording = false; defaults.set(false, forKey: "study.recording.v1")
            message = "Study collection paused because its local store could not be written. Existing data is preserved; clear the study or free disk space to resume."
        }
    }
}
