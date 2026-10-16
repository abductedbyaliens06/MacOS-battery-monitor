import AppKit
import Combine
import SwiftUI

/// Keep telemetry alive, but only create a SwiftUI dashboard while it is visible.
@MainActor
final class BatteryStatusController: NSObject, NSPopoverDelegate {
    private let service: BatteryService
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var readings: AnyCancellable?
    private var appearanceObservation: NSKeyValueObservation?

    init(service: BatteryService) {
        self.service = service
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 440, height: 700)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        readings = service.$snapshot.combineLatest(service.$labelStyle)
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot, style in self?.updateLabel(snapshot: snapshot, style: style) }
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateLabel(snapshot: self.service.snapshot, style: self.service.labelStyle)
            }
        }
        updateLabel(snapshot: service.snapshot, style: service.labelStyle)
    }

    private func updateLabel(snapshot: BatterySnapshot, style: MenuBarLabelStyle) {
        guard let button = statusItem.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let label = PowerMenuBarLabel(snapshot: snapshot, style: style, colorScheme: dark ? .dark : .light)
        button.image = label.renderedLabel()
        button.setAccessibilityLabel(label.accessibilityLabel)
        button.toolTip = label.toolTip
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.contentViewController = NSHostingController(rootView: JuicyMenuView(service: service))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        // A hidden hosting controller would keep processing every telemetry update.
        popover.contentViewController = nil
    }
}
