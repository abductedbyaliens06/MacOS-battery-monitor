import SwiftUI
import Charts

enum PopoverTab: String, CaseIterable, Identifiable {
    case flow = "Flow"
    case health = "Health"
    case bms = "BMS & PD"
    case alerts = "Alerts"
    case raw = "Raw"
    
    var id: String { rawValue }
}

struct JuicyMenuView: View {
    @ObservedObject var service: BatteryService
    @State private var selectedTab: PopoverTab = .flow
    @State private var rawSearch: String = ""
    
    var body: some View {
        let s = service.snapshot
        
        VStack(alignment: .leading, spacing: 12) {
            // 1. Top Header: Ring + Percentage + Status Badge
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.12), lineWidth: 5)
                        .frame(width: 44, height: 44)
                    Circle()
                        .trim(from: 0, to: CGFloat(s.percentage) / 100.0)
                        .stroke(statusColor(for: s.powerState), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 44, height: 44)
                    Text("\(s.percentage)%")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("\(s.percentage)%")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                        Text(String(format: "(%.1f%%)", s.rawStateOfCharge))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text(timeSubtitle(s))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Text(s.powerState.rawValue)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor(for: s.powerState).opacity(0.18))
                    .foregroundStyle(statusColor(for: s.powerState))
                    .clipShape(Capsule())
            }
            
            // 2. Three Primary Live Metric Boxes (No Truncation)
            HStack(spacing: 8) {
                PopoverMetricCard(
                    title: s.liveWatts >= 0 ? "Battery Charge" : "Battery Draw",
                    value: String(format: "%+.1f W", s.liveWatts),
                    sub: String(format: "%+.1f%%/hr", s.chargeRatePercentPerHour),
                    color: s.liveWatts >= 0 ? .green : .orange
                )
                PopoverMetricCard(
                    title: "System Load",
                    value: String(format: "%.1f W", s.systemLoadWatts),
                    sub: s.adapterWatts > 0 ? "Brick: \(s.adapterWatts)W" : "On Battery",
                    color: .blue
                )
                PopoverMetricCard(
                    title: "Battery Temp",
                    value: s.temperatureCelsius > 0 ? String(format: "%.1f °C", s.temperatureCelsius) : "—",
                    sub: s.isThermalWarning ? "High Temp!" : "Nominal",
                    color: s.isThermalWarning ? .red : .primary
                )
            }
            
            // 3. Segmented Tab Bar inside Menu Bar Popover
            Picker("", selection: $selectedTab) {
                ForEach(PopoverTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            
            Divider()
            
            // 4. Tab Content Area
            Group {
                switch selectedTab {
                case .flow:
                    PopoverFlowTab(service: service)
                case .health:
                    PopoverHealthTab(s: s)
                case .bms:
                    PopoverBMSTab(s: s)
                case .alerts:
                    PopoverAlertsTab(service: service)
                case .raw:
                    PopoverRawTab(pairs: service.rawRegistryPairs, search: $rawSearch)
                }
            }
            
            Divider()
            
            // 5. Footer
            HStack {
                Button {
                    service.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.link)
                
                Spacer()
                
                Text("\(s.voltageMV) mV • \(s.amperageMA) mA")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.link)
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(width: 420)
    }
    
    private func statusColor(for state: PowerState) -> Color {
        switch state {
        case .charging, .fullyCharged: return .green
        case .pluggedInHolding: return .blue
        case .discharging: return .orange
        case .desktopAC, .unknown: return .secondary
        }
    }
    
    private func timeSubtitle(_ s: BatterySnapshot) -> String {
        if let mins = s.timeRemainingMinutes {
            let h = mins / 60
            let m = mins % 60
            let suffix = s.powerState == .charging ? "to full" : "left"
            return String(format: "%dh %02dm %@ • %.1f / %.1f Wh", h, m, suffix, s.currentEnergyWH, s.maxEnergyWH)
        }
        if s.powerState == .pluggedInHolding {
            return String(format: "Wall power (Bypassed) • %.1f / %.1f Wh", s.currentEnergyWH, s.maxEnergyWH)
        }
        return String(format: "%.1f / %.1f Wh stored", s.currentEnergyWH, s.maxEnergyWH)
    }
}

