import Foundation
import Combine
import AppKit
import CoreGraphics

/// Monitors the Claude instance status file for changes using DispatchSource
@MainActor
final class StatusFileMonitor: ObservableObject {
    @Published private(set) var instances: [ClaudeInstance] = []
    @Published private(set) var focusedInstanceId: String?
    @Published private(set) var spaceNumbers: [String: Int] = [:]

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
        // Check focus and reload status frequently for responsiveness
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.loadStatusFile()
                self?.updateFocusedInstance()
                self?.updateSpaceNumbers()
            }
        }
        // Initial check
        loadStatusFile()
        updateFocusedInstance()
        updateSpaceNumbers()
    }

    private func updateSpaceNumbers() {
        spaceNumbers = SpaceDetector.getSpaceNumbers(for: instances)
    }

    private func updateFocusedInstance() {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            focusedInstanceId = nil
            return
        }

        let frontmostPid = Int(frontmostApp.processIdentifier)

        // Find all instances that are descendants of the frontmost app
        var candidateInstances: [ClaudeInstance] = []
        for instance in instances {
            guard let claudePid = instance.pid else { continue }

            if isProcess(claudePid, descendantOf: frontmostPid) {
                candidateInstances.append(instance)
            }
        }

        // If no candidates, no focused instance
        guard !candidateInstances.isEmpty else {
            focusedInstanceId = nil
            return
        }

        // If only one candidate, it's the focused one
        if candidateInstances.count == 1 {
            focusedInstanceId = candidateInstances[0].id
            return
        }

        // Multiple candidates - try to match by frontmost window TTY or title
        if let focusedInstance = findInstanceByFrontmostWindow(
            candidates: candidateInstances,
            appPid: frontmostPid
        ) {
            focusedInstanceId = focusedInstance.id
            return
        }

        // Fallback: no match found
        focusedInstanceId = nil
    }

    private func findInstanceByFrontmostWindow(
        candidates: [ClaudeInstance],
        appPid: Int
    ) -> ClaudeInstance? {
        // First, try iTerm2-specific AppleScript to get the focused session's TTY
        if let focusedTty = getFocusedITermTty() {
            for instance in candidates {
                if instance.tty == focusedTty {
                    return instance
                }
            }
        }

        // Fallback: try matching by window title
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        // Find the frontmost window belonging to our terminal app
        for windowInfo in windowList {
            guard let windowPid = windowInfo[kCGWindowOwnerPID as String] as? Int,
                  windowPid == appPid,
                  let windowName = windowInfo[kCGWindowName as String] as? String,
                  !windowName.isEmpty else {
                continue
            }

            // Try to match window title against instance projects
            // Terminal windows often show the current directory in the title
            for instance in candidates {
                let projectName = instance.shortProjectName
                let fullPath = instance.project

                // Check if window title contains the project name or path
                if windowName.contains(projectName) ||
                   windowName.contains(fullPath) ||
                   fullPath.contains(windowName) {
                    return instance
                }
            }

            // If we found a terminal window but couldn't match it, stop looking
            // (it's the frontmost one, subsequent ones are behind it)
            break
        }

        return nil
    }

    private func getFocusedITermTty() -> String? {
        let script = """
            tell application "iTerm2"
                if (count of windows) > 0 then
                    tell current session of current window
                        return tty
                    end tell
                end if
            end tell
            """

        guard let appleScript = NSAppleScript(source: script) else {
            return nil
        }

        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)

        if error != nil {
            return nil
        }

        return result.stringValue
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
