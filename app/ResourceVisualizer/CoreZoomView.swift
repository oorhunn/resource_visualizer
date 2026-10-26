import SwiftUI

/// Illustrative zoom from one CPU core down to transistors: a textbook five-stage RISC-V
/// pipeline, the low four bits of its adder, a full adder built from NAND gates, and one CMOS
/// NAND gate. Apple does not publish its core design, so this is a teaching model rather than the
/// real circuit; only the share of clock slots that carry an instruction follows the core's load.
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
                                      size: geometry.size)
                    let hovered = zoom.pointer.flatMap(scene.target(at:))
                    Canvas { context, _ in scene.draw(in: &context, highlight: hovered) }
                        .onTapGesture { location in
                            if let next = scene.target(at: location) {
                                withAnimation(.snappy) { zoom.path.append(next) }
                            }
                        }
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
                + "The carry ripples from bit 0 to bit 3. Click a full adder."
        case .adder(let bit):
            let s = Adder(instruction).signals(bit: bit)
            return idle + "a \(s[0].digit) + b \(s[1].digit) + carry in \(s[2].digit) gives sum "
                + "\(s[10].digit), carry out \(s[11].digit). Lit transistors conduct and lit wires carry a 1; "
                + "on each clock edge the new values ripple through one gate delay at a time. "
                + "Click a cell to enlarge it."
        case .gate(let bit, let gate):
            let s = Adder(instruction).signals(bit: bit)
            let (x, y) = FullAdder.gates[gate]
            return idle + "\(s[x].digit) NAND \(s[y].digit) = \((!(s[x] && s[y])).digit). PMOS transistors "
                + "conduct when their input is 0 and NMOS when it is 1, so the output connects to VDD or "
                + "to ground, never both. Current flows only while the output switches."
        }
    }
}

private enum Level: Hashable {
    case pipeline, alu, adder(bit: Int), gate(bit: Int, gate: Int)

    var title: String {
        switch self {
        case .pipeline: "Pipeline"
        case .alu: "Adder"
        case .adder(let bit): "Full adder, bit \(bit)"
        case .gate(_, let gate): "NAND N\(gate + 1)"
        }
    }
}

@MainActor
private final class ZoomState: ObservableObject {
    @Published var path: [Level] = []
    @Published var pointer: CGPoint?
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
    static let positions: [(Double, Double)] = [
        (1.9, 1.75), (3.5, 1.0), (3.5, 2.5), (5.1, 1.75), (6.7, 3.3), (8.3, 2.3), (8.3, 4.3),
        (9.9, 3.3), (8.3, 5.7),
    ]
    static let inputs: [Double] = [1.2, 2.3, 4.5] // y of a, b and carry in

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
    static let box = Color(red: 0.19, green: 0.20, blue: 0.23)
    static let edge = Color.white.opacity(0.22)
    static let text = Color.white.opacity(0.85)
    static let dim = Color.white.opacity(0.5)
    static let high = Color(red: 0.38, green: 0.86, blue: 1.0)
    static let low = Color(white: 0.4)
}

/// Maps a level's diagram units onto the view, centred and scaled to fit.
private struct Fit {
    let size: CGSize, scale: Double, origin: CGPoint

    init(_ unit: CGSize, in size: CGSize) {
        self.size = size
        scale = min(size.width / unit.width, size.height / unit.height)
        origin = CGPoint(x: (size.width - unit.width * scale) / 2, y: (size.height - unit.height * scale) / 2)
    }

    func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }

    func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> CGRect {
        CGRect(origin: p(x, y), size: CGSize(width: width * scale, height: height * scale))
    }

    func line(_ points: [(Double, Double)]) -> Path { Path { $0.addLines(points.map { p($0.0, $0.1) }) } }
}

