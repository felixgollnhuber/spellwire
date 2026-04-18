export type HelperMethod =
    | "helper.status"
    | "projects.list"
    | "threads.list"
    | "threads.create"
    | "threads.open"
    | "threads.read"
    | "models.list"
    | "turns.start"
    | "turns.steer"
    | "turns.interrupt"
    | "branches.list"
    | "branches.switch"
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
    attachmentsRootPath: string;
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

export type CodexSandboxPolicy =
    | { type: "dangerFullAccess" }
    | { type: "readOnly" }
    | { type: "workspaceWrite" }
    | { type: "externalSandbox" };

export interface CodexGitInfo {
    sha: string | null;
    branch: string | null;
    originURL: string | null;
}

export interface CodexThreadRuntime {
    cwd: string;
    model: string | null;
    modelProvider: string | null;
    serviceTier: string | null;
    reasoningEffort: string | null;
    approvalPolicy: string | null;
    sandbox: CodexSandboxPolicy | null;
    git: CodexGitInfo | null;
}

export interface CodexThreadDetail {
    thread: CodexThreadSummary;
    project: CodexProject;
    timeline: CodexTimelineItem[];
    activeTurnID: string | null;
    recovery: CodexRecoveryState | null;
    runtime: CodexThreadRuntime;
}

export interface ReasoningEffortOption {
    reasoningEffort: string;
    description: string;
}

export interface ModelOption {
    id: string;
    model: string;
    displayName: string;
    description: string;
    hidden: boolean;
    supportedReasoningEfforts: ReasoningEffortOption[];
    defaultReasoningEffort: string;
    inputModalities: string[];
    additionalSpeedTiers: string[];
    isDefault: boolean;
}

export interface BranchInfo {
    name: string;
    isCurrent: boolean;
}

export interface BranchListParams {
    cwd: string;
}

export interface BranchSwitchParams {
    cwd: string;
    name: string;
}

export interface BranchSwitchResult {
    cwd: string;
    currentBranch: string;
}

export type TurnInputItem =
    | { type: "text"; text: string }
    | { type: "localImage"; path: string }
    | { type: "image"; url: string }
    | { type: "mention"; name: string; path: string }
    | { type: "skill"; name: string; path: string };

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
    input: TurnInputItem[];
    cwd?: string | null;
    model?: string | null;
    effort?: string | null;
    serviceTier?: string | null;
    sandboxPolicy?: CodexSandboxPolicy | null;
}

export interface TurnSteerPromptParams {
    threadID: string;
    prompt: string;
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
