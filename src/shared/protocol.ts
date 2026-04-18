export type HelperMethod =
    | "helper.status"
    | "projects.list"
    | "threads.list"
    | "threads.create"
    | "threads.open"
    | "threads.read"
    | "turns.start"
    | "turns.steer"
    | "turns.interrupt"
    | "desktop.open"
    | "previews.list";

export type HelperEventName = "helper.status.changed" | "app.notification";

export type JSONPrimitive = string | number | boolean | null;
export type JSONValue = JSONPrimitive | JSONValue[] | { [key: string]: JSONValue };

export interface HelperRequestEnvelope<T = unknown> {
    kind: "request";
    id: string;
    method: HelperMethod;
    params: T;
}

export interface HelperSuccessResponseEnvelope<T = unknown> {
    kind: "response";
    id: string;
    ok: true;
    result: T;
}

export interface HelperErrorPayload {
    code: string;
    message: string;
    details?: unknown;
}

export interface HelperFailureResponseEnvelope {
    kind: "response";
    id: string;
    ok: false;
    error: HelperErrorPayload;
}

export interface HelperEventEnvelope<T = unknown> {
    kind: "event";
    event: HelperEventName;
    data: T;
}

export type HelperResponseEnvelope = HelperSuccessResponseEnvelope | HelperFailureResponseEnvelope;

export type HelperEnvelope =
    | HelperRequestEnvelope
    | HelperResponseEnvelope
    | HelperEventEnvelope;

export interface HelperStatusSnapshot {
    helperVersion: string;
    daemonRunning: boolean;
    appServerRunning: boolean;
    socketPath: string;
    logFilePath: string;
    codexHome: string | null;
    lastActiveThreadId: string | null;
    lastActiveCwd: string | null;
    startedAt: string | null;
    lastNotificationAt: string | null;
    lastError: string | null;
}

export interface RecoverySnippet {
    id: string;
    text: string;
    timestamp: string | null;
    source: "rollout";
}

export interface CodexRecoveryState {
    rolloutPath: string;
    lastEventAt: string | null;
    snippets: RecoverySnippet[];
}

export interface CodexProject {
    id: string;
    cwd: string;
    title: string;
    threadCount: number;
    activeThreadCount: number;
    archivedThreadCount: number;
    updatedAt: number;
}

export interface CodexThreadSummary {
    id: string;
    projectID: string;
    cwd: string;
    title: string;
    preview: string;
    status: string;
    archived: boolean;
    updatedAt: number;
    createdAt: number;
    sourceKind: string;
    agentNickname: string | null;
    lastTurnID: string | null;
}

export interface CodexTimelineItem {
    id: string;
    turnID: string;
    kind: string;
    title: string;
    body: string;
    status: string | null;
    timestamp: number | null;
    source: "canonical" | "recovery";
}

export interface CodexThreadDetail {
    thread: CodexThreadSummary;
    project: CodexProject;
    timeline: CodexTimelineItem[];
    activeTurnID: string | null;
    recovery: CodexRecoveryState | null;
}

export interface ThreadsListParams {
    projectID?: string | null;
    query?: string | null;
    archived?: boolean | null;
    limit?: number | null;
}

export interface ThreadCreateParams {
    cwd: string;
}

export interface TurnPromptParams {
    threadID: string;
    prompt: string;
}

export interface TurnSteerPromptParams extends TurnPromptParams {
    expectedTurnID: string;
}

export interface TurnInterruptRequest {
    threadID: string;
    turnID: string;
}

export interface DesktopOpenRequest {
    threadID: string;
}

export interface TurnMutationResult {
    threadID: string;
    turnID: string;
}

export interface PreviewEntry {
    id: string;
    url: string;
    host: string;
    port: number;
    processName: string;
    pid: number | null;
}
