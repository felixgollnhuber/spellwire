import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class TerminalSessionCoordinator: TerminalTransportDelegate {
    let host: HostRecord
    let identity: SSHDeviceIdentity
    let trustStore: HostTrustStore
    let terminal: GhosttyTerminalController

    var state: TerminalConnectionState = .idle
    var exitStatus: Int32?
    var pendingHostKeyChallenge: HostKeyChallenge?

    private var transport: TerminalTransport?
    private var pendingTrustReply: ((Bool) -> Void)?
    private var reconnectTask: Task<Void, Never>?
    private var shouldReconnect = true

    init?(host: HostRecord, identity: SSHDeviceIdentity, trustStore: HostTrustStore) {
        guard let terminal = GhosttyTerminalController() else {
            return nil
        }

        self.host = host
        self.identity = identity
        self.trustStore = trustStore
        self.terminal = terminal
        terminal.onWriteToPTY = { [weak self] data in
            self?.transport?.send(data)
        }
    }

    deinit {}

    func connectIfNeeded() {
        switch state {
        case .idle, .disconnected, .failed:
            connect(isReconnect: false)
        default:
            break
        }
    }

    func reconnect() {
        reconnectTask?.cancel()
        transport?.disconnect()
        connect(isReconnect: true)
    }

    func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        transport?.disconnect()
        transport = nil
        state = .disconnected
    }

    func send(_ data: Data) {
        transport?.send(data)
    }

    func pasteFromClipboard() {
        guard let string = UIPasteboard.general.string else { return }
        send(Data(string.utf8))
    }

    func sendEscape() {
        send(Data([0x1B]))
    }

    func sendTab() {
        send(Data([0x09]))
    }

    func sendReturn() {
        send(Data([0x0D]))
    }

    func sendBackspace() {
        send(Data([0x7F]))
    }

    func sendArrowUp() {
        send(Data("\u{1B}[A".utf8))
    }

    func sendArrowDown() {
        send(Data("\u{1B}[B".utf8))
    }

    func sendArrowLeft() {
        send(Data("\u{1B}[D".utf8))
    }

    func sendArrowRight() {
        send(Data("\u{1B}[C".utf8))
    }

    func sendControl(_ letter: Character) {
        guard let scalar = letter.uppercased().unicodeScalars.first else { return }
        send(Data([UInt8(scalar.value & 0x1F)]))
    }

    func updateViewport(viewSize: CGSize, cellSize: CGSize) {
        terminal.resize(to: viewSize, cellSize: cellSize)
        let size = terminal.sizeForRemote()
        transport?.resize(cols: size.cols, rows: size.rows, pixelSize: size.pixelSize)
    }

    func scroll(delta: Int, at location: CGPoint, in viewSize: CGSize) {
        guard delta != 0 else { return }

        if host.prefersTmuxResume,
           let payload = terminal.encodeMouseScroll(delta: delta, at: location, in: viewSize)
        {
            send(payload)
            return
        }

        terminal.scroll(delta: delta)
    }

    func scrollToBottom() {
        terminal.scrollToBottom()
    }

    func resolveHostKeyChallenge(approved: Bool) {
        guard let challenge = pendingHostKeyChallenge else { return }
        if approved {
            try? trustStore.saveTrust(
                TrustedHost(
                    hostID: host.id,
                    openSSHKey: challenge.openSSHKey,
                    fingerprintSHA256: challenge.fingerprint,
                    approvedAt: .now
                )
            )
        }

        pendingHostKeyChallenge = nil
        let reply = pendingTrustReply
        pendingTrustReply = nil
        reply?(approved)
    }

    func transportDidConnect() {
        state = .connected
        exitStatus = nil
        let size = terminal.sizeForRemote()
        transport?.resize(cols: size.cols, rows: size.rows, pixelSize: size.pixelSize)
    }

    func transportDidReceive(data: Data) {
        terminal.ingest(data)
    }

    func transportDidDisconnect(error: Error?) {
        transport = nil
        if let error {
            state = .failed(error.localizedDescription)
        } else {
            state = .disconnected
        }

        guard shouldReconnect, error != nil else {
            return
        }

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            self.connect(isReconnect: true)
        }
    }

    func transportDidReceiveExitStatus(_ status: Int32) {
        exitStatus = status
    }

    private func connect(isReconnect: Bool) {
        shouldReconnect = true
        state = isReconnect ? .reconnecting : .connecting
        let trustedHost = trustStore.trustedHost(for: host.id)
        do {
            let transport = SSHTerminalTransport(
                host: host,
                identity: try identity.clientIdentity(username: host.username),
                trustedHost: trustedHost
            ) { [weak self] challenge, reply in
                guard let self else { return }
                self.state = .trustPrompt
                self.pendingHostKeyChallenge = challenge
                self.pendingTrustReply = reply
            }
            transport.delegate = self
            self.transport = transport
            transport.connect()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
