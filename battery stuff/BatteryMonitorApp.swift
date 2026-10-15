import SwiftUI
import AppKit

@main
struct BatteryMonitorApp: App {
    @StateObject private var batteryService = BatteryService()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            JuicyMenuView(service: batteryService)
        } label: {
            PowerMenuBarLabel(snapshot: batteryService.snapshot, style: batteryService.labelStyle)
        }
        .menuBarExtraStyle(.window)
    }
}

/// A non-template image preserves wattage colors in the macOS status bar.
struct PowerMenuBarLabel: View {
    let snapshot: BatterySnapshot
    let style: MenuBarLabelStyle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: renderedLabel())
            .accessibilityLabel("\(snapshot.powerState.rawValue), \(title)")
            .help("\(snapshot.powerState.rawValue) · \(snapshot.powerReadingSource)\n+ charging / − draining · Green = charging · Blue = charger input · Warm colors = drain / load")
    }

    private var displayedWatts: Double {
        switch style {
        case .inputWatts: return snapshot.wallInputWatts
        case .systemWatts, .percentAndSysLoad: return snapshot.systemLoadWatts
        default: return abs(snapshot.liveWatts)
        }
    }

    private var title: String {
        let s = snapshot
        guard s.hasBattery else { return s.powerState == .desktopAC ? "AC" : "— W" }
        let battery = s.powerReadingAvailable ? String(format: "%+.1f W", abs(s.liveWatts) < 0.05 ? 0 : s.liveWatts) : "— W"
        switch style {
        case .wattsOnly: return battery
        case .inputWatts: return s.inputReadingAvailable ? String(format: "%.1f W", s.wallInputWatts) : "— W"
        case .systemWatts: return s.powerReadingAvailable ? String(format: "%.1f W", s.systemLoadWatts) : "— W"
        case .percentAndWatts: return "\(s.percentage)% \(battery)"
        case .percentAndSysLoad: return s.powerReadingAvailable ? String(format: "%d%% · %.1f W", s.percentage, s.systemLoadWatts) : "\(s.percentage)% · — W"
        case .percentAndTemp: return "\(s.percentage)% · " + (s.temperatureCelsius.map { String(format: "%.1f°C", $0) } ?? "—°C")
        case .percentOnly: return "\(s.percentage)%"
        }
    }

    private var symbol: String {
        if style == .inputWatts { return "powerplug.fill" }
        if style == .systemWatts || style == .percentAndSysLoad { return "waveform.path" }
        switch snapshot.powerState {
        case .charging: return "bolt.fill"
        case .discharging: return "arrow.down.right"
        case .pluggedInHolding, .fullyCharged, .desktopAC: return "powerplug.fill"
        case .unknown: return "ellipsis"
        }
    }

    private func renderedLabel() -> NSImage {
        let tint: NSColor
        if !snapshot.powerReadingAvailable || style == .percentOnly || style == .percentAndTemp {
            tint = colorScheme == .dark ? .white : .black
        } else if style == .inputWatts {
            tint = colorScheme == .dark ? NSColor(red: 0.42, green: 0.72, blue: 1, alpha: 1) : NSColor(red: 0.10, green: 0.40, blue: 0.72, alpha: 1)
        } else if (style == .wattsOnly || style == .percentAndWatts) && snapshot.liveWatts >= 0 {
            // Fast charging is expected; only discharge/load uses the warm intensity scale.
            tint = colorScheme == .dark ? NSColor(red: 0.40, green: 0.87, blue: 0.62, alpha: 1) : NSColor(red: 0.05, green: 0.48, blue: 0.27, alpha: 1)
        } else {
            switch displayedWatts {
            case ..<10: tint = colorScheme == .dark ? NSColor(red: 0.40, green: 0.87, blue: 0.62, alpha: 1) : NSColor(red: 0.05, green: 0.48, blue: 0.27, alpha: 1)
            case ..<20: tint = colorScheme == .dark ? NSColor(red: 0.96, green: 0.78, blue: 0.35, alpha: 1) : NSColor(red: 0.58, green: 0.38, blue: 0.02, alpha: 1)
            case ..<40: tint = colorScheme == .dark ? NSColor(red: 1, green: 0.60, blue: 0.32, alpha: 1) : NSColor(red: 0.75, green: 0.31, blue: 0.06, alpha: 1)
            default: tint = colorScheme == .dark ? NSColor(red: 1, green: 0.43, blue: 0.45, alpha: 1) : NSColor(red: 0.77, green: 0.15, blue: 0.20, alpha: 1)
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: tint
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let width = ceil(text.size().width)
        let image = NSImage(size: NSSize(width: width + 19, height: 18), flipped: false) { _ in
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
            let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            glyph?.draw(in: NSRect(x: 0, y: 3, width: 12, height: 12))
            text.draw(at: NSPoint(x: 17, y: floor((18 - text.size().height) / 2)))
            return true
        }
        image.isTemplate = false
        return image
    }
}
