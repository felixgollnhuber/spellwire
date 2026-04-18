import path from "node:path";
import type {
    CodexGitInfo,
    CodexProject,
    CodexRecoveryState,
    CodexSandboxPolicy,
    CodexThreadDetail,
    CodexThreadRuntime,
    CodexThreadSummary,
    CodexTimelineItem,
} from "../shared/protocol.js";

interface RawThreadStatus {
    type?: string;
}

interface RawThreadItem {
    type: string;
    id: string;
    [key: string]: unknown;
}

interface RawTurn {
    id: string;
    items: RawThreadItem[];
    status: string;
    startedAt: number | null;
    completedAt: number | null;
}

interface RawThread {
    id: string;
    cwd: string;
    name: string | null;
    preview: string;
    status: RawThreadStatus;
    updatedAt: number;
    createdAt: number;
    source: unknown;
    agentNickname: string | null;
    gitInfo?: {
        sha?: string | null;
        branch?: string | null;
        originUrl?: string | null;
    } | null;
    turns: RawTurn[];
}

function mapGitInfo(gitInfo: RawThread["gitInfo"]): CodexGitInfo | null {
    if (!gitInfo) {
        return null;
    }

    return {
        sha: gitInfo.sha ?? null,
        branch: gitInfo.branch ?? null,
        originURL: gitInfo.originUrl ?? null,
    };
}

export function mapSandboxPolicy(value: unknown): CodexSandboxPolicy | null {
    if (!value || typeof value !== "object") {
        return null;
    }

    const type = (value as { type?: unknown }).type;
    switch (type) {
        case "dangerFullAccess":
        case "readOnly":
        case "workspaceWrite":
        case "externalSandbox":
            return { type };
        default:
            return null;
    }
}

function sourceKindForThread(source: unknown): string {
    if (typeof source === "string") {
        return source;
    }
    if (source && typeof source === "object") {
        if ("custom" in source && typeof (source as { custom?: unknown }).custom === "string") {
            return "custom";
        }
        if ("subAgent" in source) {
            return "subAgent";
        }
    }
    return "unknown";
}

function threadStatusLabel(status: RawThreadStatus): string {
    switch (status.type) {
        case "active":
            return "active";
        case "idle":
            return "idle";
        case "systemError":
            return "systemError";
        default:
            return "notLoaded";
    }
}

function titleForThread(thread: RawThread): string {
    if (thread.name?.trim()) {
        return thread.name.trim();
    }
    if (thread.preview.trim()) {
        return thread.preview.trim();
    }
    return "Untitled Thread";
}

function joinUserInput(content: unknown): string {
    if (!Array.isArray(content)) {
        return "";
    }
    return content
        .map((part) => {
            if (!part || typeof part !== "object") {
                return "";
            }
            if ((part as { type?: unknown }).type === "text") {
                return String((part as { text?: unknown }).text ?? "");
            }
            if ((part as { type?: unknown }).type === "mention") {
                return `@${String((part as { name?: unknown }).name ?? "mention")}`;
            }
            if ((part as { type?: unknown }).type === "skill") {
                return `$${String((part as { name?: unknown }).name ?? "skill")}`;
            }
            if ((part as { type?: unknown }).type === "image" || (part as { type?: unknown }).type === "localImage") {
                return "[image]";
            }
            return "";
        })
        .filter(Boolean)
        .join("\n");
}

function summarizeFileChanges(changes: unknown): string {
    if (!Array.isArray(changes) || changes.length === 0) {
        return "No file details available.";
    }
    return changes
        .map((change) => {
            if (!change || typeof change !== "object") {
                return "Updated file";
            }
            const pathValue = String((change as { path?: unknown }).path ?? "file");
            const changeType = String((change as { changeType?: unknown }).changeType ?? "updated");
            return `${changeType}: ${pathValue}`;
        })
        .join("\n");
}

