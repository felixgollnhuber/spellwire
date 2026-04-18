import Foundation
import Observation

@MainActor
@Observable
final class CodexService {
    private static let workspaceStaleAfter: TimeInterval = 12

    let host: HostRecord

    var helperStatus: HelperStatusSnapshot?
    var projects: [CodexProject] = []
    var threads: [CodexThreadSummary] = []
    var selectedThread: CodexThreadSummary?
    var threadDetail: CodexThreadDetail?
    var showsArchived = false
    var isLoadingList = false
    var isLoadingThread = false
    var pendingHostKeyChallenge: HostKeyChallenge?
    var errorMessage: String?

    private let trustStore: HostTrustStore
    private let client: HelperRPCClient
    private var pendingTrustReply: ((Bool) -> Void)?
    private var listRefreshTask: Task<Void, Never>?
    private var threadRefreshTask: Task<Void, Never>?
    private var lastWorkspaceRefreshAt: Date?

    init(host: HostRecord, identity: SSHDeviceIdentity, trustStore: HostTrustStore) {
        self.host = host
        self.trustStore = trustStore
        var challengeHandler: ((HostKeyChallenge, @escaping (Bool) -> Void) -> Void)?
        client = HelperRPCClient(
            host: host,
            identity: identity,
            trustedHost: trustStore.trustedHost(for: host.id)
        ) { challenge, reply in
            challengeHandler?(challenge, reply)
        }
        challengeHandler = { [weak self] challenge, reply in
            guard let self else { return }
            self.pendingHostKeyChallenge = challenge
            self.pendingTrustReply = reply
        }
        client.eventHandler = { [weak self] event in
            self?.handle(event: event)
        }
    }

    func loadInitialData() async {
        await refreshWorkspace()
    }

