import AppKit
import SwiftUI

@main struct UsageStudyUICheck {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let suite = "BatteryStudy.UI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var report = StudyReport(since: Date().addingTimeInterval(-3600), until: Date(), intervals: 720,
                                 seconds: 3600, batterySeconds: 3000, energyWh: 8.1)
        report.groups = [StudyGroup(id: "job:123:1", name: "python3 · PID 123", cpuSeconds: 600, awayCPUSeconds: 400,
                                   footprintPeak: 120_000_000, activitySeconds: 3000, coincidentWh: 6, coincidentSeconds: 2400),
                         StudyGroup(id: "app.editor", name: "Code Editor", cpuSeconds: 400, footprintPeak: 450_000_000, activitySeconds: 3500)]
        report.timeline = (0..<6).map { StudyTimelinePoint(date: Date().addingTimeInterval(Double($0 - 6) * 600), watts: Double(7 + $0 % 3), segment: 0) }
        let study = UsageStudyService(battery: nil, defaults: defaults, url: directory.appendingPathComponent("preview.sqlite"),
                                      startAutomatically: false, initialReport: report)
        for scheme in [ColorScheme.light, .dark] {
            let content = UsageStudyView(study: study).padding(20)
                .frame(width: 440).fixedSize(horizontal: false, vertical: true).background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                fputs("Study view could not render\n", stderr); exit(1)
            }
            try data.write(to: directory.appendingPathComponent(scheme == .dark ? "study-dark.png" : "study-light.png"))
        }
        print("Study view rendered in light and dark mode without starting collection or opening windows.")
    }
}
