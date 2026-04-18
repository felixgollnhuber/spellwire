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

    const detail = detailFromThread(activeThread, false, recovery, project);

    assert.equal(detail.thread.id, "thread-active");
    assert.equal(detail.thread.status, "active");
    assert.equal(detail.activeTurnID, "turn-2");
    assert.equal(detail.timeline.filter((item) => item.kind === "recovery").length, 1);
    assert.equal(detail.timeline.at(-1)?.body, "Recent rollout tail that was not yet reconciled.");
    assert.equal(threadToSummary(archivedThread, true).sourceKind, "subAgent");
});
