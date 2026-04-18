import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import type {
    CodexGitDiff,
    CodexGitStatus,
    GitCommitAction,
    GitCommitActionID,
    GitCommitExecuteParams,
    GitCommitPreview,
    GitCommitResult,
    GitDiffFile,
    GitDiffHunk,
    GitDiffLine,
} from "../shared/protocol.js";

const execFileAsync = promisify(execFile);

export interface ExecFileResult {
    stdout: string;
    stderr: string;
}

export type ExecFileLike = (
    file: string,
    args: string[],
    options: {
        cwd: string;
        encoding: BufferEncoding;
        maxBuffer: number;
    }
) => Promise<ExecFileResult>;

export interface GitCommandDeps {
    execFileImpl?: ExecFileLike;
    codexExecutablePath?: string | null;
    generateCommitMessageImpl?: (input: {
        cwd: string;
        branch: string | null;
        diff: string;
        fallback: string;
    }) => Promise<string | null>;
}

interface GitScope {
    paths?: string[] | null;
}

function defaultExecFileImpl(
    file: string,
    args: string[],
    options: {
        cwd: string;
        encoding: BufferEncoding;
        maxBuffer: number;
    }
): Promise<ExecFileResult> {
    return execFileAsync(file, args, options);
}

function commandDeps(overrides?: GitCommandDeps): { execFileImpl: ExecFileLike } {
    return {
        execFileImpl: overrides?.execFileImpl ?? defaultExecFileImpl,
    };
}

function normalizeExecError(error: unknown, fallback: string): Error {
    if (error instanceof Error) {
        return error;
    }
    return new Error(fallback);
}

function stdoutFromError(error: unknown): string | null {
    if (!error || typeof error !== "object") {
        return null;
    }
    const stdout = (error as { stdout?: unknown }).stdout;
    if (typeof stdout === "string") {
        return stdout;
    }
    if (stdout instanceof Buffer) {
        return stdout.toString("utf8");
    }
    return null;
}

function commandExitCode(error: unknown): number | null {
    if (!error || typeof error !== "object") {
        return null;
    }
    const code = (error as { code?: unknown; status?: unknown }).code;
    if (typeof code === "number") {
        return code;
    }
    const status = (error as { status?: unknown }).status;
    return typeof status === "number" ? status : null;
}

async function runCommand(
    file: string,
    args: string[],
    cwd: string,
    overrides?: GitCommandDeps
): Promise<string> {
    const deps = commandDeps(overrides);
    try {
        const result = await deps.execFileImpl(file, args, {
            cwd,
            encoding: "utf8",
            maxBuffer: 12 * 1024 * 1024,
        });
        return result.stdout;
    } catch (error) {
        if (file === "git" && args[0] === "diff" && commandExitCode(error) === 1) {
            return stdoutFromError(error) ?? "";
        }
        throw normalizeExecError(error, `Failed to run ${file}.`);
    }
}

export async function runGit(cwd: string, args: string[], overrides?: GitCommandDeps): Promise<string> {
    return runCommand("git", args, cwd, overrides);
}

export async function tryRunGit(cwd: string, args: string[], overrides?: GitCommandDeps): Promise<string | null> {
    try {
        return await runGit(cwd, args, overrides);
    } catch {
        return null;
    }
}

export async function isGitRepository(cwd: string, overrides?: GitCommandDeps): Promise<boolean> {
    try {
        const stdout = await runGit(cwd, ["rev-parse", "--is-inside-work-tree"], overrides);
        return stdout.trim() === "true";
    } catch {
        return false;
    }
}

export async function ensureGitRepository(cwd: string, overrides?: GitCommandDeps): Promise<void> {
    if (!(await isGitRepository(cwd, overrides))) {
        throw new Error("The selected thread is not inside a Git repository.");
    }
}

async function currentBranch(cwd: string, overrides?: GitCommandDeps): Promise<string | null> {
    const stdout = await tryRunGit(cwd, ["branch", "--show-current"], overrides);
    const branch = stdout?.trim() ?? "";
    return branch || null;
}

async function originRemoteURL(cwd: string, overrides?: GitCommandDeps): Promise<string | null> {
    const stdout = await tryRunGit(cwd, ["remote", "get-url", "origin"], overrides);
    const url = stdout?.trim() ?? "";
    return url || null;
}

