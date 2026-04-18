import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { SessionRecoveryIndex } from "../src/helper/session-recovery-index.js";

test("SessionRecoveryIndex finds rollout files and returns recent message snippets", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "spellwire-recovery-"));
    const sessionDirectory = path.join(root, "2026", "04", "18");
    await mkdir(sessionDirectory, { recursive: true });

    const rolloutPath = path.join(sessionDirectory, "rollout-thread-123.jsonl");
    await writeFile(
        rolloutPath,
        [
            JSON.stringify({ payload: { id: "thread-123" } }),
            JSON.stringify({
                timestamp: "2026-04-18T10:00:00Z",
                type: "event_msg",
                payload: { type: "user_message", message: "Show my archived threads" },
            }),
            JSON.stringify({
                timestamp: "2026-04-18T10:00:01Z",
                type: "event_msg",
                payload: { type: "agent_message", message: "Loading archived thread list" },
            }),
            JSON.stringify({
                timestamp: "2026-04-18T10:00:02Z",
                type: "event_msg",
                payload: { type: "tool_call", message: "ignored" },
            }),
        ].join("\n"),
        "utf8",
    );

    try {
        const index = new SessionRecoveryIndex(root);
        const recovery = await index.recentRecovery("thread-123");

        assert.ok(recovery);
        assert.equal(recovery.rolloutPath, rolloutPath);
        assert.equal(recovery.lastEventAt, "2026-04-18T10:00:01Z");
        assert.deepEqual(
            recovery.snippets.map((snippet) => snippet.text),
            ["Show my archived threads", "Loading archived thread list"],
        );
    } finally {
        await rm(root, { recursive: true, force: true });
    }
});
