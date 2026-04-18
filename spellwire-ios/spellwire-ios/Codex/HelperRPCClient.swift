import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSH

@MainActor
protocol HelperRPCTransportDelegate: AnyObject {
    func transportDidConnect()
    func transportDidReceive(data: Data)
    func transportDidDisconnect(error: Error?)
}

nonisolated private final class SSHExecTransport: @unchecked Sendable {
    weak var delegate: HelperRPCTransportDelegate?

    private let host: HostRecord
    private let identity: SSHClientIdentity
    private let trustedHost: TrustedHost?
    private let command: String
    private let onHostKeyChallenge: @MainActor (HostKeyChallenge, @escaping (Bool) -> Void) -> Void

    private let workQueue = DispatchQueue(label: "xyz.floritzmaier.spellwire-ios.codex.rpc")
    private var group: MultiThreadedEventLoopGroup?
    private var rootChannel: Channel?
    private var childChannel: Channel?
    private var isDisconnectRequested = false
    private var didNotifyDisconnect = false

    init(
        host: HostRecord,
        identity: SSHClientIdentity,
        trustedHost: TrustedHost?,
        command: String,
        onHostKeyChallenge: @escaping @MainActor (HostKeyChallenge, @escaping (Bool) -> Void) -> Void
    ) {
        self.host = host
        self.identity = identity
        self.trustedHost = trustedHost
        self.command = command
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
                        TransportError.connectionFailed("RPC transport was released during setup.")
                    )
                }

                guard channelType == .session else {
                    return childChannel.eventLoop.makeFailedFuture(TransportError.invalidChannelType)
                }

                return childChannel.eventLoop.makeCompletedFuture {
                    try childChannel.pipeline.syncOperations.addHandler(
                        SSHExecChannelHandler(
                            command: self.command,
                            onReady: { [weak self] in
                                self?.notifyConnected()
                            },
                            onData: { [weak self] data in
                                self?.notifyReceive(data)
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

    private func notifyDisconnect(error: Error?) {
        guard !didNotifyDisconnect else { return }
        didNotifyDisconnect = true
        DispatchQueue.main.async {
            self.delegate?.transportDidDisconnect(error: self.isDisconnectRequested ? nil : error)
        }
    }
}

nonisolated private final class SSHExecChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let onReady: () -> Void
    private let onData: (Data) -> Void
    private let onDisconnect: (Error?) -> Void

    init(
        command: String,
        onReady: @escaping () -> Void,
        onData: @escaping (Data) -> Void,
        onDisconnect: @escaping (Error?) -> Void
    ) {
        self.command = command
        self.onReady = onReady
        self.onData = onData
        self.onDisconnect = onDisconnect
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false),
            promise: nil
        )
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

@MainActor
final class HelperRPCClient: HelperRPCTransportDelegate {
    private struct OutgoingEnvelope<Params: Encodable>: Encodable {
        let kind = "request"
        let id: String
        let method: String
        let params: Params
    }

    private struct BaseEnvelope: Decodable {
        let kind: String
        let id: String?
        let ok: Bool?
    }

    private struct SuccessEnvelope<Result: Decodable>: Decodable {
        let kind: String
        let id: String
        let ok: Bool
        let result: Result
    }

    private struct FailureEnvelope: Decodable {
        let kind: String
        let id: String
        let ok: Bool
        let error: HelperResponseErrorPayload
    }

    private let host: HostRecord
    private let identity: SSHDeviceIdentity
    private var trustedHost: TrustedHost?
    private let onHostKeyChallenge: @MainActor (HostKeyChallenge, @escaping (Bool) -> Void) -> Void
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var transport: SSHExecTransport?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var pendingResponses: [String: CheckedContinuation<Data, Error>] = [:]
    private var receiveBuffer = Data()

    var eventHandler: ((HelperEventEnvelope) -> Void)?

    init(
        host: HostRecord,
        identity: SSHDeviceIdentity,
        trustedHost: TrustedHost?,
        onHostKeyChallenge: @escaping @MainActor (HostKeyChallenge, @escaping (Bool) -> Void) -> Void
    ) {
        self.host = host
        self.identity = identity
        self.trustedHost = trustedHost
        self.onHostKeyChallenge = onHostKeyChallenge
    }

    func updateTrustedHost(_ trustedHost: TrustedHost?) {
        self.trustedHost = trustedHost
    }

    func connect() async throws {
        if transport != nil {
            return
        }

        let transport = SSHExecTransport(
            host: host,
            identity: try identity.clientIdentity(username: host.username),
            trustedHost: trustedHost,
            command: "spellwire rpc",
            onHostKeyChallenge: onHostKeyChallenge
        )
        transport.delegate = self
        self.transport = transport

        try await withCheckedThrowingContinuation { continuation in
            connectContinuation = continuation
            transport.connect()
        }
    }

    func disconnect() {
        transport?.disconnect()
        transport = nil
    }

    func request<Result: Decodable, Params: Encodable>(method: String, params: Params) async throws -> Result {
        try await connect()
        let id = UUID().uuidString
        let requestData = try encoder.encode(
            OutgoingEnvelope(id: id, method: method, params: params)
        ) + Data([0x0A])

        let responseData = try await withCheckedThrowingContinuation { continuation in
            pendingResponses[id] = continuation
            transport?.send(requestData)
        }

        if let failure = try? decoder.decode(FailureEnvelope.self, from: responseData), failure.ok == false {
            throw failure.error
        }

        let success = try decoder.decode(SuccessEnvelope<Result>.self, from: responseData)
        return success.result
    }

    func transportDidConnect() {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func transportDidReceive(data: Data) {
        receiveBuffer.append(data)

        while let newlineIndex = receiveBuffer.firstIndex(of: 0x0A) {
            let line = receiveBuffer[..<newlineIndex]
            receiveBuffer.removeSubrange(...newlineIndex)
            guard !line.isEmpty else { continue }
            handleLine(Data(line))
        }
    }

    func transportDidDisconnect(error: Error?) {
        let disconnectError = error ?? TransportError.connectionFailed("The helper RPC connection closed.")
        connectContinuation?.resume(throwing: disconnectError)
        connectContinuation = nil
        let continuations = pendingResponses.values
        pendingResponses.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: disconnectError)
        }
        transport = nil
    }

    private func handleLine(_ line: Data) {
        guard let envelope = try? decoder.decode(BaseEnvelope.self, from: line) else {
            return
        }

        switch envelope.kind {
        case "response":
            guard let id = envelope.id, let continuation = pendingResponses.removeValue(forKey: id) else {
                return
            }
            continuation.resume(returning: line)
        case "event":
            guard let event = try? decoder.decode(HelperEventEnvelope.self, from: line) else {
                return
            }
            eventHandler?(event)
        default:
            break
        }
    }
}
