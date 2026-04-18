import Foundation

nonisolated protocol RemoteFileSystem: AnyObject, Sendable {
    func homePath() async throws -> String
    func canonicalize(path: String) async throws -> String
    func list(path: String) async throws -> [RemoteItem]
    func stat(path: String) async throws -> RemoteMetadata
    func readFile(path: String) async throws -> Data
    func writeFile(path: String, data: Data, expectedRevision: RemoteRevision?) async throws
    func createDirectory(path: String) async throws
    func rename(from: String, to: String) async throws
    func delete(path: String) async throws
    func disconnect() async
}

nonisolated struct RemoteItem: Identifiable, Hashable, Codable, Sendable {
    let path: String
    let name: String
    let metadata: RemoteMetadata

    var id: String { path }
}

nonisolated struct RemoteMetadata: Hashable, Codable, Sendable {
    let kind: RemoteItemKind
    let size: Int64?
    let modifiedAt: Date?
    let permissions: UInt32?

    var revision: RemoteRevision {
        RemoteRevision(size: size, modifiedAt: modifiedAt)
    }
}

nonisolated struct RemoteRevision: Hashable, Codable, Sendable {
    let size: Int64?
    let modifiedAt: Date?
}

nonisolated enum RemoteItemKind: String, Codable, Hashable, Sendable {
    case file
    case directory
    case symlink
    case unknown
}

nonisolated enum EditorDocumentKind: String, Codable, Hashable, Sendable {
    case plainText
    case markdown
    case json
    case swift
    case yaml
}

nonisolated struct OpenDocumentSession: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let hostID: HostRecord.ID
    let remotePath: String
    let localRelativePath: String
    let documentKind: EditorDocumentKind
    var lastKnownRevision: RemoteRevision?
    var dirty: Bool
    var lastOpenedAt: Date
}

nonisolated enum RemoteFileError: LocalizedError, Sendable {
    case missingIdentity
    case nonUTF8File
    case unsupportedFile(String)
    case noSuchFile(String)
    case conflict(expected: RemoteRevision?, current: RemoteRevision?)
    case protocolViolation(String)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .missingIdentity:
            return "Spellwire could not load its SSH identity."
        case .nonUTF8File:
            return "This file could not be decoded as UTF-8 text."
        case .unsupportedFile(let path):
            return "Unsupported file: \(path)"
        case .noSuchFile(let path):
            return "The remote file no longer exists: \(path)"
        case .conflict:
            return "The remote file changed since you opened it."
        case .protocolViolation(let message):
            return message
        case .serverError(let message):
            return message
        }
    }
}
