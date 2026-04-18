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

nonisolated struct KeychainCredentialStore {
    private let service = "\(Bundle.main.bundleIdentifier ?? "xyz.floritzmaier.spellwire-ios").host-password"

    func password(for hostID: UUID) throws -> String? {
        var query = baseQuery(for: hostID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw PersistenceError.unexpectedStatus(status)
        }
    }

    func setPassword(_ password: String, for hostID: UUID) throws {
        let data = Data(password.utf8)
        let query = baseQuery(for: hostID)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var createQuery = query
            createQuery[kSecValueData as String] = data
            let createStatus = SecItemAdd(createQuery as CFDictionary, nil)
            guard createStatus == errSecSuccess else {
                throw PersistenceError.unexpectedStatus(createStatus)
            }
        default:
            throw PersistenceError.unexpectedStatus(updateStatus)
        }
    }

    func removePassword(for hostID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: hostID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PersistenceError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for hostID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostID.uuidString,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }
}
