import { spawn } from "node:child_process";
import type { RuntimePaths } from "../shared/runtime-paths.js";
import { patchDaemonState } from "./state-store.js";

export class DesktopBridge {
    constructor(private readonly paths: RuntimePaths) {}

    async rememberLastActiveThread(threadID: string, cwd: string): Promise<void> {
        await patchDaemonState(this.paths, {
            lastActiveThreadId: threadID,
            lastActiveCwd: cwd,
        });
    }

    async openThread(threadID: string, cwd: string): Promise<{ opened: boolean; bestEffort: boolean }> {
        await this.rememberLastActiveThread(threadID, cwd);
        const child = spawn("codex", ["app", cwd], {
            detached: true,
            stdio: "ignore",
        });
        child.unref();
        return { opened: true, bestEffort: true };
    }
}
