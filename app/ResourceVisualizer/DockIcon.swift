import AppKit

/// Which figure the minimized window's Dock tile animates.
enum DockMetric: String, CaseIterable {
    case cpu, gpu

    var title: String { rawValue.uppercased() }

    static var saved: DockMetric {
        get { UserDefaults.standard.string(forKey: "dockMetric").flatMap(DockMetric.init) ?? .cpu }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "dockMetric") }
    }

    func value(of point: HistoryPoint) -> Double? {
        switch self {
        case .cpu: point.cpu
        case .gpu: point.gpu
        }
    }
}

/// Shared drawing for the app icon and the live Dock tile.
enum IconArt {
    /// Rounded-square body inset to the macOS icon grid (824 of 1024 points).
    static func body(in rect: NSRect) -> NSBezierPath {
        let inset = rect.width * 100 / 1024
        let body = rect.insetBy(dx: inset, dy: inset)
        return NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    }

    static func drawBackground(in rect: NSRect) {
        let body = body(in: rect)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = rect.width * 0.02
        shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.01)
        shadow.set()
        NSColor.black.setFill()
        body.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.26, alpha: 1),
                   ending: NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1))?
            .draw(in: body, angle: -90)
        NSColor.white.withAlphaComponent(0.12).setStroke()
        body.lineWidth = max(rect.width * 0.004, 0.5)
        body.stroke()
    }

    /// Same thresholds as `Color.level`.
    static func level(_ percent: Double?) -> NSColor {
        guard let percent else { return .systemGray }
        return percent < 50 ? .systemGreen : percent < 80 ? .systemYellow : .systemRed
    }
}

/// The static app icon: a chip with pins and a small load chart on its die.
enum AppIcon {
    static func image(size: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
    }

    static func draw(in rect: NSRect) {
        IconArt.drawBackground(in: rect)
        let s = rect.width
        let chip = NSRect(x: rect.midX - s * 0.2, y: rect.midY - s * 0.2, width: s * 0.4, height: s * 0.4)

        // Pins: five on each side.
        NSColor(calibratedWhite: 0.75, alpha: 1).setFill()
        let pinLength = s * 0.06, pinWidth = s * 0.03
        for i in 0..<5 {
            let offset = chip.minX + chip.width * (CGFloat(i) + 0.5) / 5 - pinWidth / 2
            let along = chip.minY + chip.height * (CGFloat(i) + 0.5) / 5 - pinWidth / 2
            for pin in [NSRect(x: offset, y: chip.maxY, width: pinWidth, height: pinLength),
                        NSRect(x: offset, y: chip.minY - pinLength, width: pinWidth, height: pinLength),
                        NSRect(x: chip.minX - pinLength, y: along, width: pinLength, height: pinWidth),
                        NSRect(x: chip.maxX, y: along, width: pinLength, height: pinWidth)] {
                NSBezierPath(roundedRect: pin, xRadius: pinWidth / 3, yRadius: pinWidth / 3).fill()
            }
        }

        let package = NSBezierPath(roundedRect: chip, xRadius: s * 0.04, yRadius: s * 0.04)
        NSGradient(starting: NSColor(calibratedWhite: 0.32, alpha: 1),
                   ending: NSColor(calibratedWhite: 0.16, alpha: 1))?.draw(in: package, angle: -90)
        NSColor.white.withAlphaComponent(0.25).setStroke()
        package.lineWidth = s * 0.006
        package.stroke()

        // Load bars on the die, coloured like the rest of the app.
        let die = chip.insetBy(dx: s * 0.055, dy: s * 0.055)
        let loads: [Double] = [35, 62, 88, 48]
        let gap = die.width * 0.08
        let barWidth = (die.width - gap * CGFloat(loads.count - 1)) / CGFloat(loads.count)
        for (i, load) in loads.enumerated() {
            let bar = NSRect(x: die.minX + CGFloat(i) * (barWidth + gap), y: die.minY,
                             width: barWidth, height: die.height * load / 100)
            IconArt.level(load).setFill()
            NSBezierPath(roundedRect: bar, xRadius: barWidth * 0.2, yRadius: barWidth * 0.2).fill()
        }
    }

    /// Writes the PNGs `iconutil` expects into an `.iconset` directory.
    static func exportIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0
                ) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
                NSGraphicsContext.restoreGraphicsState()
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try rep.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent(name))
            }
        }
    }
}

