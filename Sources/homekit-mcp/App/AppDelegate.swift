import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let mcpServer = MCPServer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppLogger.app.info("HomeKit Bridge starting...")

        // Ensure bearer token exists
        do {
            let token = try KeychainManager.ensureToken()
            AppLogger.auth.info("Bearer token ready (\(token.prefix(8))...)")
        } catch {
            AppLogger.auth.error("Failed to initialize bearer token: \(error.localizedDescription)")
        }

        // Launch HomeKit Helper and begin health monitoring
        HelperManager.shared.startMonitoring()

        // Start MCP HTTP server
        Task {
            do {
                try await mcpServer.start()
            } catch {
                AppLogger.mcp.error("MCP server failed: \(error.localizedDescription)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.app.info("HomeKit Bridge shutting down...")
        HelperManager.shared.stopMonitoring()
        Task {
            await mcpServer.stop()
        }
    }
}
