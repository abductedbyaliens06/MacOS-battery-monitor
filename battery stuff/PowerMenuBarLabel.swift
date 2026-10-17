import SwiftUI
import AppKit

/// Draw directly into the native status button, outside SwiftUI's scene graph.
struct PowerMenuBarLabel {
    let snapshot: BatterySnapshot
    let style: MenuBarLabelStyle
    let colorScheme: ColorScheme

    var accessibilityLabel: String { "\(snapshot.powerState.rawValue), \(title)" }
    var toolTip: String {
        "\(snapshot.powerState.rawValue) · \(snapshot.powerReadingSource)\n+ charging / − draining · Green = charging · Blue = charger input · Warm colors = drain / load"
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
        case .systemWatts: return s.systemLoadReadingAvailable ? String(format: "%.1f W", s.systemLoadWatts) : "— W"
        case .percentAndWatts: return "\(s.percentage)% \(battery)"
        case .percentAndSysLoad: return s.systemLoadReadingAvailable ? String(format: "%d%% · %.1f W", s.percentage, s.systemLoadWatts) : "\(s.percentage)% · — W"
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

    private var tint: NSColor {
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
        return tint
    }

    struct RenderingKey: Equatable {
        let title: String
        let symbol: String
        let tint: NSColor
        let scale: CGFloat
    }

    func renderingKey(scale: CGFloat) -> RenderingKey {
        RenderingKey(title: title, symbol: symbol, tint: tint, scale: scale)
    }

    /// Materialize pixels once. Drawing symbols lazily inside NSCustomImageRep
    /// can invalidate the status item's appearance while AppKit snapshots it.
    func renderedLabel(scale: CGFloat = 2) -> NSImage {
        let tint = tint
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: tint
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let width = ceil(text.size().width)
        let size = NSSize(width: width + 19, height: 18)
        let image = NSImage(size: size)
        let scale = max(1, scale)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)),
            pixelsHigh: Int(ceil(size.height * scale)), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return image }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        glyph?.draw(in: NSRect(x: 0, y: 3, width: 12, height: 12))
        text.draw(at: NSPoint(x: 17, y: floor((18 - text.size().height) / 2)))
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(bitmap)
        image.isTemplate = false
        return image
    }
}
