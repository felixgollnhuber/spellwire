import Foundation

actor ChatAttachmentStager {
    private let fileSystem: SFTPRemoteFileSystem

    init(host: HostRecord, identity: SSHDeviceIdentity, trustStore: HostTrustStore) {
        fileSystem = try! SFTPRemoteFileSystem(
            host: host,
            identity: identity.clientIdentity(username: host.username),
            trustedHost: trustStore.trustedHost(for: host.id)
        ) { _, reply in
            reply(false)
        }
    }

    func stageImages(localURLs: [URL], threadID: String, attachmentsRootPath: String) async throws -> [String] {
        guard !localURLs.isEmpty else { return [] }

        let threadDirectory = URL(filePath: attachmentsRootPath)
            .appending(path: sanitizedThreadID(threadID), directoryHint: .isDirectory)
            .path(percentEncoded: false)

        try? await fileSystem.createDirectory(path: threadDirectory)

        return try await localURLs.asyncMap { localURL in
            let data = try Data(contentsOf: localURL)
            let ext = localURL.pathExtension.isEmpty ? "png" : localURL.pathExtension
            let remotePath = URL(filePath: threadDirectory)
                .appending(path: "\(UUID().uuidString).\(ext)")
                .path(percentEncoded: false)
            try await fileSystem.writeFile(path: remotePath, data: data, expectedRevision: nil)
            return remotePath
        }
    }

    private func sanitizedThreadID(_ threadID: String) -> String {
        threadID
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async throws -> [T] {
        var results: [T] = []
        results.reserveCapacity(count)
        for element in self {
            results.append(try await transform(element))
        }
        return results
    }
}
