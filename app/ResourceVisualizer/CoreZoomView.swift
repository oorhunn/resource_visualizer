import AppKit
import SwiftUI

/// Illustrative zoom into one CPU core: a die of 256 lanes of 64-bit adders, laid out as 3D layout
/// in the style of Electric's 3D view, every one of its 147,456 NAND cells down to the transistors.
/// It opens on the whole die; pinch, scroll or double-click to zoom in, drag to orbit. Only what is
/// on screen is built, and in only as much detail as it shows at that size. Apple does not publish
/// its core design, so this is a teaching model rather than the real circuit; the adders work on
/// instructions clocked through a textbook pipeline, which issues as often as the core's load.
struct CoreZoomView: View {
    let core: CoreSample
    let exit: () -> Void

    // Property wrappers rather than the @State macro, which is unavailable without Xcode.
    @StateObject private var pipeline = Pipeline()
    @StateObject private var view = ViewState()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                GeometryReader { geometry in
                    let scene = Scene(pipeline: pipeline, date: timeline.date, size: geometry.size,
                                      camera: view.camera(at: timeline.date), die: view.die)
                    Canvas { context, _ in scene.draw(in: &context) }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .background(ScrollCatcher { event, point in scroll(event, at: point) })
                        .gesture(orbit)
                        .simultaneousGesture(pinch)
                        .onTapGesture(count: 2) { point in zoom(by: 4, at: point) }
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { view.size = $0 }
                }
            }
            .frame(height: 360)
            .overlay(alignment: .topTrailing) { controls }
            .accessibilityElement()
            .accessibilityLabel("\(coreName) adders")
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
                if view.dragStart == nil { view.land() }
                let start = view.dragStart ?? view.camera
                view.dragStart = start
                view.camera.yaw = start.yaw - drag.translation.width * 0.008
                view.camera.pitch = min(max(start.pitch + drag.translation.height * 0.008, 0.2), .pi / 2)
            }
            .onEnded { _ in view.dragStart = nil }
    }

    /// Zooms about the point between the fingers, so pinching over a cell opens it up.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { pinch in
                if view.pinchStart == nil { view.land() }
                let start = view.pinchStart ?? view.camera
                view.pinchStart = start
                view.camera = start.zoomed(by: pinch.magnification, about: pinch.startLocation, in: view.size)
            }
            .onEnded { _ in view.pinchStart = nil }
    }

    /// Flies the view in or out about a point, the middle of the view if none is given.
    private func zoom(by k: Double, at point: CGPoint? = nil) {
        let point = point ?? CGPoint(x: view.size.width / 2, y: view.size.height / 2)
        view.fly(to: view.camera(at: .now).zoomed(by: k, about: point, in: view.size))
    }

    /// Two-finger scrolling pans a zoomed view; a mouse wheel zooms about the pointer. Scrolling
    /// over the whole die is left to the dashboard, so it still scrolls past.
    private func scroll(_ event: NSEvent, at point: CGPoint) -> Bool {
        if event.hasPreciseScrollingDeltas {
            guard view.camera.zoom > 1 else { return false }
            view.land()
            view.camera.panX += event.scrollingDeltaX
            view.camera.panY += event.scrollingDeltaY
            view.camera = view.camera.clamped(in: view.size)
        } else {
            view.land()
            view.camera = view.camera.zoomed(by: pow(1.15, event.scrollingDeltaY), about: point, in: view.size)
        }
        return true
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button { zoom(by: 0.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
                .disabled(view.camera.zoom <= 1)
            Button { zoom(by: 4) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
                .disabled(view.camera.zoom >= Camera.maxZoom)
            if view.camera != Camera() {
                Button { view.fly(to: Camera()) } label: { Image(systemName: "arrow.counterclockwise") }
                    .help("Show the whole die")
            }
            Button(action: exit) { Image(systemName: "xmark") }
                .help("Back to the chip")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.white.opacity(0.7))
        .padding(10)
    }

    private var coreName: String {
        (core.type == "P" ? "P-core" : core.type == "E" ? "E-core" : "Core") + " \(core.id)"
    }

    private var caption: String {
        let instruction = pipeline.executed, (a, b) = instruction.operands(lane: 0)
        let idle = pipeline.stages[2] == nil ? "Execute holds a bubble, so this shows the last instruction. " : ""
        return idle + "\(coreName) running \(instruction.text) on all \(Die.lanes) lanes at once. Lane 0: "
            + "\(hex(a)) \(instruction.subtract ? "−" : "+") \(hex(b)) = \(hex(pipeline.result(lane: 0))). "
            + "Each lane is a 64-bit ripple-carry adder, one full adder of nine NAND cells per row: "
            + "\(Die.cells.formatted()) cells and \(Die.transistors.formatted()) transistors in all. "
            + "Lit cells drive a 1, and the carry ripples down every lane from bit 0 to bit 63. "
            + "Instructions arrive as often as this core's load (\(Format.percent(core.busy))) allows. "
            + "Pinch, scroll or double-click to zoom in down to the transistors; drag to orbit."
    }
}

@MainActor
private final class ViewState: ObservableObject {
    static let flightTime = 0.45 // seconds

    @Published var camera = Camera()
    var dragStart: Camera?
    var pinchStart: Camera?
    var size = CGSize(width: 1, height: 1)
    let die = DieImage()
    private var flight: (from: Camera, start: Date)?

    /// The camera to draw at a moment: on its way to `camera` if it is flying there.
    func camera(at date: Date) -> Camera {
        guard let flight else { return camera }
        let t = date.timeIntervalSince(flight.start) / Self.flightTime
        guard t < 1 else { return camera }
        return flight.from.interpolated(to: camera, 1 - pow(1 - max(t, 0), 3))
    }

    func fly(to target: Camera) {
        flight = (camera(at: .now), .now)
        camera = target
    }

    /// Stops a flight where it is, so a gesture picks the view up from what is on screen.
    func land() {
        camera = camera(at: .now)
        flight = nil
    }
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
    private(set) var executedAt = Date.distantPast  // when it entered Execute
    /// Every row's signals for the last instruction through Execute and the one before it.
    private(set) var signals = Die.signals(Instruction.make(0))
    private(set) var previousSignals = Die.signals(Instruction.make(0))
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

    /// One lane's sum, read off the sum outputs of its rows.
    func result(lane: Int) -> UInt64 {
        (0..<Die.bits).reduce(0) { $0 | UInt64(signals[lane * Die.bits + $1] >> 10 & 1) << $1 }
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
            executed = current
            executedAt = edge
            previousSignals = signals
            signals = Die.signals(current)
        }
        slots = Array(([next != nil] + slots).prefix(Self.slotCount))
        stages = [next] + stages.dropLast()
    }
}

