import readline from "node:readline";
import type { Readable } from "node:stream";

export function createJSONLineReader(
    readable: Readable,
    onValue: (value: unknown) => void,
    onError: (error: Error, line: string) => void,
): readline.Interface {
    readable.setEncoding("utf8");
    const interfaceHandle = readline.createInterface({ input: readable });
    interfaceHandle.on("line", (line) => {
        const trimmed = line.trim();
        if (trimmed.length === 0) {
            return;
        }
        try {
            onValue(JSON.parse(trimmed));
        } catch (error) {
            onError(error instanceof Error ? error : new Error(String(error)), line);
        }
    });
    return interfaceHandle;
}

export function serializeJSONLine(value: unknown): string {
    return `${JSON.stringify(value)}\n`;
}
