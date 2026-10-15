import SwiftUI
import Charts

// Shared surfaces stay neutral so color carries meaning, rather than decorating every row.
private enum PowerUI {
    static let mint = Color(red: 0.16, green: 0.66, blue: 0.46)
    static let blue = Color(red: 0.24, green: 0.51, blue: 0.88)
    static let orange = Color(red: 0.87, green: 0.40, blue: 0.14)

    static func intensity(_ watts: Double) -> Color {
        switch abs(watts) {
        case ..<10: return mint
        case ..<20: return Color(red: 0.72, green: 0.52, blue: 0.10)
        case ..<40: return orange
        default: return .red
        }
    }

    static func watts(_ value: Double, available: Bool, signed: Bool = false) -> String {
        guard available else { return "—" }
        return String(format: signed ? "%+.1f" : "%.1f", abs(value) < 0.05 ? 0 : value)
    }
}

enum PopoverTab: String, CaseIterable, Identifiable {
    case flow = "Power"
    case health = "Battery"
    case bms = "Hardware"
    case alerts = "Settings"
    case raw = "Inspector"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .flow: return "waveform.path"
        case .health: return "heart"
        case .bms: return "cpu"
        case .alerts: return "slider.horizontal.3"
        case .raw: return "curlybraces"
        }
    }
}

struct JuicyMenuView: View {
    @ObservedObject var service: BatteryService
    @State private var selectedTab: PopoverTab = .flow
    @State private var rawSearch = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PowerUI.mint)
                    .frame(width: 34, height: 34)
                    .background(PowerUI.mint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Battery Monitor").font(.system(size: 14, weight: .semibold))
                    Text("Your Mac, at a glance").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { selectedTab = selectedTab == .alerts ? .flow : .alerts } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                        .background(selectedTab == .alerts ? PowerUI.mint.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedTab == .alerts ? PowerUI.mint : .secondary)
                .accessibilityLabel("Settings")
                .help("Settings and alerts")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 16)

            HStack(spacing: 4) {
                ForEach([PopoverTab.flow, .health, .bms]) { tab in
                    Button { selectedTab = tab } label: {
                        Label(tab.rawValue, systemImage: tab.symbol)
                            .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .foregroundStyle(selectedTab == tab ? Color.primary : .secondary)
                            .background(selectedTab == tab ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                if selectedTab == tab {
                                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.06))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                }
            }
            .padding(4)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !service.snapshot.hasBattery {
                        ContentUnavailableView("No battery detected", systemImage: "powerplug", description: Text("Battery monitoring is available on Macs with a built-in battery."))
                    } else {
                        switch selectedTab {
                        case .flow: PopoverFlowTab(service: service)
                        case .health: PopoverHealthTab(s: service.snapshot)
                        case .bms:
                            PopoverBMSTab(s: service.snapshot)
                            Button { selectedTab = .raw } label: {
                                HStack {
                                    Label("Open raw data inspector", systemImage: "curlybraces")
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption2)
                                }
                                .font(.system(size: 12, weight: .medium))
                                .padding(14)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        case .alerts: PopoverAlertsTab(service: service)
                        case .raw: PopoverRawTab(pairs: service.rawRegistryPairs, search: $rawSearch)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)

            Divider().opacity(0.5)
            HStack(spacing: 6) {
                Circle()
                    .fill(service.snapshot.powerReadingAvailable ? PowerUI.mint : Color.secondary)
                    .frame(width: 5, height: 5)
                Text(service.snapshot.powerReadingSource)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { service.refresh() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh battery data")
                .help("Refresh now")
                Menu {
                    Button("Raw data inspector") { selectedTab = .raw }
                    Button("Quit Battery Monitor") { NSApplication.shared.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 22, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More options")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .frame(width: 440, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { service.refresh() }
    }
}

private struct Surface<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.06)) }
    }
}

