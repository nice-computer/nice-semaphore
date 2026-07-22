import Foundation
import AppKit

/// Brings the iTerm2 session running a given Claude instance to the front.
///
/// Instances are matched by TTY, the same identifier focus detection uses
/// (see `StatusFileMonitor.getFocusedITermTty`). Selecting the tab, session and
/// window covers the split-pane case, where several sessions share one tab.
enum TerminalActivator {

    /// Activates the iTerm2 session with the given TTY (e.g. "/dev/ttys001").
    /// Runs off the main thread: AppleScript can block for a noticeable moment.
    static func activate(tty: String, completion: ((Bool) -> Void)? = nil) {
        guard !tty.isEmpty else {
            completion?(false)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let succeeded = runActivateScript(tty: tty)
            if let completion {
                DispatchQueue.main.async { completion(succeeded) }
            }
        }
    }

    private static func runActivateScript(tty: String) -> Bool {
        // References are captured first and acted on at the top level: inside a
        // `tell tab` block, `activate` and `window` resolve against the tab and
        // the script fails with -1728.
        let source = """
            tell application "iTerm2"
                set theWindow to missing value
                set theTab to missing value
                set theSession to missing value
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if (tty of s) is "\(escaped(tty))" then
                                set theWindow to w
                                set theTab to t
                                set theSession to s
                                exit repeat
                            end if
                        end repeat
                        if theSession is not missing value then exit repeat
                    end repeat
                    if theSession is not missing value then exit repeat
                end repeat
                if theSession is missing value then return "notfound"
                select theTab
                select theSession
                select theWindow
                activate
                return "ok"
            end tell
            """

        guard let script = NSAppleScript(source: source) else { return false }

        return autoreleasepool {
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if error != nil { return false }
            return result.stringValue == "ok"
        }
    }

    /// Escapes a value for safe interpolation into an AppleScript string literal.
    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
