import Foundation
import Observation

@MainActor
@Observable
final class CodexService {
    private static let workspaceStaleAfter: TimeInterval = 12

    let host: HostRecord
    let haptics: HapticsClient

    var helperStatus: HelperStatusSnapshot?
    var projects: [CodexProject] = []
    var threads: [CodexThreadSummary] = []
    var selectedThread: CodexThreadSummary?
    var threadDetail: CodexThreadDetail?
    var selectedThreadGitStatus: CodexGitStatus?
    var selectedThreadGitDiff: CodexGitDiff?
    var selectedThreadGitCommitPreview: GitCommitPreview?
    var availableModels: [ModelOption] = []
    var availableBranches: [BranchInfo] = []
    var showsArchived = false
    var isLoadingList = false
    var isLoadingThread = false
    var isLoadingGitStatus = false
    var isLoadingGitDiff = false
    var isLoadingGitCommitPreview = false
    var isExecutingGitCommit = false
    var isLoadingModels = false
    var isLoadingBranches = false
    var pendingHostKeyChallenge: HostKeyChallenge?
    var errorMessage: String?
    private(set) var runningThreadIDs = Set<String>()
    private(set) var unreadThreadIDs = Set<String>()

    private let trustStore: HostTrustStore
    private let client: HelperRPCClient
    private var pendingTrustReply: ((Bool) -> Void)?
    private var listRefreshTask: Task<Void, Never>?
    private var threadRefreshTask: Task<Void, Never>?
    private var gitStatusRefreshTask: Task<Void, Never>?
    private var gitStatusPollingTask: Task<Void, Never>?
    private var lastWorkspaceRefreshAt: Date?

