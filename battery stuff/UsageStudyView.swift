import SwiftUI
import Charts

struct UsageStudyView: View {
    @ObservedObject var study: UsageStudyService
    @State private var confirmClear = false
    @State private var search = ""
    private var groups: [StudyGroup] {
        Array(study.report.groups.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }.prefix(30))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Usage study").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Label(study.recording ? "Observing · every 5 seconds" : "Collection paused", systemImage: study.recording ? "record.circle" : "pause.circle")
                        .font(.system(size: 11)).foregroundStyle(study.recording ? PowerUI.mint : .secondary)
                }
                Spacer()
                Button(study.recording ? "Pause" : "Resume") { study.setRecording(!study.recording) }.buttonStyle(.bordered)
            }
            Text("Observe first. No changes to brightness, refresh rate, power modes or processes.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let message = study.message {
                Label(message, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Picker("Report period", selection: $study.hours) {
                Text("1 hour").tag(1.0); Text("24 hours").tag(24.0); Text("7 days").tag(168.0)
            }.pickerStyle(.segmented)
            Surface("Current task · your label") {
                Picker("Workload", selection: $study.workload) {
                    ForEach(StudyWorkload.allCases) { Text($0.rawValue).tag($0) }
                }
                Text("Labels describe intent; they do not change scheduling. Away means at least 2 minutes without input.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                metric("Battery draw", study.report.averageWatts.map { String(format: "%.1f W", $0) } ?? "—", "Whole-Mac average")
                metric("Battery energy", String(format: "%.2f Wh", study.report.energyWh), "Measured intervals only")
            }
            HStack(spacing: 10) {
                metric("Observed", duration(study.report.seconds), "Excludes gaps / transitions")
                metric("Power coverage", study.report.seconds > 0 ? String(format: "%.0f%%", study.report.batterySeconds / study.report.seconds * 100) : "—", "Battery intervals / observed")
            }
            if !study.report.timeline.isEmpty {
                Surface("Whole-Mac battery draw · 10-minute averages") {
                    Chart(study.report.timeline) { point in
                        LineMark(x: .value("Time", point.date), y: .value("Watts", point.watts), series: .value("Segment", point.segment))
                            .foregroundStyle(PowerUI.mint)
                        PointMark(x: .value("Time", point.date), y: .value("Watts", point.watts)).foregroundStyle(PowerUI.mint).symbolSize(5)
                    }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                    .frame(height: 105)
                    .accessibilityLabel("Measured whole-Mac battery watts; individual apps are not assigned wattage")
                }
            }
            Surface("Collector health · latest sample") {
                HStack {
                    Text("\(study.readableProcesses) readable processes"); Spacer()
                    Text(String(format: "%.1f ms / scan", study.scanMS)).monospacedDigit()
                }
                HStack {
                    Text("Battery Monitor CPU"); Spacer()
                    Text(study.monitorCPU.map { String(format: "%.1f%%", $0) } ?? "—").monospacedDigit()
                }
                HStack {
                    Text("Monitor footprint"); Spacer()
                    Text(study.monitorFootprint.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .memory) } ?? "—")
                }
                Text("\(study.unavailableProcesses) unavailable in latest scan · \(study.report.newProcesses) new counter baselines. Counters may be restricted, or processes may exit between reads.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if study.discoveryLimited {
                    Text("Process discovery is restricted in this build. Other-app rankings are unavailable; the study is incomplete.")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                } else if study.report.discoveryLimitedSamples > 0 {
                    Text("Earlier intervals in this period had restricted process discovery. Rankings cover readable intervals only.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if study.unavailableProcesses > study.readableProcesses {
                    Text("Process access is limited. This report cannot rank all of your apps; missing counters are not zero usage.")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
                if study.truncated || study.report.omittedGroups > 0 {
                    Text("Some low-ranked groups were omitted to bound storage. Rankings are incomplete.")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
                Text("CPU is for the entire monitor; 100% represents one core. Collector energy overhead has not yet been experimentally isolated.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.font(.system(size: 11))
            HStack {
                Text("Apps & process families").font(.system(size: 14, weight: .semibold)); Spacer()
                Text("By CPU time").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            TextField("Find an app or process family", text: $search).textFieldStyle(.roundedBorder)
            if groups.isEmpty {
                Text(study.report.groups.isEmpty ? "Collecting a baseline. Leave the app running, then refresh after a minute." : "No matching families.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12)
            }
            LazyVStack(spacing: 10) {
                ForEach(groups) { group in
                    Surface {
                        Text(group.name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        HStack {
                            Text(String(format: "%.1f CPU s · %.1f%% average", group.cpuSeconds, group.averageCPU)); Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: group.footprintPeak), countStyle: .memory))
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(String(format: "%.1f CPU s while away · %.1f CPU s at background QoS", group.awayCPUSeconds, group.backgroundCPUSeconds))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        if let watts = group.coincidentWatts {
                            Text(String(format: "Mac draw during its activity: %.1f W", watts)).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Picker("Importance", selection: Binding(get: { study.labels[group.id] ?? .unclassified }, set: { study.setImportance($0, for: group.id) })) {
                            ForEach(StudyImportance.allCases) { Text($0.rawValue).tag($0) }
                        }.font(.system(size: 11))
                        Text(candidate(group)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            Text("CPU time is measured, not importance. Average CPU covers the family's sampled presence. Memory is peak summed footprint. Mac draw includes all activity: overlapping values cannot be added. Short-lived processes between scans can be missed.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Surface("Local data · 7-day rolling study") {
                Text("Summaries, app identities and labels stay on this Mac. No keystrokes, URLs, window titles, command arguments or file contents are collected. Brightness, per-app GPU power and performance latency are unavailable in this version.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack {
                    Button("Refresh") { study.refreshReport() }
                    Button("Export JSON…") { study.export() }; Spacer()
                    Button("Clear…", role: .destructive) { confirmClear = true }
                }.buttonStyle(.bordered).font(.system(size: 11))
            }
        }
        .onAppear { study.setVisible(true) }.onDisappear { study.setVisible(false) }
        .confirmationDialog("Delete the local usage study and importance labels? Battery history is kept.", isPresented: $confirmClear) {
            Button("Delete usage study", role: .destructive) { study.clear() }
            Button("Cancel", role: .cancel) {}
        }
    }
    private func metric(_ title: String, _ value: String, _ caption: String) -> some View {
        Surface {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(caption).font(.system(size: 9)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func duration(_ seconds: Double) -> String { String(format: "%dh %02dm", Int(seconds) / 3600, Int(seconds) % 3600 / 60) }
    private func candidate(_ group: StudyGroup) -> String {
        switch study.labels[group.id] ?? .unclassified {
        case .urgent: return "Waiting for results: protect completion time in future experiments."
        case .unclassified: return "Importance unknown. Label before considering experiments."
        case .flexible where group.awayCPUSeconds >= 30: return "Candidate for a future worker-count experiment; savings are untested."
        case .flexible: return "Flexible work; collecting more away-time observations."
        case .normal: return "Normal importance. No scheduling changes are being made."
        }
    }
}
