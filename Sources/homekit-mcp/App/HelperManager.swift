import AppKit
import Foundation

/// Centralized helper lifecycle manager. Owns launching, killing, health-checking,
/// and auto-restarting the HomeKitHelper Catalyst process.
///
/// `@Observable` so SwiftUI views (MenuBarView) can react to `state` changes
/// without manual bindings or Combine publishers.
@Observable
@MainActor
final class HelperManager {
    static let shared = HelperManager()

    // MARK: - Public State

    enum HelperState: Sendable {
        case starting
        case connected(homeNames: [String])
        case helperDown
        case homekitUnavailable(reason: String)
    }

    private(set) var state: HelperState = .starting
    private(set) var consecutiveFailures: Int = 0
    private(set) var totalRestarts: Int = 0

    /// Cached home count from last status check — used to detect changes
    /// that should trigger a home name refresh.
    private var lastKnownHomeCount: Int = 0
    /// Resolved display names for connected homes.
    private var cachedHomeNames: [String] = []

    /// How many auto-restarts remain in the current sliding window.
    var restartsRemaining: Int {
        max(0, maxAutoRestarts - restartsInWindow)
    }

    // MARK: - Configuration

    /// Exposed for UI display (e.g. "3 of 5 restarts used").
    static let maxAutoRestartsPublic = 5
    private let maxAutoRestarts = maxAutoRestartsPublic
    private let restartWindow: TimeInterval = 900  // 15 minutes
    private let healthInterval: TimeInterval = 30
    private let healthTimeout: TimeInterval = 5
    private let consecutiveFailureThreshold = 3
    private let restartDelay: TimeInterval = 2

    // MARK: - Internal Bookkeeping

    private var healthTask: Task<Void, Never>?
    private var autoRestartTimestamps: [Date] = []

    private var restartsInWindow: Int {
        let cutoff = Date().addingTimeInterval(-restartWindow)
        return autoRestartTimestamps.filter { $0 > cutoff }.count
    }

    private init() {}

    // MARK: - Public API

    /// Start helper process and begin health monitoring. Call from AppDelegate.
    func startMonitoring() {
        AppLogger.helper.info("Starting helper monitoring")
        launchHelper()
        startHealthLoop()
    }

    /// Stop health monitoring and kill helper. Call from AppDelegate on termination.
    func stopMonitoring() {
        AppLogger.helper.info("Stopping helper monitoring")
        healthTask?.cancel()
        healthTask = nil
        killHelper()
    }

    /// Manual restart triggered by user. Does NOT count against auto-restart budget.
    func restartHelper() {
        AppLogger.helper.info("Manual restart requested")
        state = .starting
        consecutiveFailures = 0
        killHelper()
        Task {
            try? await Task.sleep(for: .seconds(restartDelay))
            launchHelper()
        }
    }

    // MARK: - Helper Process Lifecycle

    private func launchHelper() {
        let helperName = "HomeKitHelper"
        let possiblePaths = [
            Bundle.main.bundlePath + "/Contents/Helpers/\(helperName).app",
            (Bundle.main.executableURL?.deletingLastPathComponent().path ?? "")
                + "/\(helperName).app",
        ]

        guard let helperPath = possiblePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            AppLogger.helper.warning(
                "HomeKit Helper not found at expected paths. CLI/MCP will use socket when helper is running separately."
            )
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", helperPath, "--args", "--background"]

        do {
            try process.run()
            AppLogger.helper.info("HomeKit Helper launched from \(helperPath)")
        } catch {
            AppLogger.helper.error("Failed to launch HomeKit Helper: \(error.localizedDescription)")
            state = .helperDown
        }
    }

    private func killHelper() {
        // Remove stale socket so health checks fail fast during restart
        try? FileManager.default.removeItem(atPath: AppConfig.socketPath)

        // Find and terminate the actual HomeKitHelper process.
        // We can't hold a Process reference because `open -a` returns immediately.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "HomeKitHelper"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        AppLogger.helper.info("Sent kill signal to HomeKitHelper")
    }

