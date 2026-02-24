import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppLogger.app.info("HomeKit Bridge starting...")

        // Launch HomeKit Helper and begin health monitoring
        HelperManager.shared.startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.app.info("HomeKit Bridge shutting down...")
        HelperManager.shared.stopMonitoring()
    }
}
