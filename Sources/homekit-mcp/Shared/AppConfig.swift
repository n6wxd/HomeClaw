import Foundation

enum AppConfig {
    static let bundleID = "com.shahine.homekit-bridge"
    static let appName = "HomeKit Bridge"
    static let version = "0.1.0"

    // MCP Server
    static let defaultPort: Int = 9090
    static let mcpEndpoint = "/mcp"

    // CLI Socket
    static let socketPath = "/tmp/homekit-bridge.sock"

    // Keychain
    static let keychainService = "\(bundleID).auth"
    static let keychainAccount = "mcp-bearer-token"

    // UserDefaults keys
    static let portKey = "mcpServerPort"
    static let launchAtLoginKey = "launchAtLogin"

    static var port: Int {
        let stored = UserDefaults.standard.integer(forKey: portKey)
        return stored > 0 ? stored : defaultPort
    }
}
