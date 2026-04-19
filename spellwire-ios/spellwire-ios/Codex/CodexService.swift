import Foundation
import Observation

@MainActor
@Observable
final class CodexService {
    private static let workspaceStaleAfter: TimeInterval = 12
    private static let defaultRecentThreadWindowSize = 80

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
    var isLoadingOlderHistory = false
    var pendingHostKeyChallenge: HostKeyChallenge?
    var errorMessage: String?
    var olderHistoryError: String?
    var isShowingCachedData = false
    var isReadOnlyFallback = false
    var hasOlderHistory = false
    var oldestLoadedItemID: String?
    var newestLoadedItemID: String?
    var threadTimelineRevision = 0
    var lastWorkspaceUpdatedAt: Date?
    var lastSelectedThreadUpdatedAt: Date?
    private(set) var runningThreadIDs = Set<String>()
    private(set) var unreadThreadIDs = Set<String>()

    private let trustStore: HostTrustStore
    private let client: any HelperRPCRequesting
    private let workspaceSnapshotStore: CodexWorkspaceSnapshotStore?
    private let threadDetailCacheStore: CodexThreadDetailCacheStore?
    private let metadataCacheStore: CodexMetadataCacheStore?
    private var pendingTrustReply: ((Bool) -> Void)?
    private var listRefreshTask: Task<Void, Never>?
    private var threadRefreshTask: Task<Void, Never>?
    private var gitStatusRefreshTask: Task<Void, Never>?
    private var gitStatusPollingTask: Task<Void, Never>?
    private var threadCacheWriteTask: Task<Void, Never>?
    private var lastWorkspaceRefreshAt: Date?

    init(
        host: HostRecord,
        identity: SSHDeviceIdentity,
        trustStore: HostTrustStore,
        haptics: HapticsClient,
        workspaceSnapshotStore: CodexWorkspaceSnapshotStore? = nil,
        threadDetailCacheStore: CodexThreadDetailCacheStore? = nil,
        metadataCacheStore: CodexMetadataCacheStore? = nil
    ) {
        var challengeHandler: ((HostKeyChallenge, @escaping (Bool) -> Void) -> Void)?
        let rpcClient = HelperRPCClient(
            host: host,
            identity: identity,
            trustedHost: trustStore.trustedHost(for: host.id)
        ) { challenge, reply in
            challengeHandler?(challenge, reply)
        }
        self.host = host
        self.trustStore = trustStore
        self.haptics = haptics
        self.client = rpcClient
        self.workspaceSnapshotStore = workspaceSnapshotStore
        self.threadDetailCacheStore = threadDetailCacheStore
        self.metadataCacheStore = metadataCacheStore
        challengeHandler = { [weak self] challenge, reply in
            guard let self else { return }
            self.pendingHostKeyChallenge = challenge
            self.pendingTrustReply = reply
            self.haptics.play(.warning)
        }
        rpcClient.eventHandler = { [weak self] event in
            self?.handle(event: event)
        }
    }

    init(
        host: HostRecord,
        trustStore: HostTrustStore,
        haptics: HapticsClient,
        client: any HelperRPCRequesting,
        workspaceSnapshotStore: CodexWorkspaceSnapshotStore? = nil,
        threadDetailCacheStore: CodexThreadDetailCacheStore? = nil,
        metadataCacheStore: CodexMetadataCacheStore? = nil
    ) {
        self.host = host
        self.trustStore = trustStore
        self.haptics = haptics
        self.client = client
        self.workspaceSnapshotStore = workspaceSnapshotStore
        self.threadDetailCacheStore = threadDetailCacheStore
        self.metadataCacheStore = metadataCacheStore
        client.eventHandler = { [weak self] event in
            self?.handle(event: event)
        }
    }

    func loadInitialData() async {
        hydrateWorkspaceSnapshotFromCache()
        await refreshWorkspace()
    }

