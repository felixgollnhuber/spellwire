import Foundation

enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let string):
            try container.encode(string)
        case .number(let number):
            try container.encode(number)
        case .bool(let bool):
            try container.encode(bool)
        case .object(let object):
            try container.encode(object)
        case .array(let array):
            try container.encode(array)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self {
            return Int(value)
        }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self {
            return value
        }
        return nil
    }
}

struct EmptyParams: Codable, Sendable {}

struct HelperStatusSnapshot: Codable, Hashable, Sendable {
    let helperVersion: String
    let daemonRunning: Bool
    let appServerRunning: Bool
    let attachmentsRootPath: String
    let socketPath: String
    let logFilePath: String
    let codexHome: String?
    let lastActiveThreadId: String?
    let lastActiveCwd: String?
    let startedAt: String?
    let lastNotificationAt: String?
    let lastError: String?
}

struct CodexRecoverySnippet: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let text: String
    let timestamp: String?
    let source: String
}

struct CodexRecoveryState: Codable, Hashable, Sendable {
    let rolloutPath: String
    let lastEventAt: String?
    let snippets: [CodexRecoverySnippet]
}

struct CodexProject: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let cwd: String
    let title: String
    let threadCount: Int
    let activeThreadCount: Int
    let archivedThreadCount: Int
    let updatedAt: TimeInterval
}

struct CodexThreadSummary: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let projectID: String
    let cwd: String
    let title: String
    let preview: String
    let status: String
    let archived: Bool
    let updatedAt: TimeInterval
    let createdAt: TimeInterval
    let sourceKind: String
    let agentNickname: String?
    let lastTurnID: String?
}

struct CodexTimelineContentPart: Codable, Hashable, Sendable {
    let type: String
    let text: String?
    let path: String?
    let url: String?
    let name: String?

    static func text(_ value: String) -> CodexTimelineContentPart {
        CodexTimelineContentPart(type: "text", text: value, path: nil, url: nil, name: nil)
    }

    static func mention(name: String, path: String?) -> CodexTimelineContentPart {
        CodexTimelineContentPart(type: "mention", text: nil, path: path, url: nil, name: name)
    }

    static func skill(name: String, path: String?) -> CodexTimelineContentPart {
        CodexTimelineContentPart(type: "skill", text: nil, path: path, url: nil, name: name)
    }

    static func image(url: String) -> CodexTimelineContentPart {
        CodexTimelineContentPart(type: "image", text: nil, path: nil, url: url, name: nil)
    }

    static func localImage(path: String) -> CodexTimelineContentPart {
        CodexTimelineContentPart(type: "localImage", text: nil, path: path, url: nil, name: nil)
    }

    var fallbackText: String? {
        switch type {
        case "text":
            return text
        case "mention":
            return "@\(name ?? "mention")"
        case "skill":
            return "$\(name ?? "skill")"
        case "image", "localImage":
            return "[image]"
        default:
            return nil
        }
    }

    static func joinedFallbackText(from parts: [CodexTimelineContentPart]) -> String {
        parts.compactMap(\.fallbackText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func from(jsonValue: JSONValue?) -> [CodexTimelineContentPart]? {
        guard let entries = jsonValue?.arrayValue else { return nil }

        let parts = entries.compactMap { entry -> CodexTimelineContentPart? in
            guard let object = entry.objectValue, let type = object["type"]?.stringValue else {
                return nil
            }

            switch type {
            case "text":
                let text = object["text"]?.stringValue ?? ""
                return .text(text)
            case "mention":
                return .mention(
                    name: object["name"]?.stringValue ?? "mention",
                    path: object["path"]?.stringValue
                )
            case "skill":
                return .skill(
                    name: object["name"]?.stringValue ?? "skill",
                    path: object["path"]?.stringValue
                )
            case "image":
                guard let url = object["url"]?.stringValue, !url.isEmpty else { return nil }
                return .image(url: url)
            case "localImage":
                guard let path = object["path"]?.stringValue, !path.isEmpty else { return nil }
                return .localImage(path: path)
            default:
                return nil
            }
        }

        return parts.isEmpty ? nil : parts
    }
}

struct CodexTimelineItem: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let turnID: String
    let kind: String
    var title: String
    var body: String
    var changedPaths: [String]?
    var content: [CodexTimelineContentPart]?
    var status: String?
    var timestamp: TimeInterval?
    let source: String
}

struct CodexSandboxPolicy: Codable, Hashable, Sendable {
    let type: String
}

struct CodexGitInfo: Codable, Hashable, Sendable {
    let sha: String?
    let branch: String?
    let originURL: String?
}

struct CodexGitStatus: Codable, Hashable, Sendable {
    let cwd: String
    let isRepository: Bool
    let branch: String?
    let hasChanges: Bool
    let additions: Int
    let deletions: Int
    let hasStaged: Bool
    let hasUnstaged: Bool
    let hasUntracked: Bool
    let pushRemote: String?
    let canPush: Bool
    let canCreatePR: Bool
    let defaultBranch: String?
    let blockingReason: String?
}

struct GitDiffLine: Codable, Hashable, Sendable, Identifiable {
    let kind: String
    let text: String
    let oldLineNumber: Int?
    let newLineNumber: Int?

