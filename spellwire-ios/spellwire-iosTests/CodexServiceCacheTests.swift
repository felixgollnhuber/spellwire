import XCTest
@testable import spellwire_ios

@MainActor
final class CodexServiceCacheTests: XCTestCase {
    func testWarmLaunchShowsCachedWorkspaceBeforeLiveRefreshCompletes() async throws {
        let directories = try makeAppDirectories()
        let host = makeHost()
        let trustStore = HostTrustStore(appDirectories: directories)
        let workspaceStore = CodexWorkspaceSnapshotStore(appDirectories: directories)
        let threadStore = CodexThreadDetailCacheStore(appDirectories: directories)
        let metadataStore = CodexMetadataCacheStore(appDirectories: directories)

        let cachedProject = makeProject(cwd: "/tmp/cached-project", updatedAt: 10)
        let cachedThread = makeThreadSummary(id: "thread-cached", cwd: cachedProject.cwd, title: "Cached", updatedAt: 10)
        try workspaceStore.saveSnapshot(
            CodexWorkspaceSnapshot(
                hostID: host.id,
                helperStatus: makeHelperStatus(),
                projects: [cachedProject],
                threads: [cachedThread],
                showsArchived: false,
                cachedAt: Date(timeIntervalSince1970: 100),
                lastLiveRefreshAt: Date(timeIntervalSince1970: 90),
                isStale: true
            )
        )

        let liveProject = makeProject(cwd: "/tmp/live-project", updatedAt: 20)
        let liveThread = makeThreadSummary(id: "thread-live", cwd: liveProject.cwd, title: "Live", updatedAt: 20)
        let client = FakeHelperRPCClient { method, _ in
            try await Task.sleep(for: .milliseconds(150))
            switch method {
            case "helper.status":
                return makeHelperStatus()
            case "projects.list":
                return [liveProject]
            case "threads.list":
                return [liveThread]
            default:
                throw TestError.unhandledMethod(method)
            }
        }

        let service = CodexService(
            host: host,
            trustStore: trustStore,
            haptics: .noop,
            client: client,
            workspaceSnapshotStore: workspaceStore,
            threadDetailCacheStore: threadStore,
            metadataCacheStore: metadataStore
        )

        let loadTask = Task {
            await service.loadInitialData()
        }

        await Task.yield()

        XCTAssertEqual(service.projects, [cachedProject])
        XCTAssertEqual(service.threads, [cachedThread])
        XCTAssertTrue(service.isShowingCachedData)

        await loadTask.value

        XCTAssertEqual(service.projects, [liveProject])
        XCTAssertEqual(service.threads, [liveThread])
        XCTAssertFalse(service.isShowingCachedData)
        XCTAssertFalse(service.isReadOnlyFallback)
    }

    func testOpenUsesCachedThreadDetailThenReplacesItWithLiveDetail() async throws {
        let directories = try makeAppDirectories()
        let host = makeHost()
        let trustStore = HostTrustStore(appDirectories: directories)
        let workspaceStore = CodexWorkspaceSnapshotStore(appDirectories: directories)
        let threadStore = CodexThreadDetailCacheStore(appDirectories: directories)
        let metadataStore = CodexMetadataCacheStore(appDirectories: directories)

        let cachedDetail = makeThreadDetail(id: "thread-1", title: "Cached Thread")
        let liveDetail = makeThreadDetail(id: "thread-1", title: "Live Thread")
        try threadStore.saveEntry(
            CachedThreadDetailEntry(
                hostID: host.id,
                threadID: cachedDetail.thread.id,
                detail: cachedDetail,
                cachedAt: Date(timeIntervalSince1970: 100),
                lastLiveRefreshAt: Date(timeIntervalSince1970: 95),
                lastOpenedAt: Date(timeIntervalSince1970: 100),
                isStale: true
            )
        )

        let client = FakeHelperRPCClient { method, _ in
            switch method {
            case "threads.open":
                try await Task.sleep(for: .milliseconds(120))
                return liveDetail
            case "models.list":
                return [makeModelOption(id: "gpt-5.4")]
            case "branches.list":
                return [BranchInfo(name: "main", isCurrent: true)]
            case "git.status":
                return makeGitStatus(cwd: liveDetail.runtime.cwd)
            default:
                throw TestError.unhandledMethod(method)
            }
        }

        let service = CodexService(
            host: host,
            trustStore: trustStore,
            haptics: .noop,
            client: client,
            workspaceSnapshotStore: workspaceStore,
            threadDetailCacheStore: threadStore,
            metadataCacheStore: metadataStore
        )
        service.prepareToOpenThread(cachedDetail.thread)

        let openTask = Task {
            await service.open(cachedDetail.thread)
        }

        await Task.yield()

        XCTAssertEqual(service.threadDetail?.thread.title, "Cached Thread")
        XCTAssertTrue(service.isShowingCachedData)

        await openTask.value

        XCTAssertEqual(service.threadDetail?.thread.title, "Live Thread")
        XCTAssertFalse(service.isReadOnlyFallback)
    }

