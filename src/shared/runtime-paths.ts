import { existsSync, mkdirSync, readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

export interface RuntimePaths {
    platform: NodeJS.Platform;
    serviceManager: "launch-agent" | "background-process";
    packageRoot: string;
    runtimeRoot: string;
    attachmentsRootPath: string;
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

export function runtimePaths(overrides: {
    platform?: NodeJS.Platform;
    homeDirectory?: string;
    env?: NodeJS.ProcessEnv;
} = {}): RuntimePaths {
    const platform = overrides.platform ?? process.platform;
    const homeDirectory = overrides.homeDirectory ?? os.homedir();
    const env = overrides.env ?? process.env;
    const runtimeRoot = resolveRuntimeRoot(platform, homeDirectory, env);
    const logRoot = path.join(runtimeRoot, "logs");
    const runRoot = path.join(runtimeRoot, "run");
    const stateRoot = path.join(runtimeRoot, "state");
    const launchAgentLabel = "dev.spellwire.helper";
    const serviceManager = platform === "darwin" ? "launch-agent" : "background-process";

    const inheritedPath = env.PATH ?? defaultPathForPlatform(platform);
    const codexExecutablePath = resolveExecutablePath("codex", inheritedPath, env);

    return {
        platform,
        serviceManager,
        packageRoot,
        runtimeRoot,
        attachmentsRootPath: path.join(runtimeRoot, "attachments"),
        socketPath: path.join(runRoot, "spellwire-helper.sock"),
        stateFilePath: path.join(stateRoot, "helper-state.json"),
        logFilePath: path.join(logRoot, "helper.jsonl"),
        launchAgentPlistPath:
            platform === "darwin"
                ? path.join(homeDirectory, "Library", "LaunchAgents", `${launchAgentLabel}.plist`)
                : path.join(runtimeRoot, "launch-agents", `${launchAgentLabel}.plist`),
        launchAgentLabel,
        launchAgentStdoutPath: path.join(logRoot, "launch-agent.stdout.log"),
        launchAgentStderrPath: path.join(logRoot, "launch-agent.stderr.log"),
        nodePath: process.execPath,
        cliEntrypointPath: path.join(packageRoot, "dist", "src", "cli.js"),
        inheritedPath,
        codexExecutablePath,
    };
}

function resolveRuntimeRoot(platform: NodeJS.Platform, homeDirectory: string, env: NodeJS.ProcessEnv): string {
    if (platform === "darwin") {
        return path.join(homeDirectory, "Library", "Application Support", "Spellwire");
    }

    if (platform === "linux") {
        const stateHome = env.XDG_STATE_HOME?.trim();
        if (stateHome && path.isAbsolute(stateHome)) {
            return path.join(stateHome, "spellwire");
        }
        return path.join(homeDirectory, ".local", "state", "spellwire");
    }

    return path.join(homeDirectory, ".spellwire");
}

function defaultPathForPlatform(platform: NodeJS.Platform): string {
    return platform === "darwin"
        ? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        : "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
}

function resolveExecutablePath(command: string, inheritedPath: string, env: NodeJS.ProcessEnv): string | null {
    const result = spawnSync("which", [command], {
        encoding: "utf8",
        env: {
            ...env,
            PATH: inheritedPath,
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
    mkdirSync(paths.attachmentsRootPath, { recursive: true });
    mkdirSync(path.dirname(paths.socketPath), { recursive: true });
    mkdirSync(path.dirname(paths.stateFilePath), { recursive: true });
    mkdirSync(path.dirname(paths.logFilePath), { recursive: true });
    mkdirSync(path.dirname(paths.launchAgentPlistPath), { recursive: true });
}