private struct Instruction {
    let serial: Int
    let text: String
    let subtract: Bool
    let immediate: UInt64?

    /// A short loop body. Register values are made up; immediates are the ones in the text.
    private static let program: [(String, Bool, UInt64?)] = [
        ("addi x5, x5, 1", false, 1), ("add x6, x6, x5", false, nil), ("lw x7, 8(x10)", false, 8),
        ("sub x8, x7, x6", true, nil), ("sw x8, 4(x10)", false, 4), ("bne x5, x11, loop", true, nil),
    ]

    static func make(_ serial: Int) -> Instruction {
        let (text, subtract, immediate) = program[serial % program.count]
        return Instruction(serial: serial, text: text, subtract: subtract, immediate: immediate)
    }

    /// The operands one lane adds: its own made-up register values, varied but repeatable, and
    /// the immediate shared by every lane.
    func operands(lane: Int) -> (UInt64, UInt64) {
        let a = mix(UInt64(serial) << 16 | UInt64(lane))
        return (a, immediate ?? mix(a))
    }
}

/// SplitMix64's finaliser: spreads a counter into well-mixed bits.
private func mix(_ x: UInt64) -> UInt64 {
    var z = x &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ z >> 30) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ z >> 27) &* 0x94D0_49BB_1331_11EB
    return z ^ z >> 31
}

/// A full adder as nine two-input NAND gates. Signals 0–2 are a, b and carry in; gate i drives
/// signal 3 + i, so gate 7 gives the sum and gate 8 the carry out.
private enum FullAdder {
    static let gates = [(0, 1), (0, 3), (1, 3), (4, 5), (6, 2), (6, 7), (2, 7), (8, 9), (7, 3)]

    /// All twelve signals as bits of one mask, signal i in bit i.
    static func signals(_ a: Bool, _ b: Bool, _ carry: Bool) -> UInt16 {
        var s: UInt16 = (a ? 1 : 0) | (b ? 2 : 0) | (carry ? 4 : 0)
        for (i, (x, y)) in gates.enumerated() where s >> x & s >> y & 1 == 0 { s |= 1 << (3 + i) }
        return s
    }
}

/// The die: a grid of lanes, each one 64-bit ripple-carry adder laid out as a column of 64 rows,
/// one full adder of nine NAND cells per row with bit 0 on top. Sizes are in λ.
private enum Die {
    static let columns = 64, laneRows = 4, bits = 64
    static let lanes = columns * laneRows
    static let cells = lanes * bits * 9, transistors = cells * 4

    static let pitch = 36.0                  // cell to cell along a row, leaving a 10 λ gap for risers
    static let rowEnd = 8 * pitch + 26       // right edge of the last cell
    static let carryX = 8 * pitch + 28       // riser of the last cell, N9, which gives the carry out
    static let left = -16.0, right = rowEnd + 16
    static let trackPitch = 3.0

