import AppKit
import Combine

@MainActor
final class SchedulingControlService: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var connected = false
    @Published private(set) var active: Set<String> = []
    @Published private(set) var status = "Administrator helper is not connected. No live changes applied."
    @Published private(set) var blocked: [SchedulingReply.Blocked] = []
    @Published private(set) var restorationUnconfirmed = false
    private let client = SchedulingControlClient()
    private var sequence = 0
    private var acknowledgement = SchedulingAcknowledgement()
    private var connectedBefore = false
    var authorizationCommand: String {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/BatteryOptimizerHelper").path
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "sudo \(quoted) --serve \(getuid()) \(ProcessInfo.processInfo.processIdentifier)"
    }
    func copyRecoveryCommand() {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/BatteryOptimizerHelper").path
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("sudo \(quoted) --recover \(getuid())", forType: .string)
    }
    func copyCommand() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(authorizationCommand, forType: .string)
    }
    func setEnabled(_ value: Bool) {
        guard !value || (connected && !restorationUnconfirmed) else { return }
        enabled = value
    }
    func update(live: LiveProcessSnapshot?, labels: [String: StudyImportance], recording: Bool,
                context: OptimizerContext, foregroundKey: String) {
        let targets = SchedulingControlPolicy.targets(live: live, labels: labels, enabled: enabled,
            recording: recording, power: context.power, sleeping: context.sleeping, foregroundKey: foregroundKey,
            previouslyActive: active)
        acknowledgement.sending(nonempty: !targets.isEmpty)
        sequence += 1; let token = sequence
        client.exchange(targets) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.sequence == token else { return }
                switch result {
                case .success(let reply):
                    self.acknowledgement.received(reply)
                    self.connected = !reply.failed; self.connectedBefore = true
                    self.active = Set(reply.active); self.blocked = reply.blocked
                    self.restorationUnconfirmed = reply.failed && self.acknowledgement.mayHaveApplied
                    if reply.failed { self.enabled = false; self.status = "Helper reported a failure. New changes paused; recovery may be required." }
                    else if !reply.onBattery { self.status = "On the adapter. Scheduling changes restored." }
                    else if !self.enabled { self.status = "Paused. Scheduling changes restored." }
                    else if !reply.active.isEmpty { self.status = "Efficient scheduling applied to \(reply.active.count) flexible workers." }
                    else { self.status = reply.blocked.isEmpty ? "Enabled. Waiting for sustained, explicitly flexible Python work." : "No eligible change could be applied. See helper results below." }
                case .failure:
                    self.connected = false; self.enabled = false
                    self.restorationUnconfirmed = self.acknowledgement.mayHaveApplied
                    self.status = self.restorationUnconfirmed ? "Connection lost. Restoration is unconfirmed; the guardian attempts rollback. Restart it to recover before further testing." : (self.connectedBefore ? "Helper disconnected. Reauthorize a new session to continue." : "Administrator helper is not connected. No live changes applied.")
                }
            }
        }
    }
    func stop() { enabled = false; client.exchange([]) { _ in }; client.close() }
}