    func testOfflineRefreshKeepsCachedWorkspaceAndDisablesMutations() async throws {
        let directories = try makeAppDirectories()
        let host = makeHost()
        let trustStore = HostTrustStore(appDirectories: directories)
        let workspaceStore = CodexWorkspaceSnapshotStore(appDirectories: directories)
        let threadStore = CodexThreadDetailCacheStore(appDirectories: directories)
        let metadataStore = CodexMetadataCacheStore(appDirectories: directories)

        let cachedProject = makeProject(cwd: "/tmp/cached-project", updatedAt: 10)
        let cachedThread = makeThreadSummary(id: "thread-cached", cwd: cachedProject.cwd, title: "Cached", updatedAt: 10)
        try workspaceStore.saveSnapshot(
            CodexWorkspaceSnapshot(
                hostID: host.id,
                helperStatus: makeHelperStatus(),
                projects: [cachedProject],
                threads: [cachedThread],
                showsArchived: false,
                cachedAt: Date(timeIntervalSince1970: 100),
                lastLiveRefreshAt: Date(timeIntervalSince1970: 90),
                isStale: true
            )
        )

        let client = FakeHelperRPCClient { method, _ in
            throw TestError.unhandledMethod(method)
        }
        let service = CodexService(
            host: host,
            trustStore: trustStore,
            haptics: .noop,
            client: client,
            workspaceSnapshotStore: workspaceStore,
            threadDetailCacheStore: threadStore,
            metadataCacheStore: metadataStore
        )

        await service.loadInitialData()

        XCTAssertEqual(service.projects, [cachedProject])
        XCTAssertTrue(service.isShowingCachedData)
        XCTAssertTrue(service.isReadOnlyFallback)
        XCTAssertFalse(service.canMutateRemotely)

        let created = await service.createThread(in: cachedProject)

        XCTAssertNil(created)
        XCTAssertEqual(client.calls.filter { $0 == "threads.create" }.count, 0)
    }

    func testLateOpenResponseDoesNotOverwriteNewerSelection() async throws {
        let directories = try makeAppDirectories()
        let host = makeHost()
        let trustStore = HostTrustStore(appDirectories: directories)

        let threadA = makeThreadSummary(id: "thread-a", cwd: "/tmp/project-a", title: "Thread A", updatedAt: 10)
        let threadB = makeThreadSummary(id: "thread-b", cwd: "/tmp/project-b", title: "Thread B", updatedAt: 20)
        let detailA = makeThreadDetail(id: threadA.id, title: "Detail A")
        let detailB = makeThreadDetail(id: threadB.id, title: "Detail B")

        let client = FakeHelperRPCClient { method, payload in
            switch method {
            case "threads.open":
                let request = payload as? [String: Any]
                let threadID = request?["threadID"] as? String
                switch threadID {
                case threadA.id:
                    try await Task.sleep(for: .milliseconds(200))
                    return detailA
                case threadB.id:
                    try await Task.sleep(for: .milliseconds(40))
                    return detailB
                default:
                    throw TestError.unhandledMethod("\(method):\(threadID ?? "missing-thread-id")")
                }
            case "models.list":
                return [makeModelOption(id: "gpt-5.4")]
            case "branches.list":
                return [BranchInfo(name: "main", isCurrent: true)]
            default:
                throw TestError.unhandledMethod(method)
            }
        }

        let service = CodexService(
            host: host,
            trustStore: trustStore,
            haptics: .noop,
            client: client
        )

        let firstOpen = Task {
            await service.open(threadA)
        }
        try await Task.sleep(for: .milliseconds(20))

        let secondOpen = Task {
            await service.open(threadB)
        }

        await secondOpen.value
        await firstOpen.value

        XCTAssertEqual(service.selectedThread?.id, threadB.id)
        XCTAssertEqual(service.threadDetail?.thread.id, threadB.id)
        XCTAssertEqual(service.threadDetail?.thread.title, "Detail B")
        XCTAssertFalse(service.isReadOnlyFallback)
    }