    /// A wire in a row's routing channel: a trunk on metal 2 along one track, reached on metal 3
    /// from its source and down to each cell input it drives.
    struct Wire {
        var signal: Int
        var from: Double                 // x of its source: a riser, or the row's left edge
        var pins: [(gate: Int, b: Bool)] // the cell inputs it drives
        var exits = false                // runs on to the right edge: the sum, and the last carry
        var track = 0

        var span: (Double, Double) {
            let xs = [from] + pins.map { Die.pinX($0.gate, b: $0.b) } + (exits ? [Die.right] : [])
            return (xs.min()!, xs.max()!)
        }
    }

    /// The riser beside a cell input: B just left of the cell, A left of that.
    static func pinX(_ gate: Int, b: Bool) -> Double { Double(gate) * pitch - (b ? 2.5 : 5) }

    /// The wires of the first row, which takes the carry in from the left edge, a middle row, and
    /// the last, whose carry out leaves on the right instead of dropping to the next row.
    private static let kinds = [wires(first: true, last: false), wires(first: false, last: false),
                                wires(first: false, last: true)]

    static func wires(bit: Int) -> [Wire] { kinds[bit == 0 ? 0 : bit == bits - 1 ? 2 : 1] }

    /// One row's wires, packed onto as few tracks as possible.
    private static func wires(first: Bool, last: Bool) -> [Wire] {
        var wires: [Wire] = []
        for signal in 0..<(last ? 12 : 11) {
            var pins: [(gate: Int, b: Bool)] = []
            for (gate, (x, y)) in FullAdder.gates.enumerated() {
                if x == signal { pins.append((gate, false)) }
                if y == signal { pins.append((gate, true)) }
            }
            let from = signal < 2 || (signal == 2 && first) ? left
                : signal == 2 || signal == 11 ? carryX : Double(signal - 3) * pitch + 28
            wires.append(Wire(signal: signal, from: from, pins: pins, exits: signal >= 10))
        }
        var ends: [Double] = []
        for i in wires.indices.sorted(by: { wires[$0].span.0 < wires[$1].span.0 }) {
            let (start, end) = wires[i].span
            if let free = ends.firstIndex(where: { $0 + 3 < start }) {
                wires[i].track = free
                ends[free] = end
            } else {
                wires[i].track = ends.count
                ends.append(end)
            }
        }
        return wires
    }

    static let channel = Double(kinds.flatMap { $0.map(\.track) }.max()! + 1) * trackPitch + 2.5
    static let rowPitch = channel + 31
    static func trackY(_ track: Int) -> Double { -3.5 - Double(track) * trackPitch } // above the row

    /// A lane has a spare cell's width on either side for its inputs and outputs, and a spare row
    /// above and below; the one above holds its name.
    static let laneWidth = 11 * pitch, laneHeight = Double(bits + 2) * rowPitch
    static let width = Double(columns) * laneWidth, height = Double(laneRows) * laneHeight

    static func origin(_ lane: Int) -> SIMD2<Double> {
        [Double(lane % columns) * laneWidth, Double(lane / columns) * laneHeight]
    }

    /// Maps a row's own coordinates into the die's: cells from x = 0, the routing channel above y = 0.
    static func row(_ lane: Int, _ bit: Int) -> Place {
        let o = origin(lane)
        return Place(x: o.x + pitch, y: o.y + Double(bit + 1) * rowPitch + channel)
    }

    /// Every row of every lane for an instruction, as signal masks, lane by lane from bit 0.
    /// Subtraction inverts b and sets the carry in.
    static func signals(_ instruction: Instruction) -> [UInt16] {
        var signals = [UInt16](repeating: 0, count: lanes * bits)
        for lane in 0..<lanes {
            let (a, operand) = instruction.operands(lane: lane), b = instruction.subtract ? ~operand : operand
            var carry = instruction.subtract
            for bit in 0..<bits {
                let s = FullAdder.signals(a >> bit & 1 == 1, b >> bit & 1 == 1, carry)
                signals[lane * bits + bit] = s
                carry = s >> 11 & 1 == 1
            }
        }
        return signals
    }
}

/// Every adder signal at a moment after a new instruction reaches Execute. Each NAND gate takes
/// one gate delay to follow its inputs, so new values ripple through each row, and down the carry
/// chain from bit 0 to bit 63, instead of appearing all at once. The timing does not depend on
/// the values, so it is worked out once for all lanes.
private struct Settle {
    /// Seconds per gate: the whole carry chain settles within 0.7 s of the 0.9 s clock, about
    /// half a billion times slower than a real gate.
    static let delay = 0.7 / steps[(bits - 1) * 12 + 11]
    private static let bits = Die.bits

