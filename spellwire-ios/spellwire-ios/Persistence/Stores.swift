import Foundation
import Security

nonisolated private enum PersistenceError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Security framework error \(status)"
        }
    }
}

nonisolated struct JSONStore<Value: Codable> {
    let url: URL
    let defaultValue: Value

    func load() throws -> Value {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return defaultValue
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Value.self, from: data)
    }

    func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}

nonisolated struct HostStore {
    private let store: JSONStore<[HostRecord]>

    init(appDirectories: AppDirectories) {
        store = JSONStore(url: appDirectories.applicationSupportDirectory.appending(path: "hosts.json"), defaultValue: [])
    }

    func load() throws -> [HostRecord] {
        try store.load()
    }

    func save(_ hosts: [HostRecord]) throws {
        try store.save(hosts)
    }
}

nonisolated struct HostTrustStore {
    private let store: JSONStore<[UUID: TrustedHost]>

    init(appDirectories: AppDirectories) {
        store = JSONStore(url: appDirectories.applicationSupportDirectory.appending(path: "trusted-hosts.json"), defaultValue: [:])
    }

    func load() throws -> [UUID: TrustedHost] {
        try store.load()
    }

    func save(_ trustEntries: [UUID: TrustedHost]) throws {
        try store.save(trustEntries)
    }

    func trustedHost(for hostID: UUID) -> TrustedHost? {
        try? load()[hostID]
    }

    func saveTrust(_ trustedHost: TrustedHost) throws {
        var entries = try load()
        entries[trustedHost.hostID] = trustedHost
        try save(entries)
    }

    func removeTrust(for hostID: UUID) throws {
        var entries = try load()
        entries.removeValue(forKey: hostID)
        try save(entries)
    }

    func clearAll() throws {
        try save([:])
    }
}

nonisolated struct BrowserSettingsStore {
    private let store: JSONStore<BrowserSettings>

    init(appDirectories: AppDirectories) {
        store = JSONStore(url: appDirectories.applicationSupportDirectory.appending(path: "browser-settings.json"), defaultValue: .default)
    }

    func load() throws -> BrowserSettings {
        try store.load()
    }

    func save(_ settings: BrowserSettings) throws {
        try store.save(settings)
    }
}

nonisolated struct ProjectPreviewPortStore {
    private let store: JSONStore<[String: Int]>

    init(appDirectories: AppDirectories) {
        store = JSONStore(
            url: appDirectories.applicationSupportDirectory.appending(path: "project-preview-ports.json"),
            defaultValue: [:]
        )
    }

    func load() throws -> [String: Int] {
        try store.load()
    }

    func save(_ ports: [String: Int]) throws {
        try store.save(ports)
    }

    func previewPort(hostID: HostRecord.ID, cwd: String) throws -> Int? {
        try load()[key(hostID: hostID, cwd: cwd)]
    }

    func setPreviewPort(_ port: Int, hostID: HostRecord.ID, cwd: String) throws {
        var ports = try load()
        ports[key(hostID: hostID, cwd: cwd)] = port
        try save(ports)
    }

    func removePreviewPort(hostID: HostRecord.ID, cwd: String) throws {
        var ports = try load()
        ports.removeValue(forKey: key(hostID: hostID, cwd: cwd))
        try save(ports)
    }

    private func key(hostID: HostRecord.ID, cwd: String) -> String {
        "\(hostID.uuidString)|\(cwd)"
    }
}

nonisolated struct CodexWorkspaceSnapshotStore {
    private let store: JSONStore<[UUID: CodexWorkspaceSnapshot]>

    init(appDirectories: AppDirectories) {
        store = JSONStore(
            url: appDirectories.applicationSupportDirectory.appending(path: "codex-workspace-snapshots.json"),
            defaultValue: [:]
        )
    }

    func load() throws -> [UUID: CodexWorkspaceSnapshot] {
        try store.load()
    }

    func snapshot(for hostID: HostRecord.ID) throws -> CodexWorkspaceSnapshot? {
        try load()[hostID]
    }

    func saveSnapshot(_ snapshot: CodexWorkspaceSnapshot) throws {
        var snapshots = try load()
        snapshots[snapshot.hostID] = snapshot
        try store.save(snapshots)
    }

    func removeSnapshot(for hostID: HostRecord.ID) throws {
        var snapshots = try load()
        snapshots.removeValue(forKey: hostID)
        try store.save(snapshots)
    }

    func clearAll() throws {
        try store.save([:])
    }
}

