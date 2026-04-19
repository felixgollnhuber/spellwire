import Foundation

nonisolated struct AppDirectories {
    let applicationSupportDirectory: URL
    let cachesDirectory: URL

    init(applicationSupportDirectory: URL, cachesDirectory: URL) throws {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.cachesDirectory = cachesDirectory

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cachesDirectory, withIntermediateDirectories: true)
    }

    init(fileManager: FileManager = .default) throws {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "xyz.floritzmaier.spellwire-ios"
        let appSupportBase = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let cachesBase = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)

        try self.init(
            applicationSupportDirectory: appSupportBase.appending(path: bundleIdentifier, directoryHint: .isDirectory),
            cachesDirectory: cachesBase.appending(path: bundleIdentifier, directoryHint: .isDirectory)
        )
    }
}

nonisolated struct FileSessionManager {
    private let store: JSONStore<[UUID: String]>

    init(appDirectories: AppDirectories) {
        store = JSONStore(url: appDirectories.applicationSupportDirectory.appending(path: "file-session-state.json"), defaultValue: [:])
    }

    func lastVisitedPath(for hostID: UUID) throws -> String? {
        try store.load()[hostID]
    }

    func setLastVisitedPath(_ path: String, for hostID: UUID) throws {
        var state = try store.load()
        state[hostID] = path
        try store.save(state)
    }

    func clearLastVisitedPath(for hostID: UUID) throws {
        var state = try store.load()
        state.removeValue(forKey: hostID)
        try store.save(state)
    }

    func clearAll() throws {
        try store.save([:])
    }
}
