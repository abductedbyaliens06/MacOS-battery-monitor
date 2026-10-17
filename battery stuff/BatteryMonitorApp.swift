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
    private var study: UsageStudyService?
    private var statusController: BatteryStatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let battery = BatteryService()
        let study = UsageStudyService(battery: battery)
        self.study = study
        statusController = BatteryStatusController(service: battery, study: study)
    }
    func applicationWillTerminate(_ notification: Notification) { study?.terminate() }
}
