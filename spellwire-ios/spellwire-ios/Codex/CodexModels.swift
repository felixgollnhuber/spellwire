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

struct CodexTimelineItem: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let turnID: String
    let kind: String
    var title: String
    var body: String
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
