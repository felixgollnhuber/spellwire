import XCTest
@testable import spellwire_ios

final class CodexGitPresentationTests: XCTestCase {
    func testInlineActionsAnchorToLatestAgentMessageWhenThreadIsIdleAndDirty() {
        let timeline = [
            makeItem(id: "user-1", kind: "userMessage"),
            makeItem(id: "agent-1", kind: "agentMessage"),
            makeItem(id: "plan-1", kind: "plan"),
            makeItem(id: "agent-2", kind: "agentMessage"),
        ]

        let anchor = CodexGitPresentation.inlineActionAnchorItemID(
            timeline: timeline,
            hasChanges: true,
            isThreadIdle: true
        )

        XCTAssertEqual(anchor, "agent-2")
    }

    func testInlineActionsHideWhenUserMessageFollowsLatestAgentMessage() {
        let timeline = [
            makeItem(id: "agent-1", kind: "agentMessage"),
            makeItem(id: "user-2", kind: "userMessage"),
        ]

        let anchor = CodexGitPresentation.inlineActionAnchorItemID(
            timeline: timeline,
            hasChanges: true,
            isThreadIdle: true
        )

        XCTAssertNil(anchor)
    }

    func testBranchWarningUsesFirstPreviewWarning() {
        let preview = GitCommitPreview(
            cwd: "/tmp/spellwire",
            branch: "main",
            pushRemote: "origin",
            defaultBranch: "main",
            defaultCommitMessage: "Update files",
            defaultPRTitle: "Update files",
            defaultPRBody: "Body",
            actions: [],
            warnings: ["You are about to push directly to main."]
        )

        XCTAssertEqual(
            CodexGitPresentation.branchWarning(preview: preview),
            "You are about to push directly to main."
        )
    }

    func testRelevantPathsUseCompletedFileChangesAndDeduplicate() {
        let timeline = [
            makeItem(id: "agent-1", kind: "agentMessage"),
            makeItem(id: "files-1", kind: "fileChange", changedPaths: ["src/helper/git.ts", "README.md"]),
            makeItem(id: "files-2", kind: "fileChange", changedPaths: ["README.md", "PLAN.md"]),
        ]

        XCTAssertEqual(
            CodexGitPresentation.relevantPaths(timeline: timeline),
            ["src/helper/git.ts", "README.md", "PLAN.md"]
        )
    }

    private func makeItem(id: String, kind: String, changedPaths: [String]? = nil) -> CodexTimelineItem {
        CodexTimelineItem(
            id: id,
            turnID: "turn",
            kind: kind,
            title: kind,
            body: kind,
            changedPaths: changedPaths,
            content: nil,
            status: "completed",
            timestamp: 0,
            source: "canonical"
        )
    }
}
