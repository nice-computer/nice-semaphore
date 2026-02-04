import SwiftUI

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

/// Generates the menu bar label showing colored dots
struct MenuBarLabel: View {
    let instances: [ClaudeInstance]

    var body: some View {
        HStack(spacing: 2) {
            if instances.isEmpty {
                // Show a single gray dot when no instances
                Circle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: 8, height: 8)
            } else if instances.count <= 4 {
                // Show individual dots
                ForEach(instances) { instance in
                    Circle()
                        .fill(colorForStatus(instance.status))
                        .frame(width: 8, height: 8)
                }
            } else {
                // Show count with primary status color
                let workingCount = instances.filter { $0.status == .working }.count
                let primaryColor = workingCount > 0 ? Color.orange : Color.green

                Circle()
                    .fill(primaryColor)
                    .frame(width: 8, height: 8)

                Text("\(instances.count)")
                    .font(.system(size: 10, weight: .medium))
            }
        }
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
}
