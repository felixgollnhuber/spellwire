import { spawn } from "node:child_process";
import { launchAgentInstalled, installLaunchAgent, uninstallLaunchAgent } from "./launch-agent.js";
import { daemonRunning } from "./daemon-client.js";
import { readDaemonState } from "./state-store.js";
import type { RuntimePaths } from "../shared/runtime-paths.js";

export async function installHelperService(paths: RuntimePaths): Promise<void> {
    if (paths.serviceManager === "launch-agent") {
        await installLaunchAgent(paths);
        return;
    }

    if (await daemonRunning(paths.socketPath)) {
        return;
    }

    const child = spawn(paths.nodePath, [paths.cliEntrypointPath, "internal-daemon"], {
        cwd: paths.packageRoot,
        detached: true,
        stdio: "ignore",
        env: {
            ...process.env,
            PATH: paths.inheritedPath,
            ...(paths.codexExecutablePath ? { SPELLWIRE_CODEX_PATH: paths.codexExecutablePath } : {}),
        },
    });

    await new Promise<void>((resolve, reject) => {
        child.once("error", reject);
        child.once("spawn", () => resolve());
    });
    child.unref();
}

export async function uninstallHelperService(paths: RuntimePaths): Promise<void> {
    if (paths.serviceManager === "launch-agent") {
        await uninstallLaunchAgent(paths);
        return;
    }

    const state = await readDaemonState(paths);
    if (state.pid && processAlive(state.pid)) {
        process.kill(state.pid, "SIGTERM");
        await waitForShutdown(paths, state.pid);
    }
}

export async function helperServiceInstalled(paths: RuntimePaths): Promise<boolean> {
    if (paths.serviceManager === "launch-agent") {
        return launchAgentInstalled(paths);
    }

    if (await daemonRunning(paths.socketPath)) {
        return true;
    }

    const state = await readDaemonState(paths);
    return state.pid !== null && processAlive(state.pid);
}

function processAlive(pid: number): boolean {
    try {
        process.kill(pid, 0);
        return true;
    } catch {
        return false;
    }
}

async function waitForShutdown(paths: RuntimePaths, pid: number, timeoutMs = 10_000): Promise<void> {
    const startedAt = Date.now();

    while (Date.now() - startedAt < timeoutMs) {
        if (!processAlive(pid) && !(await daemonRunning(paths.socketPath))) {
            return;
        }
        await new Promise((resolve) => setTimeout(resolve, 100));
    }

    if (processAlive(pid)) {
        process.kill(pid, "SIGKILL");
    }
}
