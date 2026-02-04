import SwiftUI
import AppKit

/// The dropdown menu content shown when clicking the menu bar item
struct MenuBarView: View {
    let instances: [ClaudeInstance]
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if instances.isEmpty {
                Text("No Claude Code instances")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(instances) { instance in
                    InstanceRow(instance: instance)
                }
            }

            Divider()
                .padding(.vertical, 4)

            Button("Quit") {
                onQuit()
            }
            .keyboardShortcut("q")
        }
        .padding(.vertical, 4)
    }
}

/// A single row showing an instance's status
struct InstanceRow: View {
    let instance: ClaudeInstance

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(colorForStatus(instance.status))
                .frame(width: 8, height: 8)

            Text(instance.displayPath)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(statusLabel(instance.status))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func colorForStatus(_ status: ClaudeInstance.Status) -> Color {
        switch status {
        case .working:
            return .orange
        case .waiting:
            return .green
        case .idle:
            return .gray
        }
    }

    private func statusLabel(_ status: ClaudeInstance.Status) -> String {
        switch status {
        case .working:
            return "Working"
        case .waiting:
            return "Waiting"
        case .idle:
            return "Idle"
        }
    }
}

/// Generates an NSImage for the menu bar showing colored dots
func createMenuBarImage(for instances: [ClaudeInstance], focusedId: String?) -> NSImage {
    let dotSize: CGFloat = 8
    let spacing: CGFloat = 4
    let height: CGFloat = 18
    let underlineHeight: CGFloat = 2
    let underlineGap: CGFloat = 2

    // Determine dots to draw
    struct DotInfo {
        let color: NSColor
        let isFocused: Bool
    }

    let dots: [DotInfo]
    if instances.isEmpty {
        dots = [DotInfo(color: NSColor.gray, isFocused: false)]
    } else if instances.count <= 4 {
        dots = instances.map { instance in
            DotInfo(
                color: nsColorForStatus(instance.status),
                isFocused: instance.id == focusedId
            )
        }
    } else {
        let workingCount = instances.filter { $0.status == .working }.count
        let hasFocused = instances.contains { $0.id == focusedId }
        dots = [DotInfo(
            color: workingCount > 0 ? NSColor.orange : NSColor.systemGreen,
            isFocused: hasFocused
        )]
    }

    let width = CGFloat(dots.count) * dotSize + CGFloat(max(0, dots.count - 1)) * spacing
    let image = NSImage(size: NSSize(width: width, height: height))

    image.lockFocus()

    for (index, dot) in dots.enumerated() {
        let x = CGFloat(index) * (dotSize + spacing)
        let y = (height - dotSize) / 2 + (dot.isFocused ? underlineHeight / 2 + underlineGap / 2 : 0)
        let rect = NSRect(x: x, y: y, width: dotSize, height: dotSize)

        dot.color.setFill()
        NSBezierPath(ovalIn: rect).fill()

        // Draw underline for focused instance
        if dot.isFocused {
            let underlineY = y - underlineGap - underlineHeight
            let underlineRect = NSRect(x: x, y: underlineY, width: dotSize, height: underlineHeight)
            dot.color.setFill()
            NSBezierPath(roundedRect: underlineRect, xRadius: 1, yRadius: 1).fill()
        }
    }

    image.unlockFocus()
    image.isTemplate = false

    return image
}

private func nsColorForStatus(_ status: ClaudeInstance.Status) -> NSColor {
    switch status {
    case .working:
        return NSColor.orange
    case .waiting:
        return NSColor.systemGreen
    case .idle:
        return NSColor.gray
    }
}
