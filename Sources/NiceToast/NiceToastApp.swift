import SwiftUI
import Combine

@main
struct NiceToastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: StatusFileMonitor!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Create monitor
        monitor = StatusFileMonitor()

        // Subscribe to changes - use RunLoop.main for immediate updates even when app isn't focused
        Task { @MainActor in
            monitor.$instances
                .combineLatest(monitor.$focusedInstanceId, monitor.$spaceNumbers)
                .receive(on: RunLoop.main)
                .sink { [weak self] instances, focusedId, spaceNumbers in
                    self?.updateIcon(instances: instances, focusedId: focusedId, spaceNumbers: spaceNumbers)
                    self?.updateMenu(instances: instances, spaceNumbers: spaceNumbers)
                }
                .store(in: &cancellables)

            monitor.startMonitoring()
        }
    }

    private func updateIcon(instances: [ClaudeInstance], focusedId: String?, spaceNumbers: [String: Int]) {
        let image = createMenuBarImage(for: instances, focusedId: focusedId, spaceNumbers: spaceNumbers)
        statusItem.button?.image = image
    }

    private func updateMenu(instances: [ClaudeInstance], spaceNumbers: [String: Int]) {
        let menu = NSMenu()

        if instances.isEmpty {
            let item = NSMenuItem(title: "No Claude Code instances", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            // Sort by space number ascending
            let sorted = instances.sorted { a, b in
                let spaceA = spaceNumbers[a.id] ?? Int.max
                let spaceB = spaceNumbers[b.id] ?? Int.max
                return spaceA < spaceB
            }
            for instance in sorted {
                let spaceLabel = spaceNumbers[instance.id].map { "[\($0)] " } ?? ""
                let title = "\(statusIcon(instance.status)) \(spaceLabel)\(instance.displayPath)"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func statusIcon(_ status: ClaudeInstance.Status) -> String {
        switch status {
        case .working:
            return "🟠"
        case .waiting:
            return "🟡"
        case .idle:
            return "🟢"
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
