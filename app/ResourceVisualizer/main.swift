import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = Monitor()
    private let dashboardState = DashboardState()
    private var dashboard: NSWindow?
    private var dashboardFitted = false
    private var notch: NotchController?
    private var notchItem: NSMenuItem?
    private var dockGauge: DockGauge?

    private var showsNotch: Bool {
        get { UserDefaults.standard.object(forKey: "showNotch") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showNotch") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIcon.image()
        NSApp.mainMenu = makeMenu()
        monitor.start()
        notch = NotchController(monitor: monitor) { [weak self] in self?.showDashboard() }
        if showsNotch { notch?.show() }
        showDashboard()
    }

    // Closing the window keeps the notch running; quit from the menu or the notch.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showDashboard()
        return true
    }

    @objc func showDashboard() {
        if dashboard == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 820),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Resource Visualizer"
            window.contentViewController = NSHostingController(rootView: DashboardView(
                monitor: monitor, state: dashboardState
            ) { [weak self, weak window] height in
                guard let self, let window, !self.dashboardFitted else { return }
                self.dashboardFitted = true
                Self.fit(window, toContentHeight: height)
            })
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("Dashboard")
            dockGauge = DockGauge(window: window, monitor: monitor, metric: DockMetric.saved)
            dashboard = window
        }
        NSApp.activate()
        dashboard?.makeKeyAndOrderFront(nil)
    }

    /// Sizes the window so the content down to the chip shows without scrolling, keeping its top edge.
    private static func fit(_ window: NSWindow, toContentHeight height: CGFloat) {
        let current = window.frame
        let width = window.contentRect(forFrameRect: current).width
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height.rounded(.up)))
        frame.origin = NSPoint(x: current.minX, y: current.maxY - frame.height)
        if let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            frame.size.height = min(frame.height, visible.height)
            frame.origin.y = min(max(current.maxY - frame.height, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true)
    }

    @objc fileprivate func selectDockMetric(_ sender: NSMenuItem) {
        guard let metric = sender.representedObject as? String, let metric = DockMetric(rawValue: metric)
        else { return }
        DockMetric.saved = metric
        dockGauge?.metric = metric
    }

    /// One CPU/GPU item per metric; checked by `validateMenuItem` so the main and Dock menus agree.
    private func dockMetricMenuItems() -> [NSMenuItem] {
        DockMetric.allCases.map { metric in
            let item = NSMenuItem(title: metric.title, action: #selector(selectDockMetric(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = metric.rawValue
            return item
        }
    }

    private func dockMetricSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Minimized Icon Shows", action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: item.title)
        dockMetricMenuItems().forEach(item.submenu!.addItem)
        return item
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(dockMetricSubmenu())
        return menu
    }

    @objc private func toggleNotch() {
        showsNotch.toggle()
        showsNotch ? notch?.show() : notch?.hide()
        notchItem?.state = showsNotch ? .on : .off
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }

        let notchItem = item("Show in Notch", #selector(toggleNotch), "n", [.command, .shift])
        notchItem.target = self
        notchItem.state = showsNotch ? .on : .off
        self.notchItem = notchItem
        submenu("Resource Visualizer", [
            item("About Resource Visualizer",
                 #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            notchItem,
            dockMetricSubmenu(),
            .separator(),
            item("Hide Resource Visualizer", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
                 [.command, .option]),
            .separator(),
            item("Quit Resource Visualizer", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("Edit", [
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        let dashboardItem = item("Dashboard", #selector(showDashboard), "1")
        dashboardItem.target = self
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            .separator(),
            dashboardItem,
        ])
        return main
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectDockMetric(_:)) {
            menuItem.state = menuItem.representedObject as? String == DockMetric.saved.rawValue ? .on : .off
        }
        return true
    }
}

// `--export-icon <dir.iconset>` renders the app icon for scripts/bundle.sh.
if let flag = CommandLine.arguments.firstIndex(of: "--export-icon"),
   CommandLine.arguments.indices.contains(flag + 1) {
    try MainActor.assumeIsolated {
        try AppIcon.exportIconset(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
