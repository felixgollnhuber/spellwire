import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { PreviewEntry } from "../shared/protocol.js";

const execFileAsync = promisify(execFile);

export class PreviewRegistry {
    async list(): Promise<PreviewEntry[]> {
        try {
            const { stdout } = await execFileAsync("lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"]);
            const lines = stdout
                .split("\n")
                .map((line) => line.trim())
                .filter(Boolean)
                .slice(1);

            const entries = lines.flatMap((line, index) => {
                const columns = line.split(/\s+/);
                if (columns.length < 9) {
                    return [];
                }

                const processName = columns[0] ?? "unknown";
                const pid = Number.parseInt(columns[1] ?? "", 10);
                const hostPort = columns.at(-1) ?? "";
                const match = hostPort.match(/(.+):(\d+)\s+\(LISTEN\)$/);
                if (!match) {
                    return [];
                }
                const port = Number.parseInt(match[2] ?? "", 10);
                if (!Number.isFinite(port) || port < 1024) {
                    return [];
                }

                return [
                    {
                        id: `preview:${index}:${port}`,
                        url: `http://127.0.0.1:${port}`,
                        host: "127.0.0.1",
                        port,
                        processName,
                        pid: Number.isFinite(pid) ? pid : null,
                    },
                ];
            });

            const unique = new Map<number, PreviewEntry>();
            for (const entry of entries) {
                if (!unique.has(entry.port)) {
                    unique.set(entry.port, entry);
                }
            }
            return [...unique.values()].sort((left, right) => left.port - right.port);
        } catch {
            return [];
        }
    }
}
