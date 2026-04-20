#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { daemonRequest, daemonRunning, waitForDaemonReady } from "./helper/daemon-client.js";
import { runForegroundDaemon } from "./helper/daemon.js";
import { helperServiceInstalled, installHelperService, uninstallHelperService } from "./helper/service-manager.js";
import { readDaemonState } from "./helper/state-store.js";
import { ensureRuntimeDirectories, runtimePaths, spellwireVersion } from "./shared/runtime-paths.js";

const paths = runtimePaths();
ensureRuntimeDirectories(paths);

async function main(): Promise<void> {
    const [, , command, ...args] = process.argv;

    switch (command) {
        case "up":
            await installHelperService(paths);
            await waitForDaemonReady(paths);
            console.log(JSON.stringify(await daemonRequest(paths, "helper.status", {}), null, 2));
            break;
        case "stop":
            await uninstallHelperService(paths);
            console.log(JSON.stringify({ stopped: true }, null, 2));
            break;
        case "status":
            if (await daemonRunning(paths.socketPath)) {
                console.log(JSON.stringify(await daemonRequest(paths, "helper.status", {}), null, 2));
            } else {
                const state = await readDaemonState(paths);
                console.log(
                    JSON.stringify(
                        {
                            helperVersion: spellwireVersion(),
                            daemonRunning: false,
                            appServerRunning: false,
                            socketPath: paths.socketPath,
                            logFilePath: paths.logFilePath,
                            codexHome: state.codexHome,
                            lastActiveThreadId: state.lastActiveThreadId,
                            lastActiveCwd: state.lastActiveCwd,
                            startedAt: state.startedAt,
                            lastNotificationAt: state.lastNotificationAt,
                            lastError: state.lastError,
                        },
                        null,
                        2,
                    ),
                );
            }
            break;
        case "logs": {
            const content = await readFile(paths.logFilePath, "utf8").catch(() => "");
            const lines = content
                .split("\n")
                .filter(Boolean)
                .slice(-200)
                .join("\n");
            process.stdout.write(lines);
            if (lines.length > 0 && !lines.endsWith("\n")) {
                process.stdout.write("\n");
            }
            break;
        }
        case "doctor":
            console.log(JSON.stringify(await doctor(), null, 2));
            break;
        case "rpc": {
            const socket = await import("node:net").then(({ createConnection }) => createConnection(paths.socketPath));
            socket.pipe(process.stdout);
            process.stdin.pipe(socket);
            process.stdin.resume();
            break;
        }
        case "open":
            console.log(
                JSON.stringify(
                    await daemonRequest(paths, "desktop.open", {
                        threadID: args[0] ?? "",
                    }),
                    null,
                    2,
                ),
            );
            break;
        case "previews":
            if (args[0] !== "list") {
                throw new Error("Expected `spellwire previews list`.");
            }
            console.log(JSON.stringify(await daemonRequest(paths, "previews.list", {}), null, 2));
            break;
        case "internal-daemon":
            await runForegroundDaemon();
            break;
        default:
            printUsage();
    }
}

async function doctor(): Promise<Record<string, unknown>> {
    const codex = spawnSync("which", ["codex"], { encoding: "utf8" });
    const node = spawnSync("which", ["node"], { encoding: "utf8" });
    const serviceInstalled = await helperServiceInstalled(paths);
    return {
        helperVersion: spellwireVersion(),
        platform: paths.platform,
        serviceManager: paths.serviceManager,
        helperServiceInstalled: serviceInstalled,
        launchAgentInstalled: paths.serviceManager === "launch-agent" ? serviceInstalled : false,
        daemonRunning: await daemonRunning(paths.socketPath),
        codexPath: codex.status === 0 ? codex.stdout.trim() : null,
        nodePath: node.status === 0 ? node.stdout.trim() : null,
        socketPath: paths.socketPath,
        state: await readDaemonState(paths),
    };
}

function printUsage(): void {
    process.stdout.write(
        [
            "spellwire up",
            "spellwire stop",
            "spellwire status",
            "spellwire logs",
            "spellwire doctor",
            "spellwire rpc",
            "spellwire open <threadId>",
            "spellwire previews list",
        ].join("\n"),
    );
    process.stdout.write("\n");
}

void main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exit(1);
});
