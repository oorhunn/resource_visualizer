import Charts
import SwiftUI

/// View state that outlives redraws; SwiftUI's @State macro is unavailable without Xcode.
@MainActor @Observable
final class DashboardState {
    var filter = ""
    var order = [KeyPathComparator(\ProcessRow.cpu, order: .reverse)]
    var zoomedCore: Int? // CPU core shown in the transistor-level zoom, if any
}

struct DashboardView: View {
    @Bindable var monitor: Monitor
    @Bindable var state: DashboardState
    /// Receives the content height that ends just below the chip card.
    var fitHeight: (CGFloat) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(Machine.model).font(.title2.bold())
                    Spacer()
                    Text("Refresh").foregroundStyle(.secondary)
                    Picker("Refresh", selection: $monitor.interval) {
                        ForEach([0.5, 1, 2, 5], id: \.self) { Text("\($0, specifier: "%g") s").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                tiles
                HStack(alignment: .top, spacing: 16) {
                    Card("Last 2 minutes") { HistoryChart(history: monitor.history) }
                    Card("Memory") { MemoryBreakdown(memory: monitor.memory) }
                        .frame(width: 280)
                }
                Card("Chip") {
                    if let id = state.zoomedCore, let core = monitor.cores.first(where: { $0.id == id }) {
                        CoreZoomView(core: core) { withAnimation(.snappy) { state.zoomedCore = nil } }
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        ChipView(cores: monitor.cores, gpu: monitor.gpus.first, memory: monitor.memory) { id in
                            withAnimation(.snappy) { state.zoomedCore = id }
                        }
                        .frame(height: 300)
                        .transition(.scale(scale: 1.2).combined(with: .opacity))
                        Text("Layout generated from the reported core counts. Height and colour show load; "
                            + "GPU load is one figure for all cores, and the Neural Engine is not reported. "
                            + "Click a CPU core to zoom in to its transistors.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("content")).maxY + 20 } action: { fitHeight($0) }
                Card("Cores") { CoreGrid(cores: monitor.cores) }
                Card("Processes") { ProcessTable(processes: monitor.processes, state: state) }
            }
            .padding(20)
            .coordinateSpace(.named("content"))
        }
        .frame(minWidth: 760, minHeight: 640)
    }

    private var tiles: some View {
        HStack(spacing: 16) {
            Tile(title: "CPU", value: Format.percent(monitor.cpuAverage),
                 detail: "\(monitor.cores.count) cores", fraction: monitor.cpuAverage.map { $0 / 100 })
            Tile(title: "Memory", value: Format.percent(monitor.memory.usedPercent),
                 detail: "\(Format.bytes(monitor.memory.used)) of \(Format.bytes(monitor.memory.total))",
                 fraction: monitor.memory.usedPercent / 100)
            Tile(title: "GPU", value: Format.percent(monitor.gpuUtilization),
                 detail: monitor.gpus.first.map { gpu in
                     gpu.cores.map { "\(gpu.name) · \($0) cores" } ?? gpu.name
                 } ?? "Not reported",
                 fraction: monitor.gpuUtilization.map { $0 / 100 })
            Tile(title: "Swap", value: Format.bytes(monitor.memory.swapUsed),
                 detail: "of \(Format.bytes(monitor.memory.swapTotal))",
                 fraction: monitor.memory.swapTotal == 0 ? 0
                     : Double(monitor.memory.swapUsed) / Double(monitor.memory.swapTotal))
        }
    }
}

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct Tile: View {
    let title: String
    let value: String
    let detail: String
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit().contentTransition(.numericText())
            Meter(fraction, color: .level(fraction.map { $0 * 100 }))
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct HistoryChart: View {
    let history: [HistoryPoint]

    var body: some View {
        Chart(history) { point in
            LineMark(x: .value("Sample", point.id), y: .value("Percent", point.cpu),
                     series: .value("Series", "CPU"))
                .foregroundStyle(by: .value("Series", "CPU"))
            LineMark(x: .value("Sample", point.id), y: .value("Percent", point.memory),
                     series: .value("Series", "Memory"))
                .foregroundStyle(by: .value("Series", "Memory"))
        }
        .chartForegroundStyleScale(["CPU": Color.blue, "Memory": Color.purple])
        .chartYScale(domain: 0...100)
        .chartYAxis { AxisMarks(values: [0, 50, 100]) { AxisGridLine(); AxisValueLabel("\($0.as(Int.self) ?? 0)%") } }
        .chartXAxis(.hidden)
        .chartXScale(domain: (history.last?.id ?? 0) - Monitor.historyLength + 1 ... max(history.last?.id ?? 1, 1))
        .frame(height: 180)
    }
}

private struct MemoryBreakdown: View {
    let memory: MemorySample

    var body: some View {
        let total = Double(max(memory.total, 1))
        let rows: [(String, UInt64, Color)] = [
            ("App", memory.app, .blue), ("Wired", memory.wired, .orange),
            ("Compressed", memory.compressed, .pink), ("Cached", memory.cached, .gray),
        ]
        VStack(alignment: .leading, spacing: 10) {
            Meter(segments: rows.map { (Double($0.1) / total, $0.2) }, height: 12)
            ForEach(rows, id: \.0) { row in
                HStack {
                    Circle().fill(row.2).frame(width: 8, height: 8)
                    Text(row.0)
                    Spacer()
                    Text(Format.bytes(row.1)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            Divider()
            HStack {
                Text("Used").bold()
                Spacer()
                Text("\(Format.bytes(memory.used)) of \(Format.bytes(memory.total))").monospacedDigit()
            }
            .font(.callout)
        }
    }
}

private struct CoreGrid: View {
    let cores: [CoreSample]

    var body: some View {
        let groups: [(String, [CoreSample])] = [
            ("Performance", cores.filter { $0.type == "P" }),
            ("Efficiency", cores.filter { $0.type == "E" }),
            ("Cores", cores.filter { $0.type != "P" && $0.type != "E" }),
        ].filter { !$0.1.isEmpty }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 24) {
                ForEach(groups, id: \.0) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        let busy = group.1.compactMap(\.busy)
                        Text("\(group.0) · \(Format.percent(busy.isEmpty ? nil : busy.reduce(0, +) / Double(busy.count)))")
                            .font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            ForEach(group.1) { CoreBar(core: $0).frame(width: 18, height: 90) }
                        }
                    }
                }
            }
            HStack(spacing: 16) {
                Label("User", systemImage: "circle.fill").foregroundStyle(Color.userTime)
                Label("System", systemImage: "circle.fill").foregroundStyle(Color.systemTime)
            }
            .font(.caption)
            .labelStyle(LegendLabelStyle())
        }
    }
}

private struct LegendLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 7))
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