    /// When each signal of each row takes its new value, in gate delays; row by row, 12 a row.
    private static let steps: [Double] = {
        var t: [Double] = []
        for bit in 0..<bits {
            var row = [0, 0, bit == 0 ? 0 : t[(bit - 1) * 12 + 11]]
            for (x, y) in FullAdder.gates { row.append(max(row[x], row[y]) + 1) }
            t += row
        }
        return t
    }()
    private static let times = steps.map { $0 * delay }

    let new: [UInt16], old: [UInt16]
    let elapsed: Double

    func value(_ lane: Int, _ bit: Int, _ signal: Int) -> Bool {
        let row = lane * Self.bits + bit
        return (elapsed >= Self.times[bit * 12 + signal] ? new[row] : old[row]) >> signal & 1 == 1
    }

    /// 1 just as a signal changes, fading to 0 over a third of a second.
    func flash(_ lane: Int, _ bit: Int, _ signal: Int) -> Double {
        guard let age = age(lane, bit, signal), age < 0.35 else { return 0 }
        return 1 - age / 0.35
    }

    /// Seconds since a signal changed, or nil if it did not.
    func age(_ lane: Int, _ bit: Int, _ signal: Int) -> Double? {
        let row = lane * Self.bits + bit, time = Self.times[bit * 12 + signal]
        return (new[row] ^ old[row]) >> signal & 1 == 1 && elapsed >= time ? elapsed - time : nil
    }

    /// Whether anything is still switching or fading.
    var settled: Bool { elapsed > 0.7 + 0.35 }
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

    /// On a net: full while it carries a 1, dark at 0, and whitened as a new value arrives.
    /// Dimmed while Execute holds a bubble.
    func lit(_ net: Net, idle: Bool) -> Tint {
        (net.on ? scaled(idle ? 0.8 : 1) : scaled(0.4)).mixed(.white, 0.85 * net.flash)
    }

    /// Red, green and blue bytes.
    var bytes: (UInt8, UInt8, UInt8) {
        func byte(_ x: Double) -> UInt8 { UInt8(min(max(x, 0), 1) * 255) }
        return (byte(r), byte(g), byte(b))
    }
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
/// π/2 straight down. Zoom 1 fits the whole die; pan moves the zoomed view on screen, in points.
struct Camera: Equatable {
    static let maxZoom = 800.0 // a NAND cell about half the view wide

    var yaw = -0.06, pitch = 1.05, zoom = 1.0
    var panX = 0.0, panY = 0.0

    /// Zoomed about a point in a view of the given size, keeping that point where it is.
    func zoomed(by k: Double, about point: CGPoint, in size: CGSize) -> Camera {
        var camera = self
        camera.zoom = min(max(zoom * k, 1), Self.maxZoom)
        let k = camera.zoom / zoom, ax = point.x - size.width / 2, ay = point.y - size.height / 2
        camera.panX = ax - (ax - panX) * k
        camera.panY = ay - (ay - panY) * k
        return camera.clamped(in: size)
    }

    /// Keeps the die in view: it may only move as far as it has grown.
    func clamped(in size: CGSize) -> Camera {
        var camera = self
        let reach = (zoom - 1) / 2
        camera.panX = min(max(panX, -reach * size.width), reach * size.width)
        camera.panY = min(max(panY, -reach * size.height), reach * size.height)
        return camera
    }

    /// Part of the way to another camera, zooming at an even pace however far it goes.
    func interpolated(to other: Camera, _ t: Double) -> Camera {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        let zoom = exp(mix(log(zoom), log(other.zoom)))
        // Pan grows with zoom, so it is eased per unit of zoom to keep the target point steady.
        return Camera(yaw: mix(yaw, other.yaw), pitch: mix(pitch, other.pitch), zoom: zoom,
                      panX: mix(panX / self.zoom, other.panX / other.zoom) * zoom,
                      panY: mix(panY / self.zoom, other.panY / other.zoom) * zoom)
    }
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

/// Scene to screen. The scale is fitted at the starting camera, so orbiting does not make the
/// layout breathe; the layout's centre stays in the middle of the view until it is panned.
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
        offset = CGPoint(x: frame.midX + camera.panX - u * scale, y: frame.midY + camera.panY - v * scale)
    }

    func point(_ p: SIMD3<Double>) -> CGPoint {
        let (u, v) = orientation.uv(p)
        return CGPoint(x: offset.x + u * scale, y: offset.y + v * scale)
    }

    /// Maps the plane at height z, in units of (dx, dy) from (x, y), onto the screen. The view is
    /// orthographic, so any plane maps by an affine transform.
    func transform(x: Double, y: Double, z: Double, dx: Double, dy: Double) -> CGAffineTransform {
        let o = point([x, y, z]), ex = point([x + dx, y, z]), ey = point([x, y + dy, z])
        return CGAffineTransform(a: ex.x - o.x, b: ex.y - o.y, c: ey.x - o.x, d: ey.y - o.y, tx: o.x, ty: o.y)
    }
}

