import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let appDirectories: AppDirectories
    let hostStore: HostStore
    let credentialStore: KeychainCredentialStore
    let trustStore: HostTrustStore
    let browserSettingsStore: BrowserSettingsStore
    let fileSessionManager: FileSessionManager

    private(set) var hosts: [HostRecord] = []
    var selectedHostID: HostRecord.ID?

    init() {
        do {
            let appDirectories = try AppDirectories()
            self.appDirectories = appDirectories
            hostStore = HostStore(appDirectories: appDirectories)
            credentialStore = KeychainCredentialStore()
            trustStore = HostTrustStore(appDirectories: appDirectories)
            browserSettingsStore = BrowserSettingsStore(appDirectories: appDirectories)
            fileSessionManager = FileSessionManager(appDirectories: appDirectories)
            hosts = try hostStore.load()
            selectedHostID = hosts.first?.id
        } catch {
            fatalError("Failed to initialize app model: \(error.localizedDescription)")
        }
    }

    var selectedHost: HostRecord? {
        guard let selectedHostID else { return nil }
        return hosts.first(where: { $0.id == selectedHostID })
    }

    func deleteHosts(at offsets: IndexSet) throws {
        let idsToDelete = offsets.map { hosts[$0].id }
        for offset in offsets.sorted(by: >) {
            hosts.remove(at: offset)
        }
        try hostStore.save(hosts)

        for id in idsToDelete {
            try credentialStore.removePassword(for: id)
            try trustStore.removeTrust(for: id)
            try fileSessionManager.clearLastVisitedPath(for: id)
        }

        if let selectedHostID, !hosts.contains(where: { $0.id == selectedHostID }) {
            self.selectedHostID = hosts.first?.id
        }
    }

    func password(for hostID: HostRecord.ID) -> String {
        (try? credentialStore.password(for: hostID)) ?? ""
    }

    @discardableResult
    func saveHost(from draft: HostEditorDraft, existingID: HostRecord.ID?) throws -> HostRecord {
        let hostname = draft.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let nickname = draft.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let browserURL = draft.browserURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !hostname.isEmpty else {
            throw AppModelError.validation("Host is required.")
        }

        guard !username.isEmpty else {
            throw AppModelError.validation("Username is required.")
        }

        guard let port = Int(draft.port), (1...65535).contains(port) else {
            throw AppModelError.validation("Port must be between 1 and 65535.")
        }

        let tmuxSessionName = draft.useTmux
            ? draft.tmuxSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        let existingRecord = existingID.flatMap { id in
            hosts.first(where: { $0.id == id })
        }

        let record = HostRecord(
            id: existingID ?? UUID(),
            nickname: nickname.isEmpty ? hostname : nickname,
            hostname: hostname,
            port: port,
            username: username,
            browserURLString: browserURL.isEmpty ? nil : browserURL,
            browserUsesTunnel: draft.browserUsesTunnel,
            prefersTmuxResume: draft.useTmux,
            tmuxSessionName: tmuxSessionName?.isEmpty == true ? nil : tmuxSessionName,
            createdAt: existingRecord?.createdAt ?? .now,
            updatedAt: .now
        )

        if let existingID, let index = hosts.firstIndex(where: { $0.id == existingID }) {
            hosts[index] = record
        } else {
            hosts.append(record)
        }

        hosts.sort(using: KeyPathComparator(\.nickname, order: .forward))
        try hostStore.save(hosts)

        let password = draft.password.trimmingCharacters(in: .whitespacesAndNewlines)
        if password.isEmpty {
            try credentialStore.removePassword(for: record.id)
        } else {
            try credentialStore.setPassword(password, for: record.id)
        }

        selectedHostID = record.id
        return record
    }
}

enum AppModelError: LocalizedError {
    case validation(String)

    var errorDescription: String? {
        switch self {
        case let .validation(message):
            return message
        }
    }
}

extension AppModel {
    @MainActor
    static var preview: AppModel {
        let model = AppModel()
        model.hosts = [
            HostRecord(
                nickname: "Production",
                hostname: "prod.example.com",
                username: "deploy",
                browserURLString: "https://localhost:3000",
                browserUsesTunnel: true,
                prefersTmuxResume: true,
                tmuxSessionName: "prod"
            ),
            HostRecord(
                nickname: "Staging",
                hostname: "staging.example.com",
                username: "dev",
                browserURLString: "https://staging.example.com",
                browserUsesTunnel: false,
                prefersTmuxResume: false
            ),
        ]
        model.selectedHostID = model.hosts.first?.id
        return model
    }
}
