import Foundation

actor WorkingCopyManager {
    private let sessionsStore: JSONStore<[String: OpenDocumentSession]>
    private let workingCopiesDirectory: URL
    private let fileManager: FileManager

    init(appDirectories: AppDirectories, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        sessionsStore = JSONStore(
            url: appDirectories.applicationSupportDirectory.appending(path: "open-document-sessions.json"),
            defaultValue: [:]
        )
        workingCopiesDirectory = appDirectories.cachesDirectory.appending(path: "WorkingCopies", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: workingCopiesDirectory, withIntermediateDirectories: true)
    }

    func openSession(
        hostID: HostRecord.ID,
        remotePath: String,
        documentKind: EditorDocumentKind,
        data: Data,
        revision: RemoteRevision?
    ) throws -> OpenDocumentSession {
        var sessions = try sessionsStore.load()
        let key = sessionKey(hostID: hostID, remotePath: remotePath)
        var session = sessions[key] ?? OpenDocumentSession(
            id: UUID(),
            hostID: hostID,
            remotePath: remotePath,
            localRelativePath: makeLocalRelativePath(for: remotePath),
            documentKind: documentKind,
            lastKnownRevision: revision,
            dirty: false,
            lastOpenedAt: .now
        )
        let localURL = self.localURL(for: session)
        try fileManager.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: localURL, options: .atomic)
        session.lastKnownRevision = revision
        session.dirty = false
        session.lastOpenedAt = .now
        sessions[key] = session
        try sessionsStore.save(sessions)
        return session
    }

    func text(for session: OpenDocumentSession) throws -> String {
        let localURL = localURL(for: session)
        let data = try Data(contentsOf: localURL)
        guard let string = String(data: data, encoding: .utf8) else {
            throw RemoteFileError.nonUTF8File
        }
        return string
    }

    func updateLocalText(_ text: String, for session: OpenDocumentSession) throws {
        let localURL = localURL(for: session)
        try Data(text.utf8).write(to: localURL, options: .atomic)
    }

    func markDirty(_ dirty: Bool, for sessionID: UUID) throws -> OpenDocumentSession? {
        var sessions = try sessionsStore.load()
        guard let key = sessions.first(where: { $0.value.id == sessionID })?.key,
              var session = sessions[key] else {
            return nil
        }
        session.dirty = dirty
        session.lastOpenedAt = .now
        sessions[key] = session
        try sessionsStore.save(sessions)
        return session
    }

    func updateAfterSave(sessionID: UUID, revision: RemoteRevision?) throws -> OpenDocumentSession? {
        var sessions = try sessionsStore.load()
        guard let key = sessions.first(where: { $0.value.id == sessionID })?.key,
              var session = sessions[key] else {
            return nil
        }
        session.lastKnownRevision = revision
        session.dirty = false
        session.lastOpenedAt = .now
        sessions[key] = session
        try sessionsStore.save(sessions)
        return session
    }

    func localURL(for session: OpenDocumentSession) -> URL {
        workingCopiesDirectory.appending(path: session.localRelativePath)
    }

    func clear(hostID: HostRecord.ID) throws {
        var sessions = try sessionsStore.load()
        let matchingSessions = sessions.values.filter { $0.hostID == hostID }
        for session in matchingSessions {
            try? fileManager.removeItem(at: localURL(for: session))
        }
        sessions = sessions.filter { $0.value.hostID != hostID }
        try sessionsStore.save(sessions)
    }

    private func sessionKey(hostID: HostRecord.ID, remotePath: String) -> String {
        "\(hostID.uuidString)|\(remotePath)"
    }

    private func makeLocalRelativePath(for remotePath: String) -> String {
        let filename = URL(filePath: remotePath).lastPathComponent
        let baseName = filename.isEmpty ? "document" : filename
        return "\(UUID().uuidString)-\(baseName)"
    }
}
