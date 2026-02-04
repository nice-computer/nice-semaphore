import Foundation
import Combine
import AppKit

/// Monitors the Claude instance status file for changes using DispatchSource
@MainActor
final class StatusFileMonitor: ObservableObject {
    @Published private(set) var instances: [ClaudeInstance] = []
    @Published private(set) var focusedInstanceId: String?

    private let statusFilePath: String
    private var fileDescriptor: Int32 = -1
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var lastModificationDate: Date?
    private var cleanupTimer: Timer?
    private var focusTimer: Timer?

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

        // Start periodic cleanup of dead processes
        startCleanupTimer()

        // Start focus detection
        startFocusTimer()
    }

    func stopMonitoring() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        focusTimer?.invalidate()
        focusTimer = nil
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

    private func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupDeadProcesses()
            }
        }
    }

    private func cleanupDeadProcesses() {
        let deadInstances = instances.filter { instance in
            guard let pid = instance.pid else { return false }
            return !isProcessAlive(pid: pid)
        }

        guard !deadInstances.isEmpty else { return }

        // Remove dead instances from the status file
        for instance in deadInstances {
            removeInstanceFromFile(sessionId: instance.id)
        }
    }

    private func isProcessAlive(pid: Int) -> Bool {
        // kill with signal 0 checks if process exists without sending a signal
        return kill(Int32(pid), 0) == 0
    }

    private func removeInstanceFromFile(sessionId: String) {
        guard FileManager.default.fileExists(atPath: statusFilePath),
              let data = FileManager.default.contents(atPath: statusFilePath) else {
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var statusFile = try decoder.decode(StatusFile.self, from: data)
            statusFile.instances.removeValue(forKey: sessionId)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let newData = try encoder.encode(statusFile)
            try newData.write(to: URL(fileURLWithPath: statusFilePath))

            // Force reload
            lastModificationDate = nil
            loadStatusFile()
        } catch {
            // Ignore errors
        }
    }

    private func startFocusTimer() {
        // Check focus frequently for responsiveness
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateFocusedInstance()
            }
        }
        // Initial check
        updateFocusedInstance()
    }

    private func updateFocusedInstance() {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            focusedInstanceId = nil
            return
        }

        let frontmostPid = Int(frontmostApp.processIdentifier)

        // Check if any instance's Claude process is a descendant of the frontmost app
        for instance in instances {
            guard let claudePid = instance.pid else { continue }

            // Check if Claude is a descendant of the frontmost app
            if isProcess(claudePid, descendantOf: frontmostPid) {
                focusedInstanceId = instance.id
                return
            }
        }

        focusedInstanceId = nil
    }

    private func isProcessInForeground(pid: Int, tty: String) -> Bool {
        // Get process info using sysctl
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }

        // Get Claude's process group
        let claudePgid = info.kp_eproc.e_pgid

        // Get the terminal's foreground process group
        let foregroundPgid = info.kp_eproc.e_tpgid

        // Check if Claude's process group is the foreground group
        return claudePgid == foregroundPgid
    }

    private func isProcess(_ pid: Int, descendantOf ancestorPid: Int) -> Bool {
        var currentPid = pid
        var depth = 0
        while currentPid > 1 && depth < 10 {
            if currentPid == ancestorPid {
                return true
            }
            // Get parent PID
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(currentPid)]
            if sysctl(&mib, 4, &info, &size, nil, 0) != 0 {
                break
            }
            let parentPid = Int(info.kp_eproc.e_ppid)
            if parentPid == currentPid {
                break
            }
            currentPid = parentPid
            depth += 1
        }
        return false
    }

    deinit {
        cleanupTimer?.invalidate()
        focusTimer?.invalidate()
        dispatchSource?.cancel()
        if fileDescriptor != -1 {
            close(fileDescriptor)
        }
    }
}
