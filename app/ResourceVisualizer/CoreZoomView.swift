import SwiftUI

/// Illustrative zoom into one CPU core, opening on one CMOS NAND gate of its adder as 3D layout
/// in the style of Electric's 3D view; drag to orbit, or zoom out through the breadcrumbs to the
/// low four bits of the adder and a textbook five-stage RISC-V pipeline. Apple does not
/// publish its core design, so this is a teaching model rather than the real circuit; only the
/// share of clock slots that carry an instruction follows the core's load.
struct CoreZoomView: View {
    let core: CoreSample
    let exit: () -> Void

    // Property wrappers rather than the @State macro, which is unavailable without Xcode.
    @StateObject private var pipeline = Pipeline()
    @StateObject private var zoom = ZoomState()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            breadcrumbs
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                GeometryReader { geometry in
                    let scene = Scene(level: zoom.level, pipeline: pipeline, date: timeline.date,
                                      size: geometry.size, camera: zoom.camera)
                    let hovered = zoom.pointer.flatMap(scene.target(at:))
                    Canvas { context, _ in scene.draw(in: &context, highlight: hovered) }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { location in
                            if let next = scene.target(at: location) {
                                withAnimation(.snappy) { zoom.path.append(next) }
                            }
                        }
                        .gesture(orbit)
                        .simultaneousGesture(pinch)
                }
            }
            .frame(height: 300)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): zoom.pointer = location
                case .ended: zoom.pointer = nil
                }
            }
            .id(zoom.path)
            .transition(.scale(scale: 0.7).combined(with: .opacity))
            .accessibilityElement()
            .accessibilityLabel(zoom.level == .pipeline ? coreName : zoom.level.title)
            .accessibilityValue(caption)
            Text(caption).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            pipeline.load = (core.busy ?? 0) / 100
            pipeline.start()
        }
        .onDisappear { pipeline.stop() }
        .onChange(of: core.busy) { _, busy in pipeline.load = (busy ?? 0) / 100 }
    }

    /// Dragging turns the layout; up and down tilt it between a side view and straight down.
    private var orbit: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { drag in
                let start = zoom.dragStart ?? zoom.camera
                zoom.dragStart = start
                zoom.camera.yaw = start.yaw - drag.translation.width * 0.008
                zoom.camera.pitch = min(max(start.pitch + drag.translation.height * 0.008, 0.2), .pi / 2)
            }
            .onEnded { _ in zoom.dragStart = nil }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { pinch in
                let start = zoom.pinchStart ?? zoom.camera.zoom
                zoom.pinchStart = start
                zoom.camera.zoom = min(max(start * pinch.magnification, 0.6), 4)
            }
            .onEnded { _ in zoom.pinchStart = nil }
    }

    private var coreName: String {
        (core.type == "P" ? "P-core" : core.type == "E" ? "E-core" : "Core") + " \(core.id)"
    }

    /// Chip › core › deeper levels; every crumb but the last zooms back out to it.
    private var breadcrumbs: some View {
        let crumbs = [("Chip", -2), (coreName, -1)] + zoom.path.enumerated().map { ($1.title, $0) }
        return HStack(spacing: 6) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { position, crumb in
                if position > 0 {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                if position == crumbs.count - 1 {
                    Text(crumb.0).bold()
                } else {
                    Button(crumb.0) {
                        if crumb.1 == -2 { exit() }
                        else { withAnimation(.snappy) { zoom.path = Array(zoom.path.prefix(crumb.1 + 1)) } }
                    }
                    .buttonStyle(.link)
                }
            }
            Spacer()
            if zoom.camera != Camera() {
                Button("Reset view") { withAnimation(.snappy) { zoom.camera = Camera() } }
                    .buttonStyle(.link)
            } else {
                Text("Drag to orbit").foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
    }

    private var caption: String {
        let instruction = pipeline.executed
        let idle = pipeline.stages[2] == nil
            ? "Execute holds a bubble, so this shows the last instruction, \(instruction.text). " : ""
        switch zoom.level {
        case .pipeline:
            return "A textbook five-stage RISC-V pipeline, slowed to one clock every "
                + "\(String(format: "%.1f", Pipeline.clock)) s. The share of clock slots that carry an "
                + "instruction follows this core's load (\(Format.percent(core.busy))); Apple's real "
                + "cores are much wider and run out of order. Click Execute to open the adder."
        case .alu:
            let adder = Adder(instruction)
            return idle + "\(instruction.text): the low 4 bits, \(binary(instruction.a)) "
                + "\(instruction.subtract ? "−" : "+") \(binary(instruction.b)) = \(binary(adder.result)). "
                + (instruction.subtract ? "Subtraction adds the inverted operand with carry in 1. " : "")
                + "The carry ripples from bit 0 to bit 3 one gate delay at a time; the tiles on each full "
                + "adder are its nine NAND cells, lit while their output is 1. Click a cell to see its transistors."
        case .gate(let bit, let gate):
            let s = Adder(instruction).signals(bit: bit)
            let (x, y) = FullAdder.gates[gate]
            return idle + "\(s[x].digit) NAND \(s[y].digit) = \((!(s[x] && s[y])).digit). Each transistor is "
                + "two pn junctions: p+ source and drain in the n-well for PMOS, n+ in the p-substrate for "
                + "NMOS, with a polysilicon gate over the channel between them. The gate's voltage inverts "
                + "that channel, which then conducts: PMOS when its input is 0, NMOS when it is 1, so the "
                + "output connects to VDD or to ground, never both."
        }
    }
}

private enum Level: Hashable {
    case pipeline, alu, gate(bit: Int, gate: Int)

    var title: String {
        switch self {
        case .pipeline: "Pipeline"
        case .alu: "Adder"
        case .gate(let bit, let gate): "Bit \(bit), NAND N\(gate + 1)"
        }
    }
}

@MainActor
private final class ZoomState: ObservableObject {
    /// Opens on one NAND cell's transistors, the sum gate of bit 0; the breadcrumbs zoom out to
    /// the adder and the pipeline.
    @Published var path: [Level] = [.alu, .gate(bit: 0, gate: 7)]
    @Published var pointer: CGPoint?
    @Published var camera = Camera()
    var dragStart: Camera?
    var pinchStart: Double?
    var level: Level { path.last ?? .pipeline }
}

/// Clocks instructions through five stages. Each clock issues an instruction when enough load has
/// accumulated, so at 30% load about three slots in ten carry one and the rest are bubbles.
@MainActor
private final class Pipeline: ObservableObject {
    nonisolated static let clock = 0.9 // seconds, slow enough to follow
    nonisolated static let slotCount = 24

    @Published private(set) var stages: [Instruction?] = Array(repeating: nil, count: 5)
    @Published private(set) var slots: [Bool] = [] // newest first
    private(set) var edge = Date.now                // last clock edge
    private(set) var executed = Instruction.make(0) // last instruction through Execute
    private(set) var previous: Instruction?         // the one before it
    private(set) var executedAt = Date.distantPast  // when it entered Execute
    var load = 0.0
    private var credit = 0.0, issued = 1
    private var timer: Task<Void, Never>?

    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.clock))
                if !Task.isCancelled { self?.step() }
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func step() {
        credit += min(max(load, 0), 1)
        var next: Instruction?
        if credit >= 1 {
            credit -= 1
            next = .make(issued)
            issued += 1
        }
        edge = .now
        if let current = stages[1] {
            previous = executed
            executed = current
            executedAt = edge
        }
        slots = Array(([next != nil] + slots).prefix(Self.slotCount))
        stages = [next] + stages.dropLast()
    }
}

