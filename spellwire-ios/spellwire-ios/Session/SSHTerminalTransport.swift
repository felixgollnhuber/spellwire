import Foundation
import UIKit
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSH

nonisolated final class SSHTerminalTransport: TerminalTransport, @unchecked Sendable {
    weak var delegate: TerminalTransportDelegate?

    private let host: HostRecord
    private let identity: SSHClientIdentity
    private let trustedHost: TrustedHost?
    private let onHostKeyChallenge: @MainActor (HostKeyChallenge, @escaping (Bool) -> Void) -> Void

    private let workQueue = DispatchQueue(label: "xyz.floritzmaier.spellwire-ios.ssh.transport")
    private var group: MultiThreadedEventLoopGroup?
    private var rootChannel: Channel?
    private var childChannel: Channel?
    private var isDisconnectRequested = false
    private var didNotifyDisconnect = false
    private var currentSize = (cols: 80, rows: 24, pixelSize: CGSize(width: 720, height: 456))

    init(
        host: HostRecord,
        identity: SSHClientIdentity,
        trustedHost: TrustedHost?,
        onHostKeyChallenge: @escaping @MainActor (HostKeyChallenge, @escaping (Bool) -> Void) -> Void
    ) {
        self.host = host
        self.identity = identity
        self.trustedHost = trustedHost
        self.onHostKeyChallenge = onHostKeyChallenge
    }

    func connect() {
        workQueue.async {
            self.connectSync()
        }
    }

    func send(_ data: Data) {
        workQueue.async {
            self.sendSync(data)
        }
    }

    func resize(cols: Int, rows: Int, pixelSize: CGSize) {
        currentSize = (cols, rows, pixelSize)
        workQueue.async {
            guard let childChannel = self.childChannel else { return }
            let event = SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: cols,
                terminalRowHeight: rows,
                terminalPixelWidth: Int(pixelSize.width.rounded()),
                terminalPixelHeight: Int(pixelSize.height.rounded())
            )
            let promise = childChannel.eventLoop.makePromise(of: Void.self)
            childChannel.pipeline.triggerUserOutboundEvent(event, promise: promise)
        }
    }

    func disconnect() {
        workQueue.async {
            self.isDisconnectRequested = true
            self.closeChannelsAndShutdown(error: nil)
        }
    }

    private func connectSync() {
        isDisconnectRequested = false
        didNotifyDisconnect = false

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        do {
            let hostKeyDelegate = AppHostKeyValidationDelegate(
                host: host,
                trustedHost: trustedHost,
                onHostKeyChallenge: onHostKeyChallenge
            )
            let sshHandlerBox = SSHHandlerBox()

            let bootstrap = ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let sync = channel.pipeline.syncOperations
                        let sshHandler = NIOSSHHandler(
                            role: .client(
                                .init(
                                    userAuthDelegate: SSHClientPublicKeyAuthDelegate(
                                        username: self.identity.username,
                                        privateKey: self.identity.privateKey
                                    ),
                                    serverAuthDelegate: hostKeyDelegate
                                )
                            ),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                        sshHandlerBox.handler = sshHandler
                        try sync.addHandler(sshHandler)
                    }
                }
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

            let channel = try bootstrap.connect(host: host.hostname, port: host.port).wait()
            rootChannel = channel
            guard let sshHandler = sshHandlerBox.handler else {
                throw TransportError.connectionFailed("SSH handler was not installed.")
            }
            let sessionPromise = channel.eventLoop.makePromise(of: Channel.self)

            sshHandler.createChannel(sessionPromise) { [weak self] childChannel, channelType in
                guard let self else {
                    return childChannel.eventLoop.makeFailedFuture(
                        TransportError.connectionFailed("Transport was released during channel setup.")
                    )
                }

                guard channelType == .session else {
                    return childChannel.eventLoop.makeFailedFuture(TransportError.invalidChannelType)
                }

                let launchMode: SSHLaunchMode
                if self.host.prefersTmuxResume {
                    launchMode = .tmux(sessionName: self.host.tmuxSessionName ?? "main")
                } else {
                    launchMode = .shell
                }

                return childChannel.eventLoop.makeCompletedFuture {
                    let sync = childChannel.pipeline.syncOperations
                    try sync.addHandler(
                        SSHSessionChannelHandler(
                            initialSize: self.currentSize,
                            launchMode: launchMode,
                            onReady: { [weak self] in
                                self?.notifyConnected()
                            },
                            onData: { [weak self] data in
                                self?.notifyReceive(data)
                            },
                            onExitStatus: { [weak self] status in
                                self?.notifyExitStatus(status)
                            },
                            onDisconnect: { [weak self] error in
                                self?.requestShutdown(error: error)
                            }
                        )
                    )
                }
            }

            childChannel = try sessionPromise.futureResult.wait()
        } catch {
            closeChannelsAndShutdown(error: error)
        }
    }

    private func requestShutdown(error: Error?) {
        workQueue.async {
            self.closeChannelsAndShutdown(error: error)
        }
    }

    private func closeChannelsAndShutdown(error: Error?) {
        if let childChannel {
            childChannel.eventLoop.execute {
                childChannel.close(promise: nil)
            }
            self.childChannel = nil
        }

        if let rootChannel {
            rootChannel.eventLoop.execute {
                rootChannel.close(promise: nil)
            }
            self.rootChannel = nil
        }

        if let group {
            self.group = nil
            group.shutdownGracefully(queue: workQueue) { _ in }
        }

        notifyDisconnect(error: error)
    }

    private func sendSync(_ data: Data) {
        guard let childChannel else { return }
        var buffer = childChannel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        childChannel.writeAndFlush(buffer, promise: nil)
    }

    private func notifyConnected() {
        DispatchQueue.main.async {
            self.delegate?.transportDidConnect()
        }
    }

    private func notifyReceive(_ data: Data) {
        DispatchQueue.main.async {
            self.delegate?.transportDidReceive(data: data)
        }
    }

    private func notifyExitStatus(_ status: Int32) {
        DispatchQueue.main.async {
            self.delegate?.transportDidReceiveExitStatus(status)
        }
    }

    private func notifyDisconnect(error: Error?) {
        guard !didNotifyDisconnect else { return }
        didNotifyDisconnect = true
        DispatchQueue.main.async {
            self.delegate?.transportDidDisconnect(error: self.isDisconnectRequested ? nil : error)
        }
    }
}

