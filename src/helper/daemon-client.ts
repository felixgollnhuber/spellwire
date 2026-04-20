import net from "node:net";
import readline from "node:readline";
import type {
    HelperFailureResponseEnvelope,
    HelperRequestEnvelope,
    HelperResponseEnvelope,
    HelperSuccessResponseEnvelope,
    JSONValue,
} from "../shared/protocol.js";
import { serializeJSONLine } from "../shared/json-lines.js";
import type { RuntimePaths } from "../shared/runtime-paths.js";

export async function daemonRequest<T>(paths: RuntimePaths, method: HelperRequestEnvelope["method"], params: JSONValue): Promise<T> {
    const socket = await connectDaemon(paths.socketPath);
    return new Promise<T>((resolve, reject) => {
        const requestID = `cli:${Date.now()}:${Math.random().toString(16).slice(2)}`;
        const lineInterface = readline.createInterface({ input: socket });

        lineInterface.on("line", (line) => {
            const trimmed = line.trim();
            if (!trimmed) {
                return;
            }
            const envelope = JSON.parse(trimmed) as HelperResponseEnvelope;
            if (envelope.kind !== "response" || envelope.id !== requestID) {
                return;
            }
            if (envelope.ok) {
                resolve((envelope as HelperSuccessResponseEnvelope<T>).result);
            } else {
                const errorEnvelope = envelope as HelperFailureResponseEnvelope;
                reject(new Error(errorEnvelope.error.message));
            }
            lineInterface.close();
            socket.end();
        });

        socket.on("error", reject);
        socket.write(
            serializeJSONLine({
                kind: "request",
                id: requestID,
                method,
                params,
            } satisfies HelperRequestEnvelope),
        );
    });
}

export async function connectDaemon(socketPath: string): Promise<net.Socket> {
    return new Promise((resolve, reject) => {
        const socket = net.createConnection(socketPath);
        socket.once("connect", () => resolve(socket));
        socket.once("error", reject);
    });
}

export async function daemonRunning(socketPath: string): Promise<boolean> {
    try {
        const socket = await connectDaemon(socketPath);
        socket.end();
        return true;
    } catch {
        return false;
    }
}

export async function waitForDaemonReady(paths: RuntimePaths, timeoutMs = 20_000): Promise<void> {
    const startedAt = Date.now();
    let lastError: Error | null = null;

    while (Date.now() - startedAt < timeoutMs) {
        try {
            await daemonRequest(paths, "helper.status", {});
            return;
        } catch (error) {
            lastError = error instanceof Error ? error : new Error(String(error));
            await new Promise((resolve) => setTimeout(resolve, 250));
        }
    }

    throw new Error(
        `Spellwire helper did not become ready within ${timeoutMs}ms.${lastError ? ` Last error: ${lastError.message}` : ""}`,
    );
}
