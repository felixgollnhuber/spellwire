import Foundation

nonisolated enum RemoteShellCommand {
    static func posixBootstrap(script: String) -> String {
        "/bin/sh -c \(singleQuote(script))"
    }

    static func singleQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