/// One frame of one level: what to draw and which parts zoom in further.
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
    let fit: Fit
    private(set) var targets: [(CGRect, Level)] = []

    @MainActor
    init(level: Level, pipeline: Pipeline, date: Date, size: CGSize) {
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
        let unit: CGSize = switch level {
        case .pipeline: CGSize(width: 10, height: 3.35)
        case .alu: CGSize(width: 10, height: 4.1)
        case .adder: CGSize(width: 12.4, height: 6.5)
        case .gate: CGSize(width: 9.4, height: 7)
        }
        fit = Fit(unit, in: size)
        switch level {
        case .pipeline:
            let (x, y, w, h) = Self.stage(2)
            targets = [(fit.rect(x, y, w, h), .alu)]
        case .alu:
            targets = (0..<4).map { (fit.rect(Self.adderX($0), 1.5, 1.5, 1.3), .adder(bit: $0)) }
        case .adder(let bit):
            targets = FullAdder.positions.enumerated().map { gate, p in
                (fit.rect(p.0 - 0.5, p.1 - 0.42, 1.0, 0.84), .gate(bit: bit, gate: gate))
            }
        case .gate:
            targets = []
        }
    }

    func target(at point: CGPoint) -> Level? { targets.first { $0.0.contains(point) }?.1 }

    func draw(in context: inout GraphicsContext, highlight: Level?) {
        context.fill(Path(roundedRect: CGRect(origin: .zero, size: fit.size), cornerRadius: 8),
                     with: .color(Ink.background))
        switch level {
        case .pipeline: drawPipeline(&context)
        case .alu: drawAdder(&context)
        case .adder(let bit): drawFullAdder(&context, bit: bit)
        case .gate(let bit, let gate): drawGate(&context, bit: bit, gate: gate)
        }
        for (rect, target) in targets where target == highlight {
            let path = Path(roundedRect: rect, cornerRadius: 0.08 * fit.scale)
            context.fill(path, with: .color(.white.opacity(0.1)))
            context.stroke(path, with: .color(.white.opacity(0.75)), lineWidth: 1)
        }
    }

    // MARK: Levels

    private static let stageNames = ["Fetch", "Decode", "Execute", "Memory", "Write back"]
    private static func stage(_ i: Int) -> (Double, Double, Double, Double) { (0.15 + Double(i) * 1.97, 0.2, 1.75, 1.9) }

    private func drawPipeline(_ context: inout GraphicsContext) {
        // Each instruction slides in from the previous stage just after the clock edge.
        let shift = (1 - ease(min(elapsed / 0.35, 1))) * 1.97
        for (i, name) in Self.stageNames.enumerated() {
            let (x, y, w, h) = Self.stage(i)
            let rect = fit.rect(x, y, w, h)
            box(&context, rect, lit: stages[i] != nil)
            text(&context, name, at: x + w / 2, y + 0.28, size: 0.17, color: Ink.dim)
            if i < Self.stageNames.count - 1 { arrow(&context, from: (x + w + 0.03, y + h / 2), to: (x + 1.94, y + h / 2)) }
            var inside = context
            inside.clip(to: Path(rect))
            if let instruction = stages[i] {
                text(&inside, instruction.mnemonic, at: x + w / 2 - shift, y + 0.9, size: 0.3, mono: true)
                text(&inside, instruction.operands, at: x + w / 2 - shift, y + 1.25, size: 0.14,
                     color: Ink.dim, mono: true)
            } else {
                text(&inside, "bubble", at: x + w / 2 - shift, y + 0.95, size: 0.17, color: Ink.low)
            }
            if i == 2 { text(&context, "Adder ›", at: x + w / 2, y + h - 0.22, size: 0.15, color: Ink.high) }
        }

        let used = slots.filter { $0 }.count
        text(&context, "Clock slots, newest first", at: 0.2, 2.5, size: 0.16, color: Ink.dim, anchor: .leading)
        text(&context, "\(used) of \(slots.count) carried an instruction · core load \(Format.percent(load * 100))",
             at: 9.85, 2.5, size: 0.16, color: Ink.dim, anchor: .trailing)
        for i in 0..<Pipeline.slotCount {
            let rect = Path(roundedRect: fit.rect(0.2 + Double(i) * 0.405, 2.75, 0.32, 0.32), cornerRadius: 0.05 * fit.scale)
            if i < slots.count, slots[i] {
                context.fill(rect, with: .color(Ink.high.opacity(i == 0 ? 1 : 0.7)))
            } else {
                context.stroke(rect, with: .color(Ink.low), lineWidth: 1)
            }
        }
    }

    private static func adderX(_ bit: Int) -> Double { 0.9 + Double(3 - bit) * 2.25 }

    private func drawAdder(_ context: inout GraphicsContext) {
        for bit in 0..<4 {
            let x = Self.adderX(bit)
            let v = { settle.value(bit, $0) }, f = { settle.flash(bit, $0) }
            let b = subtract ? "b̄" : "b"
            wire(&context, [(x + 0.45, 0.65), (x + 0.45, 1.5)], v(0), flash: f(0))
            wire(&context, [(x + 1.05, 0.65), (x + 1.05, 1.5)], v(1), flash: f(1))
            text(&context, "a\(bit) \(v(0).digit)", at: x + 0.45, 0.45, size: 0.17, mono: true)
            text(&context, "\(b)\(bit) \(v(1).digit)", at: x + 1.05, 0.45, size: 0.17, mono: true)
            // The box flashes while new values pass through its gates.
            let busy = (3..<12).map(f).max() ?? 0
            box(&context, fit.rect(x, 1.5, 1.5, 1.3), lit: busy > 0)
            text(&context, "Full adder", at: x + 0.75, 2.0, size: 0.17)
            text(&context, "bit \(bit) · 36 transistors", at: x + 0.75, 2.3, size: 0.13, color: Ink.dim)

            let from = bit == 0 ? 9.95 : x + 2.25
            wire(&context, [(from, 2.15), (x + 1.5, 2.15)], v(2), flash: f(2))
            if bit == 0 {
                text(&context, "carry in \(v(2).digit)", at: 9.95, 2.4, size: 0.14, color: Ink.dim, anchor: .trailing)
            } else {
                text(&context, "c\(bit)", at: x + 1.875, 1.95, size: 0.14, color: Ink.dim, mono: true)
            }
            wire(&context, [(x + 0.75, 2.8), (x + 0.75, 3.55)], v(10), flash: f(10))
            text(&context, "s\(bit) \(v(10).digit)", at: x + 0.75, 3.8, size: 0.17, mono: true)
        }
        wire(&context, [(Self.adderX(3), 2.15), (0.1, 2.15)], settle.value(3, 11), flash: settle.flash(3, 11))
        text(&context, "carry out", at: 0.1, 2.4, size: 0.14, color: Ink.dim, anchor: .leading)
    }

    private func drawFullAdder(_ context: inout GraphicsContext, bit: Int) {
        let s = settle.signals(bit: bit), f = { settle.flash(bit, $0) }
        func source(_ signal: Int) -> (Double, Double) {
            if signal < 3 { return (0.65, FullAdder.inputs[signal]) }
            let p = FullAdder.positions[signal - 3]
            return (p.0 + 0.43, p.1)
        }
        for (i, name) in ["a", "b", "carry in"].enumerated() {
            text(&context, "\(name) \(s[i].digit)", at: 0.6, FullAdder.inputs[i], size: 0.18, anchor: .trailing)
        }
        for (gate, inputs) in FullAdder.gates.enumerated() {
            let p = FullAdder.positions[gate]
            for (pin, signal) in [inputs.0, inputs.1].enumerated() {
                let from = source(signal)
                let to = (p.0 - 0.42, p.1 + (pin == 0 ? -0.17 : 0.17))
                // Long hops from a gate turn down early so they do not run through gates on the way.
                let turn = signal >= 3 && to.0 - from.0 > 3 ? from.0 + 0.2
                    : to.0 - 0.22 - 0.09 * Double(signal % 4)
                wire(&context, [from, (turn, from.1), (turn, to.1), to], s[signal], flash: f(signal))
            }
        }
        for (gate, p) in FullAdder.positions.enumerated() {
            let (x, y) = FullAdder.gates[gate]
            cell(&context, at: p, a: s[x], b: s[y], out: s[3 + gate], flash: f(3 + gate), name: "N\(gate + 1)")
        }
        wire(&context, [source(10), (11.0, 3.3)], s[10], flash: f(10))
        wire(&context, [source(11), (11.0, 5.7)], s[11], flash: f(11))
        text(&context, "sum \(s[10].digit)", at: 11.1, 3.3, size: 0.18, anchor: .leading)
        text(&context, "carry out \(s[11].digit)", at: 11.1, 5.7, size: 0.18, anchor: .leading)
        text(&context, "36 transistors in 9 NAND cells; each cell: VDD rail on top, two PMOS, two NMOS, ground below",
             at: 0.05, 6.35, size: 0.15, color: Ink.dim, anchor: .leading)
    }

    private func drawGate(_ context: inout GraphicsContext, bit: Int, gate: Int) {
        let (x, y) = FullAdder.gates[gate]
        let a = settle.value(bit, x), b = settle.value(bit, y), out = settle.value(bit, 3 + gate)
        let fa = settle.flash(bit, x), fb = settle.flash(bit, y), fo = settle.flash(bit, 3 + gate)

        // Rails, the output node and the node between the two NMOS transistors.
        wire(&context, [(2.4, 0.5), (7.0, 0.5)], true)
        text(&context, "VDD", at: 7.15, 0.5, size: 0.18, color: Ink.high, anchor: .leading)
        wire(&context, [(3.6, 6.5), (5.4, 6.5)], false)
        text(&context, "GND", at: 5.55, 6.5, size: 0.18, color: Ink.dim, anchor: .leading)
        for px in [3.0, 6.0] {
            wire(&context, [(px, 0.5), (px, 1.15)], true)
            wire(&context, [(px, 2.05), (px, 2.9)], out, flash: fo)
        }
        wire(&context, [(3.0, 2.9), (7.6, 2.9)], out, flash: fo)
        wire(&context, [(4.5, 2.9), (4.5, 3.35)], out, flash: fo)
        wire(&context, [(4.5, 4.25), (4.5, 5.15)], !b && a && out)
        wire(&context, [(4.5, 6.05), (4.5, 6.5)], false)
        text(&context, "out \(out.digit)", at: 7.75, 2.9, size: 0.18, anchor: .leading)

        // Inputs: A drives P1 and N1, B drives P2 and N2.
        text(&context, "A \(a.digit)", at: 0.15, 1.6, size: 0.18, anchor: .leading)
        text(&context, "from \(FullAdder.name(x))", at: 0.15, 1.9, size: 0.13, color: Ink.dim, anchor: .leading)
        wire(&context, [(0.85, 1.6), (2.64, 1.6)], a, flash: fa)
        wire(&context, [(1.3, 1.6), (1.3, 3.8), (4.3, 3.8)], a, flash: fa)
        text(&context, "B \(b.digit)", at: 0.15, 5.6, size: 0.18, anchor: .leading)
        text(&context, "from \(FullAdder.name(y))", at: 0.15, 5.9, size: 0.13, color: Ink.dim, anchor: .leading)
        wire(&context, [(0.85, 5.6), (4.3, 5.6)], b, flash: fb)
        wire(&context, [(1.9, 5.6), (1.9, 2.45), (5.3, 2.45), (5.3, 1.6), (5.64, 1.6)], b, flash: fb)
        for (jx, jy, on) in [(1.3, 1.6, a), (1.9, 5.6, b), (4.5, 2.9, out), (6.0, 2.9, out)] {
            context.fill(Path(ellipseIn: fit.rect(jx - 0.06, jy - 0.06, 0.12, 0.12)), with: .color(signal(on)))
        }

        transistor(&context, x: 3.0, top: 1.15, name: "P1", pmos: true, input: a)
        transistor(&context, x: 6.0, top: 1.15, name: "P2", pmos: true, input: b)
        transistor(&context, x: 4.5, top: 3.35, name: "N1", pmos: false, input: a)
        transistor(&context, x: 4.5, top: 5.15, name: "N2", pmos: false, input: b)

        // Charge moves only when the output switches: in through the PMOS, out through the NMOS.
        guard !idle, let age = settle.age(bit, 3 + gate), age < 0.8 else { return }
        let paths: [[(Double, Double)]] = out
            ? [(3.0, !a), (6.0, !b)].filter { $0.1 }.map { [($0.0, 0.5), ($0.0, 2.9), (7.6, 2.9)] }
            : [[(7.6, 2.9), (4.5, 2.9), (4.5, 6.5)]]
        let style = StrokeStyle(lineWidth: 3, lineCap: .round, dash: [1, 0.25 * fit.scale],
                                dashPhase: -time * 1.2 * fit.scale)
        for path in paths {
            context.stroke(fit.line(path), with: .color(.white.opacity(1 - age / 0.8)), style: style)
        }
    }

    // MARK: Parts

    /// MOSFET with its channel running down from `top`; PMOS conducts on 0, NMOS on 1.
    private func transistor(_ context: inout GraphicsContext, x: Double, top: Double, name: String,
                            pmos: Bool, input: Bool) {
        let on = pmos != input, bottom = top + 0.9, mid = top + 0.45
        let channel = fit.line([(x, top), (x, bottom)])
        if on { context.stroke(channel, with: .color(Ink.high.opacity(idle ? 0.15 : 0.3)), lineWidth: 12) }
        context.stroke(channel, with: .color(on ? Ink.high : Ink.low.opacity(0.6)), lineWidth: on ? 4 : 2)
        context.stroke(fit.line([(x - 0.2, top + 0.08), (x - 0.2, bottom - 0.08)]), with: .color(signal(input)),
                       lineWidth: 2)
        if pmos {
            context.stroke(Path(ellipseIn: fit.rect(x - 0.36, mid - 0.07, 0.14, 0.14)), with: .color(signal(input)),
                           lineWidth: 1.5)
        }
        text(&context, name, at: x + 0.18, mid - 0.12, size: 0.17, anchor: .leading)
        text(&context, on ? "on" : "off", at: x + 0.18, mid + 0.15, size: 0.14,
             color: on ? Ink.high : Ink.dim, anchor: .leading)
    }

    /// A NAND gate as its four transistors, small enough to place nine in one view: a VDD rail on
    /// top, PMOS P1 and P2 side by side, NMOS N1 and N2 stacked under the output, ground below.
    /// Inputs enter on the left at ±0.17 and the output leaves on the right, as in the gate view.
    private func cell(_ context: inout GraphicsContext, at p: (Double, Double), a: Bool, b: Bool, out: Bool,
                      flash: Double, name: String) {
        func at(_ x: Double, _ y: Double) -> (Double, Double) { (p.0 + x, p.1 + y) }
        let frame = Path(roundedRect: fit.rect(p.0 - 0.42, p.1 - 0.46, 0.85, 0.92), cornerRadius: 0.06 * fit.scale)
        context.fill(frame, with: .color(Ink.box.opacity(0.7)))
        context.stroke(frame, with: .color(flash > 0 ? .white.opacity(0.3 + 0.6 * flash) : Ink.edge), lineWidth: 1)
        text(&context, name, at: p.0, p.1 - 0.56, size: 0.13, color: Ink.dim)

        wire(&context, [at(-0.34, -0.4), at(0.34, -0.4)], true, width: 1)
        wire(&context, [at(-0.12, 0.4), at(0.12, 0.4)], false, width: 1)
        for x in [-0.15, 0.15] {
            wire(&context, [at(x, -0.4), at(x, -0.33)], true, width: 1)
            wire(&context, [at(x, -0.19), at(x, 0)], out, flash: flash, width: 1)
        }
        wire(&context, [at(-0.15, 0), at(0.43, 0)], out, flash: flash)
        wire(&context, [at(0, 0), at(0, 0.05)], out, width: 1)
        wire(&context, [at(0, 0.19), at(0, 0.23)], !b && a && out, width: 1)
        wire(&context, [at(0, 0.37), at(0, 0.4)], false, width: 1)

        // Input A to the gates of P1 and N1, input B to P2 and N2.
        wire(&context, [at(-0.42, -0.17), at(-0.3, -0.17), at(-0.3, -0.26), at(-0.22, -0.26)], a, width: 1)
        wire(&context, [at(-0.3, -0.17), at(-0.3, 0.12), at(-0.07, 0.12)], a, width: 1)
        wire(&context, [at(-0.42, 0.17), at(-0.2, 0.17), at(-0.2, 0.3), at(-0.07, 0.3)], b, width: 1)
        wire(&context, [at(-0.2, 0.17), at(-0.2, -0.1), at(0.04, -0.1), at(0.04, -0.26), at(0.08, -0.26)], b, width: 1)

        for (x, y, gate, pmos) in [(-0.15, -0.26, a, true), (0.15, -0.26, b, true), (0, 0.12, a, false), (0, 0.3, b, false)] {
            let on = pmos != gate
            let channel = fit.rect(p.0 + x - 0.035, p.1 + y - 0.07, 0.07, 0.14)
            if on { context.fill(Path(roundedRect: channel.insetBy(dx: -4, dy: -4), cornerRadius: 4),
                                 with: .color(Ink.high.opacity(idle ? 0.12 : 0.25))) }
            context.fill(Path(channel), with: .color(on ? Ink.high.opacity(idle ? 0.55 : 1) : Ink.low.opacity(0.35)))
        }
    }

    private func box(_ context: inout GraphicsContext, _ rect: CGRect, lit: Bool = false) {
        let path = Path(roundedRect: rect, cornerRadius: 0.08 * fit.scale)
        context.fill(path, with: .color(Ink.box))
        context.stroke(path, with: .color(lit ? Ink.high.opacity(0.7) : Ink.edge), lineWidth: 1)
    }

    private func arrow(_ context: inout GraphicsContext, from: (Double, Double), to: (Double, Double)) {
        context.stroke(fit.line([from, to]), with: .color(Ink.dim), lineWidth: 1)
        context.stroke(fit.line([(to.0 - 0.08, to.1 - 0.06), to, (to.0 - 0.08, to.1 + 0.06)]),
                       with: .color(Ink.dim), lineWidth: 1)
    }

    /// A wire carrying a 1 glows; `flash` adds a white pulse as a new value arrives.
    private func wire(_ context: inout GraphicsContext, _ points: [(Double, Double)], _ on: Bool,
                      flash: Double = 0, width: Double = 1.5) {
        let path = fit.line(points)
        func style(_ width: Double) -> StrokeStyle { StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round) }
        if on { context.stroke(path, with: .color(Ink.high.opacity(idle ? 0.1 : 0.22)), style: style(width * 4)) }
        context.stroke(path, with: .color(signal(on)), style: style(width))
        if flash > 0 { context.stroke(path, with: .color(.white.opacity(0.9 * flash)), style: style(width + 1.5)) }
    }

    /// A 1 lights up; held values are dimmer while Execute is idle.
    private func signal(_ on: Bool) -> Color { on ? Ink.high.opacity(idle ? 0.55 : 1) : Ink.low }

    private func text(_ context: inout GraphicsContext, _ string: String, at x: Double, _ y: Double,
                      size: Double, color: Color = Ink.text, anchor: UnitPoint = .center, mono: Bool = false) {
        let points = size * fit.scale
        guard points >= 5 else { return }
        context.draw(Text(string)
            .font(.system(size: points, weight: .medium, design: mono ? .monospaced : .rounded))
            .foregroundColor(color), at: fit.p(x, y), anchor: anchor)
    }

    private func ease(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
}

private extension Bool {
    var digit: String { self ? "1" : "0" }
}

private func binary(_ value: Int) -> String {
    (0..<4).reversed().map { value >> $0 & 1 == 1 ? "1" : "0" }.joined()
}
