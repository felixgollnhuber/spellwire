import Foundation
import UniformTypeIdentifiers

enum RemoteBrowserItemCategory: String, CaseIterable, Sendable {
    case folder
    case code
    case document
    case image
    case pdf
    case archive
    case hidden
    case alias
    case other

    var title: String {
        switch self {
        case .folder:
            return "Folder"
        case .code:
            return "Code"
        case .document:
            return "Document"
        case .image:
            return "Image"
        case .pdf:
            return "PDF"
        case .archive:
            return "Archive"
        case .hidden:
            return "Hidden"
        case .alias:
            return "Alias"
        case .other:
            return "File"
        }
    }

    var systemImage: String {
        switch self {
        case .folder:
            return "folder.fill"
        case .code:
            return "chevron.left.forwardslash.chevron.right"
        case .document:
            return "doc.text.fill"
        case .image:
            return "photo.fill"
        case .pdf:
            return "doc.richtext.fill"
        case .archive:
            return "shippingbox.fill"
        case .hidden:
            return "eye.slash.fill"
        case .alias:
            return "arrowshape.turn.up.right.fill"
        case .other:
            return "doc.fill"
        }
    }
}

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

    static func browserCategory(for item: RemoteItem) -> RemoteBrowserItemCategory {
        if isHidden(name: item.name) {
            return .hidden
        }

        switch item.metadata.kind {
        case .directory:
            return .folder
        case .symlink:
            return .alias
        case .file, .unknown:
            break
        }

        let fileExtension = URL(filePath: item.path).pathExtension.lowercased()
        if imageExtensions.contains(fileExtension) {
            return .image
        }
        if fileExtension == "pdf" {
            return .pdf
        }
        if archiveExtensions.contains(fileExtension) {
            return .archive
        }
        if codeExtensions.contains(fileExtension) {
            return .code
        }
        if documentExtensions.contains(fileExtension) {
            return .document
        }

        switch editorKind(for: item.path) {
        case .swift, .json, .yaml:
            return .code
        case .markdown, .plainText:
            return .document
        case nil:
            return .other
        }
    }

    static func browseSymbolName(for item: RemoteItem) -> String {
        browserCategory(for: item).systemImage
    }

    static func kindDescription(for item: RemoteItem) -> String {
        browserCategory(for: item).title
    }

    static func isHidden(name: String) -> Bool {
        name.hasPrefix(".")
    }

    private static let imageExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "jpeg", "jpg", "png", "svg", "tif", "tiff", "webp"
    ]

    private static let archiveExtensions: Set<String> = [
        "7z", "bz2", "gz", "rar", "tar", "tgz", "xz", "zip"
    ]

    private static let codeExtensions: Set<String> = [
        "bash", "c", "cc", "cpp", "css", "go", "h", "hpp", "html", "java", "js", "json",
        "kt", "m", "mm", "php", "plist", "py", "rb", "rs", "scss", "sh", "sql", "swift",
        "toml", "ts", "tsx", "xml", "yaml", "yml", "zsh"
    ]

    private static let documentExtensions: Set<String> = [
        "csv", "doc", "docx", "log", "markdown", "md", "pages", "rtf", "text", "tsv", "txt"
    ]
}
