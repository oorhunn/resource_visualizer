import SwiftUI

/// Isometric model of the system on a chip: CPU clusters, GPU cores and the Neural Engine on the
/// die, with the unified memory packages beside it on the substrate. macOS does not expose the
/// real floorplan, so the layout is generated from the reported core and cluster counts. Block
/// height and colour follow load; the Neural Engine has no public load counter and stays unlit.
struct ChipView: View {
    let cores: [CoreSample]
    let gpu: GpuSample?
    let memory: MemorySample
    var labeled = true

    // A property wrapper rather than the @State macro, which is unavailable without Xcode.
    @StateObject private var motion = ChipMotion()

    var body: some View {
        let target = Loads(cores: cores, gpu: gpu, memory: memory)
        TimelineView(.animation(paused: motion.settled)) { timeline in
            let shown = motion.loads(at: timeline.date) ?? target
            let chip = ChipModel(cores: shown.applied(to: cores), gpu: shown.applied(to: gpu),
                                 memory: shown.applied(to: memory))
            Canvas { context, size in chip.draw(in: &context, size: size, labeled: labeled) }
        }
            .onChange(of: target) { _, new in motion.retarget(new) }
            .accessibilityElement()
            .accessibilityLabel("Chip")
            .accessibilityValue("CPU \(Format.percent(average(cores.compactMap(\.busy)))), "
                + "GPU \(Format.percent(gpu?.utilization)), "
                + "memory \(Format.percent(memory.total == 0 ? nil : memory.usedPercent))")
    }
}

/// Eases the drawn loads from one sample to the next; Canvas does not take part in SwiftUI
/// animations, so the chip is redrawn every frame until the transition settles.
@MainActor
private final class ChipMotion: ObservableObject {
    @Published private(set) var settled = true
    private var from = Loads()
    private var to: Loads?
    private var start = Date.distantPast
    private var timer: Task<Void, Never>?
    private static let duration = 0.6

    /// Loads partway from the previous sample to the latest one; nil before the first change.
    func loads(at date: Date) -> Loads? {
        guard let to else { return nil }
        let t = min(max(date.timeIntervalSince(start) / Self.duration, 0), 1)
        return from.blended(toward: to, by: 1 - pow(1 - t, 3)) // ease out
    }

    func retarget(_ target: Loads) {
        let now = Date.now
        from = loads(at: now) ?? target
        to = target
        start = now
        settled = false
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.duration))
            if !Task.isCancelled { self?.settled = true }
        }
    }
}

/// The values that drive block height and colour, keyed so they can be interpolated.
private struct Loads: Equatable {
    var cores: [Int: Double] = [:]
    var gpu: Double?
    var memory: Double?

    init() {}

    init(cores: [CoreSample], gpu: GpuSample?, memory: MemorySample) {
        for core in cores { self.cores[core.id] = core.busy }
        self.gpu = gpu?.utilization
        self.memory = memory.total == 0 ? nil : memory.usedPercent
    }

    func blended(toward target: Loads, by t: Double) -> Loads {
        func mix(_ a: Double?, _ b: Double?) -> Double? {
            guard let a, let b else { return b }
            return a + (b - a) * t
        }
        var result = target
        for (id, value) in target.cores { result.cores[id] = mix(cores[id], value) }
        result.gpu = mix(gpu, target.gpu)
        result.memory = mix(memory, target.memory)
        return result
    }

    func applied(to cores: [CoreSample]) -> [CoreSample] {
        cores.map { core in
            var core = core
            if core.busy != nil, let busy = self.cores[core.id] { core.busy = busy }
            return core
        }
    }

    func applied(to gpu: GpuSample?) -> GpuSample? {
        guard let gpu, gpu.utilization != nil else { return gpu }
        return GpuSample(name: gpu.name, utilization: self.gpu, usedBytes: gpu.usedBytes,
                         cores: gpu.cores)
    }

