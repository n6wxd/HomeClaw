import Foundation

enum AppConfig {
    static let bundleID = "com.shahine.homekit-bridge"
    static let appName = "HomeKit Bridge"
    static let version: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
    }()

    static let build: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }()

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
