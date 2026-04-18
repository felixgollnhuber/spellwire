import Foundation
import Observation

struct OpenedTextDocument: Sendable {
    let session: OpenDocumentSession
    let text: String
    let localURL: URL
}

@MainActor
@Observable
final class BrowserViewModel {
    let host: HostRecord

    var pendingHostKeyChallenge: HostKeyChallenge?

    private let trustStore: HostTrustStore
    private let fileSessionManager: FileSessionManager
    private let workingCopyManager: WorkingCopyManager
    private let conflictResolver: ConflictResolver
    private let previewStore: PreviewStore
    private let fileSystem: SFTPRemoteFileSystem
    private let challengeRelay: BrowserChallengeRelay

    private var pendingTrustReply: ((Bool) -> Void)?

    init(
        host: HostRecord,
        password: String,
        trustStore: HostTrustStore,
        fileSessionManager: FileSessionManager,
        workingCopyManager: WorkingCopyManager,
        conflictResolver: ConflictResolver,
        previewStore: PreviewStore
    ) {
        self.host = host
        self.trustStore = trustStore
        self.fileSessionManager = fileSessionManager
        self.workingCopyManager = workingCopyManager
        self.conflictResolver = conflictResolver
        self.previewStore = previewStore
        let challengeRelay = BrowserChallengeRelay()
        self.challengeRelay = challengeRelay
        fileSystem = SFTPRemoteFileSystem(
            host: host,
            password: password,
            trustedHost: trustStore.trustedHost(for: host.id)
        ) { challenge, reply in
            challengeRelay.handler?(challenge, reply)
        }
        challengeRelay.handler = { [weak self] challenge, reply in
            guard let self else { return }
            self.pendingHostKeyChallenge = challenge
            self.pendingTrustReply = reply
        }
    }

    func resolveHostKeyChallenge(approved: Bool) {
        guard let challenge = pendingHostKeyChallenge else { return }
        if approved {
            try? trustStore.saveTrust(
                TrustedHost(
                    hostID: host.id,
                    openSSHKey: challenge.openSSHKey,
                    fingerprintSHA256: challenge.fingerprint,
                    approvedAt: .now
                )
            )
        }

        pendingHostKeyChallenge = nil
        let reply = pendingTrustReply
        pendingTrustReply = nil
        reply?(approved)
    }

    func initialPath() async throws -> String {
        if let lastVisitedPath = try? fileSessionManager.lastVisitedPath(for: host.id) {
            return try await fileSystem.canonicalize(path: lastVisitedPath)
        }

        let homePath = try await fileSystem.homePath()
        try? fileSessionManager.setLastVisitedPath(homePath, for: host.id)
        return homePath
    }

    func list(path: String) async throws -> [RemoteItem] {
        let resolvedPath = try await fileSystem.canonicalize(path: path)
        try? fileSessionManager.setLastVisitedPath(resolvedPath, for: host.id)
        let items = try await fileSystem.list(path: resolvedPath)
        return items.sorted { lhs, rhs in
            if lhs.metadata.kind == .directory, rhs.metadata.kind != .directory {
                return true
            }
            if lhs.metadata.kind != .directory, rhs.metadata.kind == .directory {
                return false
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func createFolder(named name: String, in parentPath: String) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw RemoteFileError.serverError("Folder name is required.")
        }

        let resolvedParent = try await fileSystem.canonicalize(path: parentPath)
        let folderPath = URL(filePath: resolvedParent)
            .appending(path: trimmedName, directoryHint: .isDirectory)
            .path(percentEncoded: false)

        try await fileSystem.createDirectory(path: folderPath)
    }

    func delete(paths: [String]) async throws {
        for path in paths {
            try await fileSystem.delete(path: path)
        }
    }

    func openTextDocument(path: String) async throws -> OpenedTextDocument {
        let resolvedPath = try await fileSystem.canonicalize(path: path)
        guard let documentKind = FileClassifier.editorKind(for: resolvedPath) else {
            throw RemoteFileError.unsupportedFile(resolvedPath)
        }

        let data = try await fileSystem.readFile(path: resolvedPath)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RemoteFileError.nonUTF8File
        }
        let metadata = try await fileSystem.stat(path: resolvedPath)
        let session = try await workingCopyManager.openSession(
            hostID: host.id,
            remotePath: resolvedPath,
            documentKind: documentKind,
            data: data,
            revision: metadata.revision
        )
        let localURL = await workingCopyManager.localURL(for: session)
        return OpenedTextDocument(session: session, text: text, localURL: localURL)
    }

    func updateWorkingCopy(text: String, session: OpenDocumentSession) async throws -> OpenDocumentSession {
        try await workingCopyManager.updateLocalText(text, for: session)
        return try await workingCopyManager.markDirty(true, for: session.id) ?? session
    }

    func saveTextDocument(
        session: OpenDocumentSession,
        text: String,
        overwriteRemote: Bool
    ) async throws -> OpenDocumentSession {
        let data = Data(text.utf8)
        let currentRevision: RemoteRevision?
        do {
            currentRevision = try await fileSystem.stat(path: session.remotePath).revision
        } catch RemoteFileError.noSuchFile {
            currentRevision = nil
        }

        if !overwriteRemote, await conflictResolver.hasConflict(expected: session.lastKnownRevision, current: currentRevision) {
            throw RemoteFileError.conflict(expected: session.lastKnownRevision, current: currentRevision)
        }

        try await workingCopyManager.updateLocalText(text, for: session)
        try await fileSystem.writeFile(path: session.remotePath, data: data, expectedRevision: session.lastKnownRevision)
        let updatedRevision = try await fileSystem.stat(path: session.remotePath).revision
        return try await workingCopyManager.updateAfterSave(sessionID: session.id, revision: updatedRevision) ?? session
    }

    func reloadTextDocument(path: String) async throws -> OpenedTextDocument {
        try await openTextDocument(path: path)
    }

    func previewURL(path: String) async throws -> URL {
        let resolvedPath = try await fileSystem.canonicalize(path: path)
        let data = try await fileSystem.readFile(path: resolvedPath)
        return try await previewStore.materialize(hostID: host.id, remotePath: resolvedPath, data: data)
    }

    func fileMetadata(path: String) async throws -> RemoteMetadata {
        try await fileSystem.stat(path: path)
    }
}

private final class BrowserChallengeRelay {
    var handler: ((HostKeyChallenge, @escaping (Bool) -> Void) -> Void)?
}
