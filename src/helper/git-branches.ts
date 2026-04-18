import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { BranchInfo } from "../shared/protocol.js";

const execFileAsync = promisify(execFile);

async function ensureGitRepository(cwd: string): Promise<void> {
    await execFileAsync("git", ["rev-parse", "--is-inside-work-tree"], { cwd });
}

export async function listLocalBranches(cwd: string): Promise<BranchInfo[]> {
    await ensureGitRepository(cwd);

    const { stdout } = await execFileAsync(
        "git",
        ["for-each-ref", "--format=%(refname:short)\t%(HEAD)", "refs/heads"],
        { cwd },
    );

    return stdout
        .split("\n")
        .map((line) => line.trim())
        .filter(Boolean)
        .map((line) => {
            const [name, headMarker] = line.split("\t");
            return {
                name,
                isCurrent: headMarker === "*",
            };
        })
        .sort((left, right) => {
            if (left.isCurrent !== right.isCurrent) {
                return left.isCurrent ? -1 : 1;
            }
            return left.name.localeCompare(right.name);
        });
}

export async function switchLocalBranch(cwd: string, name: string): Promise<string> {
    await ensureGitRepository(cwd);
    await execFileAsync("git", ["checkout", "--quiet", name], { cwd });

    const { stdout } = await execFileAsync("git", ["branch", "--show-current"], { cwd });
    const currentBranch = stdout.trim();
    if (!currentBranch) {
        throw new Error("Git checkout completed but no current branch was reported.");
    }
    return currentBranch;
}
