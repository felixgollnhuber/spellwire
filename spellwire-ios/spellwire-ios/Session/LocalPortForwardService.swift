import Dispatch
import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSH

nonisolated final class LocalPortForwardService: @unchecked Sendable {
    private let host: HostRecord
    private let password: String
    private let trustedHost: TrustedHost?
    private let onHostKeyChallenge: HostKeyChallengeHandler
    private let onDisconnect: @MainActor (Error?) -> Void

    private let workQueue = DispatchQueue(label: "xyz.floritzmaier.spellwire-ios.port-forward")
    private var group: MultiThreadedEventLoopGroup?
    private var rootChannel: Channel?
    private var serverChannel: Channel?
    private var sshHandler: NIOSSHHandler?
    private var targetHost: String?
    private var targetPort: Int?
    private var localPort: Int?
    private var startContinuations: [CheckedContinuation<Int, Error>] = []
    private var isStarting = false
    private var isStopping = false

    init(
        host: HostRecord,
        password: String,
        trustedHost: TrustedHost?,
        onHostKeyChallenge: @escaping HostKeyChallengeHandler,
        onDisconnect: @escaping @MainActor (Error?) -> Void
    ) {
        self.host = host
        self.password = password
        self.trustedHost = trustedHost
        self.onHostKeyChallenge = onHostKeyChallenge
        self.onDisconnect = onDisconnect
    }

    func start(targetHost: String, targetPort: Int) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                if self.targetHost == targetHost,
                   self.targetPort == targetPort,
                   let localPort = self.localPort {
                    continuation.resume(returning: localPort)
                    return
                }

                self.startContinuations.append(continuation)
                guard !self.isStarting else { return }
                self.isStarting = true
                self.isStopping = false
                self.targetHost = targetHost
                self.targetPort = targetPort
                self.startSync()
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            workQueue.async {
                self.isStopping = true
                self.closeConnection(error: nil, completion: {
                    continuation.resume()
                })
            }
        }
    }

    private func startSync() {
        guard !password.isEmpty else {
            finishStart(result: .failure(TransportError.missingPassword))
            return
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        do {
            let hostKeyDelegate = AppHostKeyValidationDelegate(
                host: host,
                trustedHost: trustedHost,
                onHostKeyChallenge: onHostKeyChallenge
            )
            let sshHandlerBox = PortForwardSSHHandlerBox()

            let bootstrap = ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let sshHandler = NIOSSHHandler(
                            role: .client(
                                .init(
                                    userAuthDelegate: PortForwardPasswordDelegate(
                                        username: self.host.username,
                                        password: self.password
                                    ),
                                    serverAuthDelegate: hostKeyDelegate
                                )
                            ),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                        sshHandlerBox.handler = sshHandler
                        try channel.pipeline.syncOperations.addHandlers([
                            sshHandler,
                            PortForwardRootErrorHandler { [weak self] error in
                                self?.requestClose(error: error)
                            },
                        ])
                    }
                }
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

            let rootChannel = try bootstrap.connect(host: host.hostname, port: host.port).wait()
            self.rootChannel = rootChannel
            rootChannel.closeFuture.whenComplete { [weak self] result in
                switch result {
                case .success:
                    self?.requestClose(error: nil)
                case .failure(let error):
                    self?.requestClose(error: error)
                }
            }

            guard let sshHandler = sshHandlerBox.handler else {
                throw TransportError.connectionFailed("SSH handler was not installed.")
            }
            self.sshHandler = sshHandler

            let serverBootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { [weak self] inboundChannel in
                    guard let self else {
                        return inboundChannel.eventLoop.makeFailedFuture(
                            TransportError.connectionFailed("Port forward service was released.")
                        )
                    }
                    return self.attachForwardingChannel(for: inboundChannel)
                }

            let serverChannel = try serverBootstrap.bind(host: "127.0.0.1", port: 0).wait()
            self.serverChannel = serverChannel
            self.localPort = serverChannel.localAddress?.port

            guard let localPort else {
                throw TransportError.connectionFailed("The local port forward did not bind to a port.")
            }

            isStarting = false
            finishStart(result: .success(localPort))
        } catch {
            closeConnection(error: error)
        }
    }

    private func attachForwardingChannel(for inboundChannel: Channel) -> EventLoopFuture<Void> {
        guard let sshHandler,
              let targetHost,
              let targetPort else {
            return inboundChannel.eventLoop.makeFailedFuture(
                TransportError.connectionFailed("The SSH port forward is not ready.")
            )
        }

        let promise = inboundChannel.eventLoop.makePromise(of: Channel.self)
        let originatorAddress = inboundChannel.remoteAddress ?? LocalPortForwardService.loopbackOriginatorAddress()

        sshHandler.createChannel(
            promise,
            channelType: .directTCPIP(
                .init(
                    targetHost: targetHost,
                    targetPort: targetPort,
                    originatorAddress: originatorAddress
                )
            )
        ) { childChannel, channelType in
            guard case .directTCPIP = channelType else {
                return childChannel.eventLoop.makeFailedFuture(TransportError.invalidChannelType)
            }

            let (ours, theirs) = PortForwardGlueHandler.matchedPair()
            return childChannel.pipeline.addHandlers([
                SSHPortForwardWrapperHandler(),
                ours,
                PortForwardChildErrorHandler(),
            ]).flatMap {
                inboundChannel.pipeline.addHandlers([
                    theirs,
                    PortForwardChildErrorHandler(),
                ])
            }
        }

        return promise.futureResult.map { _ in }
    }

    private func requestClose(error: Error?) {
        workQueue.async {
            self.closeConnection(error: error)
        }
    }

    private func closeConnection(error: Error?, completion: (() -> Void)? = nil) {
        let shouldNotify = error != nil && !isStopping
        let failure = error ?? TransportError.connectionFailed("The SSH tunnel closed.")

        if let serverChannel {
            self.serverChannel = nil
            serverChannel.eventLoop.execute {
                serverChannel.close(promise: nil)
            }
        }

        if let rootChannel {
            self.rootChannel = nil
            rootChannel.eventLoop.execute {
                rootChannel.close(promise: nil)
            }
        }

        sshHandler = nil
        localPort = nil
        targetHost = nil
        targetPort = nil

        let pendingContinuations = startContinuations
        startContinuations.removeAll()
        isStarting = false

        if !pendingContinuations.isEmpty {
            for continuation in pendingContinuations {
                continuation.resume(throwing: failure)
            }
        }

        let group = self.group
        self.group = nil

        let finish = {
            if shouldNotify {
                Task { @MainActor in
                    self.onDisconnect(error)
                }
            }
            completion?()
        }

        guard let group else {
            finish()
            return
        }

        group.shutdownGracefully(queue: workQueue) { _ in
            finish()
        }
    }

    private func finishStart(result: Result<Int, Error>) {
        let continuations = startContinuations
        startContinuations.removeAll()
        for continuation in continuations {
            switch result {
            case .success(let port):
                continuation.resume(returning: port)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private static func loopbackOriginatorAddress() -> SocketAddress {
        try! SocketAddress(ipAddress: "127.0.0.1", port: 0)
    }
}

nonisolated private final class PortForwardSSHHandlerBox: @unchecked Sendable {
    var handler: NIOSSHHandler?
}

nonisolated private struct PortForwardPasswordDelegate: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let password: String

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if availableMethods.contains(.password) {
            nextChallengePromise.succeed(
                .init(
                    username: username,
                    serviceName: "ssh-connection",
                    offer: .password(.init(password: password))
                )
            )
        } else {
            nextChallengePromise.fail(TransportError.connectionFailed("The SSH server did not accept password auth."))
        }
    }
}

nonisolated private final class PortForwardRootErrorHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private let onError: (Error?) -> Void

    init(onError: @escaping (Error?) -> Void) {
        self.onError = onError
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error)
        context.close(promise: nil)
    }
}

nonisolated private final class PortForwardChildErrorHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

nonisolated private final class SSHPortForwardWrapperHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .channel = message.type, case .byteBuffer(let buffer) = message.data else {
            return
        }

        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(
            wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
            promise: promise
        )
    }
}

nonisolated private final class PortForwardGlueHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: PortForwardGlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    static func matchedPair() -> (PortForwardGlueHandler, PortForwardGlueHandler) {
        let first = PortForwardGlueHandler()
        let second = PortForwardGlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerClose()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.partnerWriteEOF()
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.partnerClose()
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if partner?.isWritable ?? false {
            context.read()
        } else {
            pendingRead = true
        }
    }

    private var isWritable: Bool {
        context?.channel.isWritable ?? false
    }

    private func partnerWrite(_ data: NIOAny) {
        context?.write(data, promise: nil)
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerWriteEOF() {
        context?.close(mode: .output, promise: nil)
    }

    private func partnerClose() {
        context?.close(promise: nil)
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }
}
