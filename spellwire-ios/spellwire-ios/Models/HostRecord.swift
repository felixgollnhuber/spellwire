import Foundation

nonisolated struct HostRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var nickname: String
    var hostname: String
    var port: Int
    var username: String
    var browserURLString: String?
    var browserUsesTunnel: Bool
    var prefersTmuxResume: Bool
    var tmuxSessionName: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        nickname: String,
        hostname: String,
        port: Int = 22,
        username: String,
        browserURLString: String? = nil,
        browserUsesTunnel: Bool = false,
        prefersTmuxResume: Bool = true,
        tmuxSessionName: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.nickname = nickname
        self.hostname = hostname
        self.port = port
        self.username = username
        self.browserURLString = browserURLString
        self.browserUsesTunnel = browserUsesTunnel
        self.prefersTmuxResume = prefersTmuxResume
        self.tmuxSessionName = tmuxSessionName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var connectionSummary: String {
        "\(username)@\(hostname):\(port)"
    }

    var browserURL: URL? {
        guard let browserURLString else { return nil }
        return URL(string: browserURLString)
    }
}

nonisolated struct TrustedHost: Codable, Hashable {
    let hostID: HostRecord.ID
    let openSSHKey: String
    let fingerprintSHA256: String
    let approvedAt: Date
}

nonisolated struct BrowserSettings: Codable, Hashable {
    var defaultScheme: String
    var opensInReaderMode: Bool

    nonisolated static let `default` = BrowserSettings(defaultScheme: "https", opensInReaderMode: false)
}
