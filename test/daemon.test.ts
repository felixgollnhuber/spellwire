import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import { EventEmitter } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import { SpellwireDaemon } from "../src/helper/daemon.js";
import type { RuntimePaths } from "../src/shared/runtime-paths.js";

class FakeAppServer extends EventEmitter {
    threadListRequests: Array<{
        archived: boolean;
        cwd: string | null;
        searchTerm: string | null;
        limit: number | null;
        cursor: string | null;
    }> = [];
    threadStartRequests = 0;
    modelListRequests = 0;

    currentSnapshot() {
        return {
            running: true,
            pid: 123,
            codexHome: "/tmp/.codex",
            userAgent: "spellwire-test",
        };
    }

    async ensureStarted(): Promise<void> {}

    async shutdown(): Promise<void> {}

    async request<T>(method: string, params: unknown): Promise<T> {
        switch (method) {
            case "thread/list": {
                const request = params as {
                    archived?: boolean;
                    cwd?: string | null;
                    searchTerm?: string | null;
                    limit?: number | null;
                    cursor?: string | null;
                };
                const archived = Boolean(request.archived);
                const limit = request.limit ?? null;
                const cursor = request.cursor ?? null;
                this.threadListRequests.push({
                    archived,
                    cwd: request.cwd ?? null,
                    searchTerm: request.searchTerm ?? null,
                    limit,
                    cursor,
                });
                const data = archived
                    ? [
                        makeRawThread({
                            id: "thread-archived",
                            cwd: "/tmp/project-a",
                            preview: "Archived",
                            updatedAt: 150,
                        }),
                    ]
                    : limit === 1 && cursor === null
                      ? [
                            makeRawThread({
                                id: "thread-active",
                                cwd: "/tmp/project-a",
                                preview: "Active",
                                updatedAt: 200,
                            }),
                        ]
                      : [
                        makeRawThread({
                            id: "thread-active",
                            cwd: "/tmp/project-a",
                            preview: "Active",
                            updatedAt: 200,
                        }),
                        ];
                return {
                    data,
                    nextCursor: limit === 1 && cursor === null ? "next-page" : null,
                } as T;
            }
            case "thread/start":
                this.threadStartRequests += 1;
                return {
                    thread: makeRawThread({
                        id: `created-${this.threadStartRequests}`,
                        cwd: String((params as { cwd: string }).cwd),
                        preview: "Created thread",
                        updatedAt: 300,
                    }),
                } as T;
            case "model/list":
                this.modelListRequests += 1;
                return {
                    data: [
                        {
                            id: "model-1",
                            model: "gpt-5.4",
                            displayName: "GPT-5.4",
                            description: "Test model",
                            hidden: false,
                            supportedReasoningEfforts: [],
                            defaultReasoningEffort: "medium",
                            inputModalities: ["text"],
                            additionalSpeedTiers: [],
                            isDefault: true,
                        },
                    ],
                    nextCursor: null,
                } as T;
            default:
                throw new Error(`Unhandled fake app-server method: ${method}`);
        }
    }
}

class FakeDesktopBridge {
    async rememberLastActiveThread(_threadID: string, _cwd: string): Promise<void> {}
    async openThread(_threadID: string, _cwd: string): Promise<{ opened: boolean; bestEffort: boolean }> {
        return { opened: true, bestEffort: true };
    }
}

test("SpellwireDaemon reuses cached inventory and model reads within TTL", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "spellwire-daemon-"));

    try {
        const fakeAppServer = new FakeAppServer();
        const daemon = new SpellwireDaemon(makeRuntimePaths(root), {
            appServer: fakeAppServer,
            desktopBridge: new FakeDesktopBridge(),
        });
        const invoke = (daemon as any).handleRequest.bind(daemon) as (request: Record<string, unknown>) => Promise<unknown>;

        const firstProjects = await invoke({
            kind: "request",
            id: "1",
            method: "projects.list",
            params: {},
        });
        const secondThreads = await invoke({
            kind: "request",
            id: "2",
            method: "threads.list",
            params: { archived: false },
        });
        const firstModels = await invoke({
            kind: "request",
            id: "3",
            method: "models.list",
            params: {},
        });
        const secondModels = await invoke({
            kind: "request",
            id: "4",
            method: "models.list",
            params: {},
        });

        assert.equal(Array.isArray(firstProjects), true);
        assert.equal(Array.isArray(secondThreads), true);
        assert.equal(Array.isArray(firstModels), true);
        assert.equal(Array.isArray(secondModels), true);
        assert.deepEqual(fakeAppServer.threadListRequests, [
            { archived: false, cwd: null, searchTerm: null, limit: 100, cursor: null },
            { archived: true, cwd: null, searchTerm: null, limit: 100, cursor: null },
        ]);
        assert.equal(fakeAppServer.modelListRequests, 1);
    } finally {
        await rm(root, { recursive: true, force: true });
    }
});

