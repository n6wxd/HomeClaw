import SwiftUI

struct IntegrationsSettingsView: View {
    @AppStorage(AppConfig.portKey) private var port = AppConfig.defaultPort

    @State private var claudeDesktopStatus: DesktopStatus = .checking
    @State private var claudeCodeStatus: ClaudeCodeStatus = .checking
    @State private var statusMessage: StatusMessage?

    // MARK: - Status Enums

    private enum DesktopStatus {
        case checking
        case notInstalled
        case installed
        case nodeNotFound
    }

    private enum ClaudeCodeStatus {
        /// Still checking config files.
        case checking
        /// Plugin detected in ~/.claude/settings.json enabledPlugins.
        case pluginInstalled
        /// Legacy HTTP MCP config in ~/.claude.json (works, but plugin preferred).
        case mcpConfigured
        /// Neither plugin nor MCP config found.
        case notInstalled
    }

    // MARK: - Constants & Paths

    private static let serverName = "homekit-bridge"
    private static let pluginPrefix = "homekit-bridge@"
    private static let githubRepo = "omarshahine/HomeClaw"

    private static var claudeDesktopConfigPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/Application Support/Claude/claude_desktop_config.json"
    }

    private static var claudeCodeConfigPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.claude.json"
    }

    private static var claudeCodeSettingsPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.claude/settings.json"
    }

    /// Path to the bundled mcp-server.js inside the app's Resources.
    private static var bundledServerJSPath: String? {
        let path = Bundle.main.bundlePath + "/Contents/Resources/mcp-server.js"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // MARK: - Body

    var body: some View {
        Form {
            claudeDesktopSection
            claudeCodeSection

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

    // MARK: - Claude Desktop Section

    @ViewBuilder
    private var claudeDesktopSection: some View {
        Section("Claude Desktop") {
            LabeledContent("Status") {
                desktopStatusLabel
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

                if claudeDesktopStatus == .installed {
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
    }

    // MARK: - Claude Code Section

    @ViewBuilder
    private var claudeCodeSection: some View {
        Section("Claude Code") {
            LabeledContent("Status") {
                claudeCodeStatusLabel
            }

            switch claudeCodeStatus {
            case .pluginInstalled:
                Text("HomeKit Bridge plugin is installed and active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .mcpConfigured:
                LabeledContent("Endpoint") {
                    Text("http://localhost:\(port)\(AppConfig.mcpEndpoint)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }

                HStack {
                    Button("Copy Plugin Install Commands") {
                        copyInstallCommands()
                    }
                    Button("Remove MCP Config", role: .destructive) {
                        remove(from: Self.claudeCodeConfigPath)
                        claudeCodeStatus = .notInstalled
                    }
                }

                Text(
                    "HTTP MCP config detected in ~/.claude.json. Consider switching to the plugin for easier updates."
                )
                .font(.caption)
                .foregroundStyle(.orange)

            case .notInstalled:
                Button("Copy Install Commands") {
                    copyInstallCommands()
                }

                installInstructionsView

            case .checking:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var installInstructionsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Run these commands in Claude Code:")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("/plugin marketplace add \(Self.githubRepo)")
                Text("/plugin install homekit-bridge@homekit-bridge")
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
    }

    // MARK: - Status Labels

    @ViewBuilder
    private var desktopStatusLabel: some View {
        switch claudeDesktopStatus {
        case .checking:
            Label("Checking\u{2026}", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .notInstalled:
            Label("Not Installed", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .nodeNotFound:
            Label("Node.js Not Found", systemImage: "xmark.circle")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var claudeCodeStatusLabel: some View {
        switch claudeCodeStatus {
        case .checking:
            Label("Checking\u{2026}", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .pluginInstalled:
            Label("Plugin Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .mcpConfigured:
            Label("MCP Config", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .notInstalled:
            Label("Not Installed", systemImage: "circle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Status Checking

    private func refreshStatuses() {
        claudeDesktopStatus = checkClaudeDesktopStatus()
        claudeCodeStatus = checkClaudeCodeStatus()
    }

    private func checkClaudeDesktopStatus() -> DesktopStatus {
        guard nodeJSPath() != nil else { return .nodeNotFound }

        guard let config = readConfig(at: Self.claudeDesktopConfigPath),
            let servers = config["mcpServers"] as? [String: Any],
            servers[Self.serverName] != nil
        else {
            return .notInstalled
        }
        return .installed
    }

    private func checkClaudeCodeStatus() -> ClaudeCodeStatus {
        // Check for plugin first (preferred approach)
        if isPluginEnabled() { return .pluginInstalled }

        // Check for legacy HTTP MCP config in ~/.claude.json
        if isMCPConfigured() { return .mcpConfigured }

        return .notInstalled
    }

    /// Checks ~/.claude/settings.json enabledPlugins for any key matching "homekit-bridge@*".
    private func isPluginEnabled() -> Bool {
        guard let config = readConfig(at: Self.claudeCodeSettingsPath),
            let enabled = config["enabledPlugins"] as? [String: Any]
        else { return false }
        return enabled.keys.contains { $0.hasPrefix(Self.pluginPrefix) }
    }

    /// Checks ~/.claude.json mcpServers for a "homekit-bridge" entry.
    private func isMCPConfigured() -> Bool {
        guard let config = readConfig(at: Self.claudeCodeConfigPath),
            let servers = config["mcpServers"] as? [String: Any]
        else { return false }
        return servers[Self.serverName] != nil
    }

    // MARK: - Install Actions

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

    private func copyInstallCommands() {
        let commands = """
            /plugin marketplace add \(Self.githubRepo)
            /plugin install homekit-bridge@homekit-bridge
            """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands, forType: .string)
        showStatus("Install commands copied to clipboard", isError: false)
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