private struct Instruction {
    let text: String
    let a: Int, b: Int // low four bits of the adder's operands
    let subtract: Bool

    var mnemonic: String { String(text.prefix { $0 != " " }) }
    var operands: String { String(text.drop { $0 != " " }.dropFirst()) }

    /// A short loop body. Register values are made up; immediates are the ones in the text.
    private static let program: [(String, Bool, Int?)] = [
        ("addi x5, x5, 1", false, 1), ("add x6, x6, x5", false, nil), ("lw x7, 8(x10)", false, 8),
        ("sub x8, x7, x6", true, nil), ("sw x8, 4(x10)", false, 4), ("bne x5, x11, loop", true, nil),
    ]

    static func make(_ serial: Int) -> Instruction {
        let (text, subtract, immediate) = program[serial % program.count]
        let mix = ((serial &+ 1) &* 2_654_435_761) >> 8 // varied but repeatable register values
        return Instruction(text: text, a: mix & 15, b: immediate.map { $0 & 15 } ?? (mix >> 4) & 15,
                           subtract: subtract)
    }
}

/// A full adder as nine two-input NAND gates. Signals 0–2 are a, b and carry in; gate i drives
/// signal 3 + i, so gate 7 gives the sum and gate 8 the carry out.
private enum FullAdder {
    static let gates = [(0, 1), (0, 3), (1, 3), (4, 5), (6, 2), (6, 7), (2, 7), (8, 9), (7, 3)]

    static func signals(_ a: Bool, _ b: Bool, _ carry: Bool) -> [Bool] {
        var s = [a, b, carry]
        for (x, y) in gates { s.append(!(s[x] && s[y])) }
        return s
    }

    static func name(_ signal: Int) -> String { signal < 3 ? ["a", "b", "carry in"][signal] : "N\(signal - 2)" }
}

/// Four ripple-carry full adders; subtraction inverts b and sets the carry in.
private struct Adder {
    var a: [Bool] = [], b: [Bool] = [], carry: [Bool], sum: [Bool] = [] // bit 0 first

    init(_ instruction: Instruction) {
        let operand = instruction.subtract ? ~instruction.b & 15 : instruction.b
        carry = [instruction.subtract]
        for bit in 0..<4 {
            a.append(instruction.a >> bit & 1 == 1)
            b.append(operand >> bit & 1 == 1)
            let s = FullAdder.signals(a[bit], b[bit], carry[bit])
            sum.append(s[10])
            carry.append(s[11])
        }
    }

    func signals(bit: Int) -> [Bool] { FullAdder.signals(a[bit], b[bit], carry[bit]) }
    var result: Int { sum.enumerated().reduce(0) { $0 | ($1.element ? 1 << $1.offset : 0) } }
}

/// Every adder signal at a moment after a new instruction reaches Execute. Each NAND gate takes
/// one gate delay to follow its inputs, so new values ripple through the network, and through
/// the carry chain from bit 0 to bit 3, instead of appearing all at once.
private struct Settle {
    static let delay = 0.05 // seconds per gate, slowed down about ten billion times

    private let new: [[Bool]], old: [[Bool]]
    private var times: [[Double]] = [] // when each signal takes its new value
    private let elapsed: Double

    init(_ instruction: Instruction, before previous: Instruction?, elapsed: Double) {
        let adder = Adder(instruction)
        new = (0..<4).map { adder.signals(bit: $0) }
        old = previous.map { prev in (0..<4).map { Adder(prev).signals(bit: $0) } } ?? new
        self.elapsed = elapsed
        for bit in 0..<4 {
            var t = [0, 0, bit == 0 ? 0 : times[bit - 1][11]]
            for (x, y) in FullAdder.gates { t.append(max(t[x], t[y]) + Self.delay) }
            times.append(t)
        }
    }

