import SwiftUI

@main
struct NiceToastApp: App {
    @StateObject private var monitor = StatusFileMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                instances: monitor.instances,
                onQuit: {
                    NSApplication.shared.terminate(nil)
                }
            )
            .onAppear {
                monitor.startMonitoring()
            }
        } label: {
            MenuBarLabel(instances: monitor.instances)
        }
        .menuBarExtraStyle(.window)
    }
}
