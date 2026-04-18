import test from "node:test";
import assert from "node:assert/strict";
import { detailFromThread, projectsFromThreads, threadToSummary } from "../src/helper/mappers.js";
import type { CodexProject, CodexRecoveryState } from "../src/shared/protocol.js";

const activeThread = {
    id: "thread-active",
    cwd: "/Users/felixgollnhuber/Developer/spellwire",
    name: "Inbox",
    preview: "Investigate helper health",
    status: { type: "active" },
    updatedAt: 200,
    createdAt: 100,
    source: "cli",
    agentNickname: "codex",
    turns: [
        {
            id: "turn-1",
            status: "completed",
            startedAt: 101,
            completedAt: 110,
            items: [
                {
                    id: "user-1",
                    type: "userMessage",
                    content: [{ type: "text", text: "Show helper status" }],
                },
                {
                    id: "agent-1",
                    type: "agentMessage",
                    text: "Helper is up.",
                },
            ],
        },
        {
            id: "turn-2",
            status: "inProgress",
            startedAt: 120,
            completedAt: null,
            items: [
                {
                    id: "plan-1",
                    type: "plan",
                    text: "Sync threads and recover recent rollout state.",
                },
            ],
        },
    ],
};

const archivedThread = {
    id: "thread-archived",
    cwd: "/Users/felixgollnhuber/Developer/spellwire",
    name: null,
    preview: "Old archive preview",
    status: { type: "idle" },
    updatedAt: 150,
    createdAt: 90,
    source: { subAgent: true },
    agentNickname: null,
    turns: [],
};

test("projectsFromThreads groups exact cwd values and counts active vs archived threads", () => {
    const projects = projectsFromThreads([activeThread], [archivedThread]);

    assert.equal(projects.length, 1);
    assert.deepEqual(projects[0], {
        id: "/Users/felixgollnhuber/Developer/spellwire",
        cwd: "/Users/felixgollnhuber/Developer/spellwire",
        title: "spellwire",
        threadCount: 2,
        activeThreadCount: 1,
        archivedThreadCount: 1,
        updatedAt: 200,
    });
});

test("detailFromThread preserves canonical timeline and appends unique recovery snippets", () => {
    const project: CodexProject = {
        id: activeThread.cwd,
        cwd: activeThread.cwd,
        title: "spellwire",
        threadCount: 2,
        activeThreadCount: 1,
        archivedThreadCount: 1,
        updatedAt: 200,
    };
    const recovery: CodexRecoveryState = {
        rolloutPath: "/tmp/rollout-thread-active.jsonl",
        lastEventAt: "2026-04-18T10:00:00Z",
        snippets: [
            {
                id: "recovery-1",
                text: "Helper is up.",
                timestamp: "2026-04-18T09:59:00Z",
                source: "rollout",
            },
            {
                id: "recovery-2",
                text: "Recent rollout tail that was not yet reconciled.",
                timestamp: "2026-04-18T10:00:00Z",
                source: "rollout",
            },
        ],
    };
    const runtime = {
        cwd: activeThread.cwd,
        model: "gpt-5.4",
        modelProvider: "openai",
        serviceTier: "fast",
        reasoningEffort: "high",
        approvalPolicy: "never",
        sandbox: { type: "dangerFullAccess" as const },
        git: {
            sha: "abc123",
            branch: "main",
            originURL: "git@example.com:spellwire.git",
        },
    };

    const detail = detailFromThread(activeThread, false, recovery, project, runtime);

    assert.equal(detail.thread.id, "thread-active");
    assert.equal(detail.thread.status, "active");
    assert.equal(detail.activeTurnID, "turn-2");
    assert.equal(detail.runtime.model, "gpt-5.4");
    assert.equal(detail.runtime.git?.branch, "main");
    assert.equal(detail.timeline.filter((item) => item.kind === "recovery").length, 1);
    assert.equal(detail.timeline.at(-1)?.body, "Recent rollout tail that was not yet reconciled.");
    assert.equal(threadToSummary(archivedThread, true).sourceKind, "subAgent");
});

test("detailFromThread preserves structured user-message content for images", () => {
    const threadWithImage = {
        ...activeThread,
        turns: [
            {
                id: "turn-image",
                status: "completed",
                startedAt: 130,
                completedAt: 131,
                items: [
                    {
                        id: "user-image",
                        type: "userMessage",
                        content: [
                            { type: "text", text: "Please inspect this" },
                            { type: "localImage", path: "/tmp/chat/upload.png" },
                            { type: "image", url: "https://example.com/reference.png" },
                        ],
                    },
                ],
            },
        ],
    };

    const project: CodexProject = {
        id: threadWithImage.cwd,
        cwd: threadWithImage.cwd,
        title: "spellwire",
        threadCount: 1,
        activeThreadCount: 1,
        archivedThreadCount: 0,
        updatedAt: threadWithImage.updatedAt,
    };
    const runtime = {
        cwd: threadWithImage.cwd,
        model: "gpt-5.4",
        modelProvider: "openai",
        serviceTier: null,
        reasoningEffort: "medium",
        approvalPolicy: "never",
        sandbox: { type: "dangerFullAccess" as const },
        git: null,
    };

    const detail = detailFromThread(threadWithImage, false, null, project, runtime);
    const userMessage = detail.timeline.find((item) => item.id === "user-image");

    assert.deepEqual(userMessage?.content, [
        { type: "text", text: "Please inspect this" },
        { type: "localImage", path: "/tmp/chat/upload.png" },
        { type: "image", url: "https://example.com/reference.png" },
    ]);
    assert.equal(userMessage?.body, "Please inspect this\n[image]\n[image]");
});
