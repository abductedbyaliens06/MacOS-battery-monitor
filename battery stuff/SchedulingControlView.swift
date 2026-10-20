import SwiftUI

struct SchedulingControlView: View {
    @ObservedObject var control: SchedulingControlService
    @ObservedObject var optimizer: OptimizerService
    var body: some View {
        Surface("Selective efficiency · experimental") {
            Toggle("Optimize flexible background workers", isOn: Binding(get: { control.enabled }, set: { optimizer.setLiveOptimization($0) }))
                .disabled(!control.connected).font(.system(size: 12, weight: .medium))
            Text(control.status).font(.system(size: 11)).foregroundStyle(.secondary)
            if !control.connected {
                Text("A temporary administrator helper must first verify exact rollback on a disposable worker. It exits after 30 minutes or when this app closes; nothing is installed as a persistent system service.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Button("Copy helper authorization command") { control.copyCommand() }.buttonStyle(.bordered)
                Button("Check connection") { optimizer.refreshLiveControl() }.buttonStyle(.bordered)
                Text("Run the copied command in Terminal. Enter your password only in Terminal. Keep that session open; Ctrl-C requests restoration and exits.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if control.restorationUnconfirmed {
                Button("Copy recovery-only command") { control.copyRecoveryCommand() }.buttonStyle(.bordered)
            }
            if !control.active.isEmpty { Text("Last confirmed: \(control.active.count) worker policies applied").font(.system(size: 11)).monospacedDigit() }
            ForEach(Array(control.blocked.enumerated()), id: \.offset) { _, item in
                Text("PID \(item.pid): \(item.reason)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text("On battery only. Explicitly flexible Python workers get a lower scheduling tier. Normal/urgent work and GUI apps are excluded. Pause, power connection and stale monitoring request restoration. Children are evaluated separately.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text("The editor stays unrestricted; independent Python jobs it launched can be optimized only after you label them flexible. Background jobs may take longer. Battery savings and 90% foreground performance remain unverified.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
