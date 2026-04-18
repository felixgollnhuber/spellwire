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
