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
    private var statusController: BatteryStatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        statusController = BatteryStatusController(service: BatteryService())
    }
}
