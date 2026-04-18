import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import { mkdtempSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { listLocalBranches, switchLocalBranch } from "../src/helper/git-branches.js";

function setupRepo(): string {
    const cwd = mkdtempSync(path.join(os.tmpdir(), "spellwire-git-"));
    execFileSync("git", ["init", "--initial-branch=main"], { cwd });
    execFileSync("git", ["config", "user.name", "Spellwire Tests"], { cwd });
    execFileSync("git", ["config", "user.email", "tests@spellwire.dev"], { cwd });
    execFileSync("git", ["commit", "--allow-empty", "-m", "initial"], { cwd });
    execFileSync("git", ["branch", "feature/chat"], { cwd });
    return cwd;
}

test("listLocalBranches returns local branches with current branch first", async () => {
    const cwd = setupRepo();
    const branches = await listLocalBranches(cwd);

    assert.equal(branches[0]?.name, "main");
    assert.equal(branches[0]?.isCurrent, true);
    assert.ok(branches.some((branch) => branch.name === "feature/chat"));
});

test("switchLocalBranch checks out a local branch and reports the new current branch", async () => {
    const cwd = setupRepo();
    const currentBranch = await switchLocalBranch(cwd, "feature/chat");

    assert.equal(currentBranch, "feature/chat");
    const branches = await listLocalBranches(cwd);
    assert.equal(branches.find((branch) => branch.name == "feature/chat")?.isCurrent, true);
});