struct PopoverMetricCard: View {
    let title: String
    let value: String
    let sub: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
            Text(sub)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 1. Flow & Live Chart Tab
struct PopoverFlowTab: View {
    @ObservedObject var service: BatteryService
    
    var body: some View {
        let s = service.snapshot
        VStack(alignment: .leading, spacing: 10) {
            Text("3-WAY POWER ROUTER")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            
            HStack(spacing: 6) {
                MiniFlowPill(label: "Wall In", watts: String(format: "%.1fW", s.wallInputWatts), color: .purple)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                MiniFlowPill(label: "Mac Load", watts: String(format: "%.1fW", s.systemLoadWatts), color: .blue)
                Image(systemName: s.liveWatts >= 0 ? "plus" : "minus")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                MiniFlowPill(label: "Battery", watts: String(format: "%+.1fW", s.liveWatts), color: s.liveWatts >= 0 ? .green : .orange)
            }
            
            Text("LIVE POWER CHART (BATTERY vs SYSTEM LOAD)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            
            if service.history.count < 2 {
                Text("Sampling live power telemetry...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(height: 110)
                    .frame(maxWidth: .infinity)
            } else {
                Chart {
                    ForEach(service.history) { pt in
                        LineMark(
                            x: .value("Time", pt.timestamp),
                            y: .value("W", pt.batteryWatts),
                            series: .value("Type", "Battery")
                        )
                        .foregroundStyle(.green)
                        
                        LineMark(
                            x: .value("Time", pt.timestamp),
                            y: .value("W", pt.systemLoadWatts),
                            series: .value("Type", "System")
                        )
                        .foregroundStyle(.blue)
                    }
                    RuleMark(y: .value("Zero", 0))
                        .foregroundStyle(.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(dash: [3, 3]))
                }
                .frame(height: 110)
            }
            
            HStack {
                Text(String(format: "Peak Charge: +%.1fW", service.sessionPeakChargeWatts))
                Spacer()
                Text(String(format: "Peak Draw: -%.1fW", service.sessionPeakDrawWatts))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }
}

struct MiniFlowPill: View {
    let label: String
    let watts: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Text(watts)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - 2. Dual Health & Cell Voltages Tab
struct PopoverHealthTab: View {
    let s: BatterySnapshot
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DUAL HEALTH & CAPACITY")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            
            CompactRow(
                label: "macOS Health (Smoothed)",
                value: s.nominalHealthPercentage > 0 ? String(format: "%.1f%% (%d mAh)", s.nominalHealthPercentage, s.nominalMaxCapacityMAH) : "—"
            )
            CompactRow(
                label: "Raw Chemical Health",
                value: s.rawHealthPercentage > 0 ? String(format: "%.1f%% (%d mAh)", s.rawHealthPercentage, s.rawMaxCapacityMAH) : "—"
            )
            CompactRow(
                label: "Factory Design Capacity",
                value: s.designCapacityMAH > 0 ? String(format: "%d mAh (%.1f Wh)", s.designCapacityMAH, s.designEnergyWH) : "—"
            )
            CompactRow(
                label: "Current Stored Capacity",
                value: String(format: "%d mAh (%.1f Wh)", s.currentCapacityMAH, s.currentEnergyWH)
            )
            CompactRow(
                label: "Cycle Count / Rated",
                value: "\(s.cycleCount) / \(s.designCycleCount) cycles (\(s.conditionText))"
            )
            
            if !s.cellVoltagesMV.isEmpty {
                Divider().padding(.vertical, 2)
                Text("3S LITHIUM-ION CELL VOLTAGES (Δ \(s.cellDeltaMV) mV)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                
                HStack(spacing: 8) {
                    ForEach(Array(s.cellVoltagesMV.enumerated()), id: \.offset) { idx, mv in
                        VStack(spacing: 2) {
                            Text("Cell \(idx + 1)")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Text("\(mv) mV")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(5)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }
}

// MARK: - 3. Charger Handshake & BMS Lifetime Tab
struct PopoverBMSTab: View {
    let s: BatterySnapshot
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("USB-C PD / MAGSAFE HANDSHAKE")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            
            CompactRow(
                label: "Adapter Rating & PDO",
                value: s.adapterWatts > 0
                    ? String(format: "%dW (%.1fV @ %.2fA)", s.adapterWatts, s.adapterVoltageV, s.adapterCurrentA)
                    : "Unplugged"
            )
            CompactRow(
                label: "Wall Input / Conversion Loss",
                value: String(format: "%.1f W in  •  %.2f W loss", s.wallInputWatts, s.adapterLossWatts)
            )
            CompactRow(label: "Charger Identity", value: "\(s.adapterName) (\(s.adapterManufacturer))")
            
            Divider().padding(.vertical, 2)
            
            Text("BMS BLACK-BOX LIFETIME EXTREMES")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            
            CompactRow(
                label: "Lifetime Min / Max Temp",
                value: "\(s.lifetimeMinTempC.map { String(format: "%.1f°C", $0) } ?? "—")  /  \(s.lifetimeMaxTempC.map { String(format: "%.1f°C", $0) } ?? "—")"
            )
            CompactRow(
                label: "Peak Charge / Discharge",
                value: "+\(s.peakChargeCurrentMA ?? 0) mA  /  \(s.peakDischargeCurrentMA ?? 0) mA"
            )
            CompactRow(
                label: "Operating / High-SoC Time",
                value: "\(s.totalOperatingHours ?? 0) hrs  •  \(s.highSocHours ?? 0) hrs at high SoC"
            )
            CompactRow(
                label: "BMS Controller & Serial",
                value: "\(s.deviceName) • \(s.serialNumber)"
            )
        }
    }
}

// MARK: - 4. Alerts, Menu Bar Format & Screen Glow Tab
struct PopoverAlertsTab: View {
    @ObservedObject var service: BatteryService
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Menu Bar Format")
                    .font(.caption.weight(.semibold))
                Spacer()
                Picker("", selection: $service.labelStyle) {
                    ForEach(MenuBarLabelStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
            }
            
            Divider()
            
            Toggle("Enable Custom Battery Threshold Alerts", isOn: $service.alertsEnabled)
                .font(.caption.weight(.semibold))
            
            Toggle("Juicy-Style Full-Screen Neon Border Glow", isOn: $service.screenGlowEnabled)
                .font(.caption)
                .disabled(!service.alertsEnabled)
            
            HStack {
                Text("Low Alert: \(Int(service.lowBatteryThreshold))%")
                    .font(.caption2.monospaced())
                    .frame(width: 95, alignment: .leading)
                Slider(value: $service.lowBatteryThreshold, in: 5...45, step: 5)
            }
            
            HStack {
                Text("High Limit: \(Int(service.highChargeLimitThreshold))%")
                    .font(.caption2.monospaced())
                    .frame(width: 95, alignment: .leading)
                Slider(value: $service.highChargeLimitThreshold, in: 60...95, step: 5)
            }
            
            HStack(spacing: 8) {
                Button("Test Green Glow") {
                    service.triggerScreenEdgeGlow(color: .systemGreen)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)
                
                Button("Test Orange Glow") {
                    service.triggerScreenEdgeGlow(color: .systemOrange)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - 5. Searchable Raw IORegistry Tab
struct PopoverRawTab: View {
    let pairs: [(key: String, value: String)]
    @Binding var search: String
    
    var filtered: [(key: String, value: String)] {
        guard !search.isEmpty else { return pairs }
        return pairs.filter {
            $0.key.localizedCaseInsensitiveContains(search) ||
            $0.value.localizedCaseInsensitiveContains(search)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search IORegistry keys (e.g. Capacity, Temp, Cell)...", text: $search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filtered, id: \.key) { item in
                        HStack(alignment: .top) {
                            Text(item.key)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .frame(width: 210, alignment: .leading)
                            Spacer()
                            Text(item.value)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                        Divider()
                    }
                }
            }
            .frame(height: 155)
        }
    }
}

struct CompactRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced, weight: .medium))
        }
    }
}
