import SwiftUI
import Combine

@main
struct NiceSemaphoreApp: App {
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
                .combineLatest(monitor.$focusedInstanceId, monitor.$spaceNumbers, monitor.$focusedSinceIdle)
                .receive(on: RunLoop.main)
                .sink { [weak self] instances, focusedId, spaceNumbers, focusedSinceIdle in
                    self?.updateIcon(instances: instances, focusedId: focusedId, spaceNumbers: spaceNumbers, focusedSinceIdle: focusedSinceIdle)
                    self?.updateMenu(instances: instances, focusedId: focusedId, spaceNumbers: spaceNumbers, focusedSinceIdle: focusedSinceIdle)
                }
                .store(in: &cancellables)

            monitor.startMonitoring()
        }
    }

    private func updateIcon(instances: [ClaudeInstance], focusedId: String?, spaceNumbers: [String: Int], focusedSinceIdle: Set<String>) {
        let image = createMenuBarImage(for: instances, focusedId: focusedId, spaceNumbers: spaceNumbers, focusedSinceIdle: focusedSinceIdle)
        statusItem.button?.image = image
    }

    private func updateMenu(instances: [ClaudeInstance], focusedId: String?, spaceNumbers: [String: Int], focusedSinceIdle: Set<String>) {
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
                let title = "\(spaceLabel)\(instance.displayPath)"
                let item = NSMenuItem(title: title, action: #selector(activateInstance(_:)), keyEquivalent: "")
                let unseen = instance.status == .idle && !focusedSinceIdle.contains(instance.id) && instance.id != focusedId
                let iconColor = unseen ? pastelYellow : nsColorForStatus(instance.status)
                item.image = createMenuItemIcon(
                    color: iconColor,
                    isFocused: instance.id == focusedId
                )
                // Clicking jumps to the terminal session; only possible if we know its TTY
                if let tty = instance.tty, !tty.isEmpty {
                    item.target = self
                    item.representedObject = tty
                    item.toolTip = "Switch to this session (\(tty))"
                } else {
                    item.isEnabled = false
                }
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func createMenuItemIcon(color: NSColor, isFocused: Bool) -> NSImage {
        let size: CGFloat = 14
        let image = NSImage(size: NSSize(width: size, height: size))

        image.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: size, height: size)

        if isFocused {
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            color.setFill()
            path.fill()
        } else {
            let path = NSBezierPath(ovalIn: rect)
            color.setFill()
            path.fill()
        }

        image.unlockFocus()
        image.isTemplate = false

        return image
    }

    private func nsColorForStatus(_ status: ClaudeInstance.Status) -> NSColor {
        switch status {
        case .working:
            return NSColor.systemOrange
        case .waiting:
            return NSColor.systemRed
        case .idle:
            return NSColor.systemGreen
        }
    }

    @objc private func activateInstance(_ sender: NSMenuItem) {
        guard let tty = sender.representedObject as? String else { return }
        TerminalActivator.activate(tty: tty) { succeeded in
            if !succeeded {
                NSSound.beep()
            }
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