/// The whole die as an image with a 2 × 2 block of pixels per NAND cell: the cell, the gap beside
/// it, and the routing channel above. Drawn once the cells are too small to draw one by one, and
/// rebuilt only while signals are changing.
@MainActor
private final class DieImage {
    nonisolated static let width = Die.columns * 11 * 2, height = Die.laneRows * (Die.bits + 2) * 2

    private var key: (serial: Int, idle: Bool, frame: Int)?
    private var image: CGImage?
    private lazy var template: [UInt8] = {
        var pixels = [UInt8](repeating: 255, count: Self.width * Self.height * 4)
        func fill(_ x: Int, _ y: Int, _ tint: Tint) {
            let i = (y * Self.width + x) * 4, (r, g, b) = tint.bytes
            (pixels[i], pixels[i + 1], pixels[i + 2]) = (r, g, b)
        }
        for y in 0..<Self.height {
            for x in 0..<Self.width { fill(x, y, Layer.substrate.tint.scaled(0.8)) }
        }
        for lane in 0..<Die.lanes {
            let column = lane % Die.columns * 11 + 1, row = lane / Die.columns * (Die.bits + 2) + 1
            for bit in 0..<Die.bits {
                for gate in 0..<9 {
                    let x = 2 * (column + gate), y = 2 * (row + bit)
                    fill(x, y, Layer.metal3.tint.scaled(0.3))
                    fill(x + 1, y, Layer.metal3.tint.scaled(0.3))
                    fill(x + 1, y + 1, Layer.well.tint.scaled(0.7))
                }
            }
        }
        return pixels
    }()

