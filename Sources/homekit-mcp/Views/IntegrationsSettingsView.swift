import SwiftUI
import UniformTypeIdentifiers

struct IntegrationsSettingsView: View {
    /// Path to the built mcp-server/dist/server.js (for Claude Desktop stdio transport).
    @AppStorage("mcpServerJSPath") private var serverJSPath = ""
    @AppStorage(AppConfig.portKey) private var port = AppConfig.defaultPort

    @State private var claudeDesktopStatus: IntegrationStatus = .checking
    @State private var claudeCodeStatus: IntegrationStatus = .checking
    @State private var statusMessage: StatusMessage?

    private enum IntegrationStatus {
        case checking
        case notInstalled
        case installed
        case tokenMismatch
    }

    private static let serverName = "homekit-bridge"

    private static var claudeDesktopConfigPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/Application Support/Claude/claude_desktop_config.json"
    }

    private static var claudeCodeConfigPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.claude.json"
    }

    var body: some View {
        Form {
            Section("Claude Desktop") {
                LabeledContent("Status") {
                    statusLabel(claudeDesktopStatus)
                }

                LabeledContent("MCP Server") {
                    HStack(spacing: 4) {
                        TextField(
                            "mcp-server/dist/server.js",
                            text: $serverJSPath
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))

                        Button("Browse\u{2026}") {
                            browseForServerJS()
                        }
                    }
                }

                HStack {
                    Button(claudeDesktopStatus == .tokenMismatch ? "Update" : "Install") {
                        installClaudeDesktop()
                    }
                    .disabled(serverJSPath.isEmpty)

                    if canRemove(claudeDesktopStatus) {
                        Button("Remove", role: .destructive) {
                            remove(from: Self.claudeDesktopConfigPath)
                            claudeDesktopStatus = .notInstalled
                        }
                    }
                }

                Text("Uses the stdio MCP server. Requires Node.js and the built server.js.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Button(claudeCodeStatus == .tokenMismatch ? "Update" : "Install") {
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
            detectServerJSPath()
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

    /// Claude Desktop uses stdio — no token to compare, just check entry exists.
    private func checkClaudeDesktopStatus() -> IntegrationStatus {
        guard let config = readConfig(at: Self.claudeDesktopConfigPath),
            let servers = config["mcpServers"] as? [String: Any],
            servers[Self.serverName] != nil
        else {
            return .notInstalled
        }
        return .installed
    }

    /// Claude Code uses HTTP with bearer token — check entry exists and token matches.
    private func checkClaudeCodeStatus() -> IntegrationStatus {
        guard let config = readConfig(at: Self.claudeCodeConfigPath),
            let servers = config["mcpServers"] as? [String: Any],
            servers[Self.serverName] != nil
        else {
            return .notInstalled
        }

        // Compare configured token with current keychain token
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
        guard !serverJSPath.isEmpty else { return }

        guard FileManager.default.fileExists(atPath: serverJSPath) else {
            showStatus("Server file not found — run: npm run build:mcp", isError: true)
            return
        }

        let entry: [String: Any] = [
            "command": "node",
            "args": [serverJSPath],
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

    /// Reads an existing JSON config file, or returns nil if missing/invalid.
    private func readConfig(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Writes a JSON config file, creating the parent directory if needed.
    private func writeConfig(_ config: [String: Any], to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Adds or updates the homekit-bridge entry in an MCP config file.
    private func upsertMCPServer(entry: [String: Any], in configPath: String) throws {
        var config = readConfig(at: configPath) ?? [:]
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers[Self.serverName] = entry
        config["mcpServers"] = servers
        try writeConfig(config, to: configPath)
    }

    // MARK: - Path Detection

    /// Auto-detect the mcp-server/dist/server.js path from common locations.
    private func detectServerJSPath() {
        guard serverJSPath.isEmpty else { return }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            // Development builds: .build/app/HomeKit Bridge.app → repo root
            (Bundle.main.bundlePath as NSString)
                .appendingPathComponent("../../../mcp-server/dist/server.js"),
            // Common clone location
            home + "/GitHub/HomeClaw/mcp-server/dist/server.js",
        ]

        for path in candidates {
            let resolved = (path as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: resolved) {
                serverJSPath = resolved
                return
            }
        }
    }

    private func browseForServerJS() {
        let panel = NSOpenPanel()
        panel.title = "Select mcp-server/dist/server.js"
        panel.allowedContentTypes = [.javaScript]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            serverJSPath = url.path
        }
    }

    // MARK: - Helpers

    private func currentToken() -> String? {
        try? KeychainManager.readToken()
    }

    private func showStatus(_ text: String, isError: Bool) {
        let message = StatusMessage(text: text, isError: isError)
        statusMessage = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            // Only clear if this is still the active message
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
