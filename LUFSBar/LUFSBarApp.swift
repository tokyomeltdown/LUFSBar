import SwiftUI
import AppKit
import Combine

// SwiftUI MenuBarExtra recalculates the NSStatusItem width from the title
// string, so every time the number of digits changed AppKit quietly relaid
// out and the menu bar item shifted slightly left and right.
// Creating the NSStatusItem directly with a fixed width, and updating the
// title inside a CATransaction with animations disabled, stops that entirely.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellable: AnyCancellable?
    private var compactModeCancellable: AnyCancellable?
    private var settingsWindow: NSWindow?

    private static let statusItemWidth: CGFloat = 96
    // Compact mode only shows five characters ("-14.6"), so it can be much narrower.
    private static let compactStatusItemWidth: CGFloat = 56

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier {
            let runningInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if runningInstances.count > 1 {
                NSApp.terminate(nil)
                return
            }
        }

        LaunchAtLogin.enableByDefaultOnFirstLaunch()

        // When the postinstall script auto-launches the app through launchctl asuser,
        // that first session still carries the installer context. Creating the tap
        // there was observed on a real machine to put tccd into a suppressed state
        // without ever showing the permission prompt.
        // So on the first run the tap is not created; the user own click starts it.
        let isFirstLaunch = !UserDefaults.standard.bool(forKey: MeterState.hasCompletedFirstLaunchKey)
        if isFirstLaunch {
            MeterState.shared.markNeedsManualStart()
        } else {
            SystemAudioTap.shared.start()
        }
        MeterState.shared.startPolling()

        let initialWidth = MeterState.shared.compactMenuBar ? Self.compactStatusItemWidth : Self.statusItemWidth
        let item = NSStatusBar.system.statusItem(withLength: initialWidth)
        if let button = item.button {
            button.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.alignment = .right
            button.title = MeterState.shared.menuBarText
            button.action = #selector(handleStatusItemClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        let pop = NSPopover()
        pop.contentSize = NSSize(width: 260, height: 410)
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: PopoverContentView(
            onOpenSettings: { [weak self] in self?.showSettings() },
            onQuit: { NSApp.terminate(nil) }
        ))
        popover = pop

        cancellable = MeterState.shared.$menuBarText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let button = self?.statusItem?.button else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                button.title = text
                CATransaction.commit()
            }

        compactModeCancellable = MeterState.shared.$compactMenuBar
            .receive(on: DispatchQueue.main)
            .sink { [weak self] compact in
                self?.statusItem?.length = compact ? Self.compactStatusItemWidth : Self.statusItemWidth
            }

        if isFirstLaunch, let button = item.button {
            NSApp.activate(ignoringOtherApps: true)
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            pop.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMetricMenu(from: sender)
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: AnyObject) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMetricMenu(from button: NSStatusBarButton) {
        let options: [(MenuBarMetric, String)] = [
            (.momentary, "Momentary"),
            (.shortTerm, "Short-term"),
            (.integrated, "Integrated")
        ]
        let menu = NSMenu()
        for (metric, title) in options {
            let item = NSMenuItem(title: title, action: #selector(selectMetric(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = metric
            item.state = (MeterState.shared.menuBarMetric == metric) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let compactItem = NSMenuItem(
            title: "Compact menu bar display", action: #selector(toggleCompactMenuBar(_:)), keyEquivalent: ""
        )
        compactItem.target = self
        compactItem.state = MeterState.shared.compactMenuBar ? .on : .off
        menu.addItem(compactItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func selectMetric(_ sender: NSMenuItem) {
        guard let metric = sender.representedObject as? MenuBarMetric else { return }
        MeterState.shared.menuBarMetric = metric
    }

    @objc private func toggleCompactMenuBar(_ sender: NSMenuItem) {
        MeterState.shared.compactMenuBar.toggle()
    }

    func showSettings() {
        popover?.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 160),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "LUFSBar Settings"
            window.contentViewController = NSHostingController(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MeterState.shared.stopPolling()
        SystemAudioTap.shared.stop()
    }
}

@main
struct LUFSBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
