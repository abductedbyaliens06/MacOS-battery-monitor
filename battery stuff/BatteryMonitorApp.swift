import SwiftUI
import AppKit

@main
struct BatteryMonitorApp: App {
    @NSApplicationDelegateAdaptor(BatteryAppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class BatteryAppDelegate: NSObject, NSApplicationDelegate {
    private var optimizer: OptimizerService?
    private var study: UsageStudyService?
    private var statusController: BatteryStatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        BatteryDataLocations.importPreferences()
        let battery = BatteryService()
        let study = UsageStudyService(battery: battery)
        self.study = study
        let optimizer = OptimizerService(battery: battery, study: study)
        self.optimizer = optimizer
        statusController = BatteryStatusController(service: battery, study: study, optimizer: optimizer)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let optimizer, optimizer.runningCount > 0 else { return .terminateNow }
        optimizer.pause()
        let alert = NSAlert()
        alert.messageText = "Managed scripts are still running"
        alert.informativeText = "New launches are paused. Let these scripts finish before quitting so their output streams remain connected. The optimizer will not stop or freeze them."
        alert.addButton(withTitle: "Keep app running")
        alert.runModal()
        return .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { optimizer?.prepareForQuit(); study?.terminate() }
}
