import { open, readdir, stat } from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import type { CodexRecoveryState } from "../shared/protocol.js";

interface RecoveryIndexEntry {
    threadID: string;
    rolloutPath: string;
    modifiedAtMs: number;
}

export class SessionRecoveryIndex {
    private readonly sessionsRoot: string;
    private cacheBuiltAt = 0;
    private entries = new Map<string, RecoveryIndexEntry>();

    constructor(sessionsRoot = path.join(os.homedir(), ".codex", "sessions")) {
        this.sessionsRoot = sessionsRoot;
    }

    async recentRecovery(threadID: string): Promise<CodexRecoveryState | null> {
        await this.ensureIndexed();
        const entry = this.entries.get(threadID);
        if (!entry) {
            return null;
        }

        const fileHandle = await open(entry.rolloutPath, "r");
        try {
            const fileStats = await fileHandle.stat();
            const readLength = Math.min(fileStats.size, 256 * 1024);
            const buffer = Buffer.alloc(readLength);
            const start = Math.max(fileStats.size - readLength, 0);
            await fileHandle.read(buffer, 0, readLength, start);
            const lines = buffer
                .toString("utf8")
                .split("\n")
                .map((line) => line.trim())
                .filter(Boolean);

            const snippets = lines
                .map((line) => {
                    try {
                        return JSON.parse(line) as {
                            timestamp?: string;
                            type?: string;
                            payload?: { type?: string; message?: string };
                        };
                    } catch {
                        return null;
                    }
                })
                .filter((entryValue): entryValue is NonNullable<typeof entryValue> => entryValue !== null)
                .flatMap((lineValue, index) => {
                    if (lineValue.type !== "event_msg") {
                        return [];
                    }
                    const payloadType = lineValue.payload?.type;
                    if (payloadType !== "agent_message" && payloadType !== "user_message") {
                        return [];
                    }
                    const message = lineValue.payload?.message?.trim();
                    if (!message) {
                        return [];
                    }
                    return [
                        {
                            id: `recovery:${threadID}:${index}`,
                            text: message,
                            timestamp: lineValue.timestamp ?? null,
                            source: "rollout" as const,
                        },
                    ];
                })
                .slice(-12);

            const lastEventAt = snippets.at(-1)?.timestamp ?? null;
            return {
                rolloutPath: entry.rolloutPath,
                lastEventAt,
                snippets,
            };
        } finally {
            await fileHandle.close();
        }
    }

    async invalidate(): Promise<void> {
        this.cacheBuiltAt = 0;
        this.entries.clear();
    }

    private async ensureIndexed(): Promise<void> {
        if (Date.now() - this.cacheBuiltAt < 30_000 && this.entries.size > 0) {
            return;
        }

        this.entries.clear();
        const rolloutPaths = await this.collectRollouts(this.sessionsRoot);
        const ranked = await Promise.all(
            rolloutPaths.map(async (rolloutPath) => ({
                rolloutPath,
                modifiedAtMs: (await stat(rolloutPath)).mtimeMs,
            })),
        );

        ranked.sort((left, right) => right.modifiedAtMs - left.modifiedAtMs);
        for (const rankedEntry of ranked.slice(0, 400)) {
            const threadID = await this.readThreadID(rankedEntry.rolloutPath);
            if (!threadID || this.entries.has(threadID)) {
                continue;
            }
            this.entries.set(threadID, {
                threadID,
                rolloutPath: rankedEntry.rolloutPath,
                modifiedAtMs: rankedEntry.modifiedAtMs,
            });
        }
        this.cacheBuiltAt = Date.now();
    }

    private async collectRollouts(root: string): Promise<string[]> {
        const results: string[] = [];
        let directoryEntries;
        try {
            directoryEntries = await readdir(root, { withFileTypes: true });
        } catch {
            return results;
        }

        for (const entry of directoryEntries) {
            const entryName = String(entry.name);
            const fullPath = path.join(root, entryName);
            if (entry.isDirectory()) {
                results.push(...(await this.collectRollouts(fullPath)));
                continue;
            }
            if (entry.isFile() && entryName.endsWith(".jsonl") && entryName.startsWith("rollout-")) {
                results.push(fullPath);
            }
        }
        return results;
    }

    private async readThreadID(rolloutPath: string): Promise<string | null> {
        const fileHandle = await open(rolloutPath, "r");
        try {
            const buffer = Buffer.alloc(4096);
            const { bytesRead } = await fileHandle.read(buffer, 0, buffer.length, 0);
            const firstLine = buffer.toString("utf8", 0, bytesRead).split("\n")[0]?.trim();
            if (!firstLine) {
                return null;
            }
            const parsed = JSON.parse(firstLine) as {
                payload?: { id?: string };
            };
            return parsed.payload?.id ?? null;
        } catch {
            return null;
        } finally {
            await fileHandle.close();
        }
    }
}
