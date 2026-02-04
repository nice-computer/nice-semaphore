import Foundation
import Combine

/// Monitors the Claude instance status file for changes using DispatchSource
@MainActor
final class StatusFileMonitor: ObservableObject {
    @Published private(set) var instances: [ClaudeInstance] = []

    private let statusFilePath: String
    private var fileDescriptor: Int32 = -1
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var lastModificationDate: Date?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.statusFilePath = "\(home)/.claude/instance-status.json"
    }

    func startMonitoring() {
        // Initial load
        loadStatusFile()

        // Ensure the directory exists
        let directory = (statusFilePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        // Create the file if it doesn't exist
        if !FileManager.default.fileExists(atPath: statusFilePath) {
            try? "{\"instances\":{}}".write(toFile: statusFilePath, atomically: true, encoding: .utf8)
        }

        // Start watching the file
        startWatchingFile()
    }

    func stopMonitoring() {
        dispatchSource?.cancel()
        dispatchSource = nil
        if fileDescriptor != -1 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    private func startWatchingFile() {
        // Close any existing file descriptor
        if fileDescriptor != -1 {
            close(fileDescriptor)
        }

        // Open the file for monitoring
        fileDescriptor = open(statusFilePath, O_EVTONLY)
        guard fileDescriptor != -1 else {
            // File doesn't exist yet, try again later
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startWatchingFile()
            }
            return
        }

        // Create dispatch source to monitor file changes
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .attrib],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // File was deleted or renamed, restart monitoring
                self.stopMonitoring()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.startMonitoring()
                }
            } else {
                self.loadStatusFile()
            }
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd != -1 {
                close(fd)
                self?.fileDescriptor = -1
            }
        }

        dispatchSource = source
        source.resume()
    }

    private func loadStatusFile() {
        guard FileManager.default.fileExists(atPath: statusFilePath) else {
            instances = []
            return
        }

        // Check if file was actually modified
        if let attrs = try? FileManager.default.attributesOfItem(atPath: statusFilePath),
           let modDate = attrs[.modificationDate] as? Date {
            if let lastMod = lastModificationDate, modDate <= lastMod {
                return // File hasn't changed
            }
            lastModificationDate = modDate
        }

        guard let data = FileManager.default.contents(atPath: statusFilePath) else {
            instances = []
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let statusFile = try decoder.decode(StatusFile.self, from: data)
            instances = statusFile.toInstances()
        } catch {
            // If parsing fails, reset instances
            instances = []
        }
    }

    deinit {
        dispatchSource?.cancel()
        if fileDescriptor != -1 {
            close(fileDescriptor)
        }
    }
}
