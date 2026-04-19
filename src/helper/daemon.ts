import net from "node:net";
import { rmSync } from "node:fs";
import type {
    BranchInfo,
    BranchListParams,
    BranchSwitchParams,
    BranchSwitchResult,
    CodexGitDiff,
    CodexGitStatus,
    CodexProject,
    CodexThreadDetail,
    CodexThreadSummary,
    DesktopOpenRequest,
    GitCommitExecuteParams,
    GitCommitPreview,
    GitCommitPreviewParams,
    GitDiffParams,
    GitStatusParams,
    ThreadCreateParams,
    HelperEventEnvelope,
    HelperFailureResponseEnvelope,
    HelperRequestEnvelope,
    HelperStatusSnapshot,
    HelperSuccessResponseEnvelope,
    ModelOption,
    TurnInputItem,
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
import { listLocalBranches, switchLocalBranch } from "./git-branches.js";
import { executeGitCommit, getGitCommitPreview, getGitDiff, getGitStatus } from "./git.js";
import { JSONLLogger } from "./logger.js";
import { detailFromThread, mapSandboxPolicy, projectsFromThreads, threadToSummary } from "./mappers.js";
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
    gitInfo?: {
        sha?: string | null;
        branch?: string | null;
        originUrl?: string | null;
    } | null;
    turns: Array<{
        id: string;
        items: Array<{ id: string; type: string; [key: string]: unknown }>;
        status: string;
        startedAt: number | null;
        completedAt: number | null;
    }>;
    [key: string]: unknown;
}

interface RawThreadResumeResponse {
    thread: RawThread;
    model: string;
    modelProvider: string;
    serviceTier: string | null;
    cwd: string;
    approvalPolicy: unknown;
    sandbox: unknown;
    reasoningEffort: string | null;
}

interface RawModelOption {
    id: string;
    model: string;
    displayName: string;
    description: string;
    hidden: boolean;
    supportedReasoningEfforts: Array<{
        reasoningEffort: string;
        description: string;
    }>;
    defaultReasoningEffort: string;
    inputModalities: string[];
    additionalSpeedTiers: string[];
    isDefault: boolean;
}

interface RawModelListResponse {
    data: RawModelOption[];
    nextCursor: string | null;
}

interface AppServerNotification {
    method: string;
    params?: unknown;
}

interface AppServerLike {
    on(event: "notification", listener: (notification: AppServerNotification) => void): this;
    on(event: "exit", listener: (error: Error) => void): this;
    currentSnapshot(): ReturnType<AppServerClient["currentSnapshot"]>;
    ensureStarted(): Promise<void>;
    request<T>(method: string, params: unknown): Promise<T>;
    shutdown(): Promise<void>;
}

interface DesktopBridgeLike {
    rememberLastActiveThread(threadID: string, cwd: string): Promise<void>;
    openThread(threadID: string, cwd: string): Promise<{ opened: boolean; bestEffort: boolean }>;
}

interface TimedCacheEntry<T> {
    value: T;
    expiresAt: number;
}

interface TimedCacheState<T> {
    entry: TimedCacheEntry<T> | null;
    inFlight: Promise<T> | null;
}

const inventoryCacheTTL = 10_000;
const modelsCacheTTL = 10_000;
const projectsCacheTTL = 10_000;
const branchCacheTTL = 5_000;

export class SpellwireDaemon {
    private readonly paths: RuntimePaths;
    private readonly logger: JSONLLogger;
    private readonly appServer: AppServerLike;
    private readonly recoveryIndex = new SessionRecoveryIndex();
    private readonly previewRegistry = new PreviewRegistry();
    private readonly desktopBridge: DesktopBridgeLike;
    private activeInventoryCache: TimedCacheState<RawThread[]> = { entry: null, inFlight: null };
    private archivedInventoryCache: TimedCacheState<RawThread[]> = { entry: null, inFlight: null };
    private projectsCache: TimedCacheState<CodexProject[]> = { entry: null, inFlight: null };
    private modelsCache: TimedCacheState<ModelOption[]> = { entry: null, inFlight: null };
    private branchCaches = new Map<string, TimedCacheState<BranchInfo[]>>();
    private server: net.Server | null = null;
    private readonly sockets = new Set<net.Socket>();

