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
            return .red
        case .idle:
            return .green
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

/// Generates an NSImage for the menu bar showing space numbers in colored boxes
func createMenuBarImage(for instances: [ClaudeInstance], focusedId: String?, spaceNumbers: [String: Int]) -> NSImage {
    let boxSize: CGFloat = 16
    let spacing: CGFloat = 2
    let height: CGFloat = 18

    struct ItemInfo {
        let text: String
        let color: NSColor
        let isFocused: Bool
    }

    let items: [ItemInfo]
    if instances.isEmpty {
        items = [ItemInfo(text: "–", color: NSColor.gray, isFocused: false)]
    } else if instances.count <= 6 {
        // Sort instances by space number (ascending), unknowns at end
        let sorted = instances.sorted { a, b in
            let spaceA = spaceNumbers[a.id] ?? Int.max
            let spaceB = spaceNumbers[b.id] ?? Int.max
            return spaceA < spaceB
        }
        items = sorted.map { instance in
            let spaceNum = spaceNumbers[instance.id]
            let text = spaceNum != nil ? "\(spaceNum!)" : "?"
            return ItemInfo(
                text: text,
                color: nsColorForStatus(instance.status),
                isFocused: instance.id == focusedId
            )
        }
    } else {
        // Too many instances - show count
        let workingCount = instances.filter { $0.status == .working }.count
        let hasFocused = instances.contains { $0.id == focusedId }
        items = [ItemInfo(
            text: "\(instances.count)",
            color: workingCount > 0 ? NSColor.orange : NSColor.systemGreen,
            isFocused: hasFocused
        )]
    }

    let totalWidth = CGFloat(items.count) * boxSize + CGFloat(max(0, items.count - 1)) * spacing
    let image = NSImage(size: NSSize(width: totalWidth, height: height))

    image.lockFocus()

    var x: CGFloat = 0
    for item in items {
        let boxRect = NSRect(x: x, y: (height - boxSize) / 2, width: boxSize, height: boxSize)
        let path = NSBezierPath(roundedRect: boxRect, xRadius: 3, yRadius: 3)

        let textColor = contrastingTextColor(for: item.color)

        if item.isFocused {
            // Focused: rounded square background
            item.color.setFill()
            path.fill()
            drawCenteredText(item.text, in: boxRect, color: textColor)
        } else {
            // Not focused: circle background
            let circlePath = NSBezierPath(ovalIn: boxRect)
            item.color.setFill()
            circlePath.fill()
            drawCenteredText(item.text, in: boxRect, color: textColor)
        }

        x += boxSize + spacing
    }

    image.unlockFocus()
    image.isTemplate = false  // Keep our colors

    return image
}

private func drawCenteredText(_ text: String, in rect: NSRect, color: NSColor) {
    let font = NSFont.boldSystemFont(ofSize: 11)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center

    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraphStyle
    ]

    let textSize = (text as NSString).size(withAttributes: attributes)
    let textRect = NSRect(
        x: rect.origin.x,
        y: rect.origin.y + (rect.height - textSize.height) / 2,
        width: rect.width,
        height: textSize.height
    )
    (text as NSString).draw(in: textRect, withAttributes: attributes)
}

/// Returns black or white depending on which has better contrast with the background
private func contrastingTextColor(for backgroundColor: NSColor) -> NSColor {
    // Convert to RGB color space
    guard let rgbColor = backgroundColor.usingColorSpace(.sRGB) else {
        return .white
    }

    // Calculate relative luminance using sRGB formula
    let r = rgbColor.redComponent
    let g = rgbColor.greenComponent
    let b = rgbColor.blueComponent

    // Weighted luminance (human eye is more sensitive to green)
    let luminance = 0.299 * r + 0.587 * g + 0.114 * b

    // Use black text for light backgrounds, white for dark
    return luminance > 0.5 ? .black : .white
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
