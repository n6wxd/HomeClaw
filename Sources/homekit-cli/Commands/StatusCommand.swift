import ArgumentParser
import Foundation

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show HomeKit Bridge status"
    )

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        let response = try SocketClient.send(command: "status")

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if json {
            printJSON(response.data?.value)
            return
        }

        guard let status = response.data?.value as? [String: Any] else {
            print("Could not parse status.")
            return
        }

        let ready = (status["ready"] as? Bool ?? false) ? "Connected" : "Connecting..."
        let homes = status["homes"] as? Int ?? 0
        let accessories = status["accessories"] as? Int ?? 0
        let version = status["version"] as? String ?? "?"

        // MCP port lives in the main app's UserDefaults, not the helper's status response
        let appDefaults = UserDefaults(suiteName: "com.shahine.homekit-bridge")
        let storedPort = appDefaults?.integer(forKey: "mcpServerPort") ?? 0
        let port = storedPort > 0 ? storedPort : 9090

        print("HomeKit Bridge v\(version)")
        print("  HomeKit:     \(ready)")
        print("  Homes:       \(homes)")
        print("  Accessories: \(accessories)")
        print("  MCP Server:  http://127.0.0.1:\(port)/mcp")
        print("  CLI Socket:  \(SocketClient.socketPath)")
    }
}