    var id: String {
        "\(kind)|\(oldLineNumber ?? -1)|\(newLineNumber ?? -1)|\(text)"
    }
}

struct GitDiffHunk: Codable, Hashable, Sendable, Identifiable {
    let header: String
    let lines: [GitDiffLine]

    var id: String { header }
}

struct GitDiffFile: Codable, Hashable, Sendable, Identifiable {
    let path: String
    let oldPath: String?
    let newPath: String?
    let status: String
    let additions: Int
    let deletions: Int
    let isBinary: Bool
    let hunks: [GitDiffHunk]

    var id: String { path }
}

struct CodexGitDiff: Codable, Hashable, Sendable {
    let cwd: String
    let branch: String?
    let additions: Int
    let deletions: Int
    let files: [GitDiffFile]
}

enum GitCommitActionID: String, Codable, Hashable, Sendable, Identifiable {
    case commit
    case commitAndPush
    case commitPushAndPR

    var id: String { rawValue }
}

struct GitCommitAction: Codable, Hashable, Sendable, Identifiable {
    let id: GitCommitActionID
    let title: String
    let enabled: Bool
    let reason: String?
}

struct GitCommitPreview: Codable, Hashable, Sendable {
    let cwd: String
    let branch: String?
    let pushRemote: String?
    let defaultBranch: String?
    let defaultCommitMessage: String
    let defaultPRTitle: String
    let defaultPRBody: String
    let actions: [GitCommitAction]
    let warnings: [String]
}

struct GitCommitResult: Codable, Hashable, Sendable {
    let cwd: String
    let commitSHA: String
    let branch: String
    let pushed: Bool
    let prURL: String?
}

struct CodexThreadRuntime: Codable, Hashable, Sendable {
    let cwd: String
    let model: String?
    let modelProvider: String?
    let serviceTier: String?
    let reasoningEffort: String?
    let approvalPolicy: String?
    let sandbox: CodexSandboxPolicy?
    let git: CodexGitInfo?
}

struct CodexThreadDetail: Codable, Hashable, Sendable {
    var thread: CodexThreadSummary
    let project: CodexProject
    var timeline: [CodexTimelineItem]
    var activeTurnID: String?
    let recovery: CodexRecoveryState?
    var runtime: CodexThreadRuntime
}

struct ReasoningEffortOption: Codable, Hashable, Sendable {
    let reasoningEffort: String
    let description: String
}

struct ModelOption: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let hidden: Bool
    let supportedReasoningEfforts: [ReasoningEffortOption]
    let defaultReasoningEffort: String
    let inputModalities: [String]
    let additionalSpeedTiers: [String]
    let isDefault: Bool
}

struct BranchInfo: Codable, Hashable, Sendable, Identifiable {
    var id: String { name }

    let name: String
    let isCurrent: Bool
}

struct BranchSwitchResult: Codable, Hashable, Sendable {
    let cwd: String
    let currentBranch: String
}

struct CodexTurnInputItem: Codable, Hashable, Sendable {
    let type: String
    let text: String?
    let path: String?
    let url: String?
    let name: String?

    static func text(_ value: String) -> CodexTurnInputItem {
        CodexTurnInputItem(type: "text", text: value, path: nil, url: nil, name: nil)
    }

    static func localImage(path: String) -> CodexTurnInputItem {
        CodexTurnInputItem(type: "localImage", text: nil, path: path, url: nil, name: nil)
    }
}

struct TurnMutationResult: Codable, Hashable, Sendable {
    let threadID: String
    let turnID: String
}

struct HelperEventEnvelope: Decodable, Sendable {
    let kind: String
    let event: String
    let data: JSONValue
}

struct HelperResponseErrorPayload: Decodable, Error, Sendable {
    let code: String
    let message: String
}
