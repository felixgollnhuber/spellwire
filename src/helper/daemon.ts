import net from "node:net";
import { rmSync } from "node:fs";
import type {
    CodexProject,
    CodexThreadDetail,
    CodexThreadSummary,
    DesktopOpenRequest,
    ThreadCreateParams,
    HelperEventEnvelope,
    HelperFailureResponseEnvelope,
    HelperRequestEnvelope,
    HelperStatusSnapshot,
    HelperSuccessResponseEnvelope,
    ThreadsListParams,
    TurnInterruptRequest,
    TurnMutationResult,
    TurnPromptParams,
    TurnSteerPromptParams,
} from "../shared/protocol.js";
import { createJSONLineReader, serializeJSONLine } from "../shared/json-lines.js";
import { runtimePaths, type RuntimePaths, spellwireVersion, ensureRuntimeDirectories } from "../shared/runtime-paths.js";
import { AppServerClient } from "./app-server-client.js";
import { DesktopBridge } from "./desktop-bridge.js";
import { JSONLLogger } from "./logger.js";
import { detailFromThread, projectsFromThreads, threadToSummary } from "./mappers.js";
import { PreviewRegistry } from "./preview-registry.js";
import { SessionRecoveryIndex } from "./session-recovery-index.js";
import { patchDaemonState, readDaemonState } from "./state-store.js";

const allSourceKinds = [
    "cli",
    "vscode",
    "exec",
    "appServer",
    "subAgent",
    "subAgentReview",
    "subAgentCompact",
    "subAgentThreadSpawn",
    "subAgentOther",
];

interface RawThread {
    id: string;
    cwd: string;
    name: string | null;
    preview: string;
    status: { type?: string };
    updatedAt: number;
    createdAt: number;
    source: unknown;
    agentNickname: string | null;
    turns: Array<{
        id: string;
        items: Array<{ id: string; type: string; [key: string]: unknown }>;
        status: string;
        startedAt: number | null;
        completedAt: number | null;
    }>;
    [key: string]: unknown;
}

export class SpellwireDaemon {
    private readonly paths: RuntimePaths;
    private readonly logger: JSONLLogger;
    private readonly appServer: AppServerClient;
    private readonly recoveryIndex = new SessionRecoveryIndex();
    private readonly previewRegistry = new PreviewRegistry();
    private readonly desktopBridge: DesktopBridge;
    private server: net.Server | null = null;
    private readonly sockets = new Set<net.Socket>();

    constructor(paths = runtimePaths()) {
        this.paths = paths;
        ensureRuntimeDirectories(paths);
        this.logger = new JSONLLogger(paths.logFilePath);
        this.appServer = new AppServerClient(this.logger);
        this.desktopBridge = new DesktopBridge(paths);
        this.appServer.on("notification", (notification) => {
            void patchDaemonState(this.paths, {
                appServerPID: this.appServer.currentSnapshot().pid,
                codexHome: this.appServer.currentSnapshot().codexHome,
                userAgent: this.appServer.currentSnapshot().userAgent,
                lastNotificationAt: new Date().toISOString(),
                lastError: null,
            });
            this.broadcast({
                kind: "event",
                event: "app.notification",
                data: notification as unknown as Record<string, unknown>,
            });
        });
        this.appServer.on("exit", (error: Error) => {
            void patchDaemonState(this.paths, {
                appServerPID: null,
                lastError: error.message,
            });
            this.broadcast({
                kind: "event",
                event: "helper.status.changed",
                data: {
                    reason: "app-server-exit",
                    error: error.message,
                },
            });
        });
    }

    async start(): Promise<void> {
        rmSync(this.paths.socketPath, { force: true });
        await patchDaemonState(this.paths, {
            pid: process.pid,
            startedAt: new Date().toISOString(),
            appServerPID: null,
            lastError: null,
        });
        await this.appServer.ensureStarted();
        await patchDaemonState(this.paths, {
            appServerPID: this.appServer.currentSnapshot().pid,
            codexHome: this.appServer.currentSnapshot().codexHome,
            userAgent: this.appServer.currentSnapshot().userAgent,
        });

        this.server = net.createServer((socket) => {
            this.sockets.add(socket);
            createJSONLineReader(
                socket,
                (value) => {
                    void this.handleSocketMessage(socket, value as HelperRequestEnvelope);
                },
                (error, line) => {
                    this.logger.warn("Failed to decode daemon socket line", { error: error.message, line });
                },
            );
            socket.on("close", () => {
                this.sockets.delete(socket);
            });
        });

        await new Promise<void>((resolve, reject) => {
            this.server?.once("error", reject);
            this.server?.listen(this.paths.socketPath, resolve);
        });
        this.logger.info("Spellwire daemon listening", { socketPath: this.paths.socketPath });
    }

