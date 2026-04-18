import { appendFileSync, mkdirSync } from "node:fs";
import path from "node:path";

export class JSONLLogger {
    constructor(private readonly filePath: string) {
        mkdirSync(path.dirname(filePath), { recursive: true });
    }

    info(message: string, context?: Record<string, unknown>): void {
        this.write("info", message, context);
    }

    warn(message: string, context?: Record<string, unknown>): void {
        this.write("warn", message, context);
    }

    error(message: string, context?: Record<string, unknown>): void {
        this.write("error", message, context);
    }

    private write(level: "info" | "warn" | "error", message: string, context?: Record<string, unknown>): void {
        appendFileSync(
            this.filePath,
            `${JSON.stringify({
                timestamp: new Date().toISOString(),
                level,
                message,
                context: context ?? {},
            })}\n`,
        );
    }
}
