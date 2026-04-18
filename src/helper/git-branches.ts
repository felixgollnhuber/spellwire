import type { BranchInfo } from "../shared/protocol.js";
import { ensureGitRepository, runGit } from "./git.js";

export async function listLocalBranches(cwd: string): Promise<BranchInfo[]> {
    await ensureGitRepository(cwd);

    const stdout = await runGit(cwd, ["for-each-ref", "--format=%(refname:short)\t%(HEAD)", "refs/heads"]);

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
    await runGit(cwd, ["checkout", "--quiet", name]);

    const currentBranch = (await runGit(cwd, ["branch", "--show-current"])).trim();
    if (!currentBranch) {
        throw new Error("Git checkout completed but no current branch was reported.");
    }
    return currentBranch;
}
