import Foundation
import UniformTypeIdentifiers

enum FileClassifier {
    static func utType(for path: String) -> UTType? {
        let fileExtension = URL(filePath: path).pathExtension
        guard !fileExtension.isEmpty else { return nil }
        return UTType(filenameExtension: fileExtension)
    }

    static func editorKind(for path: String) -> EditorDocumentKind? {
        let fileExtension = URL(filePath: path).pathExtension.lowercased()
        switch fileExtension {
        case "txt", "log", "text":
            return .plainText
        case "md", "markdown":
            return .markdown
        case "json":
            return .json
        case "swift":
            return .swift
        case "yaml", "yml":
            return .yaml
        default:
            return nil
        }
    }

    static func isPreviewable(path: String) -> Bool {
        guard let type = utType(for: path) else { return false }
        return type.conforms(to: .pdf) || type.conforms(to: .image)
    }
}