    func image(_ settle: Settle, serial: Int, idle: Bool) -> CGImage? {
        let key = (serial: serial, idle: idle, frame: settle.settled ? -1 : Int(settle.elapsed * 30))
        if let image, let old = self.key, old == key { return image }
        var pixels = template
        pixels.withUnsafeMutableBufferPointer { pixels in
            for lane in 0..<Die.lanes {
                let column = lane % Die.columns * 11 + 1, row = lane / Die.columns * (Die.bits + 2) + 1
                for bit in 0..<Die.bits {
                    let y = 2 * (row + bit) + 1
                    for gate in 0..<9 {
                        let out = Net(on: settle.value(lane, bit, 3 + gate), flash: settle.flash(lane, bit, 3 + gate))
                        let (r, g, b) = Layer.metal2.tint.lit(out, idle: idle).bytes
                        let i = (y * Self.width + 2 * (column + gate)) * 4
                        (pixels[i], pixels[i + 1], pixels[i + 2]) = (r, g, b)
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        image = CGImage(width: Self.width, height: Self.height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: Self.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        self.key = key
        return image
    }
}

/// One frame of the die, built as layout and drawn the way Electric's 3D view shows a cell:
/// every layer extruded at its own height in its own colour, seen through an orbiting camera.
/// Lit channels conduct and lit metal carries a 1. Only what is on screen is built, in as much
/// detail as its size allows: the whole die as an image of its cells, then each cell as a tile,
/// then every transistor and wire.
private struct Scene {
    private enum Detail { case die, cells, layout }

    let settle: Settle
    let subtract: Bool
    let idle: Bool
    let time: Double
    let size: CGSize
    private var detail = Detail.die
    private var boxes: [Box] = []
    private var tiles: [(corners: [CGPoint], color: Color)] = [] // flat tops of cells and rows
    private var image: (image: CGImage, transform: CGAffineTransform)?
    private var labels: [Label] = []
    private var flows: [(points: [SIMD3<Double>], opacity: Double)] = [] // charge moving through a gate
    private var projection = Projection()

    @MainActor
    init(pipeline: Pipeline, date: Date, size: CGSize, camera: Camera, die: DieImage) {
        settle = Settle(new: pipeline.signals, old: pipeline.previousSignals,
                        elapsed: date.timeIntervalSince(pipeline.executedAt))
        subtract = pipeline.executed.subtract
        idle = pipeline.stages[2] == nil
        time = date.timeIntervalSinceReferenceDate
        self.size = size
        projection = Projection(camera, lo: [0, 0, Layer.substrate.z.0], hi: [Die.width, Die.height, Layer.metal3.z.1],
                                frame: CGRect(origin: .zero, size: size))
        // How wide a cell's pitch is on screen decides how much of it to draw.
        let cell = projection.scale * Die.pitch
        detail = cell >= 80 ? .layout : cell >= 14 ? .cells : .die
        if detail == .die, let image = die.image(settle, serial: pipeline.executed.serial, idle: idle) {
            self.image = (image, projection.transform(x: 0, y: 0, z: 0, dx: Die.pitch / 2, dy: Die.rowPitch / 2))
        }
        buildDie()
    }

    func draw(in context: inout GraphicsContext) {
        context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(Ink.background))
        let projected = boxes.map { corners($0.lo, $0.hi).map(projection.point) }
        for i in paintOrder(projected) { drawBox(&context, boxes[i], projected[i]) }
        let shown = Set(boxes.indices.filter { onScreen(projected[$0]) }.compactMap { boxes[$0].layer })
        if let image {
            var plane = context
            plane.concatenate(image.transform)
            // Pixels smaller than a point are smoothed, or the cell grid beats against the screen's.
            let sharp = projection.scale * Die.pitch / 2 >= 2
            plane.draw(Image(decorative: image.image, scale: 1).interpolation(sharp ? .none : .high),
                       in: CGRect(x: 0, y: 0, width: DieImage.width, height: DieImage.height))
        }
        for tile in tiles {
            context.fill(Path { $0.addLines(tile.corners); $0.closeSubpath() }, with: .color(tile.color))
        }
        for flow in flows { drawFlow(&context, flow.points, opacity: flow.opacity) }

        var ink = context
        ink.addFilter(.shadow(color: .black.opacity(0.9), radius: 1.5))
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -150, dy: -30)
        for label in labels {
            let points = label.size * projection.scale
            var at = projection.point(label.at)
            guard points >= 5, bounds.contains(at) else { continue }
            at.y += label.dy
            ink.draw(Text(label.text)
                .font(.system(size: min(points, 18), weight: .medium, design: label.mono ? .monospaced : .rounded))
                .foregroundColor(label.color), at: at, anchor: label.anchor)
        }
        if detail == .layout { drawLegend(&ink, shown) } else { drawSummary(&ink) }
    }

    // MARK: Rendering

    /// Back-to-front order for the painter's algorithm. Two boxes whose outlines overlap on screen
    /// are ordered by a plane that separates them: the one on the far side is drawn first. The
    /// substrate and wells lie below everything else, and the camera always looks down, so they
    /// go first without being compared.
    private func paintOrder(_ corners: [[CGPoint]]) -> [Int] {
        let base = boxes.indices.filter { boxes[$0].hi.z <= 1e-9 }.sorted { boxes[$0].lo.z < boxes[$1].lo.z }
        let rest = boxes.indices.filter { boxes[$0].hi.z > 1e-9 }
        return base + paintOrder(rest, corners).map { rest[$0] }
    }

    private func paintOrder(_ subset: [Int], _ allCorners: [[CGPoint]]) -> [Int] {
        let boxes = subset.map { self.boxes[$0] }, corners = subset.map { allCorners[$0] }
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
    private func drawLegend(_ context: inout GraphicsContext, _ shown: Set<Layer>) {
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

    /// The size of what is on screen, bottom left, until the layers themselves show.
    private func drawSummary(_ context: inout GraphicsContext) {
        let text = "\(Die.lanes) lanes × 64-bit adders · \(Die.cells.formatted()) NAND cells · "
            + "\(Die.transistors.formatted()) transistors"
        context.draw(Text(text).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(Ink.dim),
                     at: CGPoint(x: 10, y: size.height - 14), anchor: .leading)
    }

    // MARK: Building

    /// Whether any of a plan rectangle, through the full height of the layer stack, is on screen.
    private func onScreen(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Bool {
        onScreen(corners([x0, y0, Layer.substrate.z.0], [x1, y1, Layer.metal3.z.1]).map(projection.point))
    }

    /// Whether the outline around projected points reaches the screen.
    private func onScreen(_ points: [CGPoint]) -> Bool {
        let xs = points.map(\.x), ys = points.map(\.y)
        return xs.max()! > -8 && xs.min()! < size.width + 8 && ys.max()! > -8 && ys.min()! < size.height + 8
    }

    /// The substrate under the whole die, then each lane on screen, row by row once they are big
    /// enough to make out.
    private mutating func buildDie() {
        rect(.substrate, -Die.pitch / 2, -Die.pitch / 2, Die.width + Die.pitch / 2, Die.height + Die.pitch / 2)
        for lane in 0..<Die.lanes {
            let o = Die.origin(lane)
            guard onScreen(o.x, o.y, o.x + Die.laneWidth, o.y + Die.laneHeight) else { continue }
            label("lane \(lane)", o.x + Die.pitch, o.y + Die.rowPitch / 2, 0, size: Die.rowPitch * 0.45,
                  color: Ink.dim, anchor: .leading)
            guard detail != .die else { continue }
            for bit in 0..<Die.bits {
                let row = Die.row(lane, bit)
                guard onScreen(row.x + Die.left - 20, row.y - Die.channel, row.x + Die.right + 20, row.y + 31)
                else { continue }
                if detail == .layout { buildRow(lane, bit, at: row) } else { sketchRow(lane, bit, at: row) }
            }
        }
    }

    private mutating func rect(_ layer: Layer, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
                               at place: Place = Place(), net: Net? = nil, z: (Double, Double)? = nil,
                               tint: Tint? = nil) {
        let (z0, z1) = z ?? layer.z
        var color = tint ?? layer.tint, glow = 0.0
        if let net {
            color = color.lit(net, idle: idle)
            glow = net.on ? (idle ? 0.35 : 1) : 0
        } else if tint == nil {
            color = color.scaled(0.8)
        }
        boxes.append(Box(lo: place.p(x0, y0, z0), hi: place.p(x1, y1, z1), tint: color, glow: glow, layer: layer,
                         opacity: layer.opacity))
    }

    /// The flat top of a plan rectangle at height z.
    private mutating func tile(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, z: Double, at place: Place,
                               _ tint: Tint) {
        let points = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)].map { projection.point(place.p($0.0, $0.1, z)) }
        tiles.append((points, tint.color()))
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

    // MARK: Rows

    /// A row too small for its transistors: the well, a tile per cell lit by its output, the
    /// rails, and the routing channel above.
    private mutating func sketchRow(_ lane: Int, _ bit: Int, at row: Place) {
        let settle = settle, idle = idle
        tile(-1, -1, Die.rowEnd + 1, 13.5, z: 0, at: row, Layer.well.tint)
        tile(Die.left, -Die.channel + 1, Die.right, -1, z: Layer.metal2.z.1, at: row, Layer.metal3.tint.scaled(0.3))
        for gate in 0..<9 {
            let gx = Double(gate) * Die.pitch
            let out = Net(on: settle.value(lane, bit, 3 + gate), flash: settle.flash(lane, bit, 3 + gate))
            tile(gx, 3, gx + 26, 25, z: Layer.metal2.z.1, at: row, Layer.metal2.tint.lit(out, idle: idle))
        }
        tile(0, 0, Die.rowEnd, 3, z: Layer.metal1.z.1, at: row, Layer.metal1.tint.lit(Net(on: true), idle: idle))
        tile(0, 25, Die.rowEnd, 28, z: Layer.metal1.z.1, at: row, Layer.metal1.tint.lit(Net(on: false), idle: idle))
        label("bit \(bit)", row.x + Die.left - 2, row.y + 10, 0, size: 4, color: Ink.dim, anchor: .trailing)
    }

    /// One full adder as nine NAND cells, the cells on screen down to their transistors, wired
    /// through the routing channel above the row. The carry out drops into the next row's channel.
    private mutating func buildRow(_ lane: Int, _ bit: Int, at row: Place) {
        let settle = settle
        let net = { Net(on: settle.value(lane, bit, $0), flash: settle.flash(lane, bit, $0)) }
        let vdd = Net(on: true), ground = Net(on: false)
        rect(.well, -1, -1, Die.rowEnd + 1, 13.5, at: row)
        // A cell's own wiring is built with it: the risers to its inputs and from its output.
        let shown = (0..<9).filter {
            onScreen(row.x + Double($0) * Die.pitch - 6, row.y - Die.channel, row.x + Double($0 + 1) * Die.pitch, row.y + 28)
        }
        for gate in shown {
            let (x, y) = FullAdder.gates[gate], gx = Double(gate) * Die.pitch, cell = Place(x: row.x + gx, y: row.y)
            nand(at: cell, a: net(x), b: net(y), out: net(3 + gate))
            label("N\(gate + 1)", cell.x + 13, row.y + 14, Layer.metal2.z.1, size: 2.2, color: Ink.dim)
            if gate < 8 { // the rails run on through the gaps
                rect(.metal1, gx + 26, 0, gx + Die.pitch, 3, at: row, net: vdd)
                rect(.metal1, gx + 26, 25, gx + Die.pitch, 28, at: row, net: ground)
            }
            addFlow(lane, bit, gate, at: cell)
        }
        // The inputs enter on the left edge; their values are named once per row.
        let carryIn = bit == 0 ? " c\(net(2).on.digit)" : ""
        label("bit \(bit)", row.x + Die.left - 2, row.y + 10, 0, size: 4, color: Ink.dim, anchor: .trailing)
        label("a\(net(0).on.digit) \(subtract ? "b̄" : "b")\(net(1).on.digit)" + carryIn, row.x + Die.left - 2,
              row.y + 17, 0, size: 3.4, anchor: .trailing, mono: true)
        label("VDD", row.x + Die.rowEnd + 1.5, row.y + 1.5, Layer.metal1.z.1, size: 2.4, color: Ink.high, anchor: .leading)
        label("GND", row.x + Die.rowEnd + 1.5, row.y + 26.5, Layer.metal1.z.1, size: 2.4, color: Ink.dim, anchor: .leading)

        for wire in Die.wires(bit: bit) {
            let n = net(wire.signal), y = Die.trackY(wire.track), (start, end) = wire.span
            route([(start, y), (end, y)], width: 2, net: n, at: row)
            if wire.from != Die.left { via2(wire.from, y, at: row) }
            if (3...10).contains(wire.signal) || wire.signal == 11, shown.contains(min(wire.signal - 3, 8)) {
                let gx = Double(wire.signal - 3) * Die.pitch
                route([(gx + 26, 14), (wire.from, 14), (wire.from, y)], width: 2, net: n, at: row)
            }
            for pin in wire.pins where shown.contains(pin.gate) {
                let x = Die.pinX(pin.gate, b: pin.b), gx = Double(pin.gate) * Die.pitch
                route([(x, y), (x, pin.b ? 19.2 : 8.75), (gx + 1.75, pin.b ? 19.2 : 8.75)], width: 2, net: n,
                      at: row, drop: true)
                via2(x, y, at: row)
            }
            let v = n.on.digit
            if wire.signal == 10 {
                label("s\(bit) \(v)", row.x + Die.right + 1, row.y + y, 0, size: 3.4, anchor: .leading, mono: true)
            } else if wire.signal == 11 {
                label("carry \(v)", row.x + Die.right + 1, row.y + y + 4, 0, size: 3.4, color: Ink.dim, anchor: .leading)
            }
        }
        // The carry out drops into the next row's channel, where that row picks it up.
        if bit < Die.bits - 1, shown.contains(8), let carry = Die.wires(bit: bit + 1).first(where: { $0.signal == 2 }) {
            route([(Die.rowEnd, 14), (Die.carryX, 14), (Die.carryX, Die.rowPitch + Die.trackY(carry.track))],
                  width: 2, net: net(11), at: row)
        }
    }

    private mutating func via2(_ x: Double, _ y: Double, at place: Place) {
        rect(.via2, x - 1, y - 1, x + 1, y + 1, at: place)
    }

    /// Charge moves through a cell only when its output switches: in from VDD through the PMOS,
    /// or out to ground through the NMOS.
    private mutating func addFlow(_ lane: Int, _ bit: Int, _ gate: Int, at place: Place) {
        guard !idle, let age = settle.age(lane, bit, 3 + gate), age < 0.8 else { return }
        let (x, y) = FullAdder.gates[gate]
        let a = settle.value(lane, bit, x), b = settle.value(lane, bit, y)
        let paths: [[SIMD3<Double>]] = settle.value(lane, bit, 3 + gate)
            ? [(8.5, !a), (21.5, !b)].filter(\.1).map { x, _ in
                [[x, 1.5, 5.5], [x, 7.5, 5.5], [x, 7.5, 1], [15, 7.5, 1], [15, 7.5, 9], [15, 14, 9], [28, 14, 9]]
            }
            : [[[28, 14, 9], [8.5, 14, 9], [8.5, 20.5, 9], [8.5, 20.5, 1], [21.5, 20.5, 1], [21.5, 20.5, 5.5],
                [21.5, 26.5, 5.5]]]
        flows += paths.map { ($0.map { place.p($0.x, $0.y, $0.z) }, 1 - age / 0.8) }
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
}

/// Hands scroll-wheel events over the view to `handler`, which returns whether it used them, so
/// panning the layout does not also scroll the dashboard. Clicks pass straight through.
private struct ScrollCatcher: NSViewRepresentable {
    let handler: (NSEvent, CGPoint) -> Bool

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.handler = handler }

    final class CatcherView: NSView {
        var handler: ((NSEvent, CGPoint) -> Bool)?
        private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // Local monitors run on the main thread.
                nonisolated(unsafe) let event = event
                let used = MainActor.assumeIsolated {
                    guard let self, event.window === self.window else { return false }
                    let point = self.convert(event.locationInWindow, from: nil)
                    return self.bounds.contains(point) && self.handler?(event, point) == true
                }
                return used ? nil : event
            }
        }
    }
}

private extension Bool {
    var digit: String { self ? "1" : "0" }
}

/// A 64-bit value in hex, grouped in fours.
private func hex(_ value: UInt64) -> String {
    let digits = String(value, radix: 16, uppercase: true)
    let padded = String(repeating: "0", count: 16 - digits.count) + digits
    return "0x" + stride(from: 0, to: 16, by: 4).map { String(padded.dropFirst($0).prefix(4)) }.joined(separator: "_")
}
