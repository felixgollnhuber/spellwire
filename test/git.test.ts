import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import {
    executeGitCommit,
    getGitCommitPreview,
    getGitDiff,
    getGitStatus,
    type ExecFileLike,
} from "../src/helper/git.js";

function setupRepo(): string {
    const cwd = mkdtempSync(path.join(os.tmpdir(), "spellwire-git-"));
    execFileSync("git", ["init", "--initial-branch=main"], { cwd });
    execFileSync("git", ["config", "user.name", "Spellwire Tests"], { cwd });
    execFileSync("git", ["config", "user.email", "tests@spellwire.dev"], { cwd });
    writeFileSync(path.join(cwd, "tracked.txt"), "first\nsecond\n");
    execFileSync("git", ["add", "tracked.txt"], { cwd });
    execFileSync("git", ["commit", "-m", "initial"], { cwd });
    return cwd;
}

function setupBareRemote(): string {
    const cwd = mkdtempSync(path.join(os.tmpdir(), "spellwire-remote-"));
    execFileSync("git", ["init", "--bare"], { cwd });
    return cwd;
}

function fakeGhExec(base: ExecFileLike, overrides?: { defaultBranch?: string; prURL?: string }): ExecFileLike {
    return async (file, args, options) => {
        if (file === "gh" && args[0] === "auth" && args[1] === "status") {
            return { stdout: "github.com\n  Logged in\n", stderr: "" };
        }
        if (file === "gh" && args[0] === "repo" && args[1] === "view") {
            return { stdout: `${overrides?.defaultBranch ?? "main"}\n`, stderr: "" };
        }
        if (file === "gh" && args[0] === "pr" && args[1] === "create") {
            return { stdout: `${overrides?.prURL ?? "https://github.com/example/spellwire/pull/1"}\n`, stderr: "" };
        }
        return base(file, args, options);
    };
}

const realExec: ExecFileLike = async (file, args, options) => {
    const stdout = execFileSync(file, args, {
        cwd: options.cwd,
        encoding: "utf8",
        maxBuffer: options.maxBuffer,
    });
    return { stdout, stderr: "" };
};

test("getGitStatus counts staged, unstaged, deleted, and untracked changes", async () => {
    const cwd = setupRepo();

    writeFileSync(path.join(cwd, "tracked.txt"), "first\nsecond changed\nthird\n");
    writeFileSync(path.join(cwd, "staged.txt"), "staged\n");
    execFileSync("git", ["add", "staged.txt"], { cwd });
    writeFileSync(path.join(cwd, "staged.txt"), "staged\nunstaged tail\n");
    writeFileSync(path.join(cwd, "untracked.txt"), "alpha\nbeta\n");
    execFileSync("git", ["rm", "-f", "tracked.txt"], { cwd });
    writeFileSync(path.join(cwd, "tracked.txt"), "first\nsecond changed\n");

    const status = await getGitStatus(cwd);

    assert.equal(status.isRepository, true);
    assert.equal(status.hasChanges, true);
    assert.equal(status.hasStaged, true);
    assert.equal(status.hasUnstaged, true);
    assert.equal(status.hasUntracked, true);
    assert.equal(status.additions > 0, true);
    assert.equal(status.deletions > 0, true);
});

test("getGitStatus returns a non-repository payload outside git", async () => {
    const cwd = mkdtempSync(path.join(os.tmpdir(), "spellwire-nonrepo-"));
    const status = await getGitStatus(cwd);

    assert.equal(status.isRepository, false);
    assert.equal(status.hasChanges, false);
    assert.match(status.blockingReason ?? "", /not inside a Git repository/i);
});

test("getGitStatus scopes changes to the current chat paths", async () => {
    const cwd = setupRepo();
    writeFileSync(path.join(cwd, "tracked.txt"), "first\nsecond updated\n");
    writeFileSync(path.join(cwd, "outside.txt"), "outside\n");

    const status = await getGitStatus(cwd, { paths: ["tracked.txt"] });

    assert.equal(status.hasChanges, true);
    assert.equal(status.additions, 1);
    assert.equal(status.deletions, 1);

    const outsideStatus = await getGitStatus(cwd, { paths: ["README-does-not-exist-yet.md"] });
    assert.equal(outsideStatus.hasChanges, false);
});

