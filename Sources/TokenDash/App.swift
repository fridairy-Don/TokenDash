import SwiftUI
import AppKit
import Combine
import ServiceManagement

@main
struct TokenDashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Settings UI lives entirely inside the WebView popover now; the SwiftUI
    // Settings scene is kept empty just to satisfy the App protocol.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var standaloneWindow: NSWindow?
    var store: DataStore!
    private var cancellables: Set<AnyCancellable> = []
    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        store = DataStore()
        store.startAutoRefresh(interval: 30)

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 420, height: 640)
        let root = DashboardWebView()
            .environmentObject(store)
        popover.contentViewController = NSHostingController(rootView: root)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButton()

        // React to snapshot changes to repaint the status icon (warn/danger dot).
        store.$snapshots
            .receive(on: RunLoop.main)
            .sink { [weak self] snaps in
                self?.updateStatusIcon(for: snaps)
            }
            .store(in: &cancellables)

        installHotkey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = globalHotkeyMonitor { NSEvent.removeMonitor(m) }
        if let m = localHotkeyMonitor  { NSEvent.removeMonitor(m) }
    }

    // MARK: - Status item

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.image = StatusBarIcon.templateImage(state: .ok)
        button.action = #selector(handleClick(_:))
        button.target = self
        // Receive both left- and right-click events so we can route them.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func updateStatusIcon(for snapshots: [ProviderSnapshot]) {
        guard let button = statusItem.button else { return }
        let state = StatusBarState.aggregate(from: snapshots)
        button.image = StatusBarIcon.badgedImage(state: state)
    }

    @objc private func handleClick(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Show instantly from cached data; kick a refresh in the background.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { await store.refreshAll() }
        }
    }

    // MARK: - Context menu

    private func showContextMenu() {
        let menu = NSMenu()

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let settings = NSMenuItem(title: "Settings", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let window = NSMenuItem(title: "Open Dashboard in Window", action: #selector(openStandaloneWindow), keyEquivalent: "o")
        window.target = self
        menu.addItem(window)

        menu.addItem(.separator())

        let launch = NSMenuItem(title: LoginLauncher.isEnabled ? "Disable Launch at Login" : "Launch at Login",
                                action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.state = LoginLauncher.isEnabled ? .on : .off
        launch.target = self
        menu.addItem(launch)

        let hotkey = NSMenuItem(title: "Shortcut: ⌥⌘T", action: nil, keyEquivalent: "")
        hotkey.isEnabled = false
        menu.addItem(hotkey)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About TokenDash", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit TokenDash", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        // Temporarily attach the menu to the status item and perform a click so
        // AppKit positions it correctly under the menu-bar icon. We reset menu
        // right after so normal left-click keeps toggling the popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() {
        Task { await store.refreshAll() }
    }

    @objc private func openSettingsFromMenu() {
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { await store.refreshAll() }
        }
        NotificationCenter.default.post(name: .tdOpenSettings, object: nil)
    }

    @objc private func toggleLaunchAtLogin() {
        LoginLauncher.toggle()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: "A quiet menu-bar dashboard for your AI API usage.",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                         .font: NSFont.systemFont(ofSize: 11)]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "TokenDash",
            .applicationVersion: "0.3",
            .version: "M3",
            .credits: credits,
        ])
    }

    @objc private func openStandaloneWindow() {
        if popover.isShown { popover.performClose(nil) }

        // Accessory-policy apps can't bring windows to front with just activate().
        // Temporarily switch to .regular so the window receives focus, then
        // restore when it closes.
        NSApp.setActivationPolicy(.regular)

        if let win = standaloneWindow {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }

        let root = DashboardWebView().environmentObject(store)
        let hosting = NSHostingController(rootView: root)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.title = "TokenDash"
        win.contentViewController = hosting
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self          // watch for close to restore .accessory
        standaloneWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        // Restore accessory policy when the standalone window is closed so the
        // Dock icon and app switcher entry disappear again.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Global hotkey (⌥⌘T)

    private func installHotkey() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.type == .keyDown else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let wanted: NSEvent.ModifierFlags = [.command, .option]
            guard flags == wanted else { return }
            // keyCode 17 = T
            guard event.keyCode == 17 else { return }
            DispatchQueue.main.async { self?.togglePopover(nil) }
        }
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { e in handler(e) }
        localHotkeyMonitor  = NSEvent.addLocalMonitorForEvents(matching: .keyDown)  { e in handler(e); return e }
    }
}

extension Notification.Name {
    static let tdOpenSettings = Notification.Name("TDOpenSettings")
}

// MARK: - LoginLauncher
//
// macOS 13+ SMAppService wrapper. If unavailable (older OS), falls back to no-op.
@MainActor
enum LoginLauncher {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    static func toggle() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't update Launch at Login"
            alert.informativeText = "\(error.localizedDescription)"
            alert.runModal()
        }
    }
}
