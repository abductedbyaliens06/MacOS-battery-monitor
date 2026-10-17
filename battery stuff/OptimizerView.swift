import SwiftUI

struct OptimizerView: View {
    @ObservedObject var optimizer: OptimizerService
    @ObservedObject var study: UsageStudyService
    @State private var confirmStart = false
    @State private var expandedOutput: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Running-task optimizer").font(.system(size: 21, weight: .semibold, design: .rounded))
            Label("Automatic discovery · preview only", systemImage: "shield.lefthalf.filled")
                .font(.system(size: 11)).foregroundStyle(PowerUI.mint)
            LiveProcessView(study: study, optimizer: optimizer)
            if let message = optimizer.message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary) }
            Surface("Your constraints") {
                Label("Brightness and refresh rate stay unchanged", systemImage: "display")
                Label("No voltage, current, charging, fan or firmware controls", systemImage: "lock.shield")
                Text("8 W regular / 14 W demanding · 90% performance · 30–40% more runtime are research targets, not measured results or enforced caps.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.font(.system(size: 11))
            DisclosureGroup("Optional · managed Python queue", isExpanded: $optimizer.managedQueueExpanded) {
                HStack {
                    Text(optimizer.enabled ? "Queue enabled" : "Queue paused")
                    Spacer()
                    if optimizer.enabled {
                        Button("Pause queue") { optimizer.pause() }
                    } else {
                        Button("Start queue…") { confirmStart = true }.disabled(!optimizer.hasPending)
                    }
                }.font(.system(size: 11)).buttonStyle(.bordered)
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
            }.font(.system(size: 12))
            if optimizer.runningCount > 0 { Text("Managed jobs running: \(optimizer.runningCount)").font(.system(size: 11)).foregroundStyle(.secondary) }
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