    func testOpenRequestsRecentWindowAndUsesHelperGitRelevantPathsForGitStatus() async throws {
        let directories = try makeAppDirectories()
        let host = makeHost()
        let trustStore = HostTrustStore(appDirectories: directories)
        let thread = makeThreadSummary(id: "thread-recent", cwd: "/tmp/project-recent", title: "Recent", updatedAt: 10)
        let detail = makeThreadDetail(
            id: thread.id,
            title: "Recent Detail",
            timeline: makeTimelineItems(threadID: thread.id, range: 81...100),
            hasOlderHistory: true,
            oldestLoadedItemID: "item-81",
            newestLoadedItemID: "item-100",
            gitRelevantPaths: ["Sources/1.swift", "Sources/2.swift", "Sources/3.swift"]
        )

        var threadOpenPayload: [String: Any]?
        var gitStatusPayload: [String: Any]?
        let client = FakeHelperRPCClient { method, payload in
            switch method {
            case "threads.open":
                threadOpenPayload = payload as? [String: Any]
                return detail
            case "models.list":
                return [makeModelOption(id: "gpt-5.4")]
            case "branches.list":
                return [BranchInfo(name: "main", isCurrent: true)]
            case "git.status":
                gitStatusPayload = payload as? [String: Any]
                return makeGitStatus(cwd: detail.runtime.cwd)
            default:
                throw TestError.unhandledMethod(method)
            }
        }

        let service = CodexService(
            host: host,
            trustStore: trustStore,
            haptics: .noop,
            client: client,
            workspaceSnapshotStore: CodexWorkspaceSnapshotStore(appDirectories: directories),
            threadDetailCacheStore: CodexThreadDetailCacheStore(appDirectories: directories),
            metadataCacheStore: CodexMetadataCacheStore(appDirectories: directories)
        )

        await service.open(thread)

        XCTAssertEqual(threadOpenPayload?["threadID"] as? String, thread.id)
        XCTAssertEqual(threadOpenPayload?["historyMode"] as? String, "recent")
        XCTAssertEqual(threadOpenPayload?["windowSize"] as? Int, 80)
        XCTAssertNil(threadOpenPayload?["beforeItemID"])
        XCTAssertEqual(gitStatusPayload?["paths"] as? [String], detail.gitRelevantPaths)
        XCTAssertEqual(service.threadDetail?.gitRelevantPaths, detail.gitRelevantPaths)
    }

    func testLoadOlderHistoryPrependsItemsWithoutDuplicates() async throws {
        let host = makeHost()
        let trustStore = HostTrustStore(appDirectories: try makeAppDirectories())
        let thread = makeThreadSummary(id: "thread-history", cwd: "/tmp/project-history", title: "History", updatedAt: 10)
        let recentDetail = makeThreadDetail(
            id: thread.id,
            title: "History Detail",
            timeline: makeTimelineItems(threadID: thread.id, range: 81...100),
            hasOlderHistory: true,
            oldestLoadedItemID: "item-81",
            newestLoadedItemID: "item-100",
            gitRelevantPaths: ["Sources/history.swift"]
        )
        let olderPage = makeThreadDetail(
            id: thread.id,
            title: "History Detail",
            timeline: makeTimelineItems(threadID: thread.id, range: 61...81),
            hasOlderHistory: true,
            oldestLoadedItemID: "item-61",
            newestLoadedItemID: "item-81",
            gitRelevantPaths: ["Sources/history.swift"]
        )

        let client = FakeHelperRPCClient { method, payload in
            switch method {
            case "threads.open":
                return recentDetail
            case "threads.read":
                let request = payload as? [String: Any]
                if request?["beforeItemID"] as? String == "item-81" {
                    return olderPage
                }
                return recentDetail
            case "models.list":
                return [makeModelOption(id: "gpt-5.4")]
            case "branches.list":
                return [BranchInfo(name: "main", isCurrent: true)]
            case "git.status":
                return makeGitStatus(cwd: recentDetail.runtime.cwd)
            default:
                throw TestError.unhandledMethod(method)
            }
        }

        let service = CodexService(
            host: host,
            trustStore: trustStore,
            haptics: .noop,
            client: client
        )

        await service.open(thread)
        await service.loadOlderHistory()

        XCTAssertEqual(service.threadDetail?.timeline.first?.id, "item-61")
        XCTAssertEqual(service.threadDetail?.timeline.last?.id, "item-100")
        XCTAssertEqual(Set(service.threadDetail?.timeline.map(\.id) ?? []).count, service.threadDetail?.timeline.count)
        XCTAssertEqual(service.oldestLoadedItemID, "item-61")
        XCTAssertTrue(service.hasOlderHistory)
    }