function timelineItemFromRawItem(turn: RawTurn, item: RawThreadItem): CodexTimelineItem {
    const base = {
        id: item.id,
        turnID: turn.id,
        status: turn.status,
        timestamp: turn.completedAt ?? turn.startedAt,
        source: "canonical" as const,
    };

    switch (item.type) {
        case "userMessage":
            return {
                ...base,
                kind: "userMessage",
                title: "You",
                body: joinUserInput(item.content),
            };
        case "agentMessage":
            return {
                ...base,
                kind: "agentMessage",
                title: "Codex",
                body: String(item.text ?? ""),
            };
        case "plan":
            return {
                ...base,
                kind: "plan",
                title: "Plan",
                body: String(item.text ?? ""),
            };
        case "reasoning":
            return {
                ...base,
                kind: "reasoning",
                title: "Reasoning",
                body: [...((item.summary as string[] | undefined) ?? []), ...((item.content as string[] | undefined) ?? [])]
                    .filter(Boolean)
                    .join("\n\n"),
            };
        case "commandExecution":
            return {
                ...base,
                kind: "commandExecution",
                title: String(item.command ?? "Command"),
                body: String(item.aggregatedOutput ?? ""),
            };
        case "fileChange":
            return {
                ...base,
                kind: "fileChange",
                title: "File Changes",
                body: summarizeFileChanges(item.changes),
            };
        case "mcpToolCall":
            return {
                ...base,
                kind: "mcpToolCall",
                title: `${String(item.server ?? "MCP")} · ${String(item.tool ?? "tool")}`,
                body: item.result ? JSON.stringify(item.result) : String(item.error ?? ""),
            };
        case "dynamicToolCall":
            return {
                ...base,
                kind: "dynamicToolCall",
                title: String(item.tool ?? "Tool Call"),
                body: item.contentItems ? JSON.stringify(item.contentItems) : "",
            };
        default:
            return {
                ...base,
                kind: item.type,
                title: item.type,
                body: JSON.stringify(item),
            };
    }
}

export function threadToSummary(thread: RawThread, archived: boolean): CodexThreadSummary {
    const lastTurn = [...thread.turns].sort((left, right) => (left.startedAt ?? 0) - (right.startedAt ?? 0)).at(-1) ?? null;
    return {
        id: thread.id,
        projectID: thread.cwd,
        cwd: thread.cwd,
        title: titleForThread(thread),
        preview: thread.preview,
        status: threadStatusLabel(thread.status),
        archived,
        updatedAt: thread.updatedAt,
        createdAt: thread.createdAt,
        sourceKind: sourceKindForThread(thread.source),
        agentNickname: thread.agentNickname,
        lastTurnID: lastTurn?.id ?? null,
    };
}

export function projectsFromThreads(activeThreads: RawThread[], archivedThreads: RawThread[]): CodexProject[] {
    const grouped = new Map<string, RawThread[]>();
    for (const thread of [...activeThreads, ...archivedThreads]) {
        const bucket = grouped.get(thread.cwd) ?? [];
        bucket.push(thread);
        grouped.set(thread.cwd, bucket);
    }

    return [...grouped.entries()]
        .map(([cwd, threads]) => {
            const activeThreadCount = threads.filter((thread) => !archivedThreads.some((archived) => archived.id === thread.id)).length;
            const archivedThreadCount = threads.length - activeThreadCount;
            return {
                id: cwd,
                cwd,
                title: path.basename(cwd) || cwd,
                threadCount: threads.length,
                activeThreadCount,
                archivedThreadCount,
                updatedAt: Math.max(...threads.map((thread) => thread.updatedAt)),
            };
        })
        .sort((left, right) => right.updatedAt - left.updatedAt);
}

export function detailFromThread(
    thread: RawThread,
    archived: boolean,
    recovery: CodexRecoveryState | null,
    project: CodexProject,
    runtime: CodexThreadRuntime,
): CodexThreadDetail {
    const summary = threadToSummary(thread, archived);
    const timeline = thread.turns
        .slice()
        .sort((left, right) => (left.startedAt ?? 0) - (right.startedAt ?? 0))
        .flatMap((turn) => turn.items.map((item) => timelineItemFromRawItem(turn, item)));

    const recoveryTimeline: CodexTimelineItem[] = (recovery?.snippets ?? [])
        .filter((snippet) => !timeline.some((item) => item.body.includes(snippet.text)))
        .map((snippet) => ({
            id: snippet.id,
            turnID: summary.lastTurnID ?? "recovery",
            kind: "recovery",
            title: "Recovery",
            body: snippet.text,
            status: null,
            timestamp: snippet.timestamp ? Date.parse(snippet.timestamp) / 1000 : null,
            source: "recovery",
        }));

    const activeTurn = [...thread.turns].reverse().find((turn) => turn.status === "inProgress") ?? null;

    return {
        thread: summary,
        project,
        timeline: [...timeline, ...recoveryTimeline],
        activeTurnID: activeTurn?.id ?? null,
        recovery,
        runtime: {
            ...runtime,
            git: runtime.git ?? mapGitInfo(thread.gitInfo),
        },
    };
}
