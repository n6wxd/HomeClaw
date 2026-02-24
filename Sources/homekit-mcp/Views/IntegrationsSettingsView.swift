import SwiftUI

struct IntegrationsSettingsView: View {
    @AppStorage(AppConfig.portKey) private var port = AppConfig.defaultPort

    @State private var claudeDesktopStatus: IntegrationStatus = .checking
    @State private var claudeCodeStatus: IntegrationStatus = .checking
    @State private var statusMessage: StatusMessage?

    private enum IntegrationStatus {
        case checking
        case notInstalled
        case installed
        case tokenMismatch
        case nodeNotFound
    }

    private static let serverName = "homekit-bridge"

    private static var claudeDesktopConfigPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/Application Support/Claude/claude_desktop_config.json"
    }

    private static var claudeCodeConfigPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.claude.json"
    }

    /// Path to the bundled mcp-server.js inside the app's Resources.
    private static var bundledServerJSPath: String? {
        let path = Bundle.main.bundlePath + "/Contents/Resources/mcp-server.js"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    var body: some View {
        Form {
            Section("Claude Desktop") {
                LabeledContent("Status") {
                    statusLabel(claudeDesktopStatus)
                }

                if let path = Self.bundledServerJSPath {
                    LabeledContent("MCP Server") {
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                HStack {
                    Button(claudeDesktopStatus == .installed ? "Reinstall" : "Install") {
                        installClaudeDesktop()
                    }
                    .disabled(claudeDesktopStatus == .nodeNotFound)

                    if canRemove(claudeDesktopStatus) {
                        Button("Remove", role: .destructive) {
                            remove(from: Self.claudeDesktopConfigPath)
                            claudeDesktopStatus = .notInstalled
                        }
                    }
                }

                if claudeDesktopStatus == .nodeNotFound {
                    Text("Node.js is required for Claude Desktop integration. Install from nodejs.org.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if Self.bundledServerJSPath == nil {
                    Text("MCP server not bundled. Rebuild with: npm run build:mcp && scripts/build.sh")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Uses the bundled stdio MCP server. Requires Node.js.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Claude Code") {
                LabeledContent("Status") {
                    statusLabel(claudeCodeStatus)
                }

                LabeledContent("Endpoint") {
                    Text("http://localhost:\(port)\(AppConfig.mcpEndpoint)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }

                HStack {
                    Button(installButtonLabel(claudeCodeStatus)) {
                        installClaudeCode()
                    }

                    if canRemove(claudeCodeStatus) {
                        Button("Remove", role: .destructive) {
                            remove(from: Self.claudeCodeConfigPath)
                            claudeCodeStatus = .notInstalled
                        }
                    }
                }

                Text("Connects to the HTTP MCP server with bearer token authentication.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = statusMessage {
                Section {
                    Label(
                        message.text,
                        systemImage: message.isError
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                    .foregroundStyle(message.isError ? .red : .green)
                }
            }

            Section {
                Text(
                    "After installing or updating, restart the target application to load the new MCP configuration."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshStatuses()
        }
    }

    // MARK: - Status Display

    @ViewBuilder
    private func statusLabel(_ status: IntegrationStatus) -> some View {
        switch status {
        case .checking:
            Label("Checking\u{2026}", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .notInstalled:
            Label("Not Installed", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .tokenMismatch:
            Label("Token Outdated", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .nodeNotFound:
            Label("Node.js Not Found", systemImage: "xmark.circle")
                .foregroundStyle(.red)
        }
    }

    private func installButtonLabel(_ status: IntegrationStatus) -> String {
        switch status {
        case .tokenMismatch: "Update"
        case .installed: "Reinstall"
        default: "Install"
        }
    }

    private func canRemove(_ status: IntegrationStatus) -> Bool {
        status == .installed || status == .tokenMismatch
    }

    // MARK: - Status Checking

    private func refreshStatuses() {
        claudeDesktopStatus = checkClaudeDesktopStatus()
        claudeCodeStatus = checkClaudeCodeStatus()
    }

    private func checkClaudeDesktopStatus() -> IntegrationStatus {
        // Check Node.js availability first
        guard nodeJSPath() != nil else { return .nodeNotFound }

        guard let config = readConfig(at: Self.claudeDesktopConfigPath),
            let servers = config["mcpServers"] as? [String: Any],
            servers[Self.serverName] != nil
        else {
            return .notInstalled
        }
        return .installed
    }

    private func checkClaudeCodeStatus() -> IntegrationStatus {
        guard let config = readConfig(at: Self.claudeCodeConfigPath),
            let servers = config["mcpServers"] as? [String: Any],
            servers[Self.serverName] != nil
        else {
            return .notInstalled
        }

        if let currentToken = currentToken(),
            let configToken = extractBearerToken(from: config)
        {
            return configToken == currentToken ? .installed : .tokenMismatch
        }

        return .installed
    }

    private func extractBearerToken(from config: [String: Any]) -> String? {
        guard let servers = config["mcpServers"] as? [String: Any],
            let entry = servers[Self.serverName] as? [String: Any],
            let headers = entry["headers"] as? [String: Any],
            let auth = headers["Authorization"] as? String,
            auth.hasPrefix("Bearer ")
        else { return nil }
        return String(auth.dropFirst("Bearer ".count))
    }

    // MARK: - Install

    private func installClaudeDesktop() {
        guard let serverJS = Self.bundledServerJSPath else {
            showStatus("MCP server not bundled in app — rebuild first", isError: true)
            return
        }

        guard let nodePath = nodeJSPath() else {
            showStatus("Node.js not found — install from nodejs.org", isError: true)
            return
        }

        let entry: [String: Any] = [
            "command": nodePath,
            "args": [serverJS],
        ]

        do {
            try upsertMCPServer(entry: entry, in: Self.claudeDesktopConfigPath)
            claudeDesktopStatus = .installed
            showStatus("Claude Desktop integration installed", isError: false)
            AppLogger.app.info("Installed MCP config for Claude Desktop")
        } catch {
            showStatus("Failed: \(error.localizedDescription)", isError: true)
            AppLogger.app.error(
                "Failed to install Claude Desktop config: \(error.localizedDescription)")
        }
    }

    private func installClaudeCode() {
        guard let token = currentToken() else {
            showStatus("No bearer token found in Keychain", isError: true)
            return
        }

        let entry: [String: Any] = [
            "type": "http",
            "url": "http://localhost:\(port)\(AppConfig.mcpEndpoint)",
            "headers": ["Authorization": "Bearer \(token)"],
        ]

        do {
            try upsertMCPServer(entry: entry, in: Self.claudeCodeConfigPath)
            claudeCodeStatus = .installed
            showStatus("Claude Code integration installed", isError: false)
            AppLogger.app.info("Installed MCP config for Claude Code")
        } catch {
            showStatus("Failed: \(error.localizedDescription)", isError: true)
            AppLogger.app.error(
                "Failed to install Claude Code config: \(error.localizedDescription)")
        }
    }

    // MARK: - Remove

    private func remove(from configPath: String) {
        guard var config = readConfig(at: configPath) else { return }
        guard var servers = config["mcpServers"] as? [String: Any] else { return }

        servers.removeValue(forKey: Self.serverName)
        config["mcpServers"] = servers

        do {
            try writeConfig(config, to: configPath)
            showStatus("Integration removed", isError: false)
        } catch {
            showStatus("Failed: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Config File I/O

    private func readConfig(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func writeConfig(_ config: [String: Any], to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func upsertMCPServer(entry: [String: Any], in configPath: String) throws {
        var config = readConfig(at: configPath) ?? [:]
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers[Self.serverName] = entry
        config["mcpServers"] = servers
        try writeConfig(config, to: configPath)
    }

    // MARK: - Helpers

    private func currentToken() -> String? {
        try? KeychainManager.readToken()
    }

    /// Finds the absolute path to the `node` binary, or nil if not installed.
    private func nodeJSPath() -> String? {
        let knownPaths = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/bin/node",
        ]
        return knownPaths.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    private func showStatus(_ text: String, isError: Bool) {
        let message = StatusMessage(text: text, isError: isError)
        statusMessage = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if statusMessage?.id == message.id {
                statusMessage = nil
            }
        }
    }
}

// MARK: - Status Message

private struct StatusMessage: Sendable {
    let id: UUID
    let text: String
    let isError: Bool

    init(text: String, isError: Bool) {
        self.id = UUID()
        self.text = text
        self.isError = isError
    }
}
