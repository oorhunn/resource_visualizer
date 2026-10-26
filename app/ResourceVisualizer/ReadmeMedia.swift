#if README_MEDIA
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Records the README GIFs from live data, offscreen. Only compiled by scripts/readme-media.sh.
@MainActor
final class ReadmeMedia {
    private struct Scene {
        let name: String
        let view: NSView
        let width: Int // output width in pixels
        var frames: [CGImage] = []
    }

    private static let fps = 15.0
    private static let seconds = 10.0
    private static let warmUp = 15.0 // fills part of the history chart before recording

    private let directory: URL
    private let monitor = Monitor()
    private var scenes: [Scene] = []
    private var windows: [NSWindow] = []
    private var gauge: DockGauge?
    private var notchState: NotchState?
    private var load: [Process] = []
    private var frame = 0

    init(directory: URL) { self.directory = directory }

    func run() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        monitor.interval = 0.5
        monitor.start()

        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
        let notch = NotchState(geometry: NotchGeometry(screen: screen))
        notchState = notch
        let notchHeight = NotchGeometry.expandedSize.height + notch.geometry.height
        add("notch", width: 760, size: CGSize(width: 760, height: notchHeight + 40), NotchScene(
            monitor: monitor, state: notch, height: notchHeight
        ))
        add("dashboard", width: 960, size: CGSize(width: 960, height: 820), DashboardView(
            monitor: monitor, state: DashboardState()
        ).background(Color(nsColor: .windowBackgroundColor)))
        add("chip", width: 720, size: CGSize(width: 720, height: 340), LiveChip(monitor: monitor)
            .padding(20).background(.black).environment(\.colorScheme, .dark))
        add("core-zoom", width: 720, size: CGSize(width: 720, height: 420), LiveZoom(monitor: monitor)
            .padding(20).background(.black).environment(\.colorScheme, .dark))

        // The Dock tile: a real DockGauge on an offscreen window, "minimized" by notification.
        let tileWindow = offscreenWindow(size: CGSize(width: 10, height: 10))
        let gauge = DockGauge(window: tileWindow, monitor: monitor, metric: .cpu)
        self.gauge = gauge
        if let tile = tileWindow.dockTile.contentView {
            tile.frame = NSRect(x: 0, y: 0, width: 256, height: 256)
            scenes.append(Scene(name: "dock", view: tile, width: 256))
        }

        // Let samples accumulate, then start recording.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.warmUp) { [self] in
            NotificationCenter.default.post(name: NSWindow.willMiniaturizeNotification, object: tileWindow)
            let timer = Timer(timeInterval: 1 / Self.fps, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated { self?.tick(timer) }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func add(_ name: String, width: Int, size: CGSize, _ view: some View) {
        let window = offscreenWindow(size: size)
        let hosting = NSHostingView(rootView: view
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(.black))
        hosting.sizingOptions = [] // keep the window at the scene size
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        scenes.append(Scene(name: name, view: hosting, width: width))
    }

    /// Borderless window far off any screen, ordered in so animations and timelines keep running.
    private func offscreenWindow(size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20000 - 2000 * CGFloat(windows.count), y: -20000,
                                                  width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    private func tick(_ timer: Timer) {
        let t = Double(frame) / Self.fps
        frame += 1
        // Script: busy-loop some cores in the middle, open the notch, switch the tile to GPU.
        if frame == Int(1.5 * Self.fps) { startLoad() }
        if frame == Int(5.5 * Self.fps) { stopLoad() }
        if frame == Int(1 * Self.fps) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { notchState?.expanded = true }
        }
        if frame == Int(8 * Self.fps) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { notchState?.expanded = false }
        }
        if frame == Int(6 * Self.fps) { gauge?.metric = .gpu }
        // Zoom in: the Execute stage, then a full adder, then one of its NAND gates.
        let clicks: [(Double, CGPoint)] = [(2.5, CGPoint(x: 360, y: 150)), (5, CGPoint(x: 438, y: 190)),
                                           (7.5, CGPoint(x: 360, y: 200))]
        for (time, point) in clicks where frame == Int(time * Self.fps) { click("core-zoom", at: point) }

        for i in scenes.indices {
            if let image = snapshot(scenes[i].view, width: scenes[i].width) { scenes[i].frames.append(image) }
        }
        guard t >= Self.seconds else { return }
        timer.invalidate()
        stopLoad()
        for scene in scenes { write(scene) }
        exit(0)
    }

    /// Clicks a point given from the scene's top-left corner.
    private func click(_ name: String, at topLeft: CGPoint) {
        guard let view = scenes.first(where: { $0.name == name })?.view, let window = view.window else { return }
        let point = NSPoint(x: topLeft.x, y: view.bounds.height - topLeft.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
    }

    private func startLoad() {
        for _ in 0..<max(ProcessInfo.processInfo.activeProcessorCount / 2, 1) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
            process.standardOutput = FileHandle.nullDevice
            try? process.run()
            load.append(process)
        }
    }

    private func stopLoad() {
        load.forEach { $0.terminate() }
        load.removeAll()
    }

    private func snapshot(_ view: NSView, width: Int) -> CGImage? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return nil }
        // Downscale to the output width.
        let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func write(_ scene: Scene) {
        let url = directory.appendingPathComponent("\(scene.name).gif")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, scene.frames.count, nil
        ) else { return }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / Self.fps]]
        for image in scene.frames { CGImageDestinationAddImage(destination, image, frame as CFDictionary) }
        CGImageDestinationFinalize(destination)
        print("Wrote \(url.path) (\(scene.frames.count) frames)")
    }
}

/// The notch hanging from a strip of menu bar over a wallpaper gradient.
private struct NotchScene: View {
    let monitor: Monitor
    let state: NotchState
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.25, green: 0.35, blue: 0.6),
                                    Color(red: 0.55, green: 0.35, blue: 0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(.black.opacity(0.25)).frame(height: state.geometry.height)
            NotchView(monitor: monitor, state: state, openDashboard: {})
                .frame(width: NotchGeometry.expandedSize.width, height: height)
        }
    }
}

private struct LiveChip: View {
    let monitor: Monitor

    var body: some View {
        ChipView(cores: monitor.cores, gpu: monitor.gpus.first, memory: monitor.memory)
    }
}

private struct LiveZoom: View {
    let monitor: Monitor

    var body: some View {
        if let core = monitor.cores.first(where: { $0.type == "P" }) ?? monitor.cores.first {
            CoreZoomView(core: core) {}
        }
    }
}
#endif