private struct BatteryHero: View {
    let s: BatterySnapshot
    private var tint: Color {
        guard s.powerReadingAvailable else { return .secondary }
        return s.liveWatts >= 0 ? PowerUI.mint : PowerUI.intensity(s.liveWatts)
    }
    private var direction: String {
        guard s.powerReadingAvailable else { return "Battery power" }
        if s.liveWatts > 0.05 { return "Charging battery" }
        if s.liveWatts < -0.05 { return "Battery draw" }
        return "Battery idle"
    }
    private var status: String {
        switch s.powerState {
        case .charging: return "Charging"
        case .discharging: return "On battery"
        case .pluggedInHolding: return "Charge paused"
        case .fullyCharged: return "Fully charged"
        case .desktopAC: return "External power"
        case .unknown: return "Unavailable"
        }
    }
    private var subtitle: String {
        guard s.powerReadingAvailable else { return "Waiting for a fresh reading" }
        if let minutes = s.timeRemainingMinutes {
            return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m \(s.powerState == .charging ? "until full" : "remaining") · Estimate"
        }
        switch s.powerState {
        case .charging: return "Power flowing into your battery"
        case .discharging: return "Powering your Mac from the battery"
        case .fullyCharged: return "Fully charged · Running on external power"
        case .pluggedInHolding: return "External power · Charging paused"
        default: return "Battery telemetry"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(direction).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Label(status,
                      systemImage: s.powerState == .discharging ? "battery.75" : "powerplug.fill")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05), in: Capsule())
            }
            HStack(alignment: .center) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(PowerUI.watts(s.liveWatts, available: s.powerReadingAvailable, signed: true))
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .tracking(-1.5)
                    Text("W").font(.system(size: 18, weight: .medium)).foregroundStyle(Color.secondary)
                }
                .foregroundStyle(tint)
                Spacer()
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.08), lineWidth: 4)
                    Circle().trim(from: 0, to: CGFloat(min(100, max(0, s.percentage))) / 100)
                        .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(s.percentage)%").font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .frame(width: 54, height: 54)
                .accessibilityLabel("Battery level \(s.percentage) percent")
            }
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(LinearGradient(colors: [tint.opacity(0.12), tint.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(tint.opacity(0.17)) }
    }
}