    // MARK: - Health Check Loop

    private func startHealthLoop() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            // Give the helper a moment to start up before first check
            try? await Task.sleep(for: .seconds(5))

            while !Task.isCancelled {
                await self?.performHealthCheck()
                try? await Task.sleep(for: .seconds(self?.healthInterval ?? 30))
            }
        }
    }

    private func performHealthCheck() async {
        do {
            let status = try await withThrowingTimeout(seconds: healthTimeout) {
                try await HomeKitClient.shared.status()
            }

            if status.ready {
                // Refresh home names on first connect or when home count changes
                if cachedHomeNames.isEmpty || status.homeCount != lastKnownHomeCount {
                    cachedHomeNames = await fetchDisplayHomeNames()
                    lastKnownHomeCount = status.homeCount
                }
                state = .connected(homeNames: cachedHomeNames)
                if consecutiveFailures > 0 {
                    AppLogger.helper.info(
                        "Health check recovered after \(self.consecutiveFailures) failure(s)"
                    )
                }
                consecutiveFailures = 0
            } else if status.homeCount == 0 {
                state = .homekitUnavailable(reason: "No homes found — check iCloud & HomeKit hub")
                consecutiveFailures = 0  // Helper is alive, HomeKit is the problem
            } else {
                // ready=false but homes > 0: still initializing
                state = .starting
                consecutiveFailures = 0
            }
        } catch {
            consecutiveFailures += 1
            AppLogger.helper.warning(
                "Health check failed (\(self.consecutiveFailures)/\(self.consecutiveFailureThreshold)): \(error.localizedDescription)"
            )

            if consecutiveFailures >= consecutiveFailureThreshold {
                if restartsInWindow < maxAutoRestarts {
                    await autoRestart()
                } else {
                    state = .helperDown
                    AppLogger.helper.error(
                        "Helper unresponsive. Auto-restart budget exhausted (\(self.maxAutoRestarts) in \(Int(self.restartWindow / 60))min). Use manual restart."
                    )
                }
            }
        }
    }

    // MARK: - Home Name Resolution

    /// Fetches home names from the helper, filtered by the default home config.
    /// Returns all home names if no default is set, or just the default home's name.
    private func fetchDisplayHomeNames() async -> [String] {
        do {
            let homesData = try await HomeKitClient.shared.listHomes()
            guard let arr = try? JSONSerialization.jsonObject(with: homesData) as? [[String: Any]] else {
                return []
            }

            let allHomes = arr.compactMap { $0["name"] as? String }

            // Check if a default home is configured
            let configData = try await HomeKitClient.shared.getConfig()
            if let configDict = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
               let config = configDict["config"] as? [String: Any],
               let defaultID = config["default_home_id"] as? String,
               !defaultID.isEmpty
            {
                // Find the name matching the default home ID
                if let match = arr.first(where: { ($0["id"] as? String) == defaultID }),
                   let name = match["name"] as? String
                {
                    return [name]
                }
            }

            return allHomes
        } catch {
            AppLogger.helper.warning("Failed to fetch home names: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Auto-Restart

    private func autoRestart() async {
        totalRestarts += 1
        autoRestartTimestamps.append(Date())
        let attempt = restartsInWindow
        AppLogger.helper.warning(
            "Auto-restarting helper (attempt \(attempt)/\(self.maxAutoRestarts) in window)"
        )

        state = .starting
        consecutiveFailures = 0
        killHelper()

        try? await Task.sleep(for: .seconds(restartDelay))
        launchHelper()
    }
}

// MARK: - Timeout Helper

/// Runs an async closure with a timeout. Throws `CancellationError` if the deadline is exceeded.
private func withThrowingTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CancellationError()
        }
        // First to finish wins
        guard let result = try await group.next() else {
            throw CancellationError()
        }
        group.cancelAll()
        return result
    }
}
