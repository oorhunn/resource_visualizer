import SwiftUI

enum Format {
    static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = value
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit >= 3 ? String(format: "%.1f %@", value, units[unit])
            : String(format: "%.0f %@", value, units[unit])
    }

    static func bytes(_ value: UInt64) -> String { bytes(Double(value)) }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.0f%%", value)
    }
}

enum Machine {
    /// CPU brand, e.g. "Apple M3 Pro"; falls back to the machine name.
    static let model: String = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 1 else {
            return Foundation.Host.current().localizedName ?? "This Mac"
        }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }()
}

extension Color {
    static let userTime = Color.blue
    static let systemTime = Color.orange

    /// Same thresholds as the terminal bars: green below 50%, yellow below 80%, red above.
    static func level(_ percent: Double?) -> Color {
        guard let percent else { return .secondary }
        return percent < 50 ? .green : percent < 80 ? .yellow : .red
    }
}

/// Horizontal meter with a rounded track; segments are (fraction, color) and stack left to right.
struct Meter: View {
    var segments: [(Double, Color)]
    var height: CGFloat = 6

    init(_ fraction: Double?, color: Color, height: CGFloat = 6) {
        segments = [(fraction ?? 0, color)]
        self.height = height
    }

    init(segments: [(Double, Color)], height: CGFloat = 6) {
        self.segments = segments
        self.height = height
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                HStack(spacing: 0) {
                    ForEach(segments.indices, id: \.self) { i in
                        Rectangle().fill(segments[i].1)
                            .frame(width: geometry.size.width * min(max(segments[i].0, 0), 1))
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: height)
    }
}

/// Vertical per-core bar split into user and system time.
struct CoreBar: View {
    let core: CoreSample

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle().fill(Color.systemTime)
                    .frame(height: geometry.size.height * (core.system ?? 0) / 100)
                Rectangle().fill(Color.userTime)
                    .frame(height: geometry.size.height * (core.user ?? 0) / 100)
            }
            .frame(maxWidth: .infinity)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .help("Core \(core.id): \(Format.percent(core.busy)) busy "
            + "(user \(Format.percent(core.user)), system \(Format.percent(core.system)))")
    }
}
