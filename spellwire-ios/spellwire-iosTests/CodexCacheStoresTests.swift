import XCTest
@testable import spellwire_ios

final class CodexCacheStoresTests: XCTestCase {
    func testWorkspaceSnapshotStoreReloadsSavedSnapshot() throws {
        let directories = try makeAppDirectories()
        let store = CodexWorkspaceSnapshotStore(appDirectories: directories)
        let snapshot = CodexWorkspaceSnapshot(
            hostID: UUID(),
            helperStatus: makeHelperStatus(),
            projects: [makeProject(cwd: "/tmp/project-a", updatedAt: 10)],
            threads: [makeThreadSummary(id: "thread-1", cwd: "/tmp/project-a", title: "Cached thread", updatedAt: 10)],
            showsArchived: false,
            cachedAt: Date(timeIntervalSince1970: 100),
            lastLiveRefreshAt: Date(timeIntervalSince1970: 90),
            isStale: true
        )

        try store.saveSnapshot(snapshot)

        XCTAssertEqual(try store.snapshot(for: snapshot.hostID), snapshot)
    }

    func testThreadDetailStoreEvictsLeastRecentlyOpenedEntriesPerHost() throws {
        let directories = try makeAppDirectories()
        let store = CodexThreadDetailCacheStore(appDirectories: directories)
        let hostID = UUID()

        for index in 0..<12 {
            try store.saveEntry(
                CachedThreadDetailEntry(
                    hostID: hostID,
                    threadID: "thread-\(index)",
                    detail: makeThreadDetail(id: "thread-\(index)", title: "Thread \(index)"),
                    cachedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    lastLiveRefreshAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    lastOpenedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    isStale: false
                )
            )
        }

        let entries = try store.entries(for: hostID)
        XCTAssertEqual(entries.count, 10)
        XCTAssertEqual(entries.first?.threadID, "thread-11")
        XCTAssertNil(try store.entry(for: hostID, threadID: "thread-0"))
        XCTAssertNil(try store.entry(for: hostID, threadID: "thread-1"))
    }

    func testMetadataStoreEvictsBranchEntriesAndClearsHostData() throws {
        let directories = try makeAppDirectories()
        let store = CodexMetadataCacheStore(appDirectories: directories)
        let hostID = UUID()

        try store.saveModels(
            CachedModelListEntry(
                hostID: hostID,
                models: [makeModelOption(id: "model-1")],
                cachedAt: .now,
                lastLiveRefreshAt: .now,
                isStale: false
            )
        )

        for index in 0..<12 {
            try store.saveBranches(
                CachedBranchListEntry(
                    hostID: hostID,
                    cwd: "/tmp/project-\(index)",
                    branches: [BranchInfo(name: "branch-\(index)", isCurrent: true)],
                    cachedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    lastLiveRefreshAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    lastOpenedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    isStale: false
                )
            )
        }

        XCTAssertEqual(try store.cachedBranches(for: hostID, cwd: "/tmp/project-11")?.branches.first?.name, "branch-11")
        XCTAssertNil(try store.cachedBranches(for: hostID, cwd: "/tmp/project-0"))

        try store.removeEntries(for: hostID)

        XCTAssertNil(try store.cachedModels(for: hostID))
        XCTAssertNil(try store.cachedBranches(for: hostID, cwd: "/tmp/project-11"))
    }
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

private func makeThreadDetail(id: String, title: String) -> CodexThreadDetail {
    let cwd = "/tmp/project-\(id)"
    let thread = makeThreadSummary(id: id, cwd: cwd, title: title, updatedAt: 10)
    return CodexThreadDetail(
        thread: thread,
        project: makeProject(cwd: cwd, updatedAt: 10),
        timeline: [
            CodexTimelineItem(
                id: "item-\(id)",
                turnID: "turn-\(id)",
                kind: "agentMessage",
                title: "Codex",
                body: "Body \(title)",
                changedPaths: nil,
                content: nil,
                status: "completed",
                timestamp: 10,
                source: "canonical"
            )
        ],
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
        )
    )
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