    func signals(bit: Int) -> [Bool] { (0..<new[bit].count).map { value(bit, $0) } }

    func value(_ bit: Int, _ signal: Int) -> Bool { elapsed >= times[bit][signal] ? new[bit][signal] : old[bit][signal] }

    /// 1 just as a signal changes, fading to 0 over a third of a second.
    func flash(_ bit: Int, _ signal: Int) -> Double {
        let age = elapsed - times[bit][signal]
        return new[bit][signal] != old[bit][signal] && age >= 0 && age < 0.35 ? 1 - age / 0.35 : 0
    }

    /// Seconds since a signal changed, or nil if it did not.
    func age(_ bit: Int, _ signal: Int) -> Double? {
        new[bit][signal] != old[bit][signal] && elapsed >= times[bit][signal] ? elapsed - times[bit][signal] : nil
    }
}

private enum Ink {
    static let background = Color(red: 0.09, green: 0.10, blue: 0.09)
    static let text = Color.white.opacity(0.85)
    static let dim = Color.white.opacity(0.5)
    static let high = Color(red: 0.38, green: 0.86, blue: 1.0)
}

// MARK: 3D

/// An RGB colour that can be shaded, which SwiftUI's Color cannot.
private struct Tint: Equatable {
    var r, g, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) { (self.r, self.g, self.b) = (r, g, b) }

    static let white = Tint(1, 1, 1)
    static let high = Tint(0.38, 0.86, 1.0)
    static let conducting = Tint(1.0, 0.92, 0.55) // a transistor channel that conducts
    static let block = Tint(0.22, 0.23, 0.27)

    func scaled(_ k: Double) -> Tint { Tint(r * k, g * k, b * k) }
    func mixed(_ other: Tint, _ t: Double) -> Tint {
        Tint(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }
    func color(_ opacity: Double = 1) -> Color { Color(red: r, green: g, blue: b, opacity: opacity) }
}

/// Layout layers in the colours of Electric's MOSIS CMOS technology, with heights in λ. Contacts
/// and vias fill the gap between the layers they join. Thicknesses are exaggerated, as in
/// Electric's 3D view, so the stack is readable.
private enum Layer: CaseIterable {
    case substrate, well, pDiffusion, nDiffusion, poly, contact, metal1, via1, metal2, via2, metal3

    var tint: Tint {
        switch self {
        case .substrate: Tint(0.24, 0.19, 0.16)
        case .well: Tint(0.2, 0.36, 0.3)
        case .pDiffusion: Tint(1.0, 0.6, 0.22)
        case .nDiffusion: Tint(0.42, 0.89, 0.38)
        case .poly: Tint(1.0, 0.36, 0.42)
        case .contact, .via1, .via2: Tint(0.62, 0.62, 0.66)
        case .metal1: Tint(0.38, 0.72, 1.0)
        case .metal2: Tint(0.88, 0.37, 1.0)
        case .metal3: Tint(1.0, 0.78, 0.2)
        }
    }

    var z: (Double, Double) {
        switch self {
        case .substrate: (-2.4, -0.8)
        case .well: (-0.8, 0)
        case .pDiffusion, .nDiffusion: (0, 1)
        case .poly: (1.6, 2.6)
        case .contact: (1, 4)
        case .metal1: (4, 5.5)
        case .via1: (5.5, 7.5)
        case .metal2: (7.5, 9)
        case .via2: (9, 11)
        case .metal3: (11, 12.5)
        }
    }

    /// Metal and vias are see-through, as Electric's 3D view can make them, so the transistors
    /// underneath stay visible.
    var opacity: Double {
        switch self {
        case .metal1, .metal2, .metal3, .via1, .via2: 0.72
        default: 1
        }
    }

    var name: String? {
        switch self {
        case .substrate: "P-substrate"
        case .well: "N-well"
        case .pDiffusion: "p+"
        case .nDiffusion: "n+"
        case .poly: "Polysilicon"
        case .metal1: "Metal 1"
        case .metal2: "Metal 2"
        case .metal3: "Metal 3"
        default: nil
        }
    }
}

/// A signal: whether it carries a 1, and a 0…1 pulse as a new value arrives.
private struct Net {
    var on: Bool
    var flash = 0.0
}

/// An axis-aligned box: plan x to the right, plan y towards the viewer, z up.
private struct Box {
    var lo: SIMD3<Double>, hi: SIMD3<Double>
    var tint: Tint
    var glow = 0.0 // halo around the top face of a part carrying a 1
    var layer: Layer?
    var opacity = 1.0
}

/// Maps a part's own coordinates (λ for a NAND cell) into the scene's.
private struct Place {
    var x = 0.0, y = 0.0, s = 1.0, zs = 1.0

    func p(_ px: Double, _ py: Double, _ pz: Double) -> SIMD3<Double> { [x + px * s, y + py * s, pz * zs] }
}

private struct Label {
    var text: String
    var at: SIMD3<Double>
    var size: Double // in scene units
    var color = Ink.text
    var anchor = UnitPoint.center
    var mono = false
    var dy = 0.0 // extra offset in points, for a second line
}

/// Orbit camera. Yaw turns the layout about its vertical axis; pitch 0 looks from the side and
/// π/2 straight down.
struct Camera: Equatable {
    var yaw = -0.2, pitch = 0.9, zoom = 1.0
}

/// Orthographic view of a camera orientation, the way Electric's 3D view looks at a cell.
private struct Orientation {
    let cy, sy, cp, sp: Double

    init(_ camera: Camera) {
        (cy, sy, cp, sp) = (cos(camera.yaw), sin(camera.yaw), cos(camera.pitch), sin(camera.pitch))
    }

