import Foundation

nonisolated enum SSHSetupCommand {
    static func installAuthorizedKeyCommand(for publicKey: String) -> String {
        let quotedKey = shellSingleQuote(publicKey)
        return """
        # Add the Spellwire iPhone key to ~/.ssh/authorized_keys
        mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && { grep -qxF \(quotedKey) ~/.ssh/authorized_keys || printf '%s\\n' \(quotedKey) >> ~/.ssh/authorized_keys; }
        """
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