    init(host: HostRecord, identity: SSHDeviceIdentity, trustStore: HostTrustStore, haptics: HapticsClient) {
        self.host = host
        self.trustStore = trustStore
        self.haptics = haptics
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
            self.haptics.play(.warning)
        }
        client.eventHandler = { [weak self] event in
            self?.handle(event: event)
        }
    }

    func loadInitialData() async {
        await refreshWorkspace()
    }

    func refreshWorkspace(showArchived: Bool? = nil, userInitiated: Bool = false) async {
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
            let fetchedThreads: [CodexThreadSummary] = try await client.request(
                method: "threads.list",
                params: ThreadsQuery(projectID: nil, query: nil, archived: showsArchived, limit: nil)
            )
            threads = fetchedThreads
            reconcileThreadIndicators(using: fetchedThreads)
            lastWorkspaceRefreshAt = .now
            errorMessage = nil
            if userInitiated {
                haptics.play(.success)
            }
        } catch {
            errorMessage = error.localizedDescription
            if userInitiated {
                haptics.play(.error)
            }
        }
    }

    func open(_ thread: CodexThreadSummary) async {
        prepareToOpenThread(thread)
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
            prepareToOpenThread(created)
            errorMessage = nil
            scheduleWorkspaceRefresh()
            haptics.play(.success)
            return created
        } catch {
            errorMessage = error.localizedDescription
            haptics.play(.error)
            return nil
        }
    }

    func prepareToOpenThread(_ thread: CodexThreadSummary) {
        selectedThread = thread
        unreadThreadIDs.remove(thread.id)
        threadRefreshTask?.cancel()
        gitStatusRefreshTask?.cancel()
        if threadDetail?.thread.id != thread.id {
            threadDetail = nil
        }
        selectedThreadGitStatus = nil
        selectedThreadGitDiff = nil
        selectedThreadGitCommitPreview = nil
        availableBranches = []
    }

    func refreshSelectedThread(userInitiated: Bool = false) async {
        await loadThread(method: "threads.read", userInitiated: userInitiated)
    }

    func send(
        prompt: String,
        attachmentPaths: [String] = [],
        pendingAttachmentPreviewPaths: [URL] = [],
        model: String? = nil,
        effort: String? = nil,
        serviceTier: String? = nil
    ) async {
        guard let selectedThread else { return }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty || !attachmentPaths.isEmpty else { return }

        let pendingID = "local:\(UUID().uuidString)"
        var detailSnapshot = threadDetail
        let requestCWD = detailSnapshot?.runtime.cwd
        let pendingContent = pendingUserMessageContent(
            prompt: trimmedPrompt,
            previewPaths: pendingAttachmentPreviewPaths,
            fallbackPaths: attachmentPaths
        )

        if detailSnapshot?.thread.id == selectedThread.id {
            detailSnapshot?.timeline.append(
                CodexTimelineItem(
                    id: pendingID,
                    turnID: selectedThread.lastTurnID ?? "pending",
                    kind: "userMessage",
                    title: "You",
                    body: CodexTimelineContentPart.joinedFallbackText(from: pendingContent),
                    changedPaths: nil,
                    content: pendingContent,
                    status: "pending",
                    timestamp: Date().timeIntervalSince1970,
                    source: "canonical"
                )
            )
            threadDetail = detailSnapshot
        }

        do {
            let input = ([trimmedPrompt].filter { !$0.isEmpty }.map(CodexTurnInputItem.text))
                + attachmentPaths.map { CodexTurnInputItem.localImage(path: $0) }
            let mutation: TurnMutationResult = try await client.request(
                method: "turns.start",
                params: TurnPromptRequest(
                    threadID: selectedThread.id,
                    input: input,
                    cwd: requestCWD,
                    model: model,
                    effort: effort,
                    serviceTier: serviceTier,
                    sandboxPolicy: CodexSandboxPolicy(type: "dangerFullAccess")
                )
            )
            runningThreadIDs.insert(selectedThread.id)
            unreadThreadIDs.remove(selectedThread.id)

            if var updatedDetail = threadDetail, updatedDetail.thread.id == selectedThread.id {
                let currentRuntime = updatedDetail.runtime
                updatedDetail.activeTurnID = mutation.turnID
                updatedDetail.runtime = CodexThreadRuntime(
                    cwd: currentRuntime.cwd,
                    model: model ?? currentRuntime.model,
                    modelProvider: currentRuntime.modelProvider,
                    serviceTier: serviceTier ?? currentRuntime.serviceTier,
                    reasoningEffort: effort ?? currentRuntime.reasoningEffort,
                    approvalPolicy: currentRuntime.approvalPolicy,
                    sandbox: CodexSandboxPolicy(type: "dangerFullAccess"),
                    git: currentRuntime.git
                )
                threadDetail = updatedDetail
            }
            scheduleThreadRefresh()
            scheduleWorkspaceRefresh()
            errorMessage = nil
            haptics.play(.success)
        } catch {
            if var failedDetail = threadDetail,
               let index = failedDetail.timeline.firstIndex(where: { $0.id == pendingID }) {
                failedDetail.timeline.remove(at: index)
                threadDetail = failedDetail
            }
            errorMessage = error.localizedDescription
            haptics.play(.error)
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
            runningThreadIDs.remove(selectedThread.id)
            errorMessage = nil
            haptics.play(.success)
        } catch {
            errorMessage = error.localizedDescription
            haptics.play(.error)
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
            haptics.play(.success)
        } catch {
            errorMessage = error.localizedDescription
            haptics.play(.error)
        }
    }

    func loadModelsIfNeeded() async {
        guard availableModels.isEmpty else { return }
        await refreshModels()
    }

    func refreshModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }

        do {
            availableModels = try await client.request(method: "models.list", params: EmptyParams())
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshBranches() async {
        guard let cwd = threadDetail?.runtime.cwd else {
            availableBranches = []
            return
        }

        isLoadingBranches = true
        defer { isLoadingBranches = false }

        do {
            availableBranches = try await client.request(
                method: "branches.list",
                params: BranchListRequest(cwd: cwd)
            )
            errorMessage = nil
        } catch {
            availableBranches = []
        }
    }

    func switchBranch(to name: String) async {
        guard let cwd = threadDetail?.runtime.cwd else { return }

        do {
            let result: BranchSwitchResult = try await client.request(
                method: "branches.switch",
                params: BranchSwitchRequest(cwd: cwd, name: name)
            )
            availableBranches = availableBranches.map { branch in
                BranchInfo(name: branch.name, isCurrent: branch.name == result.currentBranch)
            }
            if var currentRuntime = threadDetail?.runtime {
                currentRuntime = CodexThreadRuntime(
                    cwd: currentRuntime.cwd,
                    model: currentRuntime.model,
                    modelProvider: currentRuntime.modelProvider,
                    serviceTier: currentRuntime.serviceTier,
                    reasoningEffort: currentRuntime.reasoningEffort,
                    approvalPolicy: currentRuntime.approvalPolicy,
                    sandbox: currentRuntime.sandbox,
                    git: CodexGitInfo(
                        sha: currentRuntime.git?.sha,
                        branch: result.currentBranch,
                        originURL: currentRuntime.git?.originURL
                    )
                )
                threadDetail?.runtime = currentRuntime
            }
            await refreshSelectedThread()
            await refreshGitStatus()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func beginGitStatusPolling() {
        gitStatusPollingTask?.cancel()
        gitStatusPollingTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshGitStatus()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func stopGitStatusPolling() {
        gitStatusPollingTask?.cancel()
        gitStatusPollingTask = nil
    }

    func refreshGitStatus(reportErrors: Bool = false) async {
        guard let cwd = currentThreadCWD else {
            selectedThreadGitStatus = nil
            selectedThreadGitDiff = nil
            selectedThreadGitCommitPreview = nil
            return
        }
        let scopedPaths = currentThreadGitPaths
        guard !scopedPaths.isEmpty else {
            selectedThreadGitStatus = nil
            selectedThreadGitDiff = nil
            selectedThreadGitCommitPreview = nil
            return
        }

        isLoadingGitStatus = true
        defer { isLoadingGitStatus = false }

        do {
            let status: CodexGitStatus = try await client.request(
                method: "git.status",
                params: GitStatusRequest(cwd: cwd, paths: scopedPaths)
            )
            selectedThreadGitStatus = status
            applyGitStatusToRuntime(status)
            if !status.hasChanges {
                selectedThreadGitDiff = nil
                selectedThreadGitCommitPreview = nil
            }
        } catch {
            if reportErrors {
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadGitDiff(force: Bool = false, reportErrors: Bool = true) async {
        guard let cwd = currentThreadCWD else { return }
        let scopedPaths = currentThreadGitPaths
        guard !scopedPaths.isEmpty else {
            selectedThreadGitDiff = nil
            return
        }
        if !force, selectedThreadGitDiff?.cwd == cwd {
            return
        }

        isLoadingGitDiff = true
        defer { isLoadingGitDiff = false }

        do {
            selectedThreadGitDiff = try await client.request(
                method: "git.diff",
                params: GitDiffRequest(cwd: cwd, paths: scopedPaths)
            )
        } catch {
            if reportErrors {
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadGitCommitPreview(force: Bool = false, reportErrors: Bool = true) async {
        guard let cwd = currentThreadCWD else { return }
        let scopedPaths = currentThreadGitPaths
        guard !scopedPaths.isEmpty else {
            selectedThreadGitCommitPreview = nil
            return
        }
        if !force, selectedThreadGitCommitPreview?.cwd == cwd {
            return
        }

        isLoadingGitCommitPreview = true
        defer { isLoadingGitCommitPreview = false }

        do {
            selectedThreadGitCommitPreview = try await client.request(
                method: "git.commit.preview",
                params: GitCommitPreviewRequest(cwd: cwd, paths: scopedPaths)
            )
        } catch {
            if reportErrors {
                errorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    func executeGitCommit(
        action: GitCommitActionID,
        commitMessage: String?,
        prTitle: String? = nil,
        prBody: String? = nil
    ) async -> GitCommitResult? {
        guard let cwd = currentThreadCWD else { return nil }
        let scopedPaths = currentThreadGitPaths
        guard !scopedPaths.isEmpty else { return nil }

        isExecutingGitCommit = true
        defer { isExecutingGitCommit = false }

        do {
            let result: GitCommitResult = try await client.request(
                method: "git.commit.execute",
                params: GitCommitExecuteRequest(
                    cwd: cwd,
                    paths: scopedPaths,
                    action: action,
                    commitMessage: commitMessage?.nilIfBlank,
                    prTitle: prTitle?.nilIfBlank,
                    prBody: prBody?.nilIfBlank
                )
            )
            selectedThreadGitCommitPreview = nil
            selectedThreadGitDiff = nil
            await refreshGitStatus(reportErrors: false)
            if selectedThreadGitStatus?.hasChanges == true {
                await loadGitDiff(force: true, reportErrors: false)
            }
            if var runtime = threadDetail?.runtime {
                runtime = CodexThreadRuntime(
                    cwd: runtime.cwd,
                    model: runtime.model,
                    modelProvider: runtime.modelProvider,
                    serviceTier: runtime.serviceTier,
                    reasoningEffort: runtime.reasoningEffort,
                    approvalPolicy: runtime.approvalPolicy,
                    sandbox: runtime.sandbox,
                    git: CodexGitInfo(
                        sha: result.commitSHA,
                        branch: result.branch,
                        originURL: runtime.git?.originURL
                    )
                )
                threadDetail?.runtime = runtime
            }
            errorMessage = nil
            haptics.play(.success)
            return result
        } catch {
            errorMessage = error.localizedDescription
            haptics.play(.error)
            return nil
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
        haptics.play(approved ? .success : .warning)
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

    func isThreadSelected(_ thread: CodexThreadSummary) -> Bool {
        selectedThread?.id == thread.id
    }

    func isThreadRunning(_ thread: CodexThreadSummary) -> Bool {
        if runningThreadIDs.contains(thread.id) {
            return true
        }
        if selectedThread?.id == thread.id, threadDetail?.activeTurnID != nil {
            return true
        }
        return threadHasActiveStatus(thread)
    }

    func hasUnreadActivity(_ thread: CodexThreadSummary) -> Bool {
        unreadThreadIDs.contains(thread.id) && !isThreadSelected(thread) && !isThreadRunning(thread)
    }

    private func loadThread(method: String, userInitiated: Bool = false) async {
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
                runningThreadIDs.remove(detail.thread.id)
                if detail.activeTurnID != nil || threadHasActiveStatus(detail.thread) {
                    runningThreadIDs.insert(detail.thread.id)
                }
                unreadThreadIDs.remove(detail.thread.id)
            }
            await loadModelsIfNeeded()
            await refreshBranches()
            await refreshGitStatus()
            errorMessage = nil
            if userInitiated {
                haptics.play(.success)
            }
        } catch {
            errorMessage = error.localizedDescription
            if userInitiated {
                haptics.play(.error)
            }
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
            if let threadID {
                runningThreadIDs.insert(threadID)
                unreadThreadIDs.remove(threadID)
            }
            if threadID == selectedThread?.id {
                threadDetail?.activeTurnID = params?["turn"]?.objectValue?["id"]?.stringValue
            }
            scheduleWorkspaceRefresh()
        case "turn/completed":
            if let threadID {
                runningThreadIDs.remove(threadID)
                if threadID == selectedThread?.id {
                    unreadThreadIDs.remove(threadID)
                } else {
                    unreadThreadIDs.insert(threadID)
                }
            }
            if threadID == selectedThread?.id {
                threadDetail?.activeTurnID = nil
                scheduleThreadReconciliation()
                scheduleGitStatusRefresh()
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
                    scheduleGitStatusRefresh()
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
                    changedPaths: nil,
                    content: nil,
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

        mergeTimelineItem(mapped)
    }

    private func mergeStartedItem(item: JSONValue?, turnID: String?) {
        guard let item, let itemObject = item.objectValue, var mapped = timelineItem(from: itemObject, turnID: turnID) else {
            return
        }
        mapped.status = "inProgress"

        mergeTimelineItem(mapped)
    }

    private func mergeTimelineItem(_ mapped: CodexTimelineItem) {
        if let index = threadDetail?.timeline.firstIndex(where: { $0.id == mapped.id }) {
            threadDetail?.timeline[index] = mapped
        } else if let pendingIndex = threadDetail?.timeline.firstIndex(where: { isMatchingPendingLocalMessage($0, canonical: mapped) }) {
            threadDetail?.timeline[pendingIndex] = mapped
        } else {
            threadDetail?.timeline.append(mapped)
        }
    }

    private func isMatchingPendingLocalMessage(_ existing: CodexTimelineItem, canonical mapped: CodexTimelineItem) -> Bool {
        guard mapped.kind == "userMessage" else { return false }
        guard existing.kind == "userMessage", existing.id.hasPrefix("local:") else { return false }
        guard existing.status == "pending" || existing.status == "inProgress" else { return false }
        return normalizedTimelineBody(existing.body) == normalizedTimelineBody(mapped.body)
    }

    private func normalizedTimelineBody(_ body: String) -> String {
        body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func timelineItem(from item: [String: JSONValue], turnID: String?) -> CodexTimelineItem? {
        guard let id = item["id"]?.stringValue, let type = item["type"]?.stringValue else { return nil }

        switch type {
        case "userMessage":
            let content = CodexTimelineContentPart.from(jsonValue: item["content"])
            return CodexTimelineItem(
                id: id,
                turnID: turnID ?? "turn",
                kind: "userMessage",
                title: "You",
                body: content.map { CodexTimelineContentPart.joinedFallbackText(from: $0) } ?? "",
                changedPaths: nil,
                content: content,
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
                changedPaths: nil,
                content: nil,
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
                changedPaths: nil,
                content: nil,
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
                changedPaths: nil,
                content: nil,
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
                changedPaths: nil,
                content: nil,
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
                changedPaths: item["changes"]?.arrayValue?.compactMap { $0.objectValue?["path"]?.stringValue },
                content: nil,
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

    private func scheduleGitStatusRefresh() {
        gitStatusRefreshTask?.cancel()
        gitStatusRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            await self.refreshGitStatus()
        }
    }

    private func reconcileThreadIndicators(using fetchedThreads: [CodexThreadSummary]) {
        let knownThreadIDs = Set(fetchedThreads.map(\.id))
        runningThreadIDs = Set(fetchedThreads.filter(threadHasActiveStatus).map(\.id))
        if let selectedThread, threadDetail?.activeTurnID != nil {
            runningThreadIDs.insert(selectedThread.id)
        }

        unreadThreadIDs = unreadThreadIDs
            .intersection(knownThreadIDs)
            .subtracting(runningThreadIDs)

        if let selectedThread {
            unreadThreadIDs.remove(selectedThread.id)
        }
    }

    private func threadHasActiveStatus(_ thread: CodexThreadSummary) -> Bool {
        let normalizedStatus = thread.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalizedStatus {
        case "active", "running", "inprogress":
            return true
        default:
            return false
        }
    }

    private func pendingUserMessageContent(
        prompt: String,
        previewPaths: [URL],
        fallbackPaths: [String]
    ) -> [CodexTimelineContentPart] {
        var content: [CodexTimelineContentPart] = []

        if !prompt.isEmpty {
            content.append(.text(prompt))
        }

        let imagePaths = previewPaths.map(\.path) + Array(fallbackPaths.dropFirst(previewPaths.count))
        content.append(contentsOf: imagePaths.map(CodexTimelineContentPart.localImage(path:)))
        return content
    }

    private var currentThreadCWD: String? {
        threadDetail?.runtime.cwd ?? selectedThread?.cwd
    }

    private var currentThreadGitPaths: [String] {
        guard let detail = threadDetail else { return [] }
        return CodexGitPresentation.relevantPaths(timeline: detail.timeline)
    }

    private func applyGitStatusToRuntime(_ status: CodexGitStatus) {
        guard var runtime = threadDetail?.runtime else { return }
        runtime = CodexThreadRuntime(
            cwd: runtime.cwd,
            model: runtime.model,
            modelProvider: runtime.modelProvider,
            serviceTier: runtime.serviceTier,
            reasoningEffort: runtime.reasoningEffort,
            approvalPolicy: runtime.approvalPolicy,
            sandbox: runtime.sandbox,
            git: CodexGitInfo(
                sha: runtime.git?.sha,
                branch: status.branch,
                originURL: runtime.git?.originURL
            )
        )
        threadDetail?.runtime = runtime
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
    let input: [CodexTurnInputItem]
    let cwd: String?
    let model: String?
    let effort: String?
    let serviceTier: String?
    let sandboxPolicy: CodexSandboxPolicy?
}

private struct BranchListRequest: Codable {
    let cwd: String
}

private struct BranchSwitchRequest: Codable {
    let cwd: String
    let name: String
}

private struct GitStatusRequest: Codable {
    let cwd: String
    let paths: [String]
}

private struct GitDiffRequest: Codable {
    let cwd: String
    let paths: [String]
}

private struct GitCommitPreviewRequest: Codable {
    let cwd: String
    let paths: [String]
}

private struct GitCommitExecuteRequest: Codable {
    let cwd: String
    let paths: [String]
    let action: GitCommitActionID
    let commitMessage: String?
    let prTitle: String?
    let prBody: String?
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

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
