import { existsSync, mkdirSync, readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

export interface RuntimePaths {
    packageRoot: string;
    runtimeRoot: string;
    socketPath: string;
    stateFilePath: string;
    logFilePath: string;
    launchAgentPlistPath: string;
    launchAgentLabel: string;
    launchAgentStdoutPath: string;
    launchAgentStderrPath: string;
    nodePath: string;
    cliEntrypointPath: string;
    inheritedPath: string;
    codexExecutablePath: string | null;
}

function resolvePackageRoot(moduleURL: string): string {
    let currentDirectory = path.dirname(fileURLToPath(moduleURL));

    while (true) {
        const packageJSONPath = path.join(currentDirectory, "package.json");
        if (existsSync(packageJSONPath)) {
            return currentDirectory;
        }

        const parentDirectory = path.dirname(currentDirectory);
        if (parentDirectory === currentDirectory) {
            throw new Error("Unable to locate package.json for Spellwire runtime.");
        }
        currentDirectory = parentDirectory;
    }
}

const packageRoot = resolvePackageRoot(import.meta.url);
const packageJSONPath = path.join(packageRoot, "package.json");
const packageMetadata = JSON.parse(readFileSync(packageJSONPath, "utf8")) as { version: string };

export function spellwireVersion(): string {
    return packageMetadata.version;
}

export function runtimePaths(): RuntimePaths {
    const runtimeRoot = path.join(os.homedir(), "Library", "Application Support", "Spellwire");
    const logRoot = path.join(runtimeRoot, "logs");
    const runRoot = path.join(runtimeRoot, "run");
    const stateRoot = path.join(runtimeRoot, "state");
    const launchAgentLabel = "dev.spellwire.helper";

    const inheritedPath = process.env.PATH ?? "/usr/bin:/bin:/usr/sbin:/sbin";
    const codexExecutablePath = resolveExecutablePath("codex");

    return {
        packageRoot,
        runtimeRoot,
        socketPath: path.join(runRoot, "spellwire-helper.sock"),
        stateFilePath: path.join(stateRoot, "helper-state.json"),
        logFilePath: path.join(logRoot, "helper.jsonl"),
        launchAgentPlistPath: path.join(os.homedir(), "Library", "LaunchAgents", `${launchAgentLabel}.plist`),
        launchAgentLabel,
        launchAgentStdoutPath: path.join(logRoot, "launch-agent.stdout.log"),
        launchAgentStderrPath: path.join(logRoot, "launch-agent.stderr.log"),
        nodePath: process.execPath,
        cliEntrypointPath: path.join(packageRoot, "dist", "src", "cli.js"),
        inheritedPath,
        codexExecutablePath,
    };
}

function resolveExecutablePath(command: string): string | null {
    const result = spawnSync("which", [command], {
        encoding: "utf8",
        env: {
            ...process.env,
            PATH: process.env.PATH ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        },
    });
    if (result.status !== 0) {
        return null;
    }
    const resolvedPath = result.stdout.trim();
    return resolvedPath.length > 0 ? resolvedPath : null;
}

export function ensureRuntimeDirectories(paths: RuntimePaths): void {
    mkdirSync(paths.runtimeRoot, { recursive: true });
    mkdirSync(path.dirname(paths.socketPath), { recursive: true });
    mkdirSync(path.dirname(paths.stateFilePath), { recursive: true });
    mkdirSync(path.dirname(paths.logFilePath), { recursive: true });
    mkdirSync(path.dirname(paths.launchAgentPlistPath), { recursive: true });
}