    constructor(
        paths = runtimePaths(),
        dependencies: {
            logger?: JSONLLogger;
            appServer?: AppServerLike;
            desktopBridge?: DesktopBridgeLike;
        } = {},
    ) {
        this.paths = paths;
        ensureRuntimeDirectories(paths);
        this.logger = dependencies.logger ?? new JSONLLogger(paths.logFilePath);
        this.appServer = dependencies.appServer ?? new AppServerClient(this.logger);
        this.desktopBridge = dependencies.desktopBridge ?? new DesktopBridge(paths);
        this.appServer.on("notification", (notification) => {
            if (this.notificationTouchesThreadCaches(notification.method)) {
                this.invalidateHelperCaches();
            }
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
            case "models.list":
                return this.modelsList();
            case "turns.start":
                return this.turnStart(request.params as unknown as TurnPromptParams);
            case "turns.steer":
                return this.turnSteer(request.params as unknown as TurnSteerPromptParams);
            case "turns.interrupt":
                return this.turnInterrupt(request.params as unknown as TurnInterruptRequest);
            case "branches.list":
                return this.branchesList(request.params as BranchListParams);
            case "branches.switch":
                return this.branchesSwitch(request.params as BranchSwitchParams);
            case "git.status":
                return this.gitStatus(request.params as GitStatusParams);
            case "git.diff":
                return this.gitDiff(request.params as GitDiffParams);
            case "git.commit.preview":
                return this.gitCommitPreview(request.params as GitCommitPreviewParams);
            case "git.commit.execute":
                return this.gitCommitExecute(request.params as GitCommitExecuteParams);
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
            attachmentsRootPath: this.paths.attachmentsRootPath,
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
        return this.readCachedValue(this.projectsCache, projectsCacheTTL, async () => {
            const { activeThreads, archivedThreads } = await this.threadInventory();
            return projectsFromThreads(activeThreads, archivedThreads);
        });
    }

    private async threadsList(params: ThreadsListParams): Promise<CodexThreadSummary[]> {
        const archived = params.archived ?? false;
        const filters = {
            cwd: params.projectID ?? undefined,
            searchTerm: params.query ?? undefined,
            limit: params.limit ?? undefined,
        };
        const threads = this.shouldUseInventoryCache(filters)
            ? this.filterThreads(await this.inventory(archived), filters)
            : await this.loadThreadsFromServer(archived, filters);
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
        this.invalidateHelperCaches();

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
        const runtime = await this.threadRuntime(threadID, resume);
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
            runtime,
        );
    }

    private async turnStart(params: TurnPromptParams): Promise<TurnMutationResult> {
        await this.appServer.request("thread/resume", {
            threadId: params.threadID,
        });
        const response = await this.appServer.request<{ turn: { id: string } }>("turn/start", {
            threadId: params.threadID,
            input: params.input.map((item) => this.appServerInput(item)),
            cwd: params.cwd ?? undefined,
            model: params.model ?? undefined,
            effort: params.effort ?? undefined,
            serviceTier: params.serviceTier ?? undefined,
            sandboxPolicy: params.sandboxPolicy ?? undefined,
        });
        this.invalidateHelperCaches();
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
        this.invalidateHelperCaches();
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
        this.invalidateHelperCaches();
        return {
            threadID: params.threadID,
            turnID: params.turnID,
        };
    }

    private async desktopOpen(params: DesktopOpenRequest): Promise<{ opened: boolean; bestEffort: boolean }> {
        const detail = await this.threadDetail(params.threadID);
        return this.desktopBridge.openThread(params.threadID, detail.thread.cwd);
    }

    private async modelsList(): Promise<ModelOption[]> {
        return this.readCachedValue(this.modelsCache, modelsCacheTTL, async () => {
            const models: ModelOption[] = [];
            let cursor: string | null = null;

            do {
                const page: RawModelListResponse = await this.appServer.request("model/list", {
                    cursor,
                    includeHidden: false,
                });
                models.push(
                    ...page.data.map((model: RawModelOption) => ({
                        id: model.id,
                        model: model.model,
                        displayName: model.displayName,
                        description: model.description,
                        hidden: model.hidden,
                        supportedReasoningEfforts: model.supportedReasoningEfforts,
                        defaultReasoningEffort: model.defaultReasoningEffort,
                        inputModalities: model.inputModalities,
                        additionalSpeedTiers: model.additionalSpeedTiers,
                        isDefault: model.isDefault,
                    })),
                );
                cursor = page.nextCursor;
            } while (cursor);

            return models;
        });
    }

    private async branchesList(params: BranchListParams): Promise<BranchInfo[]> {
        if (!params.cwd) {
            throw new Error("cwd is required.");
        }

        const cache = this.branchCaches.get(params.cwd) ?? { entry: null, inFlight: null };
        this.branchCaches.set(params.cwd, cache);
        return this.readCachedValue(cache, branchCacheTTL, async () => listLocalBranches(params.cwd));
    }

    private async branchesSwitch(params: BranchSwitchParams): Promise<BranchSwitchResult> {
        if (!params.cwd) {
            throw new Error("cwd is required.");
        }
        if (!params.name) {
            throw new Error("name is required.");
        }

        this.invalidateHelperCaches();
        return {
            cwd: params.cwd,
            currentBranch: await switchLocalBranch(params.cwd, params.name),
        };
    }

    private async gitStatus(params: GitStatusParams): Promise<CodexGitStatus> {
        if (!params.cwd) {
            throw new Error("cwd is required.");
        }
        return getGitStatus(params.cwd, { paths: params.paths ?? [] });
    }

    private async gitDiff(params: GitDiffParams): Promise<CodexGitDiff> {
        if (!params.cwd) {
            throw new Error("cwd is required.");
        }
        return getGitDiff(params.cwd, { paths: params.paths ?? [] });
    }

    private async gitCommitPreview(params: GitCommitPreviewParams): Promise<GitCommitPreview> {
        if (!params.cwd) {
            throw new Error("cwd is required.");
        }
        return getGitCommitPreview(params.cwd, { paths: params.paths ?? [] });
    }

    private async gitCommitExecute(params: GitCommitExecuteParams) {
        if (!params.cwd) {
            throw new Error("cwd is required.");
        }
        return executeGitCommit(params, {
            codexExecutablePath: this.paths.codexExecutablePath,
        });
    }

    private broadcast(event: HelperEventEnvelope): void {
        const payload = serializeJSONLine(event);
        for (const socket of this.sockets) {
            socket.write(payload);
        }
    }

    private async threadInventory(): Promise<{ activeThreads: RawThread[]; archivedThreads: RawThread[] }> {
        const [activeThreads, archivedThreads] = await Promise.all([
            this.inventory(false),
            this.inventory(true),
        ]);
        return { activeThreads, archivedThreads };
    }

    private async inventory(archived: boolean): Promise<RawThread[]> {
        const cache = archived ? this.archivedInventoryCache : this.activeInventoryCache;
        return this.readCachedValue(cache, inventoryCacheTTL, async () => this.loadThreadsFromServer(archived));
    }

    private async loadThreadsFromServer(
        archived: boolean,
        filters?: { cwd?: string; searchTerm?: string; limit?: number },
    ): Promise<RawThread[]> {
        const threads: RawThread[] = [];
        let cursor: string | null = null;
        const requestedLimit = filters?.limit && filters.limit > 0 ? filters.limit : null;
        const pageLimit = requestedLimit ? Math.min(requestedLimit, 100) : 100;

        do {
            const response: { data: RawThread[]; nextCursor: string | null } = await this.appServer.request("thread/list", {
                cursor,
                limit: pageLimit,
                sortKey: "updated_at",
                sourceKinds: allSourceKinds,
                archived,
                cwd: filters?.cwd ?? null,
                searchTerm: filters?.searchTerm ?? null,
            });
            threads.push(...response.data);
            if (requestedLimit && threads.length >= requestedLimit) {
                return threads.slice(0, requestedLimit);
            }
            cursor = response.nextCursor;
        } while (cursor);

        return threads;
    }

    private filterThreads(threads: RawThread[], filters?: { cwd?: string; searchTerm?: string; limit?: number }): RawThread[] {
        let filtered = [...threads];

        if (filters?.cwd) {
            filtered = filtered.filter((thread) => thread.cwd === filters.cwd);
        }

        const normalizedSearchTerm = filters?.searchTerm?.trim().toLowerCase();
        if (normalizedSearchTerm) {
            filtered = filtered.filter((thread) => {
                const haystack = [
                    thread.cwd,
                    thread.name ?? "",
                    thread.preview,
                    thread.agentNickname ?? "",
                ]
                    .join("\n")
                    .toLowerCase();
                return haystack.includes(normalizedSearchTerm);
            });
        }

        filtered.sort((left, right) => right.updatedAt - left.updatedAt);

        if (filters?.limit && filters.limit > 0) {
            return filtered.slice(0, filters.limit);
        }

        return filtered;
    }

    private notificationTouchesThreadCaches(method: string): boolean {
        return method.startsWith("thread/") || method.startsWith("turn/") || method.startsWith("item/");
    }

    private shouldUseInventoryCache(filters?: { cwd?: string; searchTerm?: string; limit?: number }): boolean {
        return !filters?.cwd && !filters?.searchTerm?.trim() && !(filters?.limit && filters.limit > 0);
    }

    private invalidateHelperCaches(): void {
        this.activeInventoryCache = { entry: null, inFlight: null };
        this.archivedInventoryCache = { entry: null, inFlight: null };
        this.projectsCache = { entry: null, inFlight: null };
        this.modelsCache = { entry: null, inFlight: null };
        this.branchCaches.clear();
    }

    private async readCachedValue<T>(
        cache: TimedCacheState<T>,
        ttlMs: number,
        loader: () => Promise<T>,
    ): Promise<T> {
        if (cache.entry && cache.entry.expiresAt > Date.now()) {
            return cache.entry.value;
        }
        if (cache.inFlight) {
            return cache.inFlight;
        }

        cache.inFlight = loader()
            .then((value) => {
                cache.entry = {
                    value,
                    expiresAt: Date.now() + ttlMs,
                };
                return value;
            })
            .finally(() => {
                cache.inFlight = null;
            });

        return cache.inFlight;
    }

    private async threadRuntime(threadID: string, _resume: boolean): Promise<CodexThreadDetail["runtime"]> {
        const response = await this.appServer.request<RawThreadResumeResponse>("thread/resume", {
            threadId: threadID,
        });

        return {
            cwd: response.cwd,
            model: response.model,
            modelProvider: response.modelProvider,
            serviceTier: response.serviceTier,
            reasoningEffort: response.reasoningEffort,
            approvalPolicy: typeof response.approvalPolicy === "string" ? response.approvalPolicy : JSON.stringify(response.approvalPolicy),
            sandbox: mapSandboxPolicy(response.sandbox),
            git: response.thread.gitInfo
                ? {
                    sha: response.thread.gitInfo.sha ?? null,
                    branch: response.thread.gitInfo.branch ?? null,
                    originURL: response.thread.gitInfo.originUrl ?? null,
                }
                : null,
        };
    }

    private appServerInput(item: TurnInputItem): Record<string, unknown> {
        switch (item.type) {
            case "text":
                return {
                    type: "text",
                    text: item.text,
                    text_elements: [],
                };
            case "localImage":
                return {
                    type: "localImage",
                    path: item.path,
                };
            case "image":
                return {
                    type: "image",
                    url: item.url,
                };
            case "mention":
                return {
                    type: "mention",
                    name: item.name,
                    path: item.path,
                };
            case "skill":
                return {
                    type: "skill",
                    name: item.name,
                    path: item.path,
                };
        }
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