    func refreshWorkspace(showArchived: Bool? = nil) async {
        if let showArchived {
            showsArchived = showArchived
        }

        if shouldInvalidateWorkspaceSnapshot {
            helperStatus = nil
            projects = []
            threads = []
        }

        isLoadingList = true
        defer { isLoadingList = false }

        do {
            helperStatus = try await client.request(method: "helper.status", params: EmptyParams())
            projects = try await client.request(method: "projects.list", params: EmptyParams())
            threads = try await client.request(
                method: "threads.list",
                params: ThreadsQuery(projectID: nil, query: nil, archived: showsArchived, limit: nil)
            )
            lastWorkspaceRefreshAt = .now
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(_ thread: CodexThreadSummary) async {
        selectedThread = thread
        await loadThread(method: "threads.open")
    }

    func createThread(in project: CodexProject) async -> CodexThreadSummary? {
        do {
            let created: CodexThreadSummary = try await client.request(
                method: "threads.create",
                params: ThreadCreateRequest(cwd: project.cwd)
            )
            if let existingIndex = threads.firstIndex(where: { $0.id == created.id }) {
                threads[existingIndex] = created
            } else {
                threads.insert(created, at: 0)
            }
            errorMessage = nil
            scheduleWorkspaceRefresh()
            return created
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func refreshSelectedThread() async {
        await loadThread(method: "threads.read")
    }

    func send(prompt: String) async {
        guard let selectedThread else { return }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        let pendingID = "local:\(UUID().uuidString)"
        if threadDetail?.thread.id == selectedThread.id {
            threadDetail?.timeline.append(
                CodexTimelineItem(
                    id: pendingID,
                    turnID: selectedThread.lastTurnID ?? "pending",
                    kind: "userMessage",
                    title: "You",
                    body: trimmedPrompt,
                    status: "pending",
                    timestamp: Date().timeIntervalSince1970,
                    source: "canonical"
                )
            )
        }

        do {
            let mutation: TurnMutationResult = try await client.request(
                method: "turns.start",
                params: TurnPromptRequest(threadID: selectedThread.id, prompt: trimmedPrompt)
            )
            threadDetail?.activeTurnID = mutation.turnID
            scheduleThreadRefresh()
            scheduleWorkspaceRefresh()
            errorMessage = nil
        } catch {
            if let index = threadDetail?.timeline.firstIndex(where: { $0.id == pendingID }) {
                threadDetail?.timeline.remove(at: index)
            }
            errorMessage = error.localizedDescription
        }
    }

    func interrupt() async {
        guard let selectedThread, let turnID = threadDetail?.activeTurnID else { return }

        do {
            let _: TurnMutationResult = try await client.request(
                method: "turns.interrupt",
                params: TurnInterruptRequest(threadID: selectedThread.id, turnID: turnID)
            )
            threadDetail?.activeTurnID = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openOnMac() async {
        guard let selectedThread else { return }
        do {
            let _: DesktopOpenResponse = try await client.request(
                method: "desktop.open",
                params: DesktopOpenRequest(threadID: selectedThread.id)
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resolveHostKeyChallenge(approved: Bool) {
        guard let challenge = pendingHostKeyChallenge else { return }
        if approved {
            let trustedHost = TrustedHost(
                hostID: host.id,
                openSSHKey: challenge.openSSHKey,
                fingerprintSHA256: challenge.fingerprint,
                approvedAt: .now
            )
            try? trustStore.saveTrust(trustedHost)
            client.updateTrustedHost(trustedHost)
        }

        pendingHostKeyChallenge = nil
        let reply = pendingTrustReply
        pendingTrustReply = nil
        reply?(approved)
    }

    func threadsForProject(projectID: String, matching query: String) -> [CodexThreadSummary] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return threads
            .filter { $0.projectID == projectID }
            .filter {
                normalizedQuery.isEmpty
                    || $0.title.localizedCaseInsensitiveContains(normalizedQuery)
                    || $0.preview.localizedCaseInsensitiveContains(normalizedQuery)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func projectIsVisible(_ project: CodexProject, query: String) -> Bool {
        !threadsForProject(projectID: project.id, matching: query).isEmpty
    }

    private func loadThread(method: String) async {
        guard let selectedThread else { return }

        isLoadingThread = true
        defer { isLoadingThread = false }

        do {
            threadDetail = try await client.request(
                method: method,
                params: ThreadSelectionRequest(threadID: selectedThread.id)
            )
            if let detail = threadDetail {
                if let index = threads.firstIndex(where: { $0.id == detail.thread.id }) {
                    threads[index] = detail.thread
                }
                if let index = projects.firstIndex(where: { $0.id == detail.project.id }) {
                    projects[index] = detail.project
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handle(event: HelperEventEnvelope) {
        switch event.event {
        case "helper.status.changed":
            listRefreshTask?.cancel()
            listRefreshTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                await self.refreshWorkspace()
            }
        case "app.notification":
            handleAppNotification(event.data)
        default:
            break
        }
    }

    private func handleAppNotification(_ payload: JSONValue) {
        guard
            let envelope = payload.objectValue,
            let method = envelope["method"]?.stringValue
        else {
            return
        }

        let params = envelope["params"]?.objectValue
        let threadID = params?["threadId"]?.stringValue

        switch method {
        case "item/started":
            if threadID == selectedThread?.id {
                mergeStartedItem(
                    item: params?["item"],
                    turnID: params?["turnId"]?.stringValue
                )
            }
        case "item/agentMessage/delta":
            mergeDelta(
                threadID: threadID,
                turnID: params?["turnId"]?.stringValue,
                itemID: params?["itemId"]?.stringValue,
                kind: "agentMessage",
                title: "Codex",
                delta: params?["delta"]?.stringValue ?? ""
            )
        case "item/plan/delta":
            mergeDelta(
                threadID: threadID,
                turnID: params?["turnId"]?.stringValue,
                itemID: params?["itemId"]?.stringValue,
                kind: "plan",
                title: "Plan",
                delta: params?["delta"]?.stringValue ?? ""
            )
        case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta":
            mergeDelta(
                threadID: threadID,
                turnID: params?["turnId"]?.stringValue,
                itemID: params?["itemId"]?.stringValue,
                kind: "reasoning",
                title: "Reasoning",
                delta: params?["delta"]?.stringValue ?? ""
            )
        case "item/fileChange/outputDelta":
            mergeDelta(
                threadID: threadID,
                turnID: params?["turnId"]?.stringValue,
                itemID: params?["itemId"]?.stringValue,
                kind: "fileChange",
                title: "File Changes",
                delta: params?["delta"]?.stringValue ?? ""
            )
        case "item/commandExecution/outputDelta":
            mergeDelta(
                threadID: threadID,
                turnID: params?["turnId"]?.stringValue,
                itemID: params?["itemId"]?.stringValue,
                kind: "commandExecution",
                title: "Command",
                delta: params?["delta"]?.stringValue ?? ""
            )
        case "turn/started":
            if threadID == selectedThread?.id {
                threadDetail?.activeTurnID = params?["turn"]?.objectValue?["id"]?.stringValue
            }
            scheduleWorkspaceRefresh()
        case "turn/completed":
            if threadID == selectedThread?.id {
                threadDetail?.activeTurnID = nil
                scheduleThreadReconciliation()
            }
            scheduleWorkspaceRefresh()
        case "item/completed":
            if threadID == selectedThread?.id {
                mergeCompletedItem(
                    item: params?["item"],
                    turnID: params?["turnId"]?.stringValue
                )
            }
        default:
            if method.hasPrefix("thread/") || method.hasPrefix("turn/") {
                scheduleWorkspaceRefresh()
                if threadID == selectedThread?.id {
                    scheduleThreadRefresh()
                }
            }
        }
    }

    private func mergeDelta(
        threadID: String?,
        turnID: String?,
        itemID: String?,
        kind: String,
        title: String,
        delta: String
    ) {
        guard
            threadID == selectedThread?.id,
            let itemID,
            !delta.isEmpty
        else {
            return
        }

        if let index = threadDetail?.timeline.firstIndex(where: { $0.id == itemID }) {
            threadDetail?.timeline[index].body += delta
            threadDetail?.timeline[index].status = "inProgress"
        } else {
            threadDetail?.timeline.append(
                CodexTimelineItem(
                    id: itemID,
                    turnID: turnID ?? threadDetail?.activeTurnID ?? "active",
                    kind: kind,
                    title: title,
                    body: delta,
                    status: "inProgress",
                    timestamp: Date().timeIntervalSince1970,
                    source: "canonical"
                )
            )
        }
    }

    private func mergeCompletedItem(item: JSONValue?, turnID: String?) {
        guard let item, let itemObject = item.objectValue, let mapped = timelineItem(from: itemObject, turnID: turnID) else {
            return
        }

        if let index = threadDetail?.timeline.firstIndex(where: { $0.id == mapped.id }) {
            threadDetail?.timeline[index] = mapped
        } else {
            threadDetail?.timeline.append(mapped)
        }
    }

    private func mergeStartedItem(item: JSONValue?, turnID: String?) {
        guard let item, let itemObject = item.objectValue, var mapped = timelineItem(from: itemObject, turnID: turnID) else {
            return
        }
        mapped.status = "inProgress"

        if let index = threadDetail?.timeline.firstIndex(where: { $0.id == mapped.id }) {
            threadDetail?.timeline[index] = mapped
        } else {
            threadDetail?.timeline.append(mapped)
        }
    }

    private func timelineItem(from item: [String: JSONValue], turnID: String?) -> CodexTimelineItem? {
        guard let id = item["id"]?.stringValue, let type = item["type"]?.stringValue else { return nil }

        switch type {
        case "userMessage":
            return CodexTimelineItem(
                id: id,
                turnID: turnID ?? "turn",
                kind: "userMessage",
                title: "You",
                body: joinedContentText(from: item["content"]),
                status: "completed",
                timestamp: Date().timeIntervalSince1970,
                source: "canonical"
            )
        case "agentMessage":
            return CodexTimelineItem(
                id: id,
                turnID: turnID ?? "turn",
                kind: "agentMessage",
                title: "Codex",
                body: item["text"]?.stringValue ?? "",
                status: "completed",
                timestamp: Date().timeIntervalSince1970,
                source: "canonical"
            )
        case "plan":
            return CodexTimelineItem(
                id: id,
                turnID: turnID ?? "turn",
                kind: "plan",
                title: "Plan",
                body: item["text"]?.stringValue ?? "",
                status: "completed",
                timestamp: Date().timeIntervalSince1970,
                source: "canonical"
            )
        case "reasoning":
            return CodexTimelineItem(
                id: id,
                turnID: turnID ?? "turn",
                kind: "reasoning",
                title: "Reasoning",
                body: joinedStringArray(item["summary"]) + joinedStringArray(item["content"]),
                status: "completed",
                timestamp: Date().timeIntervalSince1970,
                source: "canonical"
            )
        case "commandExecution":
            return CodexTimelineItem(
                id: id,
                turnID: turnID ?? "turn",
                kind: "commandExecution",
                title: item["command"]?.stringValue ?? "Command",
                body: item["aggregatedOutput"]?.stringValue ?? "",
                status: "completed",
                timestamp: Date().timeIntervalSince1970,
                source: "canonical"
            )
        case "fileChange":
            return CodexTimelineItem(
                id: id,
                turnID: turnID ?? "turn",
                kind: "fileChange",
                title: "File Changes",
                body: item["changes"]?.arrayValue?.compactMap { $0.objectValue?["path"]?.stringValue }.joined(separator: "\n") ?? "",
                status: "completed",
                timestamp: Date().timeIntervalSince1970,
                source: "canonical"
            )
        default:
            return nil
        }
    }

    private func scheduleWorkspaceRefresh() {
        listRefreshTask?.cancel()
        listRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            await self.refreshWorkspace()
        }
    }

    private var shouldInvalidateWorkspaceSnapshot: Bool {
        guard hasWorkspaceSnapshot else { return false }
        guard let lastWorkspaceRefreshAt else { return true }
        return Date().timeIntervalSince(lastWorkspaceRefreshAt) >= Self.workspaceStaleAfter
    }

    private var hasWorkspaceSnapshot: Bool {
        helperStatus != nil || !projects.isEmpty || !threads.isEmpty
    }

    private func scheduleThreadRefresh() {
        threadRefreshTask?.cancel()
        threadRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            await self.refreshSelectedThread()
        }
    }

    private func scheduleThreadReconciliation() {
        threadRefreshTask?.cancel()
        threadRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            await self.refreshSelectedThread()

            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            await self.refreshSelectedThread()
        }
    }

    private func joinedContentText(from value: JSONValue?) -> String {
        guard let parts = value?.arrayValue else { return "" }
        return parts.compactMap { part in
            guard let object = part.objectValue else { return nil }
            switch object["type"]?.stringValue {
            case "text":
                return object["text"]?.stringValue
            case "mention":
                return "@\(object["name"]?.stringValue ?? "mention")"
            case "skill":
                return "$\(object["name"]?.stringValue ?? "skill")"
            case "image":
                return "[image]"
            default:
                return nil
            }
        }
        .joined(separator: "\n")
    }

    private func joinedStringArray(_ value: JSONValue?) -> String {
        guard let entries = value?.arrayValue else { return "" }
        return entries.compactMap(\.stringValue)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

private struct ThreadsQuery: Codable {
    let projectID: String?
    let query: String?
    let archived: Bool
    let limit: Int?
}

private struct ThreadSelectionRequest: Codable {
    let threadID: String
}

private struct ThreadCreateRequest: Codable {
    let cwd: String
}

private struct TurnPromptRequest: Codable {
    let threadID: String
    let prompt: String
}

private struct TurnInterruptRequest: Codable {
    let threadID: String
    let turnID: String
}

private struct DesktopOpenRequest: Codable {
    let threadID: String
}

private struct DesktopOpenResponse: Codable {
    let opened: Bool
    let bestEffort: Bool
}
