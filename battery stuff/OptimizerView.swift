import SwiftUI

struct OptimizerView: View {
    @ObservedObject var optimizer: OptimizerService
    @ObservedObject var study: UsageStudyService
    @State private var confirmStart = false
    @State private var expandedOutput: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Optimizer prototype").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Label(optimizer.enabled ? "Managed queue enabled" : "Preview · queue paused", systemImage: optimizer.enabled ? "play.circle" : "shield.lefthalf.filled")
                        .font(.system(size: 11)).foregroundStyle(PowerUI.mint)
                }
                Spacer()
                if optimizer.enabled {
                    Button("Pause queue") { optimizer.pause() }.buttonStyle(.borderedProminent)
                } else {
                    Button("Start queue…") { confirmStart = true }.buttonStyle(.bordered).disabled(!optimizer.hasPending)
                }
            }
            Text("Only scripts you explicitly add can run. Existing apps and processes are never throttled, suspended or stopped.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let message = optimizer.message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary) }
            Surface("Your constraints") {
                Label("Brightness and refresh rate stay unchanged", systemImage: "display")
                Label("No voltage, current, charging, fan or firmware controls", systemImage: "lock.shield")
                Text("8 W regular / 14 W demanding · 90% performance · 30–40% more runtime are research targets, not measured results or enforced caps.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.font(.system(size: 11))
            Surface("Current context") {
                HStack {
                    Text(optimizer.context.power == .battery ? "On battery" : (optimizer.context.power == .adapter ? "Power adapter" : "Power source unknown"))
                    Spacer(); Text(optimizer.context.away ? "Away" : "Interacting")
                }
                HStack {
                    Text("Sustained battery draw")
                    Spacer()
                    Text(optimizer.context.sustainedWatts.map { String(format: "%.1f W", $0) } ?? "Collecting / unavailable").monospacedDigit()
                }
                Text(optimizer.context.fresh ? "Monitoring is fresh. Non-urgent jobs wait while you interact on battery; no running job is interrupted when you return." : "New launches wait for fresh, enabled study monitoring.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text("At most one root job on battery; up to two on the adapter. A script may create its own workers—this prototype does not cap threads or promise a CPU budget.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.font(.system(size: 11))
            Surface("Study recommendations · no changes applied") {
                if optimizer.preview.isEmpty {
                    Text("Label process families in Study as Waiting for results or Can finish later to build an intent-aware preview.")
                } else {
                    ForEach(Array(optimizer.preview.enumerated()), id: \.offset) { _, text in Text(text) }
                }
                Text("No trained model yet. The prototype cannot measure or guarantee 90% foreground performance, and lower launch concurrency is not proven to save energy.")
                    .foregroundStyle(.secondary)
            }.font(.system(size: 10))
            Surface("Managed Python jobs · explicit opt-in") {
                Stepper("Adapter concurrency: \(optimizer.limit)", value: $optimizer.limit, in: 1...2).font(.system(size: 11))
                Text("Pause queue stops new launches. Running scripts finish normally. Quit is blocked while jobs run to preserve their output streams; scripts must join their own workers.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Button(optimizer.showDraft ? "Hide new job" : "Add a Python job…") { optimizer.showDraft.toggle() }.buttonStyle(.bordered)
            }
            if optimizer.showDraft { draft }
            if optimizer.records.isEmpty {
                Text("No jobs added. The optimizer is making no changes while the study collects data.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(optimizer.records.prefix(30)) { record in
                Surface {
                    HStack {
                        Text(record.label).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        Spacer(); Text(record.state.rawValue).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if record.state == .queued {
                        Picker("Importance", selection: Binding(get: { record.priority }, set: { optimizer.setPriority($0, for: record.id) })) {
                            ForEach(ManagedJobPriority.allCases) { Text($0.rawValue).tag($0) }
                        }.font(.system(size: 11))
                    }
                    if let pid = record.pid { Text("PID \(pid) · \(record.priority.rawValue)").font(.system(size: 10)).foregroundStyle(.secondary) }
                    if let duration = record.duration { Text(String(format: "Root script duration: %.1f s", duration)).font(.system(size: 10)).foregroundStyle(.secondary) }
                    Text(record.reason).font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack {
                        if record.state == .queued { Button("Remove") { optimizer.remove(record.id) } }
                        if record.started != nil { Button(expandedOutput == record.id ? "Hide output" : "View output") { expandedOutput = expandedOutput == record.id ? nil : record.id } }
                    }.font(.system(size: 11)).buttonStyle(.bordered)
                    if expandedOutput == record.id {
                        ScrollView {
                            Text(optimizer.output(for: record.id).isEmpty ? "No captured output. Output from prior app sessions is not retained." : optimizer.output(for: record.id))
                                .font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: 140)
                    }
                }
            }
            Button("Clear finished summaries") { optimizer.clearFinished() }.font(.system(size: 11)).buttonStyle(.bordered)
            Text("Queue definitions, script paths, arguments and capped output remain in memory. Only named run summaries are saved locally; no pending job is restored or restarted after relaunch.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .onAppear { study.setVisible(true) }.onDisappear { study.setVisible(false) }
        .confirmationDialog("Run the scripts you added with your normal user permissions? Only run code you trust. This does not enable control of existing apps or hardware.", isPresented: $confirmStart) {
            Button("Start managed queue") { optimizer.startQueue() }
            Button("Cancel", role: .cancel) {}
        }
    }
    private var draft: some View {
        Surface("New job · adding does not execute it") {
            TextField("Job name", text: $optimizer.draftLabel).textFieldStyle(.roundedBorder)
            Button("Choose Python interpreter…") { optimizer.chooseInterpreter() }
            Text(optimizer.draftInterpreter?.path ?? "No interpreter selected").lineLimit(2).foregroundStyle(.secondary)
            Button("Choose .py script…") { optimizer.chooseScript() }
            Text(optimizer.draftScript?.path ?? "No script selected").lineLimit(2).foregroundStyle(.secondary)
            Button("Choose working folder…") { optimizer.chooseDirectory() }
            Text(optimizer.draftDirectory?.path ?? "Defaults to script folder").lineLimit(2).foregroundStyle(.secondary)
            Picker("Importance", selection: $optimizer.draftPriority) {
                ForEach(ManagedJobPriority.allCases) { Text($0.rawValue).tag($0) }
            }
            Text("Arguments · one literal argument per line; no shell expansion").foregroundStyle(.secondary)
            TextEditor(text: $optimizer.draftArguments).font(.system(size: 11, design: .monospaced)).frame(height: 70)
                .border(Color.primary.opacity(0.12)).accessibilityLabel("Script arguments, one per line")
            Text("Your scripts have normal user access and can modify files. The optimizer does not inspect or sandbox their contents. Only select scripts you trust.")
                .foregroundStyle(.secondary)
            Button("Add to paused queue") { optimizer.enqueueDraft() }.buttonStyle(.borderedProminent)
        }.font(.system(size: 11))
    }
}