    func uv(_ p: SIMD3<Double>) -> (Double, Double) { (p.x * cy - p.y * sy, (p.x * sy + p.y * cy) * sp - p.z * cp) }
    /// Points towards the viewer; a larger dot product with it is closer.
    var toViewer: SIMD3<Double> { [sy * cp, cy * cp, sp] }
    func depth(_ p: SIMD3<Double>) -> Double { (p * toViewer).sum() }
}

/// Corner i of a box takes hi on x for bit 0, on y for bit 1 and on z for bit 2.
private func corners(_ lo: SIMD3<Double>, _ hi: SIMD3<Double>) -> [SIMD3<Double>] {
    (0..<8).map { [$0 & 1 == 0 ? lo.x : hi.x, $0 & 2 == 0 ? lo.y : hi.y, $0 & 4 == 0 ? lo.z : hi.z] }
}

/// Scene to screen. The scale is fixed per level, fitted at the starting camera, so orbiting
/// does not make the layout breathe; the layout's centre stays in the middle of the view.
private struct Projection {
    var orientation = Orientation(Camera())
    var scale = 1.0
    var offset = CGPoint.zero

    init() {}

    init(_ camera: Camera, lo: SIMD3<Double>, hi: SIMD3<Double>, frame: CGRect) {
        orientation = Orientation(camera)
        let home = corners(lo, hi).map(Orientation(Camera()).uv)
        let us = home.map(\.0), vs = home.map(\.1)
        scale = 0.94 * camera.zoom * min(frame.width / (us.max()! - us.min()!), frame.height / (vs.max()! - vs.min()!))
        let (u, v) = orientation.uv((lo + hi) / 2)
        offset = CGPoint(x: frame.midX - u * scale, y: frame.midY - v * scale)
    }

    func point(_ p: SIMD3<Double>) -> CGPoint {
        let (u, v) = orientation.uv(p)
        return CGPoint(x: offset.x + u * scale, y: offset.y + v * scale)
    }
}

/// One frame of one level, built as layout and drawn the way Electric's 3D view shows a cell:
/// every layer extruded at its own height in its own colour, seen through an orbiting camera.
/// Lit channels conduct and lit metal carries a 1.
private struct Scene {
    let level: Level
    let stages: [Instruction?]
    let slots: [Bool]
    let settle: Settle
    let subtract: Bool
    let idle: Bool
    let load: Double
    let elapsed: Double // seconds since the last clock edge
    let time: Double
    let size: CGSize
    private var boxes: [Box] = []
    private var labels: [Label] = []
    private var flows: [(points: [SIMD3<Double>], opacity: Double)] = [] // charge moving through a gate
    private var targets: [(lo: SIMD3<Double>, hi: SIMD3<Double>, level: Level)] = []
    private var projection = Projection()

    /// Height scale of the pipeline and adder levels, whose plan is in their own units.
    static let blockHeight = 0.03

    @MainActor
    init(level: Level, pipeline: Pipeline, date: Date, size: CGSize, camera: Camera) {
        self.level = level
        stages = pipeline.stages
        slots = pipeline.slots
        settle = Settle(pipeline.executed, before: pipeline.previous,
                        elapsed: date.timeIntervalSince(pipeline.executedAt))
        subtract = pipeline.executed.subtract
        idle = pipeline.stages[2] == nil
        load = pipeline.load
        elapsed = date.timeIntervalSince(pipeline.edge)
        time = date.timeIntervalSinceReferenceDate
        self.size = size
        switch level {
        case .pipeline: buildPipeline()
        case .alu: buildAdder()
        case .gate(let bit, let gate): buildGate(bit: bit, gate: gate)
        }
        // A single gate is fitted to the cell itself, so its substrate runs off the edges.
        var fitted = boxes
        if case .gate = level { fitted = boxes.filter { $0.layer != .substrate } }
        let lo = fitted.map(\.lo).reduce(fitted[0].lo) { pointwiseMin($0, $1) }
        let hi = fitted.map(\.hi).reduce(fitted[0].hi) { pointwiseMax($0, $1) }
        projection = Projection(camera, lo: lo, hi: hi, frame: CGRect(origin: .zero, size: size))
    }

    /// The part under a point, if it zooms in further; the closest one wins.
    func target(at point: CGPoint) -> Level? {
        targets.filter { outline($0.lo, $0.hi).contains(point) }
            .max { projection.orientation.depth($0.hi) < projection.orientation.depth($1.hi) }?.level
    }

    func draw(in context: inout GraphicsContext, highlight: Level?) {
        context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(Ink.background))
        let corners = boxes.map { corners($0.lo, $0.hi).map(projection.point) }
        for i in paintOrder(corners) { drawBox(&context, boxes[i], corners[i]) }

        for target in targets where target.level == highlight {
            let path = outline(target.lo, target.hi)
            context.fill(path, with: .color(.white.opacity(0.08)))
            context.stroke(path, with: .color(.white.opacity(0.75)), lineWidth: 1)
        }
        for flow in flows { drawFlow(&context, flow.points, opacity: flow.opacity) }

