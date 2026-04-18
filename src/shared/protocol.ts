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
    | "git.status"
    | "git.diff"
    | "git.commit.preview"
    | "git.commit.execute"
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

export type CodexTimelineContentPart =
    | { type: "text"; text: string }
    | { type: "mention"; name: string; path?: string | null }
    | { type: "skill"; name: string; path?: string | null }
    | { type: "image"; url: string }
    | { type: "localImage"; path: string };

export interface CodexTimelineItem {
    id: string;
    turnID: string;
    kind: string;
    title: string;
    body: string;
    changedPaths?: string[] | null;
    content?: CodexTimelineContentPart[] | null;
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

export interface CodexGitStatus {
    cwd: string;
    isRepository: boolean;
    branch: string | null;
    hasChanges: boolean;
    additions: number;
    deletions: number;
    hasStaged: boolean;
    hasUnstaged: boolean;
    hasUntracked: boolean;
    pushRemote: string | null;
    canPush: boolean;
    canCreatePR: boolean;
    defaultBranch: string | null;
    blockingReason: string | null;
}

export interface GitDiffLine {
    kind: "context" | "addition" | "deletion" | "hunk" | "meta";
    text: string;
    oldLineNumber: number | null;
    newLineNumber: number | null;
}

export interface GitDiffHunk {
    header: string;
    lines: GitDiffLine[];
}

export interface GitDiffFile {
    path: string;
    oldPath: string | null;
    newPath: string | null;
    status: "added" | "modified" | "deleted" | "renamed" | "copied" | "typeChanged" | "unmerged" | "unknown";
    additions: number;
    deletions: number;
    isBinary: boolean;
    hunks: GitDiffHunk[];
}

export interface CodexGitDiff {
    cwd: string;
    branch: string | null;
    additions: number;
    deletions: number;
    files: GitDiffFile[];
}

export type GitCommitActionID = "commit" | "commitAndPush" | "commitPushAndPR";

export interface GitCommitAction {
    id: GitCommitActionID;
    title: string;
    enabled: boolean;
    reason: string | null;
}

export interface GitCommitPreview {
    cwd: string;
    branch: string | null;
    pushRemote: string | null;
    defaultBranch: string | null;
    defaultCommitMessage: string;
    defaultPRTitle: string;
    defaultPRBody: string;
    actions: GitCommitAction[];
    warnings: string[];
}

export interface GitCommitExecuteParams {
    cwd: string;
    paths?: string[] | null;
    action: GitCommitActionID;
    commitMessage?: string | null;
    prTitle?: string | null;
    prBody?: string | null;
}

export interface GitCommitResult {
    cwd: string;
    commitSHA: string;
    branch: string;
    pushed: boolean;
    prURL: string | null;
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

export interface GitStatusParams {
    cwd: string;
    paths?: string[] | null;
}

export interface GitDiffParams {
    cwd: string;
    paths?: string[] | null;
}

export interface GitCommitPreviewParams {
    cwd: string;
    paths?: string[] | null;
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
