import AppKit
import Observation
import SwiftUI

/// Where the notch is on a screen, in AppKit screen coordinates (origin bottom-left).
struct NotchGeometry: Equatable {
    static let wingWidth: CGFloat = 76
    static let expandedSize = CGSize(width: 720, height: 200)

    let screenFrame: NSRect
    let notchWidth: CGFloat // 0 on screens without a notch
    let height: CGFloat     // notch or menu bar height

    init(screen: NSScreen) {
        screenFrame = screen.frame
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
            height = screen.safeAreaInsets.top
        } else {
            // No notch: sit in the middle of the menu bar as a small pill.
            notchWidth = 0
            height = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        }
    }

    var collapsedSize: CGSize { CGSize(width: notchWidth + 2 * Self.wingWidth, height: height) }

    /// Rectangle of the given size hanging from the top centre of the screen.
    func rect(_ size: CGSize) -> NSRect {
        NSRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height,
               width: size.width, height: size.height)
    }
}

@MainActor @Observable
final class NotchState {
    var expanded = false
    var geometry: NotchGeometry

    init(geometry: NotchGeometry) { self.geometry = geometry }
}

/// Borderless panel that floats over the menu bar around the notch and expands on hover.
///
/// Hover is detected with tracking areas rather than a system-wide mouse-move monitor, so the
/// app only hears about the pointer when it crosses the notch or the expanded panel.
@MainActor
final class NotchController {
    private let panel: NSPanel
    /// Catches the pointer over the collapsed notch while `panel` lets clicks through.
    private let trigger: NSPanel
    private let state: NotchState
    private let triggerTracker = HoverTracker()
    private let panelTracker = HoverTracker()
    private var screenObserver: NSObjectProtocol?
    private var collapseWork: DispatchWorkItem?

    init(monitor: Monitor, openDashboard: @escaping () -> Void) {
        state = NotchState(geometry: NotchGeometry(screen: Self.preferredScreen()))
        panel = Self.makePanel(level: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: NotchView(monitor: monitor, state: state,
                                                        openDashboard: openDashboard))
        hosting.sizingOptions = []
        panel.contentView = hosting

        // Sits just under the panel, which draws the notch over it. A fully transparent window
        // would let the pointer through, so it gets an invisible sliver of alpha.
        trigger = Self.makePanel(level: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        let catcher = NSView()
        catcher.wantsLayer = true
        catcher.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor
        trigger.contentView = catcher

        triggerTracker.onEnter = { [weak self] in self?.setExpanded(true) }
        triggerTracker.attach(to: catcher)
        panelTracker.onEnter = { [weak self] in self?.cancelCollapse() }
        panelTracker.onExit = { [weak self] in self?.scheduleCollapse() }
        layout()
    }

    private static func makePanel(level: Int) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .init(level)
        // Not .fullScreenAuxiliary, so it stays out of the way of full-screen apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovable = false
        return panel
    }

    func show() {
        trigger.orderFrontRegardless()
        panel.orderFrontRegardless()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    func hide() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        setExpanded(false)
        panel.orderOut(nil)
        trigger.orderOut(nil)
    }

    /// Prefer the built-in display, which is the one with the notch.
    private static func preferredScreen() -> NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func layout() {
        state.geometry = NotchGeometry(screen: Self.preferredScreen())
        // The window always has the expanded size; the transparent part ignores clicks while collapsed.
        let size = CGSize(width: NotchGeometry.expandedSize.width,
                          height: NotchGeometry.expandedSize.height + state.geometry.height)
        panel.setFrame(state.geometry.rect(size), display: true)
        trigger.setFrame(state.geometry.rect(state.geometry.collapsedSize), display: false)
    }

    private func scheduleCollapse() {
        guard state.expanded, collapseWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.setExpanded(false) }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func cancelCollapse() {
        collapseWork?.cancel()
        collapseWork = nil
    }

    private func setExpanded(_ expanded: Bool) {
        cancelCollapse()
        guard state.expanded != expanded else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { state.expanded = expanded }
        panel.ignoresMouseEvents = !expanded
        if expanded, let view = panel.contentView {
            // The pointer is already over the panel, so only its exit is reported.
            panelTracker.attach(to: view, assumeInside: true)
        } else {
            panelTracker.detach()
        }
    }
}

/// Owns one tracking area that reports the pointer entering and leaving a view.
@MainActor
private final class HoverTracker: NSResponder {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var area: NSTrackingArea?
    private weak var view: NSView?

