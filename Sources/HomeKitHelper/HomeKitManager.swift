import HomeKit
import OSLog

/// Central HomeKit interface. Must run on @MainActor because HMHomeManager
/// requires main-thread delegate callbacks.
@MainActor
final class HomeKitManager: NSObject, Observable {
    static let shared = HomeKitManager()

    private let homeManager = HMHomeManager()
    private var homesReady = false
    private var pendingContinuations: [CheckedContinuation<Void, Never>] = []

    private let cache = CharacteristicCache.shared
    private var isWarmingCache = false

    private(set) var homes: [HMHome] = []

    override private init() {
        super.init()
        homeManager.delegate = self
    }

    // MARK: - Readiness

    /// Waits until HomeKit has delivered the initial set of homes.
    func waitForReady() async {
        if homesReady { return }
        await withCheckedContinuation { continuation in
            pendingContinuations.append(continuation)
        }
    }

    var isReady: Bool { homesReady }

    var totalAccessoryCount: Int {
        homes.reduce(0) { $0 + $1.accessories.count }
    }

    // MARK: - Homes

    func listHomes() async -> [[String: Any]] {
        await waitForReady()
        return homes.map { AccessoryModel.homeSummary($0) }
    }

    // MARK: - Rooms

    func listRooms(homeID: String? = nil) async -> [[String: Any]] {
        await waitForReady()
        let targetHomes = filteredHomes(homeID: homeID)
        var result: [[String: Any]] = []
        for home in targetHomes {
            for room in home.rooms {
                let filtered = filterAccessories(room.accessories)
                var dict = AccessoryModel.roomSummary(room, homeID: home.uniqueIdentifier)
                dict["accessory_count"] = filtered.count
                let hName: String? = homes.count > 1 ? home.name : nil
                let hID: String? = homes.count > 1 ? home.uniqueIdentifier.uuidString : nil
                dict["accessories"] = filtered.map { accessory in
                    let id = accessory.uniqueIdentifier.uuidString
                    return AccessoryModel.accessorySummary(accessory, cachedState: cache.cachedState(for: id), homeName: hName, homeID: hID)
                }
                result.append(dict)
            }
        }
        if cache.isStale { Task { await warmCache() } }
        return result
    }

    // MARK: - Accessories

    func listAccessories(homeID: String? = nil, room: String? = nil) async -> [[String: Any]] {
        await waitForReady()
        let targetHomes = filteredHomes(homeID: homeID)
        var accessories: [HMAccessory] = []

        for home in targetHomes {
            if let roomName = room {
                let matchingRooms = home.rooms.filter {
                    $0.name.localizedCaseInsensitiveCompare(roomName) == .orderedSame
                }
                accessories.append(contentsOf: matchingRooms.flatMap(\.accessories))
            } else {
                accessories.append(contentsOf: home.accessories)
            }
        }

        let filtered = filterAccessories(accessories)

        // Pre-compute enrichment data
        let allFiltered = homes.flatMap { filterAccessories($0.accessories) }
        let displayNames = DeviceMap.computeDisplayNames(for: allFiltered)
        let roomZones = buildRoomZoneLookup(for: targetHomes)

        let result = filtered.map { accessory in
            let id = accessory.uniqueIdentifier
            let semanticType = DeviceMap.inferSemanticType(for: accessory)
            let zone: String? = accessory.room.flatMap { roomZones[$0.uniqueIdentifier] }
            let (homeName, hID) = homeInfo(for: accessory)
            return AccessoryModel.accessorySummary(
                accessory,
                cachedState: cache.cachedState(for: id.uuidString),
                zone: zone,
                displayName: displayNames[id],
                semanticType: semanticType.rawValue,
                homeName: homeName,
                homeID: hID
            )
        }
        if cache.isStale { Task { await warmCache() } }
        return result
    }

