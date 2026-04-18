import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let haptics: HapticsClient
    let appDirectories: AppDirectories
    let hostStore: HostStore
    let identityStore: SSHIdentityStore
    let trustStore: HostTrustStore
    let browserSettingsStore: BrowserSettingsStore
    let projectPreviewPortStore: ProjectPreviewPortStore
    let fileSessionManager: FileSessionManager
    let workingCopyManager: WorkingCopyManager
    let conflictResolver: ConflictResolver
    let previewStore: PreviewStore

    private(set) var sshIdentity: SSHDeviceIdentity
    private(set) var hosts: [HostRecord] = []
    var selectedHostID: HostRecord.ID?
    private var codexServices: [HostRecord.ID: CodexService] = [:]

    init(haptics: HapticsClient? = nil) {
        self.haptics = haptics ?? .live
        do {
            let appDirectories = try AppDirectories()
            self.appDirectories = appDirectories
            hostStore = HostStore(appDirectories: appDirectories)
            identityStore = SSHIdentityStore()
            trustStore = HostTrustStore(appDirectories: appDirectories)
            browserSettingsStore = BrowserSettingsStore(appDirectories: appDirectories)
            projectPreviewPortStore = ProjectPreviewPortStore(appDirectories: appDirectories)
            fileSessionManager = FileSessionManager(appDirectories: appDirectories)
            workingCopyManager = WorkingCopyManager(appDirectories: appDirectories)
            conflictResolver = ConflictResolver()
            previewStore = PreviewStore(appDirectories: appDirectories)
            sshIdentity = try identityStore.loadOrCreateIdentity()
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
        try removeAssociatedData(for: idsToDelete)

        if let selectedHostID, !hosts.contains(where: { $0.id == selectedHostID }) {
            self.selectedHostID = hosts.first?.id
        }
    }

    func deleteHost(id: HostRecord.ID) throws {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        try deleteHosts(at: IndexSet(integer: index))
    }

    func resetEverything() throws {
        let hostIDs = hosts.map(\.id)
        hosts = []
        selectedHostID = nil
        codexServices = [:]

        try hostStore.save([])
        try trustStore.clearAll()
        try fileSessionManager.clearAll()
        try browserSettingsStore.save(.default)
        try projectPreviewPortStore.save([:])
        try identityStore.deleteIdentity()
        sshIdentity = try identityStore.loadOrCreateIdentity()

        clearCachedHostArtifacts(for: hostIDs)
    }

    var publicKeyOpenSSH: String {
        sshIdentity.metadata.publicKeyOpenSSH
    }

    var publicKeyFingerprintSHA256: String {
        sshIdentity.metadata.publicKeyFingerprintSHA256
    }

    func clientIdentity(for username: String) throws -> SSHClientIdentity {
        try sshIdentity.clientIdentity(username: username)
    }

    func codexService(for host: HostRecord) -> CodexService {
        if let existing = codexServices[host.id], existing.host == host {
            return existing
        }

        let service = CodexService(host: host, identity: sshIdentity, trustStore: trustStore, haptics: haptics)
        codexServices[host.id] = service
        return service
    }

    func validatedHostRecord(
        from draft: HostEditorDraft,
        existingID: HostRecord.ID? = nil,
        recordID: HostRecord.ID? = nil
    ) throws -> HostRecord {
        let hostname = draft.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let nickname = draft.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let browserURL = draft.browserURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let browserForwardedPortText = draft.browserForwardedPort.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !hostname.isEmpty else {
            throw AppModelError.validation("Host is required.")
        }

        guard !username.isEmpty else {
            throw AppModelError.validation("Username is required.")
        }

        guard let port = Int(draft.port), (1...65535).contains(port) else {
            throw AppModelError.validation("Port must be between 1 and 65535.")
        }

        let browserForwardedPort: Int?
        if browserForwardedPortText.isEmpty {
            browserForwardedPort = nil
        } else if let parsedPort = Int(browserForwardedPortText), (1...65535).contains(parsedPort) {
            browserForwardedPort = parsedPort
        } else {
            throw AppModelError.validation("Browser forwarded port must be between 1 and 65535.")
        }

        if draft.browserUsesTunnel, browserForwardedPort == nil {
            throw AppModelError.validation("Browser forwarded port is required when using an SSH tunnel.")
        }

        if !draft.browserUsesTunnel, !browserURL.isEmpty, URL(string: browserURL) == nil {
            throw AppModelError.validation("Browser URL is invalid.")
        }

        let tmuxSessionName = draft.useTmux
            ? draft.tmuxSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        let existingRecord = existingID.flatMap { id in
            hosts.first(where: { $0.id == id })
        }

        return HostRecord(
            id: existingID ?? recordID ?? UUID(),
            nickname: nickname.isEmpty ? hostname : nickname,
            hostname: hostname,
            port: port,
            username: username,
            browserURLString: draft.browserUsesTunnel ? nil : (browserURL.isEmpty ? nil : browserURL),
            browserUsesTunnel: draft.browserUsesTunnel,
            browserForwardedPort: browserForwardedPort,
            prefersTmuxResume: draft.useTmux,
            tmuxSessionName: tmuxSessionName?.isEmpty == true ? nil : tmuxSessionName,
            createdAt: existingRecord?.createdAt ?? .now,
            updatedAt: .now
        )
    }

    @discardableResult
    func saveHost(from draft: HostEditorDraft, existingID: HostRecord.ID?) throws -> HostRecord {
        let record = try validatedHostRecord(from: draft, existingID: existingID)

        if let existingID, let index = hosts.firstIndex(where: { $0.id == existingID }) {
            hosts[index] = record
        } else {
            hosts.append(record)
        }

        hosts.sort(using: KeyPathComparator(\.nickname, order: .forward))
        try hostStore.save(hosts)

        selectedHostID = record.id
        return record
    }

    private func removeAssociatedData(for hostIDs: [HostRecord.ID]) throws {
        for id in hostIDs {
            try trustStore.removeTrust(for: id)
            try fileSessionManager.clearLastVisitedPath(for: id)
            codexServices[id] = nil
        }

        clearCachedHostArtifacts(for: hostIDs)
    }

    private func clearCachedHostArtifacts(for hostIDs: [HostRecord.ID]) {
        for id in hostIDs {
            Task {
                try? await workingCopyManager.clear(hostID: id)
                try? await previewStore.clear(hostID: id)
            }
        }
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
                browserURLString: nil,
                browserUsesTunnel: true,
                browserForwardedPort: 3000,
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