    func applied(to memory: MemorySample) -> MemorySample {
        guard let percent = self.memory, memory.total > 0 else { return memory }
        var memory = memory
        memory.used = UInt64(Double(memory.total) * percent / 100)
        return memory
    }
}

private func average(_ values: [Double]) -> Double? {
    values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
}

/// Axis-aligned box in die units; x runs right-down on screen, y left-down, z up.
private struct Block {
    var x: Double, y: Double, width: Double, depth: Double
    var z: Double, height: Double
    var color: Color
    var tint: Color = .clear
    var heat: Double = 0 // tint opacity, 0...1
    var fill: Double = 1 // tinted share of the top face, from the back edge

    var x1: Double { x + width }
    var y1: Double { y + depth }
    var top: Double { z + height }
}

/// Text laid flat on a top face, starting at (x, y).
private struct Caption {
    let text: String
    let x: Double, y: Double, z: Double
    var dim = false
}

private enum Palette {
    static let substrate = Color(red: 0.09, green: 0.10, blue: 0.09)
    static let die = Color(red: 0.19, green: 0.20, blue: 0.23)
    static let plate = Color(red: 0.24, green: 0.25, blue: 0.29)
    static let block = Color(red: 0.31, green: 0.32, blue: 0.37)
    static let cache = Color(red: 0.16, green: 0.17, blue: 0.21)
    static let package = Color(white: 0.06)
}

private struct ChipModel {
    private var back: [Block] = []   // substrate, memory left of the die, the die
    private var plates: [Block] = [] // functional regions on the die
    private var parts: [Block] = []  // cores and caches on the regions
    private var front: [Block] = []  // memory right of the die, nearer the viewer
    private var captions: [Caption] = []

    private static let gap = 0.18, margin = 0.5, inset = 0.2, strip = 0.42, minPlate = 2.8
    private static let dieTop = 0.3, plateTop = 0.34

    init(cores: [CoreSample], gpu: GpuSample?, memory: MemorySample) {
        let gap = Self.gap, margin = Self.margin
        var cursor = margin
        var cpuWidth = 0.0

        let clusters = Self.clusters(cores)
        for (type, members) in clusters {
            let size = type == "E" ? 0.62 : 1.0
            let rows = members.count > 2 ? 2 : 1
            let name = type == "P" ? "P-cores" : type == "E" ? "E-cores" : "CPU"
            let area = region(name, percent: average(members.compactMap(\.busy)),
                              x: margin, y: cursor, count: members.count, rows: rows, cell: size,
                              cellGap: gap, heat: members.map(\.busy))
            cpuWidth = max(cpuWidth, area.0)
            cursor += area.1 + 0.35
        }
        // All current Apple chips have a 16-core Neural Engine.
        let ane = region("Neural Engine", percent: nil, x: margin, y: cursor, count: 16, rows: 2,
                         cell: 0.3, cellGap: 0.08, heat: [])
        cpuWidth = max(cpuWidth, ane.0)
        cursor += ane.1
        let cpuDepth = cursor - margin

        let gpuCores = max(gpu?.cores ?? 8, 1)
        let cell = 0.72
        // As many rows as fit beside the CPU column, then trim empty ones.
        let fit = max(1, min(gpuCores, Int((cpuDepth - 2 * Self.inset - Self.strip) / (cell + gap))))
        let rows = (gpuCores + (gpuCores + fit - 1) / fit - 1) / ((gpuCores + fit - 1) / fit)
        let gpuX = margin + cpuWidth + 0.5
        let load = gpu?.utilization
        let gpuRegion = region(gpu?.cores == nil ? "GPU" : "GPU · \(gpuCores) cores", percent: load,
                               x: gpuX, y: margin, count: gpuCores, rows: rows, cell: cell,
                               cellGap: gap, heat: Array(repeating: load, count: gpuCores))

        let dieWidth = gpuX + gpuRegion.0 + margin
        let dieDepth = max(cpuDepth, gpuRegion.1) + 2 * margin

        // Unified memory packages sit beside the die: one side on base chips, both on larger ones.
        let packages = Self.memoryPackages
        let left = packages <= 2 ? 0 : packages / 2, right = packages - left
        let packageWidth = 1.7
        let used = memory.total == 0 ? nil : memory.usedPercent
        func column(_ count: Int, x: Double) -> [Block] {
            guard count > 0 else { return [] }
            let depth = (dieDepth - gap * Double(count - 1)) / Double(count)
            return (0..<count).map { i in
                Block(x: x, y: Double(i) * (depth + gap), width: packageWidth, depth: depth,
                      z: 0, height: 0.5, color: Palette.package, tint: .level(used), heat: 0.85,
                      fill: (used ?? 0) / 100)
            }
        }
        let leftColumn = column(left, x: -0.45 - packageWidth)
        let rightColumn = column(right, x: dieWidth + 0.45)
        if let first = rightColumn.first {
            captions.append(Caption(text: "Memory \(Format.percent(used))", x: first.x + 0.2,
                                    y: first.y1 - 0.3, z: first.top))
        }

        let minX = (leftColumn.first?.x ?? 0) - 0.5, maxX = (rightColumn.first?.x1 ?? dieWidth) + 0.5
        back = [Block(x: minX, y: -0.5, width: maxX - minX, depth: dieDepth + 1, z: -0.2,
                      height: 0.2, color: Palette.substrate)]
        back += leftColumn
        back.append(Block(x: 0, y: 0, width: dieWidth, depth: dieDepth, z: 0, height: Self.dieTop,
                          color: Palette.die))
        front = rightColumn
        parts.sort { $0.x + $0.y < $1.x + $1.y }
    }