test("getGitDiff returns structured file hunks for tracked and untracked changes", async () => {
    const cwd = setupRepo();
    writeFileSync(path.join(cwd, "tracked.txt"), "first\nsecond updated\nthird\n");
    writeFileSync(path.join(cwd, "notes.md"), "# Notes\n- item\n");

    const diff = await getGitDiff(cwd);

    assert.equal(diff.files.length >= 2, true);
    assert.ok(diff.files.some((file) => file.path === "tracked.txt" && file.hunks.length > 0));
    const untrackedFile = diff.files.find((file) => file.path === "notes.md");
    assert.ok(untrackedFile && untrackedFile.status === "added");
    assert.equal(untrackedFile?.additions, 2);
    assert.equal(untrackedFile?.deletions, 0);
});

test("getGitCommitPreview adapts actions for clean, pushable, and GitHub PR-ready repositories", async () => {
    const cleanRepo = setupRepo();
    const cleanPreview = await getGitCommitPreview(cleanRepo);
    assert.equal(cleanPreview.actions.find((action) => action.id === "commit")?.enabled, false);

    const pushableRepo = setupRepo();
    const bareRemote = setupBareRemote();
    execFileSync("git", ["remote", "add", "origin", bareRemote], { cwd: pushableRepo });
    writeFileSync(path.join(pushableRepo, "pushable.txt"), "push\n");
    const pushPreview = await getGitCommitPreview(pushableRepo);
    assert.equal(pushPreview.actions.find((action) => action.id === "commitAndPush")?.enabled, true);
    assert.equal(pushPreview.actions.find((action) => action.id === "commitPushAndPR")?.enabled, false);

    const githubRepo = setupRepo();
    execFileSync("git", ["remote", "add", "origin", "git@github.com:example/spellwire.git"], { cwd: githubRepo });
    execFileSync("git", ["checkout", "-b", "feature/git-ui"], { cwd: githubRepo });
    writeFileSync(path.join(githubRepo, "github.txt"), "github\n");
    const githubPreview = await getGitCommitPreview(githubRepo, {}, { execFileImpl: fakeGhExec(realExec) });
    assert.equal(githubPreview.actions.find((action) => action.id === "commitPushAndPR")?.enabled, true);
});

test("executeGitCommit stages all changes, pushes to origin, and returns a PR URL when requested", async () => {
    const cwd = setupRepo();
    const bareRemote = setupBareRemote();
    execFileSync("git", ["remote", "add", "origin", "git@github.com:example/spellwire.git"], { cwd });
    execFileSync("git", ["remote", "set-url", "--push", "origin", bareRemote], { cwd });
    execFileSync("git", ["checkout", "-b", "feature/git-ui"], { cwd });
    writeFileSync(path.join(cwd, "tracked.txt"), "first\nsecond updated\n");
    writeFileSync(path.join(cwd, "new.txt"), "hello\n");
    mkdirSync(path.join(cwd, "nested"));
    writeFileSync(path.join(cwd, "nested", "deep.txt"), "deep\n");

    const result = await executeGitCommit(
        {
            cwd,
            action: "commitPushAndPR",
        },
        { execFileImpl: fakeGhExec(realExec) }
    );

    assert.match(result.commitSHA, /^[0-9a-f]{40}$/);
    assert.equal(result.pushed, true);
    assert.equal(result.branch, "feature/git-ui");
    assert.equal(result.prURL, "https://github.com/example/spellwire/pull/1");

    const remoteBranch = execFileSync("git", ["--git-dir", bareRemote, "branch", "--list", "feature/git-ui"], { encoding: "utf8" });
    assert.match(remoteBranch, /feature\/git-ui/);
});

test("executeGitCommit commits only the scoped thread paths", async () => {
    const cwd = setupRepo();
    execFileSync("git", ["checkout", "-b", "feature/thread-scope"], { cwd });
    writeFileSync(path.join(cwd, "tracked.txt"), "first\nsecond updated\n");
    writeFileSync(path.join(cwd, "outside.txt"), "outside\n");

    await executeGitCommit({
        cwd,
        paths: ["tracked.txt"],
        action: "commit",
    });

    const headFiles = execFileSync("git", ["show", "--name-only", "--format=", "HEAD"], { cwd, encoding: "utf8" });
    assert.match(headFiles, /tracked\.txt/);
    assert.doesNotMatch(headFiles, /outside\.txt/);

    const remainingStatus = execFileSync("git", ["status", "--porcelain=v1", "--", "outside.txt"], { cwd, encoding: "utf8" });
    assert.match(remainingStatus, /\?\? outside\.txt/);
});