/// Live gauge drawn into a minimized window's Dock tile: a ring that eases toward the current
/// value over a scrolling history sparkline.
final class DockGaugeView: NSView {
    var metric = DockMetric.cpu
    var displayed: Double = 0           // eased value the ring shows
    var current: Double?                // latest sample, nil when not reported
    var history: [Double] = []          // oldest first
    var scroll: CGFloat = 1             // 0…1 progress of the newest point sliding in

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        let s = rect.width
        IconArt.drawBackground(in: rect)
        let body = IconArt.body(in: rect)
        let color = IconArt.level(current.map { _ in displayed })

        // Sparkline along the bottom, clipped to the icon body.
        if history.count > 1 {
            NSGraphicsContext.saveGraphicsState()
            body.addClip()
            let area = body.bounds
            let height = area.height * 0.34
            let step = area.width / CGFloat(DockGauge.sparklinePoints - 2)
            let line = NSBezierPath()
            for (i, value) in history.enumerated() {
                let x = area.maxX + (1 - scroll) * step - CGFloat(history.count - 1 - i) * step
                let point = NSPoint(x: x, y: area.minY + height * min(max(value, 0), 100) / 100)
                i == 0 ? line.move(to: point) : line.line(to: point)
            }
            let fill = line.copy() as! NSBezierPath
            fill.line(to: NSPoint(x: fill.currentPoint.x, y: area.minY))
            fill.line(to: NSPoint(x: area.maxX + step - CGFloat(history.count - 1) * step - scroll * step,
                                  y: area.minY))
            fill.close()
            NSGradient(starting: color.withAlphaComponent(0.45), ending: color.withAlphaComponent(0.02))?
                .draw(in: fill, angle: -90)
            color.withAlphaComponent(0.9).setStroke()
            line.lineWidth = s * 0.018
            line.lineJoinStyle = .round
            line.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Ring: a 270° track opening at the bottom, filled clockwise from the lower left.
        let center = NSPoint(x: rect.midX, y: rect.midY + s * 0.05)
        let radius = s * 0.27
        let start: CGFloat = 225, sweep: CGFloat = 270
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start - sweep,
                        clockwise: true)
        track.lineWidth = s * 0.065
        track.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.14).setStroke()
        track.stroke()
        if current != nil, displayed > 0.5 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: start,
                          endAngle: start - sweep * CGFloat(min(displayed, 100) / 100), clockwise: true)
            arc.lineWidth = track.lineWidth
            arc.lineCapStyle = .round
            color.setStroke()
            arc.stroke()
        }

        let value = current == nil ? "–" : String(format: "%.0f%%", displayed)
        draw(value, size: s * 0.15, weight: .bold, color: .white, centeredAt: center)
        draw(metric.title, size: s * 0.075, weight: .semibold, color: .white.withAlphaComponent(0.65),
             centeredAt: NSPoint(x: center.x, y: center.y - radius * 0.62))
    }

    private func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
                      centeredAt point: NSPoint) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = string.size()
        string.draw(at: NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
    }
}

/// Animates a window's Dock tile while it is minimized; the app icon stays static.
@MainActor
final class DockGauge {
    static let sparklinePoints = 24
    private static let frameRate = 30.0

    var metric: DockMetric {
        didSet {
            view.metric = metric
            refresh()
        }
    }

    private let window: NSWindow
    private let monitor: Monitor
    private let view = DockGaugeView()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastPointID: Int?
    private var pointArrived = Date.distantPast

    init(window: NSWindow, monitor: Monitor, metric: DockMetric) {
        self.window = window
        self.monitor = monitor
        self.metric = metric
        view.metric = metric
        window.dockTile.contentView = view
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.willMiniaturizeNotification, object: window,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.start() }
            },
            center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            },
        ]
    }

    private func start() {
        // Jump straight to the current value so the tile is right the moment it lands in the Dock.
        refresh()
        view.displayed = view.current ?? 0
        view.scroll = 1
        window.dockTile.display()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / Self.frameRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let points = monitor.history.suffix(Self.sparklinePoints)
        view.history = points.map { metric.value(of: $0) ?? 0 }
        view.current = points.last.flatMap(metric.value)
        if points.last?.id != lastPointID {
            lastPointID = points.last?.id
            pointArrived = Date()
        }
    }

    private func tick() {
        refresh()
        // Ease toward the latest value and slide the sparkline over one sampling interval.
        let target = view.current ?? 0
        let before = (view.displayed, view.scroll)
        view.displayed += (target - view.displayed) * (1 - exp(-6 / Self.frameRate))
        if abs(target - view.displayed) < 0.05 { view.displayed = target }
        view.scroll = CGFloat(min(Date().timeIntervalSince(pointArrived) / max(monitor.interval, 0.1), 1))
        // Redraw only while something is moving.
        if before != (view.displayed, view.scroll) { window.dockTile.display() }
    }
}