nonisolated private enum SSHLaunchMode {
    case shell
    case tmux(sessionName: String)

    static func tmuxCommand(sessionName: String) -> String {
        let escapedSession = shellSingleQuote(sessionName)
        let script = """
        export PATH="/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:$HOME/.local/bin:$PATH"; if command -v tmux >/dev/null 2>&1; then exec "$(command -v tmux)" start-server \\; set-option -g mouse on \\; new-session -A -s \(escapedSession); elif [ -x /opt/homebrew/bin/tmux ]; then exec /opt/homebrew/bin/tmux start-server \\; set-option -g mouse on \\; new-session -A -s \(escapedSession); elif [ -x /usr/local/bin/tmux ]; then exec /usr/local/bin/tmux start-server \\; set-option -g mouse on \\; new-session -A -s \(escapedSession); else echo "tmux not found in PATH=$PATH" >&2; exit 127; fi
        """

        // SSH exec requests are parsed by the account shell on many hosts. Wrap
        // the POSIX tmux bootstrap in /bin/sh so fish logins do not choke on it.
        return "/bin/sh -lc \(shellSingleQuote(script))"
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}

nonisolated private final class SSHSessionChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let initialSize: (cols: Int, rows: Int, pixelSize: CGSize)
    private let launchMode: SSHLaunchMode
    private let onReady: () -> Void
    private let onData: (Data) -> Void
    private let onExitStatus: (Int32) -> Void
    private let onDisconnect: (Error?) -> Void

    init(
        initialSize: (cols: Int, rows: Int, pixelSize: CGSize),
        launchMode: SSHLaunchMode,
        onReady: @escaping () -> Void,
        onData: @escaping (Data) -> Void,
        onExitStatus: @escaping (Int32) -> Void,
        onDisconnect: @escaping (Error?) -> Void
    ) {
        self.initialSize = initialSize
        self.launchMode = launchMode
        self.onReady = onReady
        self.onData = onData
        self.onExitStatus = onExitStatus
        self.onDisconnect = onDisconnect
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let setOption = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        setOption.whenFailure { [weak self] error in
            self?.onDisconnect(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false,
            term: "xterm-256color",
            terminalCharacterWidth: initialSize.cols,
            terminalRowHeight: initialSize.rows,
            terminalPixelWidth: Int(initialSize.pixelSize.width.rounded()),
            terminalPixelHeight: Int(initialSize.pixelSize.height.rounded()),
            terminalModes: .init([:])
        )
        let environment = SSHChannelRequestEvent.EnvironmentRequest(
            wantReply: false,
            name: "TERM",
            value: "xterm-256color"
        )
        context.triggerUserOutboundEvent(pty, promise: nil)
        context.triggerUserOutboundEvent(environment, promise: nil)
        switch launchMode {
        case .shell:
            context.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ShellRequest(wantReply: false),
                promise: nil
            )
        case .tmux(let sessionName):
            context.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(
                    command: SSHLaunchMode.tmuxCommand(sessionName: sessionName),
                    wantReply: false
                ),
                promise: nil
            )
        }
        onReady()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = message.data else {
            return
        }

        let payload = Data(bytes.readableBytesView)
        switch message.type {
        case .channel, .stdErr:
            onData(payload)
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            onExitStatus(Int32(status.exitStatus))
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(
            wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
            promise: promise
        )
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onDisconnect(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        onDisconnect(nil)
        context.fireChannelInactive()
    }
}
