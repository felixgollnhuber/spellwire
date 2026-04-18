import CryptoKit
import Foundation

actor PreviewStore {
    private let previewsDirectory: URL
    private let fileManager: FileManager

    init(appDirectories: AppDirectories, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        previewsDirectory = appDirectories.cachesDirectory.appending(path: "Previews", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: previewsDirectory, withIntermediateDirectories: true)
    }

    func materialize(hostID: HostRecord.ID, remotePath: String, data: Data) throws -> URL {
        let hostDirectory = previewsDirectory.appending(path: hostID.uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: hostDirectory, withIntermediateDirectories: true)

        let ext = URL(filePath: remotePath).pathExtension
        let digest = SHA256.hash(data: Data(remotePath.utf8))
        let filename = digest.compactMap { String(format: "%02x", $0) }.joined() + (ext.isEmpty ? "" : ".\(ext)")
        let url = hostDirectory.appending(path: filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    func clear(hostID: HostRecord.ID) throws {
        let hostDirectory = previewsDirectory.appending(path: hostID.uuidString, directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: hostDirectory.path) else { return }
        try fileManager.removeItem(at: hostDirectory)
    }
}