        var ink = context
        ink.addFilter(.shadow(color: .black.opacity(0.9), radius: 1.5))
        for label in labels {
            let points = label.size * projection.scale
            guard points >= 5 else { continue }
            var at = projection.point(label.at)
            at.y += label.dy
            ink.draw(Text(label.text)
                .font(.system(size: points, weight: .medium, design: label.mono ? .monospaced : .rounded))
                .foregroundColor(label.color), at: at, anchor: label.anchor)
        }
        drawLegend(&ink)
    }

    // MARK: Rendering

    /// Back-to-front order for the painter's algorithm. Two boxes whose outlines overlap on screen
    /// are ordered by a plane that separates them: the one on the far side is drawn first.
    private func paintOrder(_ corners: [[CGPoint]]) -> [Int] {
        let n = boxes.count, toViewer = projection.orientation.toViewer
        let rects = corners.map { points in
            CGRect(x: points.map(\.x).min()!, y: points.map(\.y).min()!, width: 0, height: 0)
                .union(CGRect(x: points.map(\.x).max()!, y: points.map(\.y).max()!, width: 0, height: 0))
        }
        func behind(_ a: Box, _ b: Box) -> Bool {
            for axis in 0..<3 where abs(toViewer[axis]) > 1e-6 {
                if a.hi[axis] <= b.lo[axis] + 1e-9 { return toViewer[axis] > 0 }
                if b.hi[axis] <= a.lo[axis] + 1e-9 { return toViewer[axis] < 0 }
            }
            return projection.orientation.depth((a.lo + a.hi) / 2) < projection.orientation.depth((b.lo + b.hi) / 2)
        }
        var after = [[Int]](repeating: [], count: n), waiting = [Int](repeating: 0, count: n)
        let byLeft = (0..<n).sorted { rects[$0].minX < rects[$1].minX }
        for (k, i) in byLeft.enumerated() {
            for j in byLeft[(k + 1)...] {
                if rects[j].minX >= rects[i].maxX - 0.5 { break }
                guard rects[i].minY < rects[j].maxY - 0.5, rects[j].minY < rects[i].maxY - 0.5 else { continue }
                let (first, second) = behind(boxes[i], boxes[j]) ? (i, j) : (j, i)
                after[first].append(second)
                waiting[second] += 1
            }
        }
        // Kahn's algorithm; a rare cycle is broken at its farthest box.
        var ready = (0..<n).filter { waiting[$0] == 0 }, order: [Int] = [], done = [Bool](repeating: false, count: n)
        while order.count < n {
            if ready.isEmpty, let far = (0..<n).filter({ !done[$0] }).min(by: {
                projection.orientation.depth(boxes[$0].hi) < projection.orientation.depth(boxes[$1].hi)
            }) {
                waiting[far] = 0
                ready.append(far)
            }
            let i = ready.removeLast()
            guard !done[i] else { continue }
            done[i] = true
            order.append(i)
            for j in after[i] where !done[j] {
                waiting[j] -= 1
                if waiting[j] == 0 { ready.append(j) }
            }
        }
        return order
    }

    /// The faces turned towards the camera, lit from above: tops brightest, sides darker.
    private func drawBox(_ context: inout GraphicsContext, _ box: Box, _ c: [CGPoint]) {
        let v = projection.orientation.toViewer
        var faces: [([Int], Double)] = []
        if abs(v.x) > 1e-6 { faces.append((v.x > 0 ? [1, 3, 7, 5] : [0, 2, 6, 4], 0.72)) }
        if abs(v.y) > 1e-6 { faces.append((v.y > 0 ? [2, 3, 7, 6] : [0, 1, 5, 4], 0.56)) }
        if v.z > 1e-6 { faces.append(([4, 5, 7, 6], 1)) }
        for (face, light) in faces {
            let path = Path { $0.addLines(face.map { c[$0] }); $0.closeSubpath() }
            context.fill(path, with: .color(box.tint.scaled(light).color(box.opacity)))
            context.stroke(path, with: .color(box.tint.scaled(light * 0.45).color(0.7 * box.opacity)), lineWidth: 0.5)
        }
        if box.glow > 0 {
            let top = Path { $0.addLines([4, 5, 7, 6].map { c[$0] }); $0.closeSubpath() }
            context.stroke(top, with: .color(box.tint.mixed(.white, 0.3).color(0.4 * box.glow)), lineWidth: 3)
        }
    }

    /// Screen outline of a box: the convex hull of its corners.
    private func outline(_ lo: SIMD3<Double>, _ hi: SIMD3<Double>) -> Path {
        let points = corners(lo, hi).map(projection.point).sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var hull: [CGPoint] = []
        for pass in [points, points.reversed()] {
            let start = hull.count
            for p in pass {
                while hull.count >= start + 2, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 { hull.removeLast() }
                hull.append(p)
            }
            hull.removeLast()
        }
        return Path { $0.addLines(hull); $0.closeSubpath() }
    }

    /// Charge as dots travelling along a path through the layout.
    private func drawFlow(_ context: inout GraphicsContext, _ points: [SIMD3<Double>], opacity: Double) {
        let lengths = zip(points, points.dropFirst()).map { (($1 - $0) * ($1 - $0)).sum().squareRoot() }
        let total = lengths.reduce(0, +), spacing = 2.0
        var s = (time * 10).truncatingRemainder(dividingBy: spacing)
        while s < total {
            var rest = s, k = 0
            while k < lengths.count - 1, rest > lengths[k] { rest -= lengths[k]; k += 1 }
            let p = points[k] + (points[k + 1] - points[k]) * (rest / max(lengths[k], 1e-9))
            let at = projection.point(p)
            context.fill(Path(ellipseIn: CGRect(x: at.x - 2.5, y: at.y - 2.5, width: 5, height: 5)),
                         with: .color(.white.opacity(opacity)))
            s += spacing
        }
    }

    /// Swatches for the layers on screen, in stacking order, bottom left.
    private func drawLegend(_ context: inout GraphicsContext) {
        let shown = Set(boxes.compactMap(\.layer))
        var x = 10.0
        // The substrate is only worth naming next to the doped regions in it.
        for layer in Layer.allCases where shown.contains(layer) && (layer != .substrate || shown.contains(.well)) {
            guard let name = layer.name else { continue }
            let y = size.height - 14
            context.fill(Path(roundedRect: CGRect(x: x, y: y - 4, width: 8, height: 8), cornerRadius: 2),
                         with: .color(layer.tint.color()))
            let text = context.resolve(Text(name).font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(Ink.dim))
            context.draw(text, at: CGPoint(x: x + 12, y: y), anchor: .leading)
            x += 12 + text.measure(in: size).width + 12
        }
    }

    // MARK: Building

    private mutating func rect(_ layer: Layer, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
                               at place: Place = Place(), net: Net? = nil, z: (Double, Double)? = nil,
                               tint: Tint? = nil) {
        let (z0, z1) = z ?? layer.z
        var color = tint ?? layer.tint, glow = 0.0
        if let net {
            color = (net.on ? color.scaled(idle ? 0.8 : 1) : color.scaled(0.4)).mixed(.white, 0.85 * net.flash)
            glow = net.on ? (idle ? 0.35 : 1) : 0
        } else if tint == nil {
            color = color.scaled(0.8)
        }
        // Thinner metal over a single gate, so the junctions underneath read clearly.
        var opacity = layer.opacity
        if case .gate = level, opacity < 1 { opacity = 0.5 }
        boxes.append(Box(lo: place.p(x0, y0, z0), hi: place.p(x1, y1, z1), tint: color, glow: glow, layer: layer,
                         opacity: opacity))
    }

    /// A wire through `points` that runs along x on metal 2 and along y on metal 3, with a via
    /// wherever it changes layer. `drop` ends it on a via down to a metal-1 pad.
    private mutating func route(_ points: [(Double, Double)], width w: Double, net: Net, at place: Place,
                                drop: Bool = false) {
        var previous: Layer?
        func via(_ layer: Layer, _ p: (Double, Double)) -> (Layer, Double, Double, Double, Double) {
            (layer, p.0 - w / 2, p.1 - w / 2, p.0 + w / 2, p.1 + w / 2)
        }
        var vias: [(Layer, Double, Double, Double, Double)] = []
        for (from, to) in zip(points, points.dropFirst()) {
            let layer: Layer = abs(to.1 - from.1) < 1e-9 ? .metal2 : .metal3
            rect(layer, min(from.0, to.0) - w / 2, min(from.1, to.1) - w / 2, max(from.0, to.0) + w / 2,
                 max(from.1, to.1) + w / 2, at: place, net: net)
            if previous != nil, previous != layer { vias.append(via(.via2, from)) }
            previous = layer
        }
        if drop, let last = points.last {
            if previous == .metal3 { vias.append(via(.via2, last)) }
            vias.append(via(.via1, last))
        }
        for (layer, x0, y0, x1, y1) in vias { rect(layer, x0, y0, x1, y1, at: place) }
    }

    private mutating func label(_ text: String, _ x: Double, _ y: Double, _ z: Double, size: Double,
                                color: Color = Ink.text, anchor: UnitPoint = .center, mono: Bool = false,
                                dy: Double = 0) {
        labels.append(Label(text: text, at: [x, y, z], size: size, color: color, anchor: anchor, mono: mono, dy: dy))
    }

    // MARK: Levels

    private static let stageNames = ["Fetch", "Decode", "Execute", "Memory", "Write back"]
    private static func stage(_ i: Int) -> (Double, Double, Double, Double) { (0.15 + Double(i) * 1.97, 0.2, 1.75, 1.9) }

    /// The five stages as blocks on the die; a block lights up while it holds an instruction.
    private mutating func buildPipeline() {
        let place = Place(zs: Self.blockHeight), top = 0.36
        rect(.substrate, 0, 0, 10, 3.35, at: place)
        // Each instruction slides in from the previous stage just after the clock edge.
        let shift = (1 - ease(min(elapsed / 0.35, 1))) * 1.97
        for (i, name) in Self.stageNames.enumerated() {
            let (x, y, w, h) = Self.stage(i)
            let lit = stages[i] != nil
            boxes.append(Box(lo: [x, y, 0], hi: [x + w, y + h, top],
                             tint: lit ? Tint.block.mixed(.high, 0.3) : .block, glow: lit ? 1 : 0))
            if i == 2 { targets.append(([x, y, 0], [x + w, y + h, top], .alu)) }
            if i < Self.stageNames.count - 1 {
                route([(x + w, y + h / 2), (x + 1.97, y + h / 2)], width: 0.07, net: Net(on: lit), at: place)
            }
            label(name, x + w / 2, y + 0.28, top, size: 0.17, color: Ink.dim)
            if let instruction = stages[i] {
                label(instruction.mnemonic, x + w / 2 - shift, y + 0.9, top, size: 0.3, mono: true)
                label(instruction.operands, x + w / 2 - shift, y + 1.25, top, size: 0.14, color: Ink.dim, mono: true)
            } else {
                label("bubble", x + w / 2 - shift, y + 0.95, top, size: 0.17, color: Ink.dim)
            }
            if i == 2 { label("Adder ›", x + w / 2, y + h - 0.22, top, size: 0.15, color: Ink.high) }
        }

        let used = slots.filter { $0 }.count
        label("Clock slots, newest first", 0.2, 2.5, 0, size: 0.16, color: Ink.dim, anchor: .leading)
        label("\(used) of \(slots.count) carried an instruction · core load \(Format.percent(load * 100))",
              9.85, 2.5, 0, size: 0.16, color: Ink.dim, anchor: .trailing)
        for i in 0..<Pipeline.slotCount {
            let x = 0.2 + Double(i) * 0.405, carried = i < slots.count && slots[i]
            boxes.append(Box(lo: [x, 2.75, 0], hi: [x + 0.32, 3.07, carried ? 0.22 : 0.03],
                             tint: carried ? Tint.high.scaled(i == 0 ? 1 : 0.75) : Tint(0.3, 0.3, 0.3),
                             glow: carried && i == 0 ? 1 : 0))
        }
    }

    private static func adderX(_ bit: Int) -> Double { 0.5 + Double(3 - bit) * 2.3 }

    /// Four full-adder blocks with the carry chain between them. The nine tiles on each block are
    /// its NAND cells, lit while their output is 1; clicking one opens its transistors.
    private mutating func buildAdder() {
        let place = Place(zs: Self.blockHeight), top = 0.45, w = 0.07, bw = 1.85, y0 = 1.3, y1 = 2.9
        rect(.substrate, 0, 0.15, 10, 3.95, at: place)
        for bit in 0..<4 {
            let x = Self.adderX(bit), settle = settle, mid = (y0 + y1) / 2
            let net = { Net(on: settle.value(bit, $0), flash: settle.flash(bit, $0)) }
            let v = { settle.value(bit, $0).digit }
            let busy = (3..<12).map { settle.flash(bit, $0) }.max() ?? 0
            boxes.append(Box(lo: [x, y0, 0], hi: [x + bw, y1, top], tint: Tint.block.mixed(.white, 0.3 * busy)))
            let tw = (bw - 0.1) / 3, th = (y1 - y0 - 0.1) / 3, tileTop = top / Self.blockHeight + 0.6
            for gate in 0..<9 {
                let tx = x + 0.05 + Double(gate % 3) * tw, ty = y0 + 0.05 + Double(gate / 3) * th
                rect(.metal1, tx + 0.03, ty + 0.03, tx + tw - 0.03, ty + th - 0.03, at: place, net: net(3 + gate),
                     z: (top / Self.blockHeight, tileTop))
                targets.append(([tx, ty, 0], [tx + tw, ty + th, tileTop * Self.blockHeight], .gate(bit: bit, gate: gate)))
                label("N\(gate + 1)", tx + tw / 2, ty + th / 2, tileTop * Self.blockHeight, size: 0.11, color: Ink.dim)
            }

            route([(x + 0.5, 0.7), (x + 0.5, y0)], width: w, net: net(0), at: place)
            route([(x + 1.35, 0.7), (x + 1.35, y0)], width: w, net: net(1), at: place)
            label("a\(bit) \(v(0))", x + 0.5, 0.5, 0.4, size: 0.17, mono: true)
            label("\(subtract ? "b̄" : "b")\(bit) \(v(1))", x + 1.35, 0.5, 0.4, size: 0.17, mono: true)
            label("bit \(bit)", x + bw / 2, y0, top, size: 0.13, color: Ink.dim, dy: -8)

            let from = bit == 0 ? 9.95 : x + 2.3
            route([(from, mid), (x + bw, mid)], width: w, net: net(2), at: place)
            if bit == 0 {
                label("carry in \(v(2))", 9.95, mid + 0.25, 0.3, size: 0.14, color: Ink.dim, anchor: .trailing)
            } else {
                label("c\(bit)", x + bw + 0.225, mid - 0.2, 0.3, size: 0.14, color: Ink.dim, mono: true)
            }
            route([(x + bw / 2, y1), (x + bw / 2, 3.5)], width: w, net: net(10), at: place)
            label("s\(bit) \(v(10))", x + bw / 2, 3.72, 0.4, size: 0.17, mono: true)
        }
        route([(Self.adderX(3), 2.1), (0.08, 2.1)], width: w, net: Net(on: settle.value(3, 11), flash: settle.flash(3, 11)),
              at: place)
        label("out", 0.08, 2.35, 0.3, size: 0.14, color: Ink.dim, anchor: .leading)
    }

    /// One NAND cell, 26 by 28 λ, at full size, with its inputs and output wired off the edges.
    private mutating func buildGate(bit: Int, gate: Int) {
        let (x, y) = FullAdder.gates[gate]
        let a = Net(on: settle.value(bit, x), flash: settle.flash(bit, x))
        let b = Net(on: settle.value(bit, y), flash: settle.flash(bit, y))
        let out = Net(on: settle.value(bit, 3 + gate), flash: settle.flash(bit, 3 + gate))
        rect(.substrate, -4.5, -1.5, 30.5, 29.5)
        nand(at: Place(), a: a, b: b, out: out)
        route([(-3.5, 8.75), (1.75, 8.75)], width: 2, net: a, at: Place(), drop: true)
        route([(-3.5, 19.2), (1.75, 19.2)], width: 2, net: b, at: Place(), drop: true)
        route([(26, 14), (29.5, 14)], width: 2, net: out, at: Place())

        let metal = Layer.metal2.z.1, size = 1.3
        label("VDD", 26.6, 1.5, Layer.metal1.z.1, size: size, color: Ink.high, anchor: .leading)
        label("GND", 26.6, 26.5, Layer.metal1.z.1, size: size, color: Ink.dim, anchor: .leading)
        label("A \(a.on.digit)", -4, 8.75, metal, size: size, anchor: .trailing)
        label("from \(FullAdder.name(x))", -4, 8.75, metal, size: size * 0.75, color: Ink.dim, anchor: .trailing, dy: 13)
        label("B \(b.on.digit)", -4, 19.2, metal, size: size, anchor: .trailing)
        label("from \(FullAdder.name(y))", -4, 19.2, metal, size: size * 0.75, color: Ink.dim, anchor: .trailing, dy: 13)
        label("out \(out.on.digit)", 30, 14, metal, size: size, anchor: .leading)
        for (name, px, py, on) in [("P1", 12.0, 7.5, !a.on), ("P2", 18.0, 7.5, !b.on), ("N1", 12.0, 20.5, a.on),
                                   ("N2", 18.0, 20.5, b.on)] {
            label(name, px, py, Layer.poly.z.1, size: size)
            label(on ? "on" : "off", px, py, Layer.poly.z.1, size: size * 0.8, color: on ? Ink.high : Ink.dim, dy: 12)
        }

        // Charge moves only when the output switches: in from VDD through the PMOS, or out to
        // ground through the NMOS.
        guard !idle, let age = settle.age(bit, 3 + gate), age < 0.8 else { return }
        let paths: [[SIMD3<Double>]] = out.on
            ? [(8.5, !a.on), (21.5, !b.on)].filter(\.1).map { x, _ in
                [[x, 1.5, 5.5], [x, 7.5, 5.5], [x, 7.5, 1], [15, 7.5, 1], [15, 7.5, 9], [15, 14, 9], [32, 14, 9]]
            }
            : [[[32, 14, 9], [8.5, 14, 9], [8.5, 20.5, 9], [8.5, 20.5, 1], [21.5, 20.5, 1], [21.5, 20.5, 5.5],
                [21.5, 26.5, 5.5]]]
        flows = paths.map { ($0, 1 - age / 0.8) }
    }

    /// A NAND cell, 26 by 28 λ: VDD rail on top, PMOS P1 and P2 in parallel in the n-well, NMOS
    /// N1 and N2 in series below, ground rail at the bottom. Inputs A and B land on metal-1 pads
    /// on the left edge; the output rises to metal 2 and leaves at the middle of the right edge.
    /// Each source and drain meets the body under its gate at a pn junction: p+ against the
    /// n-well for PMOS, n+ against the p-substrate for NMOS.
    private mutating func nand(at place: Place, a: Net, b: Net, out: Net) {
        let vdd = Net(on: true), ground = Net(on: false), between = Net(on: out.on && a.on && !b.on)
        // A channel shows the body's doping while off and lights up once the gate inverts it.
        func channel(_ x0: Double, _ y0: Double, _ on: Bool, body: Layer) {
            rect(body, x0, y0, x0 + 2, y0 + 5, at: place, z: Layer.pDiffusion.z,
                 tint: on ? .conducting : body.tint.scaled(1.6))
        }
        rect(.well, -1, -1, 27, 13.5, at: place)
        // PMOS in parallel: VDD, P1 (gate A), output, P2 (gate B), VDD.
        rect(.pDiffusion, 6, 5, 11, 10, at: place, net: vdd)
        channel(11, 5, !a.on, body: .well)
        rect(.pDiffusion, 13, 5, 17, 10, at: place, net: out)
        channel(17, 5, !b.on, body: .well)
        rect(.pDiffusion, 19, 5, 24, 10, at: place, net: vdd)
        // NMOS in series: output, N1 (gate A), the node between them, N2 (gate B), ground.
        rect(.nDiffusion, 6, 18, 11, 23, at: place, net: out)
        channel(11, 18, a.on, body: .substrate)
        rect(.nDiffusion, 13, 18, 17, 23, at: place, net: between)
        channel(17, 18, b.on, body: .substrate)
        rect(.nDiffusion, 19, 18, 24, 23, at: place, net: ground)
        // Polysilicon gates, each reaching a contact between the two diffusions.
        rect(.poly, 11, 4, 13, 24, at: place, net: a)
        rect(.poly, 5, 12.5, 11, 14.5, at: place, net: a)
        rect(.poly, 2, 12, 5, 15, at: place, net: a)
        rect(.poly, 17, 4, 19, 24, at: place, net: b)
        rect(.poly, 16.5, 12, 19.5, 15, at: place, net: b)
        for (x, y) in [(7.0, 6.0), (13.5, 6.0), (20.0, 6.0), (7.0, 19.0), (20.0, 19.0)] {
            rect(.contact, x + 0.5, y + 0.5, x + 2.5, y + 2.5, at: place)
        }
        for x in [2.0, 16.5] {
            rect(.contact, x + 0.5, 12.5, x + 2.5, 14.5, at: place, z: (Layer.poly.z.1, Layer.metal1.z.0))
        }
        // Metal 1: rails and straps, the output's landing pads, and the inputs.
        rect(.metal1, 0, 0, 26, 3, at: place, net: vdd)
        rect(.metal1, 7, 3, 10, 9, at: place, net: vdd)
        rect(.metal1, 20, 3, 23, 9, at: place, net: vdd)
        rect(.metal1, 13.5, 6, 16.5, 9, at: place, net: out)
        rect(.metal1, 7, 19, 10, 22, at: place, net: out)
        rect(.metal1, 20, 19, 23, 25, at: place, net: ground)
        rect(.metal1, 0, 25, 26, 28, at: place, net: ground)
        rect(.metal1, 0, 7.5, 3.5, 12, at: place, net: a)
        rect(.metal1, 2, 12, 5, 15, at: place, net: a)
        rect(.metal1, 0, 15.8, 3.5, 20.5, at: place, net: b)
        rect(.metal1, 3.5, 15.8, 16.5, 17.5, at: place, net: b)
        rect(.metal1, 16.5, 12, 19.5, 17.5, at: place, net: b)
        // The output joins the PMOS and NMOS sides on metal 2.
        for (x, y) in [(14.0, 6.5), (7.5, 19.5)] { rect(.via1, x, y, x + 2, y + 2, at: place) }
        rect(.metal2, 14, 6.5, 16, 13, at: place, net: out)
        rect(.metal2, 7.5, 13, 26, 15, at: place, net: out)
        rect(.metal2, 7.5, 15, 9.5, 21.5, at: place, net: out)
    }

    private func ease(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
}


private extension Bool {
    var digit: String { self ? "1" : "0" }
}

private func binary(_ value: Int) -> String {
    (0..<4).reversed().map { value >> $0 & 1 == 1 ? "1" : "0" }.joined()
}
