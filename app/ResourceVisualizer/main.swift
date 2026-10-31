import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = Monitor()
    private let dashboardState = DashboardState()
    private var dashboard: NSWindow?
    private var dashboardFitted = false
    private var dashboardObservers: [NSObjectProtocol] = []
    private var notch: NotchController?
    private var notchItem: NSMenuItem?
    private lazy var dockGauge = DockGauge(monitor: monitor, metric: DockMetric.saved,
                                           enabled: DockGauge.savedEnabled, inDock: wantsDockIcon)

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
        updateDockIcon()
    }

    /// The Dock icon shows while the dashboard is open, or always when the notch is off, so the
    /// app can still be reached.
    var wantsDockIcon: Bool { dashboard != nil || !showsNotch }

    private func updateDockIcon() {
        let policy: NSApplication.ActivationPolicy = wantsDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
        dockGauge.inDock = wantsDockIcon
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
            let center = NotificationCenter.default
            dashboardObservers = [
                center.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                   queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.dashboardWillClose() }
                },
                // Hidden, the dashboard pauses its animations.
                center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                   object: window, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let window else { return }
                        self?.dashboardState.visible = window.occlusionState.contains(.visible)
                    }
                },
            ]
            dashboard = window
            dockGauge.window = window
            updateDockIcon()
        }
        NSApp.activate()
        dashboard?.makeKeyAndOrderFront(nil)
    }

    /// Drops the window and its views so a closed dashboard costs nothing; it is rebuilt on open.
    private func dashboardWillClose() {
        guard let window = dashboard else { return }
        dashboardObservers.forEach(NotificationCenter.default.removeObserver)
        dashboardObservers = []
        dashboardState.visible = true
        dashboard = nil
        dockGauge.window = nil
        updateDockIcon()
        // Let the close finish before tearing down the content it is animating.
        DispatchQueue.main.async { window.contentViewController = nil }
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
        dockGauge.metric = metric
    }

    @objc fileprivate func toggleLiveDockIcon() {
        DockGauge.savedEnabled.toggle()
        dockGauge.isEnabled = DockGauge.savedEnabled
    }

    /// Checked by `validateMenuItem`, like the metric items.
    private func liveDockIconItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Live Dock Icon", action: #selector(toggleLiveDockIcon),
                              keyEquivalent: "")
        item.target = self
        return item
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
        let item = NSMenuItem(title: "Dock Icon Shows", action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: item.title)
        dockMetricMenuItems().forEach(item.submenu!.addItem)
        return item
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(liveDockIconItem())
        menu.addItem(dockMetricSubmenu())
        return menu
    }

    @objc private func toggleNotch() {
        showsNotch.toggle()
        showsNotch ? notch?.show() : notch?.hide()
        notchItem?.state = showsNotch ? .on : .off
        updateDockIcon()
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
            liveDockIconItem(),
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
        } else if menuItem.action == #selector(toggleLiveDockIcon) {
            menuItem.state = DockGauge.savedEnabled ? .on : .off
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

#if README_MEDIA
// `--readme-media <dir>` records the README GIFs; see scripts/readme-media.sh.
if let flag = CommandLine.arguments.firstIndex(of: "--readme-media"),
   CommandLine.arguments.indices.contains(flag + 1) {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let media = ReadmeMedia(directory: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        media.run()
        app.run()
    }
}
#endif

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Set before launch so a hidden Dock icon never flashes up.
    app.setActivationPolicy(delegate.wantsDockIcon ? .regular : .accessory)
    app.run()
}