private struct ProcessTable: View {
    let processes: [ProcessSample]
    @Bindable var state: DashboardState

    var body: some View {
        let query = state.filter.trimmingCharacters(in: .whitespaces)
        let rows = processes
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || String($0.id).contains(query) }
            .map(ProcessRow.init)
            .sorted(using: state.order)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Filter by name or PID", text: $state.filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                Text("\(rows.count) of \(processes.count)").font(.caption).foregroundStyle(.secondary)
            }
            Table(rows, sortOrder: $state.order) {
                TableColumn("Name", value: \.name)
                TableColumn("PID", value: \.pid) { Text(String($0.pid)).monospacedDigit() }
                    .width(70)
                TableColumn("CPU", value: \.cpu) { row in
                    Text(row.cpu < 0 ? "–" : String(format: "%.1f%%", row.cpu)).monospacedDigit()
                        .foregroundStyle(Color.level(row.cpu < 0 ? nil : row.cpu))
                }
                .width(80)
                TableColumn("Memory", value: \.memory) { Text(Format.bytes($0.memory)).monospacedDigit() }
                    .width(100)
            }
            .frame(height: 360)
        }
    }
}

/// Table rows need non-optional sort keys; a missing CPU reading sorts as -1.
struct ProcessRow: Identifiable {
    let id: Int
    let pid: Int
    let name: String
    let cpu: Double
    let memory: UInt64

    init(_ p: ProcessSample) {
        id = p.id
        pid = p.id
        name = p.name
        cpu = p.cpu ?? -1
        memory = p.memory
    }
}
