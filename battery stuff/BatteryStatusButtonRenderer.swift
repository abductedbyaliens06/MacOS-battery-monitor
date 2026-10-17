import AppKit

/// Appearance notifications may repeat during AppKit's status-item snapshots.
/// Only mutate the button when its visible content actually changes.
@MainActor
final class BatteryStatusButtonRenderer {
    private let button: NSButton
    private var lastKey: PowerMenuBarLabel.RenderingKey?
    private var lastAccessibilityLabel: String?
    private var lastToolTip: String?
    private(set) var renderCount = 0

    init(button: NSButton) { self.button = button }

    func update(_ label: PowerMenuBarLabel, scale: CGFloat) {
        let key = label.renderingKey(scale: scale)
        if lastKey != key {
            // Set the guard before mutation, including reentrant appearance callbacks.
            lastKey = key
            button.image = label.renderedLabel(scale: scale)
            renderCount += 1
        }
        if lastAccessibilityLabel != label.accessibilityLabel {
            lastAccessibilityLabel = label.accessibilityLabel
            button.setAccessibilityLabel(label.accessibilityLabel)
        }
        if lastToolTip != label.toolTip {
            lastToolTip = label.toolTip
            button.toolTip = label.toolTip
        }
    }
}