    /// Adds a region plate with a grid of cells and a caption strip; returns its width and depth.
    private mutating func region(_ name: String, percent: Double?, x: Double, y: Double, count: Int,
                                 rows: Int, cell: Double, cellGap: Double,
                                 heat: [Double?]) -> (Double, Double) {
        let columns = (count + rows - 1) / rows
        let cellsWidth = Double(columns) * cell + Double(columns - 1) * cellGap
        let cellsDepth = Double(rows) * cell + Double(rows - 1) * cellGap
        let width = max(cellsWidth + 2 * Self.inset, Self.minPlate)
        let depth = Self.inset + cellsDepth + Self.gap + Self.strip + Self.inset
        plates.append(Block(x: x, y: y, width: width, depth: depth, z: Self.dieTop,
                            height: Self.plateTop - Self.dieTop, color: Palette.plate))

        let left = x + (width - cellsWidth) / 2
        for i in 0..<count {
            let load = i < heat.count ? heat[i] : nil
            let fraction = (load ?? 0) / 100
            parts.append(Block(x: left + Double(i % columns) * (cell + cellGap),
                               y: y + Self.inset + Double(i / columns) * (cell + cellGap),
                               width: cell, depth: cell, z: Self.plateTop,
                               height: cell * (0.12 + 0.6 * fraction), color: Palette.block,
                               tint: .level(load),
                               heat: load == nil ? 0 : min(1, 0.1 + 1.2 * fraction)))
        }

        // Shared cache (or, for the Neural Engine, just a label strip) along the front edge.
        let stripY = y + Self.inset + cellsDepth + Self.gap
        parts.append(Block(x: x + Self.inset, y: stripY, width: width - 2 * Self.inset,
                           depth: Self.strip, z: Self.plateTop, height: 0.04, color: Palette.cache))
        let label = percent == nil ? name : "\(name) \(Format.percent(percent))"
        captions.append(Caption(text: label, x: x + Self.inset + 0.12, y: stripY + Self.strip / 2,
                                z: Self.plateTop + 0.04, dim: heat.isEmpty))
        return (width, depth)
    }