    func attach(to view: NSView, assumeInside: Bool = false) {
        detach()
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        if assumeInside { options.insert(.assumeInside) }
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        view.addTrackingArea(area)
        self.area = area
        self.view = view
    }

    func detach() {
        if let area { view?.removeTrackingArea(area) }
        area = nil
        view = nil
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

struct NotchView: View {
    let monitor: Monitor
    let state: NotchState
    let openDashboard: () -> Void

    var body: some View {
        let geometry = state.geometry
        let size = state.expanded
            ? CGSize(width: NotchGeometry.expandedSize.width,
                     height: NotchGeometry.expandedSize.height + geometry.height)
            : geometry.collapsedSize
        let radius: CGFloat = state.expanded ? 24 : 10
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)
                    .fill(.black)
                VStack(spacing: 0) {
                    wings.frame(height: geometry.height)
                    if state.expanded {
                        NotchPanel(monitor: monitor, openDashboard: openDashboard)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 16)
                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    /// CPU on the left of the notch, memory on the right.
    private var wings: some View {
        HStack(spacing: 0) {
            WingLabel(symbol: "cpu", value: monitor.cpuAverage)
                .frame(width: NotchGeometry.wingWidth)
            Spacer(minLength: state.geometry.notchWidth)
            WingLabel(symbol: "memorychip", value: monitor.memory.total == 0 ? nil
                : monitor.memory.usedPercent)
                .frame(width: NotchGeometry.wingWidth)
        }
        .padding(.horizontal, state.expanded ? 12 : 0)
    }
}

private struct WingLabel: View {
    let symbol: String
    let value: Double?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.level(value))
            Text(Format.percent(value))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }
}

/// Compact dashboard shown when the notch is expanded.
private struct NotchPanel: View {
    let monitor: Monitor
    let openDashboard: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ChipView(cores: monitor.cores, gpu: monitor.gpus.first, memory: monitor.memory,
                     labeled: false)
                .frame(width: 210)
                // No hover highlight or tooltip here, so pointer moves don't redraw the chip.
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        stat("CPU", Format.percent(monitor.cpuAverage), monitor.cpuAverage)
                        Meter(monitor.cpuAverage.map { $0 / 100 }, color: .level(monitor.cpuAverage))
                        Text("\(monitor.cores.count) cores").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(width: 80)
                    VStack(alignment: .leading, spacing: 6) {
                        stat("Memory", Format.percent(monitor.memory.usedPercent),
                             monitor.memory.usedPercent)
                        Meter(monitor.memory.usedPercent / 100,
                              color: .level(monitor.memory.usedPercent))
                        Text("\(Format.bytes(monitor.memory.used)) of \(Format.bytes(monitor.memory.total))")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(width: 130)
                    VStack(alignment: .leading, spacing: 6) {
                        stat("GPU", Format.percent(monitor.gpuUtilization), monitor.gpuUtilization)
                        Meter(monitor.gpuUtilization.map { $0 / 100 },
                              color: .level(monitor.gpuUtilization))
                    }
                    .frame(width: 80)
                    VStack(alignment: .leading, spacing: 6) {
                        stat("Disk", Format.percent(monitor.disk.usedPercent),
                             monitor.disk.usedPercent)
                        Meter(monitor.disk.usedPercent.map { $0 / 100 },
                              color: .level(monitor.disk.usedPercent))
                        Text(monitor.disk.total == 0 ? "–"
                             : "\(Format.bytes(monitor.disk.total - monitor.disk.used)) free")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(width: 80)
                }
                Divider().overlay(.white.opacity(0.2))
                VStack(spacing: 4) {
                    ForEach(topProcesses) { process in
                        HStack {
                            Text(process.name).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.1f%%", process.cpu ?? 0))
                                .foregroundStyle(Color.level(process.cpu))
                                .frame(width: 60, alignment: .trailing)
                            Text(Format.bytes(process.memory)).foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)
                        }
                        .font(.system(size: 11)).monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Button("Open Dashboard", action: openDashboard)
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    private var topProcesses: [ProcessSample] {
        Array(monitor.processes.filter { $0.cpu != nil }
            .sorted { ($0.cpu ?? 0) > ($1.cpu ?? 0) }.prefix(4))
    }

    private func stat(_ title: String, _ value: String, _ percent: Double?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.level(percent)).monospacedDigit()
        }
    }
}
