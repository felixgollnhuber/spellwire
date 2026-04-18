import { EventEmitter } from "node:events";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createJSONLineReader, serializeJSONLine } from "../shared/json-lines.js";
import { JSONLLogger } from "./logger.js";

interface AppServerMessage {
    id?: string | number;
    method?: string;
    params?: unknown;
    result?: unknown;
    error?: unknown;
}

interface PendingRequest {
    resolve: (value: unknown) => void;
    reject: (error: Error) => void;
}

export interface AppServerSnapshot {
    running: boolean;
    pid: number | null;
    codexHome: string | null;
    userAgent: string | null;
}

export class AppServerClient extends EventEmitter {
    private child: ChildProcessWithoutNullStreams | null = null;
    private pendingRequests = new Map<string, PendingRequest>();
    private nextRequestID = 1;
    private startupPromise: Promise<void> | null = null;
    private snapshot: AppServerSnapshot = {
        running: false,
        pid: null,
        codexHome: null,
        userAgent: null,
    };

    constructor(private readonly logger: JSONLLogger) {
        super();
    }

    currentSnapshot(): AppServerSnapshot {
        return { ...this.snapshot };
    }

    async ensureStarted(): Promise<void> {
        if (this.snapshot.running && this.child?.killed === false) {
            return;
        }
        if (this.startupPromise) {
            return this.startupPromise;
        }

        this.startupPromise = this.startInner().finally(() => {
            this.startupPromise = null;
        });
        return this.startupPromise;
    }

    async request<T>(method: string, params: unknown): Promise<T> {
        await this.ensureStarted();
        return this.sendRequest<T>(method, params);
    }

    async shutdown(): Promise<void> {
        if (!this.child) {
            return;
        }

        const child = this.child;
        this.child = null;
        child.kill("SIGTERM");
        this.snapshot = {
            running: false,
            pid: null,
            codexHome: this.snapshot.codexHome,
            userAgent: this.snapshot.userAgent,
        };
    }

    private async startInner(): Promise<void> {
        const codexCommand = process.env.SPELLWIRE_CODEX_PATH ?? "codex";
        const child = spawn(codexCommand, ["app-server", "--listen", "stdio://"], {
            stdio: ["pipe", "pipe", "pipe"],
            env: {
                ...process.env,
                PATH: process.env.PATH ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            },
        });
        await new Promise<void>((resolve, reject) => {
            const handleSpawn = () => {
                child.off("error", handleError);
                resolve();
            };
            const handleError = (error: Error) => {
                child.off("spawn", handleSpawn);
                reject(error);
            };

            child.once("spawn", handleSpawn);
            child.once("error", handleError);
        });
        this.child = child;
        this.snapshot = {
            running: true,
            pid: child.pid ?? null,
            codexHome: null,
            userAgent: null,
        };

        createJSONLineReader(
            child.stdout,
            (value) => this.handleMessage(value as AppServerMessage),
            (error, line) => {
                this.logger.error("Failed to decode app-server stdout line", { error: error.message, line });
            },
        );

        createJSONLineReader(
            child.stderr,
            (value) => {
                this.logger.warn("App-server wrote structured stderr output", { value });
            },
            (_error, line) => {
                this.logger.warn("App-server stderr", { line });
            },
        );

        child.on("exit", (code, signal) => {
            const error = new Error(`codex app-server exited (code=${code ?? "null"}, signal=${signal ?? "null"})`);
            for (const pending of this.pendingRequests.values()) {
                pending.reject(error);
            }
            this.pendingRequests.clear();
            this.snapshot = {
                running: false,
                pid: null,
                codexHome: this.snapshot.codexHome,
                userAgent: this.snapshot.userAgent,
            };
            this.emit("exit", error);
        });

        try {
            const initializeResult = await this.sendRequest<{
                codexHome?: string;
                userAgent?: string;
            }>("initialize", {
                clientInfo: {
                    name: "spellwire-helper",
                    version: "0.1.0",
                },
                capabilities: null,
            });

            this.snapshot = {
                ...this.snapshot,
                codexHome: initializeResult.codexHome ?? null,
                userAgent: initializeResult.userAgent ?? null,
            };
            this.sendRaw({ method: "initialized" });
        } catch (error) {
            this.logger.error("Failed to initialize codex app-server", {
                codexCommand,
                error: error instanceof Error ? error.message : String(error),
            });
            await this.shutdown();
            throw error;
        }
    }

    private handleMessage(message: AppServerMessage): void {
        if (message.id !== undefined && message.method) {
            this.logger.warn("Received unsupported server request from app-server", { method: message.method });
            this.sendRaw({
                id: message.id,
                error: {
                    code: -32001,
                    message: "Spellwire helper does not handle interactive app-server callbacks yet.",
                },
            });
            return;
        }

        if (message.id !== undefined) {
            const pending = this.pendingRequests.get(String(message.id));
            if (!pending) {
                return;
            }
            this.pendingRequests.delete(String(message.id));
            if (message.error) {
                pending.reject(new Error(typeof message.error === "string" ? message.error : JSON.stringify(message.error)));
            } else {
                pending.resolve(message.result);
            }
            return;
        }

        if (message.method) {
            this.emit("notification", {
                method: message.method,
                params: message.params,
            });
        }
    }

    private async sendRequest<T>(method: string, params: unknown): Promise<T> {
        const requestID = String(this.nextRequestID++);
        return new Promise<T>((resolve, reject) => {
            this.pendingRequests.set(requestID, {
                resolve: (value) => resolve(value as T),
                reject,
            });
            this.sendRaw({
                id: requestID,
                method,
                params,
            });
        });
    }

    private sendRaw(message: unknown): void {
        if (!this.child?.stdin.writable) {
            throw new Error("codex app-server stdin is not writable.");
        }
        this.child.stdin.write(serializeJSONLine(message));
    }
}