private struct MetricTile: View {
    let title: String
    let symbol: String
    let value: String
    let unit: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
                Text(unit).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PopoverFlowTab: View {
    @ObservedObject var service: BatteryService
    var body: some View {
        let s = service.snapshot
        BatteryHero(s: s)
        if let session = service.sessions.current ?? service.sessions.completed.first {
            BatterySessionCard(session: session, active: service.sessions.current != nil)
        }
        HStack(spacing: 8) {
            MetricTile(title: "Mac load", symbol: "laptopcomputer", value: PowerUI.watts(s.systemLoadWatts, available: s.powerReadingAvailable), unit: "W")
            MetricTile(title: "Temperature", symbol: "thermometer.medium", value: s.temperatureCelsius.map { String(format: "%.1f", $0) } ?? "—", unit: "°C", tint: s.isThermalWarning ? .red : .primary)
            MetricTile(title: "Stored energy", symbol: "battery.75", value: s.currentEnergyWH > 0 ? String(format: "%.1f", s.currentEnergyWH) : "—", unit: "Wh")
        }
        Text(s.temperatureCelsius == nil ? "Battery temperature unavailable from this Mac's sensors." : "Battery temperature · \(s.temperatureReadingSource)")
            .font(.system(size: 10)).foregroundStyle(.secondary)
        Surface("Power flow") {
            HStack(spacing: 8) {
                FlowNode(title: "Charger", symbol: "powerplug", value: PowerUI.watts(s.wallInputWatts, available: s.inputReadingAvailable), active: s.powerState != .discharging)
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                FlowNode(title: "Mac", symbol: "laptopcomputer", value: PowerUI.watts(s.systemLoadWatts, available: s.powerReadingAvailable), active: true)
                Image(systemName: s.liveWatts < 0 ? "arrow.left" : "arrow.right").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                FlowNode(title: "Battery", symbol: "battery.75", value: PowerUI.watts(abs(s.liveWatts), available: s.powerReadingAvailable), active: s.powerReadingAvailable && abs(s.liveWatts) > 0.05)
            }
            Text(s.powerState == .discharging ? "Battery → Mac · Charger disconnected" : (s.liveWatts < -0.05 ? "Charger + battery → Mac" : (s.liveWatts > 0.05 ? "Charger → Mac + battery" : "Charger → Mac · Battery idle")))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        Surface {
            HStack {
                Text("Power over time").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Last 2 min").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                ChartLegend(title: "Battery (+ in / − out)", color: PowerUI.mint)
                ChartLegend(title: "Mac load", color: PowerUI.blue)
            }
            if service.history.count < 2 {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.path").font(.title2).foregroundStyle(.tertiary)
                    Text("Collecting power samples").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).frame(height: 82)
            } else {
                Chart {
                    ForEach(service.history) { sample in
                        LineMark(x: .value("Time", sample.timestamp), y: .value("Watts", sample.batteryWatts), series: .value("Series", "Battery"))
                            .foregroundStyle(PowerUI.mint).lineStyle(StrokeStyle(lineWidth: 2))
                        LineMark(x: .value("Time", sample.timestamp), y: .value("Watts", sample.systemLoadWatts), series: .value("Series", "Mac"))
                            .foregroundStyle(PowerUI.blue).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                    RuleMark(y: .value("Zero", 0)).foregroundStyle(Color.primary.opacity(0.15))
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel(anchor: .trailing).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 82)
                .accessibilityLabel("Battery power and Mac load over the past two minutes, in watts")
            }
            HStack {
                Text(String(format: "Peak charge  +%.1f W", service.sessionPeakChargeWatts))
                Spacer()
                Text(String(format: "Peak draw  −%.1f W", service.sessionPeakDrawWatts))
            }
            .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

private struct FlowNode: View {
    let title: String
    let symbol: String
    let value: String
    let active: Bool
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(active ? PowerUI.mint : .secondary)
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text("\(value) W").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ChartLegend: View {
    let title: String
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 12, height: 3)
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct PopoverHealthTab: View {
    let s: BatterySnapshot
    var body: some View {
        Surface {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Battery health").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Text(s.nominalHealthPercentage > 0 ? String(format: "%.1f%%", s.nominalHealthPercentage) : "—")
                        .font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                Spacer()
                Label(s.conditionText, systemImage: s.conditionText == "Normal" ? "checkmark.shield" : "exclamationmark.shield")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(s.conditionText == "Normal" ? PowerUI.mint : PowerUI.orange)
                    .padding(8).background(Color.primary.opacity(0.04), in: Capsule())
            }
            ProgressView(value: min(100, max(0, s.nominalHealthPercentage)), total: 100).tint(PowerUI.mint)
            Text("Smoothed capacity compared with factory capacity.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        HStack(spacing: 8) {
            MetricTile(title: "Charge cycles", symbol: "arrow.trianglehead.2.clockwise.rotate.90", value: "\(s.cycleCount)", unit: "/ \(s.designCycleCount)")
            MetricTile(title: "Charge rate", symbol: "bolt", value: s.powerReadingAvailable ? String(format: "%+.1f", s.chargeRatePercentPerHour) : "—", unit: "%/h")
        }
        Surface("Capacity") {
            CompactRow(label: "Stored now", value: String(format: "%.1f Wh · %d mAh", s.currentEnergyWH, s.currentCapacityMAH))
            CompactRow(label: "Full charge · raw", value: s.rawMaxCapacityMAH > 0 ? String(format: "%.1f Wh · %d mAh", s.maxEnergyWH, s.rawMaxCapacityMAH) : "—")
            CompactRow(label: "Full charge · smoothed", value: s.nominalMaxCapacityMAH > 0 ? "\(s.nominalMaxCapacityMAH) mAh" : "—")
            CompactRow(label: "Factory capacity", value: s.designCapacityMAH > 0 ? String(format: "%.1f Wh · %d mAh", s.designEnergyWH, s.designCapacityMAH) : "—")
            CompactRow(label: "Chemical health · raw", value: s.rawHealthPercentage > 0 ? String(format: "%.1f%%", s.rawHealthPercentage) : "—")
            CompactRow(label: "Gauge charge level", value: String(format: "%.1f%%", s.rawStateOfCharge))
        }
        if !s.cellVoltagesMV.isEmpty {
            Surface("Cell balance") {
                HStack(spacing: 8) {
                    ForEach(Array(s.cellVoltagesMV.enumerated()), id: \.offset) { index, voltage in
                        VStack(spacing: 5) {
                            Text("Cell \(index + 1)").font(.system(size: 10)).foregroundStyle(.secondary)
                            Text("\(voltage) mV").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        }.frame(maxWidth: .infinity)
                    }
                }
                Text("Difference between cells: \(s.cellDeltaMV) mV").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

struct PopoverBMSTab: View {
    let s: BatterySnapshot
    var body: some View {
        Surface("Power adapter") {
            HStack(spacing: 12) {
                Image(systemName: "powerplug.fill").font(.system(size: 24)).foregroundStyle(PowerUI.blue)
                    .frame(width: 48, height: 48).background(PowerUI.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.adapterName).font(.system(size: 14, weight: .semibold))
                    Text(s.adapterManufacturer).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Divider().opacity(0.5)
            CompactRow(label: "Adapter rating", value: s.adapterWatts > 0 ? "\(s.adapterWatts) W" : "—")
            CompactRow(label: "Negotiated voltage / current", value: s.adapterVoltageV > 0 ? String(format: "%.1f V / %.2f A", s.adapterVoltageV, s.adapterCurrentA) : "—")
            CompactRow(label: "Charger input", value: s.inputReadingAvailable ? String(format: "%.1f W", s.wallInputWatts) : "—")
            CompactRow(label: "Conversion loss · registry", value: String(format: "%.2f W", s.adapterLossWatts))
            CompactRow(label: "Serial number", value: s.adapterSerial)
        }
        Surface("Lifetime records") {
            CompactRow(label: "Lowest temperature", value: s.lifetimeMinTempC.map { String(format: "%.1f °C", $0) } ?? "—")
            CompactRow(label: "Highest temperature", value: s.lifetimeMaxTempC.map { String(format: "%.1f °C", $0) } ?? "—")
            CompactRow(label: "Peak charging current", value: s.peakChargeCurrentMA.map { "\($0) mA" } ?? "—")
            CompactRow(label: "Peak discharge current", value: s.peakDischargeCurrentMA.map { "\($0) mA" } ?? "—")
            CompactRow(label: "Operating time", value: s.totalOperatingHours.map { "\($0) h" } ?? "—")
            CompactRow(label: "Time at high charge", value: s.highSocHours.map { "\($0) h" } ?? "—")
        }
        Surface("Battery controller") {
            CompactRow(label: "Device", value: s.deviceName)
            CompactRow(label: "Serial number", value: s.serialNumber)
            CompactRow(label: "Firmware", value: s.firmwareVersion)
            CompactRow(label: "Voltage / current", value: String(format: "%.2f V / %+.3f A", Double(s.voltageMV) / 1000, Double(s.amperageMA) / 1000))
        }
    }
}

struct PopoverAlertsTab: View {
    @ObservedObject var service: BatteryService
    var body: some View {
        Text("Make it yours").font(.system(size: 22, weight: .semibold, design: .rounded)).padding(.bottom, 2)
        Text("Your display and alert preferences are saved automatically on this Mac.").font(.system(size: 11)).foregroundStyle(.secondary)
        Surface("Menu bar") {
            Picker("Display", selection: $service.labelStyle) {
                ForEach(MenuBarLabelStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            .font(.system(size: 12))
            Text("Battery watts show charging (+) or draining (−). Charger input includes your Mac's load.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Charging stays green at every speed. Charger input is blue.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Battery drain / Mac load")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 0) {
                ForEach(Array([("<10 W", PowerUI.mint), ("10–20", Color(red: 0.72, green: 0.52, blue: 0.10)), ("20–40", PowerUI.orange), ("40+ W", Color.red)].enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 5) {
                        Capsule().fill(item.1).frame(height: 3)
                        Text(item.0).font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 3)
                }
            }
            Text("Warm colors indicate higher drain or load, not battery damage.").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        Surface("Battery alerts") {
            Toggle("Threshold notifications", isOn: $service.alertsEnabled).font(.system(size: 12, weight: .medium))
                .toggleStyle(.switch).controlSize(.small)
            Text("A heads-up when your battery crosses either threshold.").font(.system(size: 11)).foregroundStyle(.secondary)
            Divider().opacity(0.5)
            ThresholdSlider(title: "Low battery", value: $service.lowBatteryThreshold, range: 5...45)
            ThresholdSlider(title: "Charge target", value: $service.highChargeLimitThreshold, range: 60...95)
        }
        Surface("Screen glow") {
            Toggle("Highlight the screen edge", isOn: $service.screenGlowEnabled).font(.system(size: 12, weight: .medium))
                .toggleStyle(.switch).controlSize(.small).disabled(!service.alertsEnabled)
            Text("A brief glow accompanies threshold notifications.").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Preview charge glow") { service.triggerScreenEdgeGlow(color: .systemGreen) }
                Button("Preview low glow") { service.triggerScreenEdgeGlow(color: .systemOrange) }
            }.buttonStyle(.bordered).controlSize(.small)
        }
    }
}

private struct ThresholdSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value))%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            Slider(value: $value, in: range, step: 5).tint(PowerUI.mint).accessibilityLabel(title)
        }
    }
}

struct PopoverRawTab: View {
    let pairs: [(key: String, value: String)]
    @Binding var search: String
    private var filtered: [(key: String, value: String)] {
        guard !search.isEmpty else { return pairs }
        return pairs.filter { $0.key.localizedCaseInsensitiveContains(search) || $0.value.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        HStack {
            Text("Data inspector").font(.system(size: 22, weight: .semibold, design: .rounded))
            Spacer()
            Text("\(filtered.count) keys").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        TextField("Search keys or values", text: $search).textFieldStyle(.roundedBorder).accessibilityLabel("Search raw battery data")
        if filtered.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(filtered, id: \.key) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.key).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                        Text(item.value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}

struct CompactRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit()
                .multilineTextAlignment(.trailing).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct BatterySessionCard: View {
    let session: BatterySession
    let active: Bool
    private var duration: String {
        let minutes = Int(session.observedSeconds / 60)
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
    var body: some View {
        Surface {
            HStack {
                Label(active ? (session.startedAtUnplug ? "Since unplugging" : "Monitoring on battery") : "Last battery session", systemImage: "battery.75")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(session.startedAt, style: .time).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                statistic(duration, label: "observed")
                Spacer()
                statistic("\(session.percentagePointsUsed)%", label: "battery used")
                Spacer()
                statistic(session.averageDrawWatts.map { String(format: "%.1f W", $0) } ?? "—", label: "average draw")
            }
            Text(session.measuredSeconds >= 1
                 ? String(format: "%.2f Wh measured · %.0f%% power coverage", session.energyUsedWh, session.coverage * 100)
                 : "Collecting power samples…")
                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            Text("Observed time excludes sleep and gaps. Sessions start fresh when monitoring resumes.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private func statistic(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
