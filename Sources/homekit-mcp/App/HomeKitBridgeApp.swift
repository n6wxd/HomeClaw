import SwiftUI

@main
struct HomeKitBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("HomeKit Bridge", systemImage: "house.badge.wifi.fill") {
            MenuBarView()
        }

        Settings {
            SettingsView()
        }
    }
}