    func testRefreshSelectedThreadPreservesPreviouslyLoadedOlderHistory() async throws {
        let host = makeHost()
        let trustStore = HostTrustStore(appDirectories: try makeAppDirectories())
        let thread = makeThreadSummary(id: "thread-refresh", cwd: "/tmp/project-refresh", title: "Refresh", updatedAt: 10)
        let recentDetail = makeThreadDetail(
            id: thread.id,
            title: "Refresh Detail",
            timeline: makeTimelineItems(threadID: thread.id, range: 81...100),
            hasOlderHistory: true,
            oldestLoadedItemID: "item-81",
            newestLoadedItemID: "item-100",
            gitRelevantPaths: ["Sources/refresh.swift"]
        )
        let olderPage = makeThreadDetail(
            id: thread.id,
            title: "Refresh Detail",
            timeline: makeTimelineItems(threadID: thread.id, range: 61...80),
            hasOlderHistory: false,
            oldestLoadedItemID: "item-61",
            newestLoadedItemID: "item-80",
            gitRelevantPaths: ["Sources/refresh.swift"]
        )
        let refreshedRecentDetail = makeThreadDetail(
            id: thread.id,
            title: "Refresh Detail",
            timeline: makeTimelineItems(threadID: thread.id, range: 82...101),
            hasOlderHistory: true,
            oldestLoadedItemID: "item-82",
            newestLoadedItemID: "item-101",
            gitRelevantPaths: ["Sources/refresh.swift", "Sources/new.swift"]
        )

        let client = FakeHelperRPCClient { method, payload in
            switch method {
            case "threads.open":
                return recentDetail
            case "threads.read":
                let request = payload as? [String: Any]
                if request?["beforeItemID"] as? String == "item-81" {
                    return olderPage
                }
                return refreshedRecentDetail
            case "models.list":
                return [makeModelOption(id: "gpt-5.4")]
            case "branches.list":
                return [BranchInfo(name: "main", isCurrent: true)]
            case "git.status":
                return makeGitStatus(cwd: recentDetail.runtime.cwd)
            default:
                throw TestError.unhandledMethod(method)
            }
        }

        let service = CodexService(
            host: host,
            trustStore: trustStore,
            haptics: .noop,
            client: client
        )

        await service.open(thread)
        await service.loadOlderHistory()
        await service.refreshSelectedThread()

        XCTAssertEqual(service.threadDetail?.timeline.first?.id, "item-61")
        XCTAssertEqual(service.threadDetail?.timeline.last?.id, "item-101")
        XCTAssertEqual(service.hasOlderHistory, false)
        XCTAssertTrue(service.threadDetail?.timeline.contains(where: { $0.id == "item-61" }) == true)
        XCTAssertEqual(service.threadDetail?.gitRelevantPaths, ["Sources/refresh.swift", "Sources/new.swift"])
    }
}

@MainActor
private final class FakeHelperRPCClient: HelperRPCRequesting {
    let handler: @MainActor (String, Any) async throws -> Any
    var eventHandler: ((HelperEventEnvelope) -> Void)?
    private(set) var calls: [String] = []

    init(handler: @escaping @MainActor (String, Any) async throws -> Any) {
        self.handler = handler
    }

    func updateTrustedHost(_ trustedHost: TrustedHost?) {}

    func request<Result: Decodable, Params: Encodable>(method: String, params: Params) async throws -> Result {
        calls.append(method)
        let value = try await handler(method, try Self.jsonObject(from: params))
        guard let typed = value as? Result else {
            throw TestError.typeMismatch(method)
        }
        return typed
    }