    async stop(): Promise<void> {
        for (const socket of this.sockets) {
            socket.end();
        }
        if (this.server) {
            await new Promise<void>((resolve) => this.server?.close(() => resolve()));
            this.server = null;
        }
        await this.appServer.shutdown();
        rmSync(this.paths.socketPath, { force: true });
    }

    private async handleSocketMessage(socket: net.Socket, request: HelperRequestEnvelope): Promise<void> {
        if (request.kind !== "request") {
            return;
        }

        try {
            const result = await this.handleRequest(request);
            socket.write(
                serializeJSONLine({
                    kind: "response",
                    id: request.id,
                    ok: true,
                    result,
                } satisfies HelperSuccessResponseEnvelope),
            );
        } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            await patchDaemonState(this.paths, {
                lastError: message,
            });
            socket.write(
                serializeJSONLine({
                    kind: "response",
                    id: request.id,
                    ok: false,
                    error: {
                        code: "internal_error",
                        message,
                    },
                } satisfies HelperFailureResponseEnvelope),
            );
        }
    }

    private async handleRequest(request: HelperRequestEnvelope): Promise<unknown> {
        switch (request.method) {
            case "helper.status":
                return this.statusSnapshot();
            case "projects.list":
                return this.projectsList();
            case "threads.list":
                return this.threadsList(request.params as unknown as ThreadsListParams);
            case "threads.create":
                return this.threadCreate(request.params as unknown as ThreadCreateParams);
            case "threads.open":
                return this.threadDetail(String((request.params as unknown as { threadID?: string; threadId?: string }).threadID ?? (request.params as unknown as { threadID?: string; threadId?: string }).threadId ?? ""));
            case "threads.read":
                return this.threadDetail(String((request.params as unknown as { threadID?: string; threadId?: string }).threadID ?? (request.params as unknown as { threadID?: string; threadId?: string }).threadId ?? ""), false);
            case "turns.start":
                return this.turnStart(request.params as unknown as TurnPromptParams);
            case "turns.steer":
                return this.turnSteer(request.params as unknown as TurnSteerPromptParams);
            case "turns.interrupt":
                return this.turnInterrupt(request.params as unknown as TurnInterruptRequest);
            case "desktop.open":
                return this.desktopOpen(request.params as unknown as DesktopOpenRequest);
            case "previews.list":
                return this.previewRegistry.list();
            default:
                throw new Error(`Unsupported method: ${request.method satisfies never}`);
        }
    }

    private async statusSnapshot(): Promise<HelperStatusSnapshot> {
        const state = await readDaemonState(this.paths);
        const snapshot = this.appServer.currentSnapshot();
        return {
            helperVersion: spellwireVersion(),
            daemonRunning: true,
            appServerRunning: snapshot.running,
            socketPath: this.paths.socketPath,
            logFilePath: this.paths.logFilePath,
            codexHome: snapshot.codexHome ?? state.codexHome,
            lastActiveThreadId: state.lastActiveThreadId,
            lastActiveCwd: state.lastActiveCwd,
            startedAt: state.startedAt,
            lastNotificationAt: state.lastNotificationAt,
            lastError: state.lastError,
        };
    }

    private async projectsList(): Promise<CodexProject[]> {
        const { activeThreads, archivedThreads } = await this.threadInventory();
        return projectsFromThreads(activeThreads, archivedThreads);
    }

    private async threadsList(params: ThreadsListParams): Promise<CodexThreadSummary[]> {
        const archived = params.archived ?? false;
        const threads = await this.loadThreads(archived, {
            cwd: params.projectID ?? undefined,
            searchTerm: params.query ?? undefined,
            limit: params.limit ?? undefined,
        });
        return threads
            .map((thread) => threadToSummary(thread as unknown as Parameters<typeof threadToSummary>[0], archived))
            .sort((left, right) => right.updatedAt - left.updatedAt);
    }

    private async threadCreate(params: ThreadCreateParams): Promise<CodexThreadSummary> {
        if (!params.cwd) {
            throw new Error("cwd is required.");
        }

        const response = await this.appServer.request<{ thread: RawThread }>("thread/start", {
            cwd: params.cwd,
        });

        return threadToSummary(
            response.thread as unknown as Parameters<typeof threadToSummary>[0],
            false,
        );
    }

    private async threadDetail(threadID: string, resume = true): Promise<CodexThreadDetail> {
        if (!threadID) {
            throw new Error("threadID is required.");
        }

        const { activeThreads, archivedThreads } = await this.threadInventory();
        const archived = archivedThreads.some((thread) => thread.id === threadID);
        if (resume) {
            await this.appServer.request("thread/resume", {
                threadId: threadID,
            });
        }
        const response = await this.appServer.request<{ thread: RawThread }>("thread/read", {
            threadId: threadID,
            includeTurns: true,
        });

        const thread = response.thread;
        const projects = projectsFromThreads(activeThreads, archivedThreads);
        const project =
            projects.find((candidate) => candidate.id === thread.cwd) ??
            ({
                id: thread.cwd,
                cwd: thread.cwd,
                title: thread.cwd.split("/").at(-1) ?? thread.cwd,
                threadCount: 1,
                activeThreadCount: archived ? 0 : 1,
                archivedThreadCount: archived ? 1 : 0,
                updatedAt: Number(thread.updatedAt ?? Math.floor(Date.now() / 1000)),
            } satisfies CodexProject);
        const recovery = await this.recoveryIndex.recentRecovery(threadID);

        await this.desktopBridge.rememberLastActiveThread(threadID, thread.cwd);
        return detailFromThread(
            thread as unknown as Parameters<typeof detailFromThread>[0],
            archived,
            recovery,
            project,
        );
    }

    private async turnStart(params: TurnPromptParams): Promise<TurnMutationResult> {
        await this.appServer.request("thread/resume", {
            threadId: params.threadID,
        });
        const response = await this.appServer.request<{ turn: { id: string } }>("turn/start", {
            threadId: params.threadID,
            input: [
                {
                    type: "text",
                    text: params.prompt,
                    text_elements: [],
                },
            ],
        });
        return {
            threadID: params.threadID,
            turnID: response.turn.id,
        };
    }

    private async turnSteer(params: TurnSteerPromptParams): Promise<TurnMutationResult> {
        const response = await this.appServer.request<{ turn: { id: string } }>("turn/steer", {
            threadId: params.threadID,
            expectedTurnId: params.expectedTurnID,
            input: [
                {
                    type: "text",
                    text: params.prompt,
                    text_elements: [],
                },
            ],
        });
        return {
            threadID: params.threadID,
            turnID: response.turn.id,
        };
    }

    private async turnInterrupt(params: TurnInterruptRequest): Promise<TurnMutationResult> {
        await this.appServer.request("turn/interrupt", {
            threadId: params.threadID,
            turnId: params.turnID,
        });
        return {
            threadID: params.threadID,
            turnID: params.turnID,
        };
    }

    private async desktopOpen(params: DesktopOpenRequest): Promise<{ opened: boolean; bestEffort: boolean }> {
        const detail = await this.threadDetail(params.threadID);
        return this.desktopBridge.openThread(params.threadID, detail.thread.cwd);
    }

    private broadcast(event: HelperEventEnvelope): void {
        const payload = serializeJSONLine(event);
        for (const socket of this.sockets) {
            socket.write(payload);
        }
    }

    private async threadInventory(): Promise<{ activeThreads: RawThread[]; archivedThreads: RawThread[] }> {
        const [activeThreads, archivedThreads] = await Promise.all([
            this.loadThreads(false),
            this.loadThreads(true),
        ]);
        return { activeThreads, archivedThreads };
    }

    private async loadThreads(archived: boolean, filters?: { cwd?: string; searchTerm?: string; limit?: number }): Promise<RawThread[]> {
        const threads: RawThread[] = [];
        let cursor: string | null = null;

        do {
            const response: { data: RawThread[]; nextCursor: string | null } = await this.appServer.request("thread/list", {
                cursor,
                limit: filters?.limit ?? 100,
                sortKey: "updated_at",
                sourceKinds: allSourceKinds,
                archived,
                cwd: filters?.cwd ?? null,
                searchTerm: filters?.searchTerm ?? null,
            });
            threads.push(...response.data);
            cursor = response.nextCursor;
        } while (cursor);

        return threads;
    }
}

export async function runForegroundDaemon(): Promise<void> {
    const daemon = new SpellwireDaemon();
    await daemon.start();

    const handleSignal = async () => {
        await daemon.stop();
        process.exit(0);
    };

    process.on("SIGINT", () => {
        void handleSignal();
    });
    process.on("SIGTERM", () => {
        void handleSignal();
    });
}