test("SpellwireDaemon invalidates cached inventory after notifications and local mutations", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "spellwire-daemon-"));

    try {
        const fakeAppServer = new FakeAppServer();
        const daemon = new SpellwireDaemon(makeRuntimePaths(root), {
            appServer: fakeAppServer,
            desktopBridge: new FakeDesktopBridge(),
        });
        const invoke = (daemon as any).handleRequest.bind(daemon) as (request: Record<string, unknown>) => Promise<unknown>;

        await invoke({
            kind: "request",
            id: "1",
            method: "threads.list",
            params: { archived: false },
        });
        await invoke({
            kind: "request",
            id: "2",
            method: "threads.list",
            params: { archived: false },
        });
        assert.equal(fakeAppServer.threadListRequests.length, 1);

        fakeAppServer.emit("notification", { method: "turn/completed", params: {} });

        await invoke({
            kind: "request",
            id: "3",
            method: "threads.list",
            params: { archived: false },
        });
        assert.equal(fakeAppServer.threadListRequests.length, 2);

        await invoke({
            kind: "request",
            id: "4",
            method: "threads.create",
            params: { cwd: "/tmp/project-a" },
        });
        await invoke({
            kind: "request",
            id: "5",
            method: "threads.list",
            params: { archived: false },
        });
        assert.equal(fakeAppServer.threadListRequests.length, 3);
    } finally {
        await rm(root, { recursive: true, force: true });
    }
});

test("SpellwireDaemon forwards thread list filters and stops after the requested limit", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "spellwire-daemon-"));

    try {
        const fakeAppServer = new FakeAppServer();
        const daemon = new SpellwireDaemon(makeRuntimePaths(root), {
            appServer: fakeAppServer,
            desktopBridge: new FakeDesktopBridge(),
        });
        const invoke = (daemon as any).handleRequest.bind(daemon) as (request: Record<string, unknown>) => Promise<unknown>;

        const threads = await invoke({
            kind: "request",
            id: "1",
            method: "threads.list",
            params: {
                archived: false,
                projectID: "/tmp/project-a",
                query: "active",
                limit: 1,
            },
        });

        assert.equal(Array.isArray(threads), true);
        assert.deepEqual(fakeAppServer.threadListRequests, [
            {
                archived: false,
                cwd: "/tmp/project-a",
                searchTerm: "active",
                limit: 1,
                cursor: null,
            },
        ]);
    } finally {
        await rm(root, { recursive: true, force: true });
    }
});

function makeRuntimePaths(root: string): RuntimePaths {
    return {
        packageRoot: root,
        runtimeRoot: root,
        attachmentsRootPath: path.join(root, "attachments"),
        socketPath: path.join(root, "run", "spellwire.sock"),
        stateFilePath: path.join(root, "state", "helper-state.json"),
        logFilePath: path.join(root, "logs", "helper.jsonl"),
        launchAgentPlistPath: path.join(root, "LaunchAgents", "dev.spellwire.helper.plist"),
        launchAgentLabel: "dev.spellwire.helper",
        launchAgentStdoutPath: path.join(root, "logs", "launch.stdout.log"),
        launchAgentStderrPath: path.join(root, "logs", "launch.stderr.log"),
        nodePath: process.execPath,
        cliEntrypointPath: path.join(root, "dist", "src", "cli.js"),
        inheritedPath: process.env.PATH ?? "/usr/bin:/bin",
        codexExecutablePath: null,
    };
}

function makeRawThread(overrides: {
    id: string;
    cwd: string;
    preview: string;
    updatedAt: number;
}) {
    return {
        id: overrides.id,
        cwd: overrides.cwd,
        name: null,
        preview: overrides.preview,
        status: { type: "idle" },
        updatedAt: overrides.updatedAt,
        createdAt: overrides.updatedAt - 10,
        source: "cli",
        agentNickname: null,
        turns: [],
    };
}
