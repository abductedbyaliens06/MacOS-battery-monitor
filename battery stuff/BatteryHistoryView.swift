import SwiftUI
import Charts

private enum BatteryHistoryRange: String, CaseIterable, Identifiable {
    case hour = "1 hour", day = "24 hours", week = "7 days"
    var id: String { rawValue }
    var seconds: Double {
        switch self { case .hour: return 3600; case .day: return 86400; case .week: return 7 * 86400 }
    }
}

struct BatteryHistoryView: View {
    @ObservedObject var service: BatteryService
    @State private var range: BatteryHistoryRange = .day
    @State private var points: [BatteryHistoryBucket] = []
    @State private var chartEnd = Date()

    var body: some View {
        Text("Your energy timeline").font(.system(size: 22, weight: .semibold, design: .rounded))
        Picker("History period", selection: $range) {
            ForEach(BatteryHistoryRange.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented)
        Text("Minute averages · saved locally · gaps indicate missing observations")
            .font(.system(size: 10)).foregroundStyle(.secondary)
        if let message = service.storageMessage {
            Label(message, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange)
        }
        if points.isEmpty {
            ContentUnavailableView("Collecting history", systemImage: "chart.xyaxis.line", description: Text("Keep Battery Monitor running to build your timeline."))
        } else {
            Surface("Power · watts") {
                HStack(spacing: 14) {
                    legend("Battery (+ in / − out)", color: PowerUI.mint)
                    legend("Mac load", color: PowerUI.blue)
                }
                Chart {
                    ForEach(points) { point in
                        if let watts = point.battery.value {
                            LineMark(x: .value("Time", point.timestamp), y: .value("Watts", watts), series: .value("Segment", "battery-\(point.segmentID)"))
                                .foregroundStyle(PowerUI.mint).lineStyle(StrokeStyle(lineWidth: 2))
                            PointMark(x: .value("Time", point.timestamp), y: .value("Watts", watts)).foregroundStyle(PowerUI.mint).symbolSize(7)
                        }
                        if let watts = point.load.value {
                            LineMark(x: .value("Time", point.timestamp), y: .value("Watts", watts), series: .value("Segment", "load-\(point.segmentID)"))
                                .foregroundStyle(PowerUI.blue).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        }
                    }
                    RuleMark(y: .value("Zero", 0)).foregroundStyle(Color.primary.opacity(0.15))
                }.historyChart(start: chartEnd.addingTimeInterval(-range.seconds), end: chartEnd)
                    .accessibilityLabel("Battery power and Mac load, in watts, for the last \(range.rawValue)")
            }
            Surface("Battery level · percent") {
                Chart(points) { point in
                    LineMark(x: .value("Time", point.timestamp), y: .value("Battery percent", point.percentage), series: .value("Segment", point.segmentID.uuidString))
                        .foregroundStyle(PowerUI.blue).lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("Time", point.timestamp), y: .value("Battery percent", point.percentage)).foregroundStyle(PowerUI.blue).symbolSize(7)
                }.chartYScale(domain: 0...100)
                    .historyChart(start: chartEnd.addingTimeInterval(-range.seconds), end: chartEnd)
                    .accessibilityLabel("Battery percentage for the last \(range.rawValue)")
            }
            Surface("Battery temperature · °C") {
                if points.contains(where: { $0.temperature.value != nil }) {
                    Chart {
                        ForEach(points) { point in
                            if let temperature = point.temperature.value {
                                LineMark(x: .value("Time", point.timestamp), y: .value("Temperature Celsius", temperature), series: .value("Segment", point.segmentID.uuidString))
                                    .foregroundStyle(PowerUI.orange).lineStyle(StrokeStyle(lineWidth: 2))
                                PointMark(x: .value("Time", point.timestamp), y: .value("Temperature Celsius", temperature)).foregroundStyle(PowerUI.orange).symbolSize(7)
                            }
                        }
                    }.historyChart(start: chartEnd.addingTimeInterval(-range.seconds), end: chartEnd)
                        .accessibilityLabel("Battery temperature in degrees Celsius for the last \(range.rawValue)")
                } else { Text("No temperature readings in this period.").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
        if !service.sessions.completed.isEmpty {
            Text("Recent battery sessions").font(.system(size: 13, weight: .semibold)).padding(.top, 6)
            ForEach(service.sessions.completed.prefix(5)) { session in
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    BatterySessionCard(session: session, active: false)
                }
            }
        }
        Text("Energy totals cover measured intervals only. The app cannot reconstruct activity while it is closed or the Mac is asleep.")
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .onAppear { refresh() }
            .onChange(of: range) { _, _ in refresh() }
            .onChange(of: service.historyRevision) { _, _ in refresh() }
    }
    private func refresh() {
        chartEnd = Date()
        points = service.historyBuckets(since: chartEnd.addingTimeInterval(-range.seconds), until: chartEnd)
    }
    private func legend(_ title: String, color: Color) -> some View {
        Label { Text(title) } icon: { Circle().fill(color).frame(width: 5, height: 5) }
            .font(.system(size: 9)).foregroundStyle(.secondary)
    }
}

private extension View {
    func historyChart(start: Date, end: Date) -> some View {
        self.chartXScale(domain: start...end)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { AxisValueLabel().font(.system(size: 9)) } }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { AxisGridLine(); AxisValueLabel().font(.system(size: 9)) } }
            .frame(height: 105)
    }
}
