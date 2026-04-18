import CoreGraphics
import Foundation

nonisolated struct HostKeyChallenge: Equatable, Identifiable, Sendable {
    let id = UUID()
    let hostLabel: String
    let fingerprint: String
    let openSSHKey: String
}

nonisolated protocol TerminalTransportDelegate: AnyObject {
    func transportDidConnect()
    func transportDidReceive(data: Data)
    func transportDidDisconnect(error: Error?)
    func transportDidReceiveExitStatus(_ status: Int32)
}

nonisolated protocol TerminalTransport: AnyObject {
    var delegate: TerminalTransportDelegate? { get set }
    func connect()
    func send(_ data: Data)
    func resize(cols: Int, rows: Int, pixelSize: CGSize)
    func disconnect()
}

nonisolated enum TerminalConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case trustPrompt
    case connected
    case reconnecting
    case disconnected
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            "Idle"
        case .connecting:
            "Connecting"
        case .trustPrompt:
            "Verify Host Key"
        case .connected:
            "Connected"
        case .reconnecting:
            "Reconnecting"
        case .disconnected:
            "Disconnected"
        case .failed(let message):
            message
        }
    }
}

nonisolated enum TransportError: LocalizedError, Sendable {
    case missingIdentity
    case rejectedHostKey
    case hostKeyMismatch(expected: String, received: String)
    case invalidChannelType
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingIdentity:
            "Spellwire could not load its SSH identity."
        case .rejectedHostKey:
            "The host key was not trusted."
        case .hostKeyMismatch(let expected, let received):
            "Host key mismatch.\nExpected: \(expected)\nReceived: \(received)"
        case .invalidChannelType:
            "SSH server did not open a session channel."
        case .connectionFailed(let message):
            message
        }
    }
}
