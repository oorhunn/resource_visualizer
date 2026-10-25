import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = Monitor()
    private let dashboardState = DashboardState()
    private var dashboard: NSWindow?
    private var notch: NotchController?
    private var notchItem: NSMenuItem?

    private var showsNotch: Bool {
        get { UserDefaults.standard.object(forKey: "showNotch") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showNotch") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            window.contentViewController = NSHostingController(rootView: DashboardView(monitor: monitor, state: dashboardState))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("Dashboard")
            dashboard = window
        }
        NSApp.activate()
        dashboard?.makeKeyAndOrderFront(nil)
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

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