nonisolated struct CodexThreadDetailCacheStore {
    private static let maxEntriesPerHost = 10

    private let store: JSONStore<[UUID: [CachedThreadDetailEntry]]>

    init(appDirectories: AppDirectories) {
        store = JSONStore(
            url: appDirectories.applicationSupportDirectory.appending(path: "codex-thread-details.json"),
            defaultValue: [:]
        )
    }

    func load() throws -> [UUID: [CachedThreadDetailEntry]] {
        try store.load()
    }

    func entries(for hostID: HostRecord.ID) throws -> [CachedThreadDetailEntry] {
        try load()[hostID] ?? []
    }

    func entry(for hostID: HostRecord.ID, threadID: String) throws -> CachedThreadDetailEntry? {
        try entries(for: hostID).first(where: { $0.threadID == threadID })
    }

    func saveEntry(_ entry: CachedThreadDetailEntry) throws {
        var allEntries = try load()
        var hostEntries = allEntries[entry.hostID] ?? []
        hostEntries.removeAll { $0.threadID == entry.threadID }
        hostEntries.insert(entry, at: 0)
        hostEntries.sort { $0.lastOpenedAt > $1.lastOpenedAt }
        allEntries[entry.hostID] = Array(hostEntries.prefix(Self.maxEntriesPerHost))
        try store.save(allEntries)
    }

    func removeEntries(for hostID: HostRecord.ID) throws {
        var allEntries = try load()
        allEntries.removeValue(forKey: hostID)
        try store.save(allEntries)
    }

    func clearAll() throws {
        try store.save([:])
    }
}

nonisolated struct CodexMetadataCacheStore {
    private static let maxBranchEntriesPerHost = 10

    private struct MetadataEnvelope: Codable {
        var modelsByHost: [UUID: CachedModelListEntry]
        var branchesByHost: [UUID: [CachedBranchListEntry]]
    }

    private let store: JSONStore<MetadataEnvelope>

    init(appDirectories: AppDirectories) {
        store = JSONStore(
            url: appDirectories.applicationSupportDirectory.appending(path: "codex-metadata-cache.json"),
            defaultValue: MetadataEnvelope(modelsByHost: [:], branchesByHost: [:])
        )
    }

    func cachedModels(for hostID: HostRecord.ID) throws -> CachedModelListEntry? {
        try store.load().modelsByHost[hostID]
    }

    func saveModels(_ entry: CachedModelListEntry) throws {
        var envelope = try store.load()
        envelope.modelsByHost[entry.hostID] = entry
        try store.save(envelope)
    }

    func cachedBranches(for hostID: HostRecord.ID, cwd: String) throws -> CachedBranchListEntry? {
        try store.load().branchesByHost[hostID]?.first(where: { $0.cwd == cwd })
    }

    func saveBranches(_ entry: CachedBranchListEntry) throws {
        var envelope = try store.load()
        var branches = envelope.branchesByHost[entry.hostID] ?? []
        branches.removeAll { $0.cwd == entry.cwd }
        branches.insert(entry, at: 0)
        branches.sort { $0.lastOpenedAt > $1.lastOpenedAt }
        envelope.branchesByHost[entry.hostID] = Array(branches.prefix(Self.maxBranchEntriesPerHost))
        try store.save(envelope)
    }

    func removeEntries(for hostID: HostRecord.ID) throws {
        var envelope = try store.load()
        envelope.modelsByHost.removeValue(forKey: hostID)
        envelope.branchesByHost.removeValue(forKey: hostID)
        try store.save(envelope)
    }

    func clearAll() throws {
        try store.save(MetadataEnvelope(modelsByHost: [:], branchesByHost: [:]))
    }
}
