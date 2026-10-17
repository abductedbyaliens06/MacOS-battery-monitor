import AppKit
import SwiftUI

@MainActor final class ReentrantStatusButton: NSButton {
    var imageChanged: (() -> Void)?
    override var image: NSImage? { didSet { imageChanged?() } }
}

@main struct BatteryStatusRenderingTests {
    @MainActor static func main() {
        // Never register this command-line check as a Dock application.
        NSApplication.shared.setActivationPolicy(.prohibited)
        let button = ReentrantStatusButton(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        let renderer = BatteryStatusButtonRenderer(button: button)
        var snapshot = BatterySnapshot()
        snapshot.hasBattery = true
        snapshot.powerReadingAvailable = true
        snapshot.liveWatts = -12.3
        snapshot.powerState = .discharging
        func label(_ dark: Bool = false) -> PowerMenuBarLabel {
            PowerMenuBarLabel(snapshot: snapshot, style: .wattsOnly, colorScheme: dark ? .dark : .light)
        }
        // Model AppKit delivering another appearance update during image assignment.
        var reentrantCallbacks = 0
        button.imageChanged = {
            reentrantCallbacks += 1
            if reentrantCallbacks < 100 { renderer.update(label(), scale: 2) }
        }
        renderer.update(label(), scale: 2)
        check(reentrantCallbacks == 1, "Image assignment must not trigger recursive redraws")
        button.imageChanged = nil
        let firstImage = button.image
        for _ in 0..<10_000 { renderer.update(label(), scale: 2) }
        check(renderer.renderCount == 1 && button.image === firstImage, "Repeated appearance events must not replace the image")
        snapshot.percentage = 80
        snapshot.temperatureCelsius = 35
        snapshot.liveWatts = -12.301
        renderer.update(label(), scale: 2)
        check(renderer.renderCount == 1, "Unchanged displayed content must not redraw")
        snapshot.powerReadingSource = "Updated source"
        renderer.update(label(), scale: 2)
        check(renderer.renderCount == 1 && button.toolTip?.contains("Updated source") == true, "Tooltip updates must not redraw the image")
        snapshot.liveWatts = -20
        renderer.update(label(), scale: 2)
        check(renderer.renderCount == 2 && button.image !== firstImage, "Live watts must update")
        renderer.update(label(true), scale: 2)
        check(renderer.renderCount == 3, "Light/dark changes must update colors")
        renderer.update(label(true), scale: 1)
        check(renderer.renderCount == 4, "Moving to a different display scale must update pixels")
        for style in MenuBarLabelStyle.allCases {
            for dark in [false, true] {
                for scale: CGFloat in [1, 2] {
                    let image = PowerMenuBarLabel(snapshot: snapshot, style: style, colorScheme: dark ? .dark : .light).renderedLabel(scale: scale)
                    check(image.representations.count == 1 && image.representations[0] is NSBitmapImageRep, "Status image must contain eager bitmap pixels, with no drawing callback")
                    guard let bitmap = image.representations[0] as? NSBitmapImageRep else { exit(1) }
                    check(bitmap.pixelsHigh == Int(18 * scale), "Backing scale must match")
                    let data = bitmap.bitmapData!
                    let count = bitmap.bytesPerRow * bitmap.pixelsHigh
                    check((0..<count).contains { data[$0] != 0 }, "Rendered pixels must not be empty")
                }
            }
        }
        print("Status rendering: repeated appearances, display changes, live updates, and eager bitmap checks passed.")
    }
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
