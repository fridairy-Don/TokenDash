import SwiftUI
import AppKit

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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    var store: DataStore!

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
        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "gauge.with.dots.needle.67percent",
                accessibilityDescription: "TokenDash"
            )
            image?.isTemplate = true
            button.image = image
            button.action = #selector(handleClick(_:))
            button.target = self
            // Receive both left- and right-click events so we can route them.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
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
            Task { await store.refreshAll() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit TokenDash", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        // Temporarily attach the menu to the status item and perform a click so
        // AppKit positions it correctly under the menu-bar icon. We reset menu
        // right after so normal left-click keeps toggling the popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettingsFromMenu() {
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            Task { await store.refreshAll() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
        NotificationCenter.default.post(name: .tdOpenSettings, object: nil)
    }
}

extension Notification.Name {
    static let tdOpenSettings = Notification.Name("TDOpenSettings")
}