    func getAccessory(id: String) async -> [String: Any]? {
        await waitForReady()
        guard let accessory = findAccessory(id: id) else { return nil }
        guard isAccessoryAllowed(accessory) else { return nil }
        await readAllValues(for: accessory)
        updateCacheFromAccessory(accessory)
        let (homeName, hID) = homeInfo(for: accessory)
        return AccessoryModel.accessoryDetail(accessory, homeName: homeName, homeID: hID)
    }

    // MARK: - Control

    enum ControlError: Error, LocalizedError {
        case accessoryNotFound(String)
        case accessoryUnreachable(String)
        case characteristicNotFound(String)
        case characteristicNotWritable(String)
        case invalidValue(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .accessoryNotFound(let id): "Accessory not found: \(id)"
            case .accessoryUnreachable(let name): "Accessory unreachable: \(name)"
            case .characteristicNotFound(let name): "Characteristic not found: \(name)"
            case .characteristicNotWritable(let name): "Characteristic not writable: \(name)"
            case .invalidValue(let detail): "Invalid value: \(detail)"
            case .writeFailed(let detail): "Write failed: \(detail)"
            }
        }
    }

    func controlAccessory(id: String, characteristic: String, value: String) async throws -> [String: Any] {
        await waitForReady()

        guard let accessory = findAccessory(id: id) else {
            throw ControlError.accessoryNotFound(id)
        }
        guard isAccessoryAllowed(accessory) else {
            throw ControlError.accessoryNotFound(id)
        }
        guard accessory.isReachable else {
            throw ControlError.accessoryUnreachable(accessory.name)
        }

        // Find the characteristic by human-readable name or UUID
        guard let (hmCharacteristic, _) = findCharacteristic(named: characteristic, on: accessory) else {
            throw ControlError.characteristicNotFound(characteristic)
        }

        // Check writability via properties
        let properties = hmCharacteristic.properties
        guard properties.contains(HMCharacteristicPropertyWritable) else {
            throw ControlError.characteristicNotWritable(characteristic)
        }

        // Parse value
        guard let parsedValue = CharacteristicMapper.parseValue(value, for: hmCharacteristic) else {
            throw ControlError.invalidValue("Cannot parse '\(value)' for \(characteristic)")
        }

        // Write
        do {
            try await hmCharacteristic.writeValue(parsedValue)
            HelperLogger.homekit.info("Set \(accessory.name).\(characteristic) = \(value)")
        } catch {
            throw ControlError.writeFailed("\(error.localizedDescription)")
        }

        // Read back current values, update cache, and return updated state
        await readInterestingValues(for: accessory)
        updateCacheFromAccessory(accessory)
        let (homeName, hID) = homeInfo(for: accessory)
        return AccessoryModel.accessorySummary(accessory, homeName: homeName, homeID: hID)
    }

    // MARK: - Scenes

    func listScenes(homeID: String? = nil) async -> [[String: Any]] {
        await waitForReady()
        let targetHomes = filteredHomes(homeID: homeID)
        return targetHomes.flatMap { home in
            home.actionSets.map { AccessoryModel.sceneSummary($0, homeID: home.uniqueIdentifier) }
        }
    }

    func triggerScene(id: String) async throws -> [String: Any] {
        await waitForReady()

        for home in homes {
            if let actionSet = home.actionSets.first(where: { $0.uniqueIdentifier.uuidString == id }) {
                try await home.executeActionSet(actionSet)
                HelperLogger.homekit.info("Triggered scene: \(actionSet.name)")
                return AccessoryModel.sceneSummary(actionSet, homeID: home.uniqueIdentifier)
            }
        }

        // Try by name
        for home in homes {
            if let actionSet = home.actionSets.first(where: {
                $0.name.localizedCaseInsensitiveCompare(id) == .orderedSame
            }) {
                try await home.executeActionSet(actionSet)
                HelperLogger.homekit.info("Triggered scene: \(actionSet.name)")
                return AccessoryModel.sceneSummary(actionSet, homeID: home.uniqueIdentifier)
            }
        }

        throw ControlError.accessoryNotFound("Scene not found: \(id)")
    }

    // MARK: - Search

    func searchAccessories(query: String, category: String? = nil, homeID: String? = nil) async -> [[String: Any]] {
        await waitForReady()
        let lowercasedQuery = query.lowercased()
        let targetHomes = filteredHomes(homeID: homeID)

        // Pre-compute enrichment data for display names and aliases
        let allFiltered = targetHomes.flatMap { filterAccessories($0.accessories) }
        let displayNames = DeviceMap.computeDisplayNames(for: allFiltered)

        var results: [HMAccessory] = []
        for home in targetHomes {
            for accessory in home.accessories {
                // Existing matches
                let nameMatch = accessory.name.lowercased().contains(lowercasedQuery)
                let roomMatch = accessory.room?.name.lowercased().contains(lowercasedQuery) ?? false
                let catName = CharacteristicMapper.inferredCategoryName(for: accessory)
                let catMatch = catName.contains(lowercasedQuery)

                // New matches
                let semanticType = DeviceMap.inferSemanticType(for: accessory)
                let semanticMatch = semanticType.rawValue.contains(lowercasedQuery)

                let displayName = displayNames[accessory.uniqueIdentifier] ?? accessory.name
                let displayNameMatch = displayName.lowercased().contains(lowercasedQuery)

                let manufacturerMatch =
                    accessory.manufacturer?.lowercased().contains(lowercasedQuery) ?? false

                let aliases = DeviceMap.generateAliases(
                    accessory: accessory, semanticType: semanticType,
                    category: catName, accessories: allFiltered
                )
                let aliasMatch = aliases.contains { $0.contains(lowercasedQuery) }

                if nameMatch || roomMatch || catMatch || semanticMatch || displayNameMatch
                    || manufacturerMatch || aliasMatch
                {
                    results.append(accessory)
                }
            }
        }

        // Filter by category if specified
        if let category {
            results = results.filter {
                CharacteristicMapper.inferredCategoryName(for: $0)
                    .localizedCaseInsensitiveCompare(category) == .orderedSame
            }
        }

        let filtered = filterAccessories(results)
        let roomZones = buildRoomZoneLookup(for: targetHomes)

        let output = filtered.map { accessory in
            let id = accessory.uniqueIdentifier
            let semanticType = DeviceMap.inferSemanticType(for: accessory)
            let zone: String? = accessory.room.flatMap { roomZones[$0.uniqueIdentifier] }
            let (homeName, hID) = homeInfo(for: accessory)
            return AccessoryModel.accessorySummary(
                accessory,
                cachedState: cache.cachedState(for: id.uuidString),
                zone: zone,
                displayName: displayNames[id],
                semanticType: semanticType.rawValue,
                homeName: homeName,
                homeID: hID
            )
        }
        if cache.isStale { Task { await warmCache() } }
        return output
    }

    // MARK: - Device Map

    func deviceMap(homeID: String? = nil) async -> [String: Any] {
        await waitForReady()
        let targetHomes = filteredHomes(homeID: homeID)
        let result = DeviceMap.buildMap(homes: targetHomes, filter: filterAccessories, cache: cache)
        if cache.isStale { Task { await warmCache() } }
        return result
    }

    // MARK: - Unfiltered (Settings UI)

    /// Returns ALL accessories across all homes, ignoring filter settings.
    /// Used by the settings UI to populate the device checkbox list.
    func listAllAccessories() async -> [[String: Any]] {
        await waitForReady()
        return homes.flatMap { home in
            home.accessories.map { accessory in
                var dict: [String: Any] = [
                    "id": accessory.uniqueIdentifier.uuidString,
                    "name": accessory.name,
                    "category": CharacteristicMapper.categoryName(for: accessory.category.categoryType),
                    "home_name": home.name,
                    "home_id": home.uniqueIdentifier.uuidString,
                ]
                if let room = accessory.room {
                    dict["room"] = room.name
                }
                return dict
            }
        }
    }

    // MARK: - Cache

    /// Warms the cache by reading interesting values from all filtered accessories.
    /// Skips unreachable devices (retains their last known cached values).
    func warmCache() async {
        guard !isWarmingCache else { return }
        isWarmingCache = true
        defer { isWarmingCache = false }

        let start = Date()
        let allAccessories = homes.flatMap(\.accessories)
        let filtered = filterAccessories(allAccessories)
        let ids = filtered.map(\.uniqueIdentifier.uuidString)
        let currentHash = CharacteristicCache.computeDeviceHash(accessoryIDs: ids)

        // If device set changed, invalidate stale entries
        if !cache.deviceHashMatches(currentHash) {
            cache.invalidateValues()
            HelperLogger.homekit.info("Device set changed, cache invalidated")
        }

        var warmedCount = 0
        for accessory in filtered {
            guard accessory.isReachable else { continue }

            var state: [String: String] = [:]
            for service in accessory.services {
                for characteristic in service.characteristics {
                    let name = CharacteristicMapper.name(for: characteristic.characteristicType)
                    if AccessoryModel.isInterestingState(name) {
                        try? await characteristic.readValue()
                        state[name] = CharacteristicMapper.formatValue(
                            characteristic.value, for: characteristic.characteristicType
                        )
                    }
                }
            }
            if !state.isEmpty {
                cache.setValues(for: accessory.uniqueIdentifier.uuidString, state: state)
            }
            warmedCount += 1
            // Yield between accessories so other MainActor work (socket requests, UI) can run
            await Task.yield()
        }

        cache.markWarmed(deviceHash: currentHash)
        let elapsed = Date().timeIntervalSince(start)
        HelperLogger.homekit.info(
            "Cache warmed: \(warmedCount)/\(filtered.count) accessories in \(String(format: "%.1f", elapsed))s"
        )
    }

    /// Extracts interesting state from an accessory after a live read and updates the cache.
    private func updateCacheFromAccessory(_ accessory: HMAccessory) {
        var state: [String: String] = [:]
        for service in accessory.services {
            for characteristic in service.characteristics {
                let name = CharacteristicMapper.name(for: characteristic.characteristicType)
                if AccessoryModel.isInterestingState(name) {
                    state[name] = CharacteristicMapper.formatValue(
                        characteristic.value, for: characteristic.characteristicType
                    )
                }
            }
        }
        if !state.isEmpty {
            cache.setValues(for: accessory.uniqueIdentifier.uuidString, state: state)
            cache.save()
        }
    }

    /// Force-refreshes the cache. Returns stats for the socket command.
    func refreshCache() async -> [String: Any] {
        await warmCache()
        return [
            "cached_accessories": cache.cachedAccessoryCount,
            "is_stale": cache.isStale,
            "last_warmed": cache.lastWarmedString as Any,
        ]
    }

    // MARK: - Value Reading

    /// Reads current values for "interesting" state characteristics on an accessory.
    /// Call before AccessoryModel.accessorySummary() so cached values are populated.
    private func readInterestingValues(for accessory: HMAccessory) async {
        guard accessory.isReachable else { return }
        for service in accessory.services {
            for characteristic in service.characteristics {
                let name = CharacteristicMapper.name(for: characteristic.characteristicType)
                if AccessoryModel.isInterestingState(name) {
                    try? await characteristic.readValue()
                }
            }
        }
    }

    /// Reads all readable characteristic values for a single accessory.
    /// Call before AccessoryModel.accessoryDetail() so cached values are populated.
    private func readAllValues(for accessory: HMAccessory) async {
        guard accessory.isReachable else { return }
        for service in accessory.services {
            for characteristic in service.characteristics {
                if characteristic.properties.contains(HMCharacteristicPropertyReadable) {
                    try? await characteristic.readValue()
                }
            }
        }
    }

    // MARK: - Private Helpers

    /// Builds a room UUID → zone name lookup table for enrichment.
    private func buildRoomZoneLookup(for targetHomes: [HMHome]) -> [UUID: String] {
        var roomZones: [UUID: String] = [:]
        for home in targetHomes {
            let zones = DeviceMap.resolveZones(for: home)
            for zone in zones {
                for room in zone.rooms {
                    roomZones[room.uniqueIdentifier] = zone.name
                }
            }
        }
        return roomZones
    }

    private func filterAccessories(_ accessories: [HMAccessory]) -> [HMAccessory] {
        let config = HelperConfig.shared
        guard config.filterMode == "allowlist",
              let allowed = config.allowedIDs
        else { return accessories }
        return accessories.filter { allowed.contains($0.uniqueIdentifier.uuidString) }
    }

    private func isAccessoryAllowed(_ accessory: HMAccessory) -> Bool {
        let config = HelperConfig.shared
        guard config.filterMode == "allowlist",
              let allowed = config.allowedIDs
        else { return true }
        return allowed.contains(accessory.uniqueIdentifier.uuidString)
    }

    /// Returns (homeName, homeID) for an accessory, or (nil, nil) if there's only one home.
    /// Only populates when multiple homes exist to keep responses clean.
    private func homeInfo(for accessory: HMAccessory) -> (String?, String?) {
        guard homes.count > 1 else { return (nil, nil) }
        for home in homes where home.accessories.contains(where: { $0.uniqueIdentifier == accessory.uniqueIdentifier }) {
            return (home.name, home.uniqueIdentifier.uuidString)
        }
        return (nil, nil)
    }

    private func filteredHomes(homeID: String?) -> [HMHome] {
        // Use explicit homeID if provided, otherwise fall back to configured default
        let effectiveID = homeID ?? HelperConfig.shared.defaultHomeID
        guard let effectiveID else { return homes }

        // Match by UUID first, then by name
        let byUUID = homes.filter { $0.uniqueIdentifier.uuidString == effectiveID }
        if !byUUID.isEmpty { return byUUID }

        let byName = homes.filter { $0.name.localizedCaseInsensitiveCompare(effectiveID) == .orderedSame }
        return byName.isEmpty ? homes : byName
    }

    private func findAccessory(id: String) -> HMAccessory? {
        // Try UUID first
        for home in homes {
            if let accessory = home.accessories.first(where: { $0.uniqueIdentifier.uuidString == id }) {
                return accessory
            }
        }
        // Try name match
        for home in homes {
            if let accessory = home.accessories.first(where: {
                $0.name.localizedCaseInsensitiveCompare(id) == .orderedSame
            }) {
                return accessory
            }
        }
        return nil
    }

    private func findCharacteristic(
        named name: String, on accessory: HMAccessory
    ) -> (HMCharacteristic, String)? {
        for service in accessory.services {
            for characteristic in service.characteristics {
                let humanName = CharacteristicMapper.name(for: characteristic.characteristicType)
                if humanName.localizedCaseInsensitiveCompare(name) == .orderedSame
                    || characteristic.characteristicType == name
                {
                    return (characteristic, humanName)
                }
            }
        }
        return nil
    }
}

// MARK: - HMHomeManagerDelegate

extension HomeKitManager: HMHomeManagerDelegate {
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in
            homes = manager.homes
            HelperLogger.homekit.info(
                "HomeKit updated: \(manager.homes.count) home(s), \(self.totalAccessoryCount) accessory(ies)"
            )

            if !homesReady {
                homesReady = true
                for continuation in pendingContinuations {
                    continuation.resume()
                }
                pendingContinuations.removeAll()
            }

            // Warm cache after initial load and device set changes
            Task { await self.warmCache() }
        }
    }
}