    private static func jsonObject<Params: Encodable>(from params: Params) throws -> Any {
        let encoder = JSONEncoder()
        let data = try encoder.encode(params)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

private enum TestError: LocalizedError {
    case unhandledMethod(String)
    case typeMismatch(String)

    var errorDescription: String? {
        switch self {
        case .unhandledMethod(let method):
            "Unhandled method \(method)"
        case .typeMismatch(let method):
            "Unexpected return type for \(method)"
        }
    }
}

private func makeHost() -> HostRecord {
    HostRecord(nickname: "Mac", hostname: "mac.local", username: "user")
}

private func makeAppDirectories() throws -> AppDirectories {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    return try AppDirectories(
        applicationSupportDirectory: root.appending(path: "ApplicationSupport", directoryHint: .isDirectory),
        cachesDirectory: root.appending(path: "Caches", directoryHint: .isDirectory)
    )
}

private func makeHelperStatus() -> HelperStatusSnapshot {
    HelperStatusSnapshot(
        helperVersion: "0.1.0",
        daemonRunning: true,
        appServerRunning: true,
        attachmentsRootPath: "/tmp/attachments",
        socketPath: "/tmp/spellwire.sock",
        logFilePath: "/tmp/spellwire.log",
        codexHome: "/tmp/.codex",
        lastActiveThreadId: nil,
        lastActiveCwd: nil,
        startedAt: nil,
        lastNotificationAt: nil,
        lastError: nil
    )
}

private func makeProject(cwd: String, updatedAt: TimeInterval) -> CodexProject {
    CodexProject(
        id: cwd,
        cwd: cwd,
        title: URL(filePath: cwd).lastPathComponent,
        threadCount: 1,
        activeThreadCount: 1,
        archivedThreadCount: 0,
        updatedAt: updatedAt
    )
}

private func makeThreadSummary(id: String, cwd: String, title: String, updatedAt: TimeInterval) -> CodexThreadSummary {
    CodexThreadSummary(
        id: id,
        projectID: cwd,
        cwd: cwd,
        title: title,
        preview: title,
        status: "idle",
        archived: false,
        updatedAt: updatedAt,
        createdAt: updatedAt - 1,
        sourceKind: "cli",
        agentNickname: nil,
        lastTurnID: "turn-\(id)"
    )
}

private func makeThreadDetail(
    id: String,
    title: String,
    timeline: [CodexTimelineItem]? = nil,
    hasOlderHistory: Bool = false,
    oldestLoadedItemID: String? = nil,
    newestLoadedItemID: String? = nil,
    gitRelevantPaths: [String] = []
) -> CodexThreadDetail {
    let cwd = "/tmp/project-\(id)"
    let thread = makeThreadSummary(id: id, cwd: cwd, title: title, updatedAt: 10)
    let resolvedTimeline = timeline ?? [
        CodexTimelineItem(
            id: "item-\(id)",
            turnID: "turn-\(id)",
            kind: "agentMessage",
            title: "Codex",
            body: title,
            changedPaths: nil,
            content: nil,
            status: "completed",
            timestamp: 10,
            source: "canonical"
        )
    ]
    return CodexThreadDetail(
        thread: thread,
        project: makeProject(cwd: cwd, updatedAt: 10),
        timeline: resolvedTimeline,
        activeTurnID: nil,
        recovery: nil,
        runtime: CodexThreadRuntime(
            cwd: cwd,
            model: "gpt-5.4",
            modelProvider: "openai",
            serviceTier: nil,
            reasoningEffort: "medium",
            approvalPolicy: "never",
            sandbox: CodexSandboxPolicy(type: "dangerFullAccess"),
            git: CodexGitInfo(sha: nil, branch: "main", originURL: nil)
        ),
        hasOlderHistory: hasOlderHistory,
        historyMode: .recent,
        oldestLoadedItemID: oldestLoadedItemID ?? resolvedTimeline.first?.id,
        newestLoadedItemID: newestLoadedItemID ?? resolvedTimeline.last?.id,
        gitRelevantPaths: gitRelevantPaths.isEmpty ? ["Sources/\(id).swift"] : gitRelevantPaths
    )
}

private func makeTimelineItems(threadID: String, range: ClosedRange<Int>) -> [CodexTimelineItem] {
    range.map { index in
        CodexTimelineItem(
            id: "item-\(index)",
            turnID: "turn-\(threadID)",
            kind: "agentMessage",
            title: "Codex",
            body: "Message \(index)",
            changedPaths: nil,
            content: nil,
            status: "completed",
            timestamp: TimeInterval(index),
            source: "canonical"
        )
    }
}

private func makeModelOption(id: String) -> ModelOption {
    ModelOption(
        id: id,
        model: id,
        displayName: id,
        description: "Model \(id)",
        hidden: false,
        supportedReasoningEfforts: [ReasoningEffortOption(reasoningEffort: "medium", description: "Medium")],
        defaultReasoningEffort: "medium",
        inputModalities: ["text"],
        additionalSpeedTiers: [],
        isDefault: true
    )
}

private func makeGitStatus(cwd: String) -> CodexGitStatus {
    CodexGitStatus(
        cwd: cwd,
        isRepository: true,
        branch: "main",
        hasChanges: false,
        additions: 0,
        deletions: 0,
        hasStaged: false,
        hasUnstaged: false,
        hasUntracked: false,
        pushRemote: "origin",
        canPush: true,
        canCreatePR: true,
        defaultBranch: "main",
        blockingReason: nil
    )
}