    /// Cores grouped by cluster: performance first, then efficiency, then unknown.
    private static func clusters(_ cores: [CoreSample]) -> [(Character, [CoreSample])] {
        struct Key: Hashable { let type: Character, cluster: Int }
        func rank(_ type: Character) -> Int { type == "P" ? 0 : type == "E" ? 1 : 2 }
        return Dictionary(grouping: cores) { Key(type: $0.type, cluster: $0.cluster) }
            .sorted { (rank($0.key.type), $0.key.cluster) < (rank($1.key.type), $1.key.cluster) }
            .map { ($0.key.type, $0.value.sorted { $0.id < $1.id }) }
    }

    /// Memory package count by chip tier; the system does not report it directly.
    private static let memoryPackages: Int = {
        let model = Machine.model
        return model.contains("Ultra") ? 8 : model.contains("Max") ? 4 : 2
    }()

    func draw(in context: inout GraphicsContext, size: CGSize, labeled: Bool) {
        let c = cos(Double.pi / 6), s = 0.5
        func iso(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
            CGPoint(x: (x - y) * c, y: (x + y) * s - z)
        }
        let blocks = back + plates + parts + front
        var bounds = CGRect.null
        for b in blocks {
            for x in [b.x, b.x1] { for y in [b.y, b.y1] { for z in [b.z, b.top] {
                bounds = bounds.union(CGRect(origin: iso(x, y, z), size: .zero))
            } } }
        }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(size.width / bounds.width, size.height / bounds.height)
        let offset = CGPoint(x: (size.width - bounds.width * scale) / 2 - bounds.minX * scale,
                             y: (size.height - bounds.height * scale) / 2 - bounds.minY * scale)
        func point(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
            let p = iso(x, y, z)
            return CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y)
        }
        func face(_ corners: [(Double, Double, Double)]) -> Path {
            Path { path in path.addLines(corners.map { point($0.0, $0.1, $0.2) }); path.closeSubpath() }
        }

        for b in blocks {
            let right = face([(b.x1, b.y, b.z), (b.x1, b.y1, b.z), (b.x1, b.y1, b.top), (b.x1, b.y, b.top)])
            let near = face([(b.x, b.y1, b.z), (b.x1, b.y1, b.z), (b.x1, b.y1, b.top), (b.x, b.y1, b.top)])
            for (side, shade) in [(right, 0.5), (near, 0.32)] {
                context.fill(side, with: .color(b.color))
                if b.fill >= 1 { context.fill(side, with: .color(b.tint.opacity(b.heat * 0.7))) }
                context.fill(side, with: .color(.black.opacity(shade)))
            }
            let top = face([(b.x, b.y, b.top), (b.x1, b.y, b.top), (b.x1, b.y1, b.top), (b.x, b.y1, b.top)])
            context.fill(top, with: .color(b.color))
            if b.heat > 0, b.fill > 0 {
                let edge = b.y + b.depth * min(b.fill, 1)
                context.fill(face([(b.x, b.y, b.top), (b.x1, b.y, b.top), (b.x1, edge, b.top),
                                   (b.x, edge, b.top)]),
                             with: .color(b.tint.opacity(b.heat)))
            }
            context.stroke(top, with: .color(.white.opacity(0.08)), lineWidth: 0.5)
        }

        guard labeled else { return }
        let fontSize = 0.24 * scale
        guard fontSize >= 6 else { return }
        for caption in captions {
            var flat = context
            let p = point(caption.x, caption.y, caption.z)
            flat.translateBy(x: p.x, y: p.y)
            // Maps text x onto the die's x axis and text y onto its y axis.
            flat.concatenate(CGAffineTransform(a: c, b: s, c: -c, d: s, tx: 0, ty: 0))
            flat.draw(Text(caption.text)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(caption.dim ? 0.4 : 0.85)),
                      at: .zero, anchor: .leading)
        }
    }
}