    func refreshWorkspace(showArchived: Bool? = nil, userInitiated: Bool = false) async {
        if let showArchived {
            showsArchived = showArchived
        }
        if shouldInvalidateWorkspaceSnapshot, hasWorkspaceSnapshot {
            isShowingCachedData = true
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
            lastWorkspaceUpdatedAt = .now
            isShowingCachedData = false
            isReadOnlyFallback = false
            errorMessage = nil
            persistWorkspaceSnapshot(isStale: false)
            if userInitiated {
                haptics.play(.success)
            }
        } catch {
            if hasWorkspaceSnapshot {
                isShowingCachedData = true
                isReadOnlyFallback = true
                errorMessage = userInitiated ? "Unable to refresh. Showing cached data." : nil
            } else {
                errorMessage = error.localizedDescription
            }
            if userInitiated {
                haptics.play(.error)
            }
        }
    }

    func open(_ thread: CodexThreadSummary) async {
        prepareToOpenThread(thread)
        hydrateThreadDetailFromCache(threadID: thread.id)
        await loadThread(
            method: "threads.open",
            request: ThreadSelectionRequest(
                threadID: thread.id,
                historyMode: .recent,
                windowSize: Self.defaultRecentThreadWindowSize,
                beforeItemID: nil
            )
        )
    }

    func createThread(in project: CodexProject) async -> CodexThreadSummary? {
        guard canPerformRemoteMutations else {
            errorMessage = "Remote actions are unavailable while Spellwire is showing cached data."
            haptics.play(.warning)
            return nil
        }

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
            persistWorkspaceSnapshot(isStale: false)
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
        olderHistoryError = nil
        isLoadingOlderHistory = false
        if threadDetail?.thread.id != thread.id {
            threadDetail = nil
            hasOlderHistory = false
            oldestLoadedItemID = nil
            newestLoadedItemID = nil
            bumpThreadTimelineRevision()
        }
        selectedThreadGitStatus = nil
        selectedThreadGitDiff = nil
        selectedThreadGitCommitPreview = nil
        availableBranches = []
        lastSelectedThreadUpdatedAt = nil
    }

    func refreshSelectedThread(userInitiated: Bool = false) async {
        guard let selectedThread else { return }
        await loadThread(
            method: "threads.read",
            userInitiated: userInitiated,
            request: ThreadSelectionRequest(
                threadID: selectedThread.id,
                historyMode: .recent,
                windowSize: Self.defaultRecentThreadWindowSize,
                beforeItemID: nil
            )
        )
    }

    func loadOlderHistory() async {
        guard let selectedThread, let threadDetail, threadDetail.thread.id == selectedThread.id else { return }
        guard threadDetail.historyMode == .recent else { return }
        guard threadDetail.hasOlderHistory else { return }
        guard let beforeItemID = threadDetail.oldestLoadedItemID, !beforeItemID.isEmpty else { return }
        guard !isLoadingOlderHistory else { return }

        isLoadingOlderHistory = true
        olderHistoryError = nil
        defer { isLoadingOlderHistory = false }

        do {
            let olderPage: CodexThreadDetail = try await client.request(
                method: "threads.read",
                params: ThreadSelectionRequest(
                    threadID: selectedThread.id,
                    historyMode: .recent,
                    windowSize: Self.defaultRecentThreadWindowSize,
                    beforeItemID: beforeItemID
                )
            )
            guard self.selectedThread?.id == selectedThread.id else { return }
            mergeOlderHistoryPage(olderPage)
            lastSelectedThreadUpdatedAt = .now
            isShowingCachedData = false
            isReadOnlyFallback = false
            scheduleThreadCacheWrite()
            errorMessage = nil
        } catch {
            olderHistoryError = error.localizedDescription
        }
    }

