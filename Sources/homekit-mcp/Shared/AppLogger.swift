import OSLog

enum AppLogger {
    static let homekit = Logger(subsystem: AppConfig.bundleID, category: "homekit")
    static let mcp = Logger(subsystem: AppConfig.bundleID, category: "mcp")
    static let cli = Logger(subsystem: AppConfig.bundleID, category: "cli")
    static let app = Logger(subsystem: AppConfig.bundleID, category: "app")
    static let auth = Logger(subsystem: AppConfig.bundleID, category: "auth")
    static let helper = Logger(subsystem: AppConfig.bundleID, category: "helper")
}
