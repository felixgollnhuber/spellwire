import { access, rm, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import type { RuntimePaths } from "../shared/runtime-paths.js";

function launchctl(args: string[]): void {
    spawnSync("launchctl", args, {
        stdio: "ignore",
    });
}

export function launchAgentPlist(paths: RuntimePaths): string {
    const programArguments = [paths.nodePath, paths.cliEntrypointPath, "internal-daemon"]
        .map((argument) => `<string>${argument}</string>`)
        .join("");
    const environmentVariables = [
        ["PATH", paths.inheritedPath],
        ["SPELLWIRE_CODEX_PATH", paths.codexExecutablePath],
    ]
        .filter((entry): entry is [string, string] => typeof entry[1] === "string" && entry[1].length > 0)
        .map(
            ([key, value]) => `
    <key>${key}</key>
    <string>${value}</string>`,
        )
        .join("");
    return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${paths.launchAgentLabel}</string>
    <key>ProgramArguments</key>
    <array>${programArguments}</array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>${paths.packageRoot}</string>
    <key>EnvironmentVariables</key>
    <dict>${environmentVariables}
    </dict>
    <key>StandardOutPath</key>
    <string>${paths.launchAgentStdoutPath}</string>
    <key>StandardErrorPath</key>
    <string>${paths.launchAgentStderrPath}</string>
</dict>
</plist>
`;
}

export async function installLaunchAgent(paths: RuntimePaths): Promise<void> {
    await writeFile(paths.launchAgentPlistPath, launchAgentPlist(paths), "utf8");
    const uid = typeof process.getuid === "function" ? process.getuid() : 0;
    const domain = `gui/${uid}`;
    launchctl(["bootout", domain, paths.launchAgentPlistPath]);
    launchctl(["bootstrap", domain, paths.launchAgentPlistPath]);
    launchctl(["kickstart", "-k", `${domain}/${paths.launchAgentLabel}`]);
}

export async function uninstallLaunchAgent(paths: RuntimePaths): Promise<void> {
    const uid = typeof process.getuid === "function" ? process.getuid() : 0;
    const domain = `gui/${uid}`;
    launchctl(["bootout", domain, paths.launchAgentPlistPath]);
    await rm(paths.launchAgentPlistPath, { force: true });
}

export async function launchAgentInstalled(paths: RuntimePaths): Promise<boolean> {
    try {
        await access(paths.launchAgentPlistPath);
        return true;
    } catch {
        return false;
    }
}