    func send(
        prompt: String,
        attachmentPaths: [String] = [],
        pendingAttachmentPreviewPaths: [URL] = [],
        model: String? = nil,
        effort: String? = nil,
        serviceTier: String? = nil
    ) async {
        guard canPerformRemoteMutations else {
            errorMessage = "Remote actions are unavailable while Spellwire is showing cached data."
            haptics.play(.warning)
            return
        }
        guard let selectedThread else { return }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty || !attachmentPaths.isEmpty else { return }

        let pendingID = "local:\(UUID().uuidString)"
        let detailSnapshot = threadDetail
        let requestCWD = detailSnapshot?.runtime.cwd
        let pendingContent = pendingUserMessageContent(
            prompt: trimmedPrompt,
            previewPaths: pendingAttachmentPreviewPaths,
            fallbackPaths: attachmentPaths
        )

        if var detailSnapshot, detailSnapshot.thread.id == selectedThread.id {
            detailSnapshot.timeline.append(
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
            detailSnapshot.newestLoadedItemID = detailSnapshot.timeline.last?.id
            detailSnapshot.oldestLoadedItemID = detailSnapshot.timeline.first?.id
            threadDetail = detailSnapshot
            syncThreadHistoryStateFromDetail()
            bumpThreadTimelineRevision()
            scheduleThreadCacheWrite()
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
            scheduleThreadCacheWrite()
            scheduleWorkspaceRefresh()
            errorMessage = nil
            haptics.play(.success)
        } catch {
            if var failedDetail = threadDetail,
               let index = failedDetail.timeline.firstIndex(where: { $0.id == pendingID }) {
                failedDetail.timeline.remove(at: index)
                failedDetail.oldestLoadedItemID = failedDetail.timeline.first?.id
                failedDetail.newestLoadedItemID = failedDetail.timeline.last?.id
                applyThreadDetail(failedDetail)
                scheduleThreadCacheWrite()
            }
            errorMessage = error.localizedDescription
            haptics.play(.error)
        }
    }

    func interrupt() async {
        guard canPerformRemoteMutations else {
            errorMessage = "Remote actions are unavailable while Spellwire is showing cached data."
            haptics.play(.warning)
            return
        }
        guard let selectedThread, let turnID = threadDetail?.activeTurnID else { return }

        do {
            let _: TurnMutationResult = try await client.request(
                method: "turns.interrupt",
                params: TurnInterruptRequest(threadID: selectedThread.id, turnID: turnID)
            )
            _ = updateThreadDetail(matchingThreadID: selectedThread.id) { detail in
                detail.activeTurnID = nil
            }
            runningThreadIDs.remove(selectedThread.id)
            errorMessage = nil
            scheduleThreadCacheWrite()
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
        if availableModels.isEmpty {
            hydrateModelsFromCache()
        }
        guard availableModels.isEmpty else { return }
        await refreshModels()
    }

    func refreshModels() async {
        hydrateModelsFromCache()
        isLoadingModels = true
        defer { isLoadingModels = false }

        do {
            availableModels = try await client.request(method: "models.list", params: EmptyParams())
            persistModels()
            errorMessage = nil
        } catch {
            if availableModels.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    func refreshBranches() async {
        guard let cwd = threadDetail?.runtime.cwd else {
            availableBranches = []
            return
        }

        hydrateBranchesFromCache(cwd: cwd)
        isLoadingBranches = true
        defer { isLoadingBranches = false }

        do {
            availableBranches = try await client.request(
                method: "branches.list",
                params: BranchListRequest(cwd: cwd)
            )
            persistBranches(cwd: cwd)
            errorMessage = nil
        } catch {
            if availableBranches.isEmpty {
                availableBranches = []
            }
        }
    }

    func switchBranch(to name: String) async {
        guard canPerformRemoteMutations else {
            errorMessage = "Remote actions are unavailable while Spellwire is showing cached data."
            haptics.play(.warning)
            return
        }
        guard let cwd = threadDetail?.runtime.cwd else { return }

        do {
            let result: BranchSwitchResult = try await client.request(
                method: "branches.switch",
                params: BranchSwitchRequest(cwd: cwd, name: name)
            )
            availableBranches = availableBranches.map { branch in
                BranchInfo(name: branch.name, isCurrent: branch.name == result.currentBranch)
            }
            _ = updateThreadDetail { detail in
                let currentRuntime = detail.runtime
                detail.runtime = CodexThreadRuntime(
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
            }
            persistBranches(cwd: cwd)
            scheduleThreadCacheWrite()
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
        guard canPerformRemoteMutations else {
            errorMessage = "Remote actions are unavailable while Spellwire is showing cached data."
            haptics.play(.warning)
            return nil
        }
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
            _ = updateThreadDetail { detail in
                let runtime = detail.runtime
                detail.runtime = CodexThreadRuntime(
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

    var canMutateRemotely: Bool {
        canPerformRemoteMutations
    }

    var cacheStatusMessage: String? {
        guard isShowingCachedData, isReadOnlyFallback else { return nil }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let referenceDate = lastSelectedThreadUpdatedAt ?? lastWorkspaceUpdatedAt
        let timestampDescription = referenceDate.map { formatter.localizedString(for: $0, relativeTo: .now) } ?? "recently"

        return "Showing cached data from \(timestampDescription). Remote actions are disabled."
    }

    private func loadThread(
        method: String,
        userInitiated: Bool = false,
        request: ThreadSelectionRequest
    ) async {
        let requestedThreadID = request.threadID

        isLoadingThread = true
        defer { isLoadingThread = false }

        do {
            let detail: CodexThreadDetail = try await client.request(
                method: method,
                params: request
            )

            guard self.selectedThread?.id == requestedThreadID else {
                return
            }

            if request.historyMode == .recent, (method == "threads.read" || method == "threads.open") {
                mergeRecentThreadDetail(detail)
            } else {
                applyThreadDetail(detail)
            }
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
            lastSelectedThreadUpdatedAt = .now
            isShowingCachedData = false
            isReadOnlyFallback = false
            olderHistoryError = nil
            scheduleThreadCacheWrite()
            await loadModelsIfNeeded()

            guard self.selectedThread?.id == requestedThreadID else {
                return
            }

            await refreshBranches()

            guard self.selectedThread?.id == requestedThreadID else {
                return
            }

            await refreshGitStatus()

            guard self.selectedThread?.id == requestedThreadID else {
                return
            }

            errorMessage = nil
            if userInitiated {
                haptics.play(.success)
            }
        } catch {
            guard self.selectedThread?.id == requestedThreadID else {
                return
            }

            if threadDetail?.thread.id == requestedThreadID {
                isShowingCachedData = true
                isReadOnlyFallback = true
                errorMessage = userInitiated ? "Unable to refresh. Showing cached thread data." : nil
            } else {
                errorMessage = error.localizedDescription
            }
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
                _ = updateThreadDetail(matchingThreadID: threadID) { detail in
                    detail.activeTurnID = params?["turn"]?.objectValue?["id"]?.stringValue
                }
                scheduleThreadCacheWrite()
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
                _ = updateThreadDetail(matchingThreadID: threadID) { detail in
                    detail.activeTurnID = nil
                }
                scheduleThreadReconciliation()
                scheduleGitStatusRefresh()
                scheduleThreadCacheWrite()
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

        let didUpdate = updateThreadDetail(matchingThreadID: threadID) { detail in
            if let index = detail.timeline.firstIndex(where: { $0.id == itemID }) {
                detail.timeline[index].body += delta
                detail.timeline[index].status = "inProgress"
            } else {
                detail.timeline.append(
                    CodexTimelineItem(
                        id: itemID,
                        turnID: turnID ?? detail.activeTurnID ?? "active",
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
            detail.newestLoadedItemID = detail.timeline.last?.id
            if detail.oldestLoadedItemID == nil {
                detail.oldestLoadedItemID = detail.timeline.first?.id
            }
        }
        guard didUpdate else {
            return
        }
        syncThreadHistoryStateFromDetail()
        bumpThreadTimelineRevision()
        scheduleThreadCacheWrite()
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
        let didUpdate = updateThreadDetail { detail in
            if let index = detail.timeline.firstIndex(where: { $0.id == mapped.id }) {
                detail.timeline[index] = mapped
            } else if let pendingIndex = detail.timeline.firstIndex(where: { isMatchingPendingLocalMessage($0, canonical: mapped) }) {
                detail.timeline[pendingIndex] = mapped
            } else {
                detail.timeline.append(mapped)
            }
            if mapped.kind == "fileChange", let changedPaths = mapped.changedPaths, !changedPaths.isEmpty {
                detail.gitRelevantPaths = orderedUniqueStrings(detail.gitRelevantPaths + changedPaths)
            }
            detail.newestLoadedItemID = detail.timeline.last?.id
            if detail.oldestLoadedItemID == nil {
                detail.oldestLoadedItemID = detail.timeline.first?.id
            }
        }
        guard didUpdate else {
            return
        }
        syncThreadHistoryStateFromDetail()
        bumpThreadTimelineRevision()
        scheduleThreadCacheWrite()
    }

    private func applyThreadDetail(_ detail: CodexThreadDetail) {
        threadDetail = detail
        syncThreadHistoryStateFromDetail()
        bumpThreadTimelineRevision()
    }

    private func mergeRecentThreadDetail(_ liveDetail: CodexThreadDetail) {
        guard let existing = threadDetail, existing.thread.id == liveDetail.thread.id else {
            applyThreadDetail(liveDetail)
            return
        }

        let olderPrefix = existingOlderPrefix(existing.timeline, overlappingOldestItemID: liveDetail.oldestLoadedItemID)
        let pendingLocalItems = existing.timeline.filter { item in
            guard item.id.hasPrefix("local:"), item.status == "pending" || item.status == "inProgress" else {
                return false
            }
            return !liveDetail.timeline.contains(where: { isMatchingPendingLocalMessage(item, canonical: $0) })
        }

        var mergedDetail = liveDetail
        mergedDetail.timeline = orderedUniqueTimelineItems(olderPrefix + liveDetail.timeline + pendingLocalItems)
        if !olderPrefix.isEmpty {
            mergedDetail.hasOlderHistory = existing.hasOlderHistory
        }
        mergedDetail.oldestLoadedItemID = mergedDetail.timeline.first?.id
        mergedDetail.newestLoadedItemID = mergedDetail.timeline.last?.id
        mergedDetail.gitRelevantPaths = orderedUniqueStrings(existing.gitRelevantPaths + liveDetail.gitRelevantPaths)
        applyThreadDetail(mergedDetail)
    }

    private func mergeOlderHistoryPage(_ olderPage: CodexThreadDetail) {
        guard var current = threadDetail, current.thread.id == olderPage.thread.id else {
            applyThreadDetail(olderPage)
            return
        }

        current.thread = olderPage.thread
        current.project = olderPage.project
        current.activeTurnID = olderPage.activeTurnID
        current.runtime = olderPage.runtime
        current.timeline = orderedUniqueTimelineItems(olderPage.timeline + current.timeline)
        current.recovery = olderPage.recovery
        current.hasOlderHistory = olderPage.hasOlderHistory
        current.historyMode = olderPage.historyMode
        current.oldestLoadedItemID = current.timeline.first?.id
        current.newestLoadedItemID = current.timeline.last?.id
        current.gitRelevantPaths = orderedUniqueStrings(olderPage.gitRelevantPaths + current.gitRelevantPaths)
        applyThreadDetail(current)
    }

    private func existingOlderPrefix(
        _ timeline: [CodexTimelineItem],
        overlappingOldestItemID: String?
    ) -> [CodexTimelineItem] {
        guard let overlappingOldestItemID,
              let overlapIndex = timeline.firstIndex(where: { $0.id == overlappingOldestItemID }) else {
            return []
        }

        return Array(timeline.prefix(upTo: overlapIndex))
    }

    private func orderedUniqueTimelineItems(_ items: [CodexTimelineItem]) -> [CodexTimelineItem] {
        var seen = Set<String>()
        var ordered: [CodexTimelineItem] = []

        for item in items {
            if seen.insert(item.id).inserted {
                ordered.append(item)
            }
        }

        return ordered
    }

    private func orderedUniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for value in values where !value.isEmpty {
            if seen.insert(value).inserted {
                ordered.append(value)
            }
        }

        return ordered
    }

    private func syncThreadHistoryStateFromDetail() {
        hasOlderHistory = threadDetail?.hasOlderHistory ?? false
        oldestLoadedItemID = threadDetail?.oldestLoadedItemID
        newestLoadedItemID = threadDetail?.newestLoadedItemID
    }

    @discardableResult
    private func updateThreadDetail(
        matchingThreadID threadID: String? = nil,
        _ update: (inout CodexThreadDetail) -> Void
    ) -> Bool {
        guard var detail = threadDetail else { return false }
        if let threadID, detail.thread.id != threadID {
            return false
        }
        update(&detail)
        threadDetail = detail
        return true
    }

    private func bumpThreadTimelineRevision() {
        threadTimelineRevision &+= 1
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

    private func hydrateWorkspaceSnapshotFromCache() {
        guard let workspaceSnapshotStore, let snapshot = try? workspaceSnapshotStore.snapshot(for: host.id) else { return }
        helperStatus = snapshot.helperStatus
        projects = snapshot.projects
        threads = snapshot.threads
        showsArchived = snapshot.showsArchived
        lastWorkspaceUpdatedAt = snapshot.lastLiveRefreshAt ?? snapshot.cachedAt
        isShowingCachedData = true
        reconcileThreadIndicators(using: threads)
    }

    private func hydrateThreadDetailFromCache(threadID: String) {
        guard let threadDetailCacheStore, let entry = try? threadDetailCacheStore.entry(for: host.id, threadID: threadID) else { return }
        applyThreadDetail(entry.detail)
        if let index = threads.firstIndex(where: { $0.id == entry.detail.thread.id }) {
            threads[index] = entry.detail.thread
        }
        if let index = projects.firstIndex(where: { $0.id == entry.detail.project.id }) {
            projects[index] = entry.detail.project
        }
        lastSelectedThreadUpdatedAt = entry.lastLiveRefreshAt ?? entry.cachedAt
        isShowingCachedData = true
    }

    private func hydrateModelsFromCache() {
        guard let metadataCacheStore, let entry = try? metadataCacheStore.cachedModels(for: host.id) else { return }
        availableModels = entry.models
    }

    private func hydrateBranchesFromCache(cwd: String) {
        guard let metadataCacheStore, let entry = try? metadataCacheStore.cachedBranches(for: host.id, cwd: cwd) else { return }
        availableBranches = entry.branches
    }

    private func persistWorkspaceSnapshot(isStale: Bool) {
        guard let workspaceSnapshotStore else { return }
        let snapshot = CodexWorkspaceSnapshot(
            hostID: host.id,
            helperStatus: helperStatus,
            projects: projects,
            threads: threads,
            showsArchived: showsArchived,
            cachedAt: .now,
            lastLiveRefreshAt: lastWorkspaceRefreshAt,
            isStale: isStale
        )
        try? workspaceSnapshotStore.saveSnapshot(snapshot)
    }

    private func scheduleThreadCacheWrite() {
        threadCacheWriteTask?.cancel()
        threadCacheWriteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.persistSelectedThreadDetail(isStale: self.isShowingCachedData)
        }
    }

    private func persistSelectedThreadDetail(isStale: Bool) {
        guard let threadDetailCacheStore, let detail = threadDetail else { return }
        let entry = CachedThreadDetailEntry(
            hostID: host.id,
            threadID: detail.thread.id,
            detail: detail,
            cachedAt: .now,
            lastLiveRefreshAt: lastSelectedThreadUpdatedAt,
            lastOpenedAt: .now,
            isStale: isStale
        )
        try? threadDetailCacheStore.saveEntry(entry)
    }

    private func persistModels() {
        guard let metadataCacheStore, !availableModels.isEmpty else { return }
        let entry = CachedModelListEntry(
            hostID: host.id,
            models: availableModels,
            cachedAt: .now,
            lastLiveRefreshAt: .now,
            isStale: false
        )
        try? metadataCacheStore.saveModels(entry)
    }

    private func persistBranches(cwd: String) {
        guard let metadataCacheStore, !availableBranches.isEmpty else { return }
        let entry = CachedBranchListEntry(
            hostID: host.id,
            cwd: cwd,
            branches: availableBranches,
            cachedAt: .now,
            lastLiveRefreshAt: .now,
            lastOpenedAt: .now,
            isStale: false
        )
        try? metadataCacheStore.saveBranches(entry)
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

    private var canPerformRemoteMutations: Bool {
        !isReadOnlyFallback
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
        return detail.gitRelevantPaths
    }

    private func applyGitStatusToRuntime(_ status: CodexGitStatus) {
        _ = updateThreadDetail { detail in
            let runtime = detail.runtime
            detail.runtime = CodexThreadRuntime(
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
        }
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
    let historyMode: CodexThreadHistoryMode?
    let windowSize: Int?
    let beforeItemID: String?
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
