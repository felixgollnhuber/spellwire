import { readFile, writeFile } from "node:fs/promises";
import type { RuntimePaths } from "../shared/runtime-paths.js";

export interface DaemonState {
    pid: number | null;
    startedAt: string | null;
    appServerPID: number | null;
    codexHome: string | null;
    userAgent: string | null;
    lastNotificationAt: string | null;
    lastActiveThreadId: string | null;
    lastActiveCwd: string | null;
    lastError: string | null;
}

const defaultState: DaemonState = {
    pid: null,
    startedAt: null,
    appServerPID: null,
    codexHome: null,
    userAgent: null,
    lastNotificationAt: null,
    lastActiveThreadId: null,
    lastActiveCwd: null,
    lastError: null,
};

export async function readDaemonState(paths: RuntimePaths): Promise<DaemonState> {
    try {
        const data = await readFile(paths.stateFilePath, "utf8");
        return {
            ...defaultState,
            ...(JSON.parse(data) as Partial<DaemonState>),
        };
    } catch {
        return { ...defaultState };
    }
}

export async function writeDaemonState(paths: RuntimePaths, state: DaemonState): Promise<void> {
    await writeFile(paths.stateFilePath, `${JSON.stringify(state, null, 2)}\n`, "utf8");
}

export async function patchDaemonState(paths: RuntimePaths, patch: Partial<DaemonState>): Promise<DaemonState> {
    const nextState = {
        ...(await readDaemonState(paths)),
        ...patch,
    };
    await writeDaemonState(paths, nextState);
    return nextState;
}
