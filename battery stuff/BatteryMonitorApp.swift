import SwiftUI
import AppKit

@main
struct BatteryMonitorApp: App {
    @StateObject private var batteryService = BatteryService()
    
    init() {
        // Run strictly as a menu bar agent without a Dock icon
        NSApplication.shared.setActivationPolicy(.accessory)
    }
    
    var body: some Scene {
        MenuBarExtra {
            JuicyMenuView(service: batteryService)
        } label: {
            let s = batteryService.snapshot
            HStack(spacing: 4) {
                Image(systemName: iconName(for: s))
                Text(menuBarTitle(for: s, style: batteryService.labelStyle))
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .menuBarExtraStyle(.window)
    }
    
    private func iconName(for s: BatterySnapshot) -> String {
        switch s.powerState {
        case .charging: return "bolt.batteryblock.fill"
        case .pluggedInHolding: return "powerplug.fill"
        case .fullyCharged: return "battery.100.bolt"
        case .discharging: return "battery.75"
        case .desktopAC, .unknown: return "bolt.horizontal.fill"
        }
    }
    
    private func menuBarTitle(for s: BatterySnapshot, style: MenuBarLabelStyle) -> String {
        guard s.hasBattery else { return "AC" }
        switch style {
        case .percentAndWatts:
            return String(format: "%d%% %+.1fW", s.percentage, s.liveWatts)
        case .wattsOnly:
            return String(format: "%+.1fW", s.liveWatts)
        case .percentAndSysLoad:
            return String(format: "%d%% • %.1fW", s.percentage, s.systemLoadWatts)
        case .percentAndTemp:
            return String(format: "%d%% • %.1f°C", s.percentage, s.temperatureCelsius)
        case .percentOnly:
            return "\(s.percentage)%"
        }
    }
}