async function hasHeadCommit(cwd: string, overrides?: GitCommandDeps): Promise<boolean> {
    const stdout = await tryRunGit(cwd, ["rev-parse", "--verify", "HEAD"], overrides);
    return Boolean(stdout?.trim());
}

async function hasUpstream(branch: string, cwd: string, overrides?: GitCommandDeps): Promise<boolean> {
    const stdout = await tryRunGit(cwd, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", `${branch}@{upstream}`], overrides);
    return Boolean(stdout?.trim());
}

function isGitHubRemote(url: string | null): boolean {
    if (!url) {
        return false;
    }
    return /(^git@github\.com:)|(^https:\/\/github\.com\/)|(^ssh:\/\/git@github\.com\/)/i.test(url);
}

async function ghAuthenticated(cwd: string, overrides?: GitCommandDeps): Promise<boolean> {
    try {
        await runCommand("gh", ["auth", "status"], cwd, overrides);
        return true;
    } catch {
        return false;
    }
}

async function resolveDefaultBranch(
    cwd: string,
    originURL: string | null,
    branch: string | null,
    overrides?: GitCommandDeps
): Promise<string | null> {
    const remoteHead = await tryRunGit(cwd, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], overrides);
    const normalizedRemoteHead = remoteHead?.trim().replace(/^origin\//, "");
    if (normalizedRemoteHead) {
        return normalizedRemoteHead;
    }

    if (isGitHubRemote(originURL) && (await ghAuthenticated(cwd, overrides))) {
        const ghDefaultBranch = await tryRunCommand("gh", ["repo", "view", "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"], cwd, overrides);
        const normalized = ghDefaultBranch?.trim();
        if (normalized) {
            return normalized;
        }
    }

    const branches = await tryRunGit(cwd, ["for-each-ref", "--format=%(refname:short)", "refs/heads"], overrides);
    const knownBranches = new Set((branches ?? "").split("\n").map((value) => value.trim()).filter(Boolean));
    if (knownBranches.has("main")) {
        return "main";
    }
    if (knownBranches.has("master")) {
        return "master";
    }
    return branch;
}

async function tryRunCommand(
    file: string,
    args: string[],
    cwd: string,
    overrides?: GitCommandDeps
): Promise<string | null> {
    try {
        return await runCommand(file, args, cwd, overrides);
    } catch {
        return null;
    }
}

interface StatusEntry {
    x: string;
    y: string;
    path: string;
}

function parsePorcelain(stdout: string): StatusEntry[] {
    return stdout
        .split("\n")
        .map((line) => line.replace(/\r$/, ""))
        .filter((line) => line.length >= 3 && !line.startsWith("##"))
        .map((line) => ({
            x: line[0] ?? " ",
            y: line[1] ?? " ",
            path: line.slice(3).replace(/^"|"$/g, ""),
        }));
}

function normalizeScopedPaths(cwd: string, scope?: GitScope): string[] | null {
    if (scope?.paths == null) {
        return null;
    }

    const seen = new Set<string>();
    const normalized: string[] = [];

    for (const candidate of scope?.paths ?? []) {
        if (typeof candidate !== "string") {
            continue;
        }
        const trimmed = candidate.trim();
        if (!trimmed) {
            continue;
        }

        const absolutePath = path.isAbsolute(trimmed) ? path.normalize(trimmed) : path.normalize(path.join(cwd, trimmed));
        const relativePath = path.relative(cwd, absolutePath);
        const pathSpec = relativePath && !relativePath.startsWith("..") && !path.isAbsolute(relativePath)
            ? relativePath
            : trimmed;
        if (!seen.has(pathSpec)) {
            seen.add(pathSpec);
            normalized.push(pathSpec);
        }
    }

    return normalized;
}

function withPathspec(args: string[], scopedPaths: string[] | null): string[] {
    return scopedPaths && scopedPaths.length > 0 ? [...args, "--", ...scopedPaths] : args;
}

function parseNumstat(stdout: string): Map<string, { additions: number; deletions: number }> {
    const entries = new Map<string, { additions: number; deletions: number }>();
    for (const line of stdout.split("\n").map((value) => value.trim()).filter(Boolean)) {
        const [rawAdditions, rawDeletions, ...pathParts] = line.split("\t");
        const filePath = pathParts.join("\t");
        if (!filePath) {
            continue;
        }
        const additions = rawAdditions === "-" ? 0 : Number(rawAdditions);
        const deletions = rawDeletions === "-" ? 0 : Number(rawDeletions);
        entries.set(filePath, {
            additions: Number.isFinite(additions) ? additions : 0,
            deletions: Number.isFinite(deletions) ? deletions : 0,
        });
    }
    return entries;
}

function mergeNumstat(
    base: Map<string, { additions: number; deletions: number }>,
    incoming: Map<string, { additions: number; deletions: number }>
): Map<string, { additions: number; deletions: number }> {
    const merged = new Map(base);
    for (const [filePath, value] of incoming) {
        const existing = merged.get(filePath);
        if (existing) {
            merged.set(filePath, {
                additions: existing.additions + value.additions,
                deletions: existing.deletions + value.deletions,
            });
        } else {
            merged.set(filePath, value);
        }
    }
    return merged;
}

async function trackedNumstat(
    cwd: string,
    scopedPaths: string[] | null,
    overrides?: GitCommandDeps
): Promise<Map<string, { additions: number; deletions: number }>> {
    if (await hasHeadCommit(cwd, overrides)) {
        return parseNumstat(await runGit(cwd, withPathspec(["diff", "--numstat", "HEAD"], scopedPaths), overrides));
    }

    const staged = parseNumstat(await tryRunGit(cwd, withPathspec(["diff", "--cached", "--numstat"], scopedPaths), overrides) ?? "");
    const unstaged = parseNumstat(await tryRunGit(cwd, withPathspec(["diff", "--numstat"], scopedPaths), overrides) ?? "");
    return mergeNumstat(staged, unstaged);
}

async function untrackedNumstat(
    cwd: string,
    entries: StatusEntry[],
    overrides?: GitCommandDeps
): Promise<Map<string, { additions: number; deletions: number }>> {
    const numstat = new Map<string, { additions: number; deletions: number }>();
    for (const entry of entries.filter((candidate) => candidate.x === "?" && candidate.y === "?")) {
        const stdout = await runGit(cwd, ["diff", "--no-index", "--numstat", "/dev/null", entry.path], overrides);
        const parsed = parseNumstat(stdout);
        const summary = summarizeNumstat(parsed);
        numstat.set(entry.path, summary);
    }
    return numstat;
}

function summarizeNumstat(entries: Map<string, { additions: number; deletions: number }>): { additions: number; deletions: number } {
    let additions = 0;
    let deletions = 0;
    for (const value of entries.values()) {
        additions += value.additions;
        deletions += value.deletions;
    }
    return { additions, deletions };
}

function classifyStatus(lines: string[]): GitDiffFile["status"] {
    if (lines.some((line) => line.startsWith("new file mode "))) {
        return "added";
    }
    if (lines.some((line) => line.startsWith("deleted file mode "))) {
        return "deleted";
    }
    if (lines.some((line) => line.startsWith("rename from "))) {
        return "renamed";
    }
    if (lines.some((line) => line.startsWith("copy from "))) {
        return "copied";
    }
    if (lines.some((line) => line.startsWith("similarity index "))) {
        return "renamed";
    }
    if (lines.some((line) => line.startsWith("old mode ")) || lines.some((line) => line.startsWith("new mode "))) {
        return "typeChanged";
    }
    return "modified";
}

function parseHunkHeader(line: string): { oldLine: number; newLine: number } {
    const match = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(line);
    if (!match) {
        return { oldLine: 0, newLine: 0 };
    }
    return {
        oldLine: Number(match[1]),
        newLine: Number(match[2]),
    };
}

function patchBlocks(patch: string): string[] {
    const normalized = patch.replace(/\r\n/g, "\n").trim();
    if (!normalized) {
        return [];
    }
    return normalized
        .split("\ndiff --git ")
        .map((block, index) => (index === 0 ? block : `diff --git ${block}`))
        .filter(Boolean);
}

function normalizeDiffPath(value: string | null): string | null {
    if (!value) {
        return null;
    }
    return value.replace(/^a\//, "").replace(/^b\//, "");
}

function parsePatchBlock(
    block: string,
    numstat: Map<string, { additions: number; deletions: number }>
): GitDiffFile | null {
    const lines = block.split("\n");
    const header = lines[0] ?? "";
    const match = /^diff --git a\/(.+) b\/(.+)$/.exec(header);
    if (!match) {
        return null;
    }

    let oldPath = normalizeDiffPath(`a/${match[1]}`);
    let newPath = normalizeDiffPath(`b/${match[2]}`);
    const status = classifyStatus(lines);
    const isBinary = lines.some((line) => line.startsWith("Binary files ")) || lines.some((line) => line === "GIT binary patch");

    for (const line of lines) {
        if (line.startsWith("--- ")) {
            const parsed = normalizeDiffPath(line.slice(4).trim());
            oldPath = parsed === "/dev/null" ? null : parsed;
        } else if (line.startsWith("+++ ")) {
            const parsed = normalizeDiffPath(line.slice(4).trim());
            newPath = parsed === "/dev/null" ? null : parsed;
        } else if (line.startsWith("rename from ")) {
            oldPath = line.slice("rename from ".length).trim();
        } else if (line.startsWith("rename to ")) {
            newPath = line.slice("rename to ".length).trim();
        }
    }

    const filePath = newPath ?? oldPath ?? normalizeDiffPath(match[2]) ?? normalizeDiffPath(match[1]);
    if (!filePath) {
        return null;
    }

    const counts = numstat.get(filePath) ?? numstat.get(oldPath ?? "") ?? { additions: 0, deletions: 0 };
    const hunks: GitDiffHunk[] = [];
    let currentHunk: GitDiffHunk | null = null;
    let oldLineNumber = 0;
    let newLineNumber = 0;

    for (const line of lines) {
        if (line.startsWith("@@ ")) {
            currentHunk = {
                header: line,
                lines: [
                    {
                        kind: "hunk",
                        text: line,
                        oldLineNumber: null,
                        newLineNumber: null,
                    },
                ],
            };
            const headerLines = parseHunkHeader(line);
            oldLineNumber = headerLines.oldLine;
            newLineNumber = headerLines.newLine;
            hunks.push(currentHunk);
            continue;
        }

        if (!currentHunk) {
            continue;
        }

        if (line.startsWith("\\")) {
            currentHunk.lines.push({
                kind: "meta",
                text: line,
                oldLineNumber: null,
                newLineNumber: null,
            });
            continue;
        }

        const prefix = line[0] ?? " ";
        const text = line.length > 0 ? line : " ";
        switch (prefix) {
            case "+":
                currentHunk.lines.push({
                    kind: "addition",
                    text,
                    oldLineNumber: null,
                    newLineNumber,
                });
                newLineNumber += 1;
                break;
            case "-":
                currentHunk.lines.push({
                    kind: "deletion",
                    text,
                    oldLineNumber,
                    newLineNumber: null,
                });
                oldLineNumber += 1;
                break;
            default:
                currentHunk.lines.push({
                    kind: "context",
                    text,
                    oldLineNumber,
                    newLineNumber,
                });
                oldLineNumber += 1;
                newLineNumber += 1;
                break;
        }
    }

    return {
        path: filePath,
        oldPath,
        newPath,
        status,
        additions: counts.additions,
        deletions: counts.deletions,
        isBinary,
        hunks,
    };
}

function changedFileNames(files: GitDiffFile[]): string[] {
    return files
        .map((file) => path.basename(file.path))
        .filter(Boolean)
        .slice(0, 3);
}

function defaultCommitMessage(files: GitDiffFile[]): string {
    if (files.length === 0) {
        return "Update working tree";
    }
    const names = changedFileNames(files);
    if (files.length === 1) {
        return `Update ${names[0]}`;
    }
    if (files.length === 2) {
        return `Update ${names[0]} and ${names[1]}`;
    }
    if (files.length === 3) {
        return `Update ${names[0]}, ${names[1]}, and ${names[2]}`;
    }
    return `Update ${files.length} files`;
}

function sanitizeCommitMessage(value: string | null | undefined): string | null {
    if (!value) {
        return null;
    }

    const firstLine = value
        .replace(/\r\n/g, "\n")
        .split("\n")
        .map((line) => line.trim())
        .find(Boolean);
    if (!firstLine) {
        return null;
    }

    const cleaned = firstLine
        .replace(/^["'`]+/, "")
        .replace(/["'`]+$/, "")
        .trim();
    return cleaned || null;
}

async function fullWorkingTreePatch(cwd: string, overrides?: GitCommandDeps): Promise<string> {
    const trackedPatch = await hasHeadCommit(cwd, overrides)
        ? runGit(
            cwd,
            ["diff", "--no-color", "--patch", "--find-renames", "--find-copies", "--unified=3", "HEAD"],
            overrides
        )
        : Promise.resolve("");
    const untrackedEntries = parsePorcelain(
        await runGit(cwd, ["status", "--porcelain=v1", "--untracked-files=all"], overrides)
    ).filter((entry) => entry.x === "?" && entry.y === "?");
    const untrackedPatches = await Promise.all(
        untrackedEntries.map((entry) =>
            runGit(cwd, ["diff", "--no-index", "--no-color", "--patch", "--unified=3", "/dev/null", entry.path], overrides)
        )
    );

    return [
        await trackedPatch,
        ...untrackedPatches,
    ]
        .map((value) => value.trim())
        .filter(Boolean)
        .join("\n\n");
}

async function generateCommitMessage(
    cwd: string,
    branch: string | null,
    fallback: string,
    overrides?: GitCommandDeps
): Promise<string> {
    const fullDiff = await fullWorkingTreePatch(cwd, overrides);
    if (!fullDiff.trim()) {
        return fallback;
    }

    if (overrides?.generateCommitMessageImpl) {
        const generated = sanitizeCommitMessage(
            await overrides.generateCommitMessageImpl({
                cwd,
                branch,
                diff: fullDiff,
                fallback,
            })
        );
        return generated ?? fallback;
    }

    const codexExecutable = overrides?.codexExecutablePath?.trim() || "codex";
    const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "spellwire-commit-message-"));
    const outputPath = path.join(tempDirectory, "message.txt");
    const prompt = [
        "Write a concise git commit subject line in English for the complete working tree diff.",
        "Use imperative mood.",
        "Return exactly one line and no quotes, bullets, prefixes, explanations, or markdown.",
        "Stay under 72 characters when possible.",
        `Current branch: ${branch ?? "unknown"}`,
        `Fallback subject: ${fallback}`,
        "",
        "Full diff:",
        fullDiff,
    ].join("\n");

    try {
        await runCommand(
            codexExecutable,
            [
                "exec",
                "--ephemeral",
                "--sandbox",
                "read-only",
                "-C",
                cwd,
                "--skip-git-repo-check",
                "--output-last-message",
                outputPath,
                prompt,
            ],
            cwd,
            overrides
        );
        const generated = sanitizeCommitMessage(await readFile(outputPath, "utf8"));
        return generated ?? fallback;
    } catch {
        return fallback;
    } finally {
        await rm(tempDirectory, { recursive: true, force: true });
    }
}

function defaultPRBody(diff: CodexGitDiff, commitMessage: string): string {
    const fileList = diff.files.slice(0, 8).map((file) => `- ${file.path}`).join("\n");
    return [
        `## Summary`,
        ``,
        `- ${commitMessage}`,
        `- ${diff.additions} additions / ${diff.deletions} deletions`,
        ``,
        `## Files`,
        fileList || "- No file details available",
    ].join("\n");
}

function action(
    id: GitCommitActionID,
    title: string,
    enabled: boolean,
    reason: string | null = null
): GitCommitAction {
    return { id, title, enabled, reason };
}

function extractPRURL(stdout: string): string | null {
    const match = stdout.match(/https:\/\/github\.com\/\S+/g);
    return match?.at(-1) ?? null;
}

export async function getGitStatus(cwd: string, scope: GitScope = {}, overrides?: GitCommandDeps): Promise<CodexGitStatus> {
    if (!(await isGitRepository(cwd, overrides))) {
        return {
            cwd,
            isRepository: false,
            branch: null,
            hasChanges: false,
            additions: 0,
            deletions: 0,
            hasStaged: false,
            hasUnstaged: false,
            hasUntracked: false,
            pushRemote: null,
            canPush: false,
            canCreatePR: false,
            defaultBranch: null,
            blockingReason: "The selected thread is not inside a Git repository.",
        };
    }

    const scopedPaths = normalizeScopedPaths(cwd, scope);
    if (scopedPaths?.length === 0) {
        const branch = await currentBranch(cwd, overrides);
        const originURL = await originRemoteURL(cwd, overrides);
        const defaultBranch = await resolveDefaultBranch(cwd, originURL, branch, overrides);
        return {
            cwd,
            isRepository: true,
            branch,
            hasChanges: false,
            additions: 0,
            deletions: 0,
            hasStaged: false,
            hasUnstaged: false,
            hasUntracked: false,
            pushRemote: originURL ? "origin" : null,
            canPush: false,
            canCreatePR: false,
            defaultBranch,
            blockingReason: "No file changes from this chat were detected.",
        };
    }

    const porcelain = await runGit(
        cwd,
        withPathspec(["status", "--porcelain=v1", "--untracked-files=all", "--branch"], scopedPaths),
        overrides
    );
    const entries = parsePorcelain(porcelain);
    const tracked = await trackedNumstat(cwd, scopedPaths, overrides);
    const untracked = await untrackedNumstat(cwd, entries, overrides);
    const numstat = mergeNumstat(tracked, untracked);
    const summary = summarizeNumstat(numstat);
    const branch = await currentBranch(cwd, overrides);
    const originURL = await originRemoteURL(cwd, overrides);
    const pushRemote = originURL ? "origin" : null;
    const defaultBranch = await resolveDefaultBranch(cwd, originURL, branch, overrides);
    const canPush = Boolean(originURL && branch);
    const canCreatePR = Boolean(
        canPush &&
        branch &&
        defaultBranch &&
        branch !== defaultBranch &&
        isGitHubRemote(originURL) &&
        (await ghAuthenticated(cwd, overrides))
    );

    return {
        cwd,
        isRepository: true,
        branch,
        hasChanges: entries.length > 0,
        additions: summary.additions,
        deletions: summary.deletions,
        hasStaged: entries.some((entry) => entry.x !== " " && entry.x !== "?"),
        hasUnstaged: entries.some((entry) => entry.y !== " " && entry.y !== "?"),
        hasUntracked: entries.some((entry) => entry.x === "?" && entry.y === "?"),
        pushRemote,
        canPush,
        canCreatePR,
        defaultBranch,
        blockingReason: entries.length == 0 ? "No uncommitted changes." : null,
    };
}

export async function getGitDiff(cwd: string, scope: GitScope = {}, overrides?: GitCommandDeps): Promise<CodexGitDiff> {
    const scopedPaths = normalizeScopedPaths(cwd, scope);
    const status = await getGitStatus(cwd, { paths: scopedPaths }, overrides);
    if (!status.isRepository) {
        throw new Error(status.blockingReason ?? "The selected thread is not inside a Git repository.");
    }
    if (scopedPaths?.length === 0) {
        throw new Error(status.blockingReason ?? "No file changes from this chat were detected.");
    }

    const trackedPatch = await hasHeadCommit(cwd, overrides)
        ? runGit(
            cwd,
            withPathspec(["diff", "--no-color", "--patch", "--find-renames", "--find-copies", "--unified=3", "HEAD"], scopedPaths),
            overrides
        )
        : Promise.resolve("");
    const untrackedEntries = parsePorcelain(
        await runGit(cwd, withPathspec(["status", "--porcelain=v1", "--untracked-files=all"], scopedPaths), overrides)
    )
        .filter((entry) => entry.x === "?" && entry.y === "?");
    const untrackedPatches = await Promise.all(
        untrackedEntries.map((entry) =>
            runGit(cwd, ["diff", "--no-index", "--no-color", "--patch", "--unified=3", "/dev/null", entry.path], overrides)
        )
    );
    const blocks = [
        ...patchBlocks(await trackedPatch),
        ...untrackedPatches.flatMap((patch) => patchBlocks(patch)),
    ];
    const tracked = await trackedNumstat(cwd, scopedPaths, overrides);
    const untracked = await untrackedNumstat(cwd, untrackedEntries, overrides);
    const numstat = mergeNumstat(tracked, untracked);
    const files = blocks
        .map((block) => parsePatchBlock(block, numstat))
        .filter((value): value is GitDiffFile => value !== null);

    return {
        cwd,
        branch: status.branch,
        additions: status.additions,
        deletions: status.deletions,
        files,
    };
}

export async function getGitCommitPreview(cwd: string, scope: GitScope = {}, overrides?: GitCommandDeps): Promise<GitCommitPreview> {
    const status = await getGitStatus(cwd, scope, overrides);
    if (!status.isRepository) {
        throw new Error(status.blockingReason ?? "The selected thread is not inside a Git repository.");
    }
    const diff = await getGitDiff(cwd, scope, overrides);
    const commitMessage = defaultCommitMessage(diff.files);
    const warnings: string[] = [];
    if (status.branch && status.defaultBranch && status.branch === status.defaultBranch) {
        warnings.push(`You are about to push directly to ${status.branch}.`);
    }

    return {
        cwd,
        branch: status.branch,
        pushRemote: status.pushRemote,
        defaultBranch: status.defaultBranch,
        defaultCommitMessage: commitMessage,
        defaultPRTitle: commitMessage,
        defaultPRBody: defaultPRBody(diff, commitMessage),
        warnings,
        actions: [
            action("commit", "Commit", status.hasChanges, status.hasChanges ? null : "No uncommitted changes."),
            action(
                "commitAndPush",
                "Commit & Push",
                status.hasChanges && status.canPush,
                !status.hasChanges
                    ? "No uncommitted changes."
                    : !status.canPush
                        ? "No origin remote is configured for this branch."
                        : null
            ),
            action(
                "commitPushAndPR",
                "Commit, Push & PR",
                status.hasChanges && status.canCreatePR,
                !status.hasChanges
                    ? "No uncommitted changes."
                    : !status.canPush
                        ? "No origin remote is configured for this branch."
                        : status.branch && status.defaultBranch && status.branch === status.defaultBranch
                            ? "Create a feature branch before opening a pull request."
                            : "GitHub pull requests require a GitHub origin remote and an authenticated gh CLI session."
            ),
        ],
    };
}

export async function executeGitCommit(params: GitCommitExecuteParams, overrides?: GitCommandDeps): Promise<GitCommitResult> {
    const scopedPaths = normalizeScopedPaths(
        params.cwd,
        params.paths == null ? {} : { paths: params.paths }
    );
    const preview = await getGitCommitPreview(params.cwd, { paths: scopedPaths }, overrides);
    const fullDiff = await getGitDiff(params.cwd, {}, overrides);
    const targetAction = preview.actions.find((action) => action.id === params.action);
    if (!targetAction?.enabled) {
        throw new Error(targetAction?.reason ?? "This Git action is not available.");
    }
    if (scopedPaths?.length === 0) {
        throw new Error("No file changes from this chat were detected.");
    }

    const fallbackCommitMessage = defaultCommitMessage(fullDiff.files);
    const commitMessage = params.commitMessage?.trim()
        || await generateCommitMessage(params.cwd, preview.branch, fallbackCommitMessage, overrides);
    await runGit(params.cwd, ["add", "-A"], overrides);
    await runGit(params.cwd, ["commit", "-m", commitMessage], overrides);
    const commitSHA = (await runGit(params.cwd, ["rev-parse", "HEAD"], overrides)).trim();
    const branch = (await currentBranch(params.cwd, overrides)) ?? "";
    if (!branch) {
        throw new Error("Git commit completed but no current branch was reported.");
    }

    let pushed = false;
    let prURL: string | null = null;

    if (params.action !== "commit") {
        if (!preview.pushRemote) {
            throw new Error("No origin remote is configured for this repository.");
        }
        const upstreamExists = await hasUpstream(branch, params.cwd, overrides);
        if (upstreamExists) {
            await runGit(params.cwd, ["push", preview.pushRemote, branch], overrides);
        } else {
            await runGit(params.cwd, ["push", "--set-upstream", preview.pushRemote, branch], overrides);
        }
        pushed = true;
    }

    if (params.action === "commitPushAndPR") {
        if (!preview.defaultBranch || preview.defaultBranch === branch) {
            throw new Error("Create a feature branch before opening a pull request.");
        }
        const prTitle = params.prTitle?.trim() || preview.defaultPRTitle;
        const prBody = params.prBody?.trim() || preview.defaultPRBody;
        const stdout = await runCommand(
            "gh",
            [
                "pr",
                "create",
                "--base",
                preview.defaultBranch,
                "--head",
                branch,
                "--title",
                prTitle,
                "--body",
                prBody,
            ],
            params.cwd,
            overrides
        );
        prURL = extractPRURL(stdout);
    }

    return {
        cwd: params.cwd,
        commitSHA,
        branch,
        pushed,
        prURL,
    };
}
