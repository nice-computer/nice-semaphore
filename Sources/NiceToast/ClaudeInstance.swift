import Foundation

/// Represents a running Claude Code instance
struct ClaudeInstance: Identifiable, Codable, Equatable {
    let id: String  // session_id
    var status: Status
    var project: String
    var lastUpdate: Date

    enum Status: String, Codable {
        case working   // Claude is processing
        case waiting   // Claude finished, awaiting user input
        case idle      // No activity for a while (optional future use)
    }

    /// Returns the shortened project name (last path component)
    var shortProjectName: String {
        return (project as NSString).lastPathComponent
    }

    /// Returns a user-friendly display path (with ~ for home directory)
    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if project.hasPrefix(home) {
            return "~" + project.dropFirst(home.count)
        }
        return project
    }
}

/// The structure of the status file
struct StatusFile: Codable {
    var instances: [String: InstanceData]

    struct InstanceData: Codable {
        var status: ClaudeInstance.Status
        var project: String
        var lastUpdate: Date
    }

    /// Convert to array of ClaudeInstance
    func toInstances() -> [ClaudeInstance] {
        return instances.map { (id, data) in
            ClaudeInstance(
                id: id,
                status: data.status,
                project: data.project,
                lastUpdate: data.lastUpdate
            )
        }.sorted { $0.lastUpdate > $1.lastUpdate }
    }
}
