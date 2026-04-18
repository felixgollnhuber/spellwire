import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSH

nonisolated final class SFTPRemoteFileSystem: RemoteFileSystem, @unchecked Sendable {
    private let host: HostRecord
    private let password: String
    private let trustedHost: TrustedHost?
    private let onHostKeyChallenge: HostKeyChallengeHandler

    private let workQueue = DispatchQueue(label: "xyz.floritzmaier.spellwire-ios.sftp")
    private var group: MultiThreadedEventLoopGroup?
    private var rootChannel: Channel?
    private var sftpChannel: Channel?
    private var connectContinuations: [CheckedContinuation<Void, Error>] = []
    private var versionContinuation: CheckedContinuation<Void, Error>?
    private var pendingRequests: [UInt32: CheckedContinuation<SFTPResponse, Error>] = [:]
    private var nextRequestID: UInt32 = 1
    private var isConnecting = false
    private var isReady = false
    private var supportedExtensions: Set<String> = []
    private var cachedHomePath: String?

    init(
        host: HostRecord,
        password: String,
        trustedHost: TrustedHost?,
        onHostKeyChallenge: @escaping HostKeyChallengeHandler
    ) {
        self.host = host
        self.password = password
        self.trustedHost = trustedHost
        self.onHostKeyChallenge = onHostKeyChallenge
    }

    func homePath() async throws -> String {
        if let cachedHomePath {
            return cachedHomePath
        }

        let home = try await realPath(".")
        cachedHomePath = home
        return home
    }

    func canonicalize(path: String) async throws -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPath.isEmpty || trimmedPath == "." {
            return try await homePath()
        }

        if trimmedPath == "~" {
            return try await homePath()
        }

        if trimmedPath.hasPrefix("~/") {
            let home = try await homePath()
            return joinPath(parent: home, child: String(trimmedPath.dropFirst(2)))
        }

        return try await realPath(trimmedPath)
    }

    func list(path: String) async throws -> [RemoteItem] {
        let resolvedPath = try await canonicalize(path: path)
        let handle = try await openDirectory(path: resolvedPath)
        defer { Task { try? await self.closeHandle(handle) } }

        var items: [RemoteItem] = []
        while true {
            let response = try await sendRequest(.readDirectory) { buffer, requestID in
                buffer.writeInteger(requestID)
                buffer.writeSSHString(handle)
            }

            switch response {
            case .name(_, let entries):
                let mapped = entries
                    .filter { $0.filename != "." && $0.filename != ".." }
                    .map {
                        RemoteItem(
                            path: joinPath(parent: resolvedPath, child: $0.filename),
                            name: $0.filename,
                            metadata: $0.attributes.remoteMetadata
                        )
                }
                items.append(contentsOf: mapped)
            case .status(_, let code, _) where code == .eof:
                return items
            case .status:
                try response.throwIfError()
            default:
                throw RemoteFileError.protocolViolation("Unexpected SFTP response while listing directory.")
            }
        }
    }

    func stat(path: String) async throws -> RemoteMetadata {
        let resolvedPath = try await canonicalize(path: path)
        let response = try await sendRequest(.stat) { buffer, requestID in
            buffer.writeInteger(requestID)
            buffer.writeSSHString(resolvedPath)
        }

        switch response {
        case .attributes(_, let attributes):
            return attributes.remoteMetadata
        case .status(_, let code, _) where code == .noSuchFile:
            throw RemoteFileError.noSuchFile(resolvedPath)
        case .status:
            try response.throwIfError()
            throw RemoteFileError.protocolViolation("Unexpected empty SFTP stat response.")
        default:
            throw RemoteFileError.protocolViolation("Unexpected SFTP response while statting a path.")
        }
    }

    func readFile(path: String) async throws -> Data {
        let resolvedPath = try await canonicalize(path: path)
        let handle = try await openFile(path: resolvedPath, flags: [.read])
        defer { Task { try? await self.closeHandle(handle) } }

        var offset: UInt64 = 0
        var payload = Data()

        while true {
            let response = try await sendRequest(.read) { buffer, requestID in
                buffer.writeInteger(requestID)
                buffer.writeSSHString(handle)
                buffer.writeInteger(offset)
                buffer.writeInteger(UInt32(32 * 1024))
            }

            switch response {
            case .data(_, let chunk):
                payload.append(chunk)
                offset += UInt64(chunk.count)
            case .status(_, let code, _) where code == .eof:
                return payload
            case .status:
                try response.throwIfError()
            default:
                throw RemoteFileError.protocolViolation("Unexpected SFTP response while reading a file.")
            }
        }
    }

    func writeFile(path: String, data: Data, expectedRevision: RemoteRevision?) async throws {
        _ = expectedRevision

        let resolvedPath = try await canonicalize(path: path)
        let directory = URL(filePath: resolvedPath).deletingLastPathComponent().path(percentEncoded: false)
        let tempPath = joinPath(parent: directory, child: ".spellwire-\(UUID().uuidString).tmp")
        let handle = try await openFile(path: tempPath, flags: [.write, .create, .truncate])

        do {
            var offset = 0
            while offset < data.count {
                let end = min(offset + 32 * 1024, data.count)
                let chunk = data[offset..<end]
                try await sendRequest(.write) { buffer, requestID in
                    buffer.writeInteger(requestID)
                    buffer.writeSSHString(handle)
                    buffer.writeInteger(UInt64(offset))
                    buffer.writeSSHData(Data(chunk))
                }.throwIfError()
                offset = end
            }
        } catch {
            try? await closeHandle(handle)
            try? await deleteTemporary(path: tempPath)
            throw error
        }

        try await closeHandle(handle)
        do {
            try await renameTemporary(from: tempPath, to: resolvedPath)
        } catch {
            try? await deleteTemporary(path: tempPath)
            throw error
        }
    }

    func createDirectory(path: String) async throws {
        let parentDirectory = URL(filePath: path).deletingLastPathComponent().path(percentEncoded: false)
        let resolvedParent = try await canonicalize(path: parentDirectory)
        let targetPath = joinPath(parent: resolvedParent, child: URL(filePath: path).lastPathComponent)
        try await sendRequest(.makeDirectory) { buffer, requestID in
            buffer.writeInteger(requestID)
            buffer.writeSSHString(targetPath)
            buffer.writeSFTPAttributes(.empty)
        }.throwIfError()
    }

    func rename(from: String, to: String) async throws {
        let resolvedFrom = try await canonicalize(path: from)
        let targetParent = URL(filePath: to).deletingLastPathComponent().path(percentEncoded: false)
        let resolvedParent = try await canonicalize(path: targetParent)
        let resolvedTo = joinPath(parent: resolvedParent, child: URL(filePath: to).lastPathComponent)
        try await renameTemporary(from: resolvedFrom, to: resolvedTo)
    }

    func delete(path: String) async throws {
        let metadata = try await stat(path: path)
        let resolvedPath = try await canonicalize(path: path)
        switch metadata.kind {
        case .directory:
            try await sendRequest(.removeDirectory) { buffer, requestID in
                buffer.writeInteger(requestID)
                buffer.writeSSHString(resolvedPath)
            }.throwIfError()
        case .file, .symlink, .unknown:
            try await sendRequest(.remove) { buffer, requestID in
                buffer.writeInteger(requestID)
                buffer.writeSSHString(resolvedPath)
            }.throwIfError()
        }
    }

    func disconnect() async {
        await withCheckedContinuation { continuation in
            workQueue.async {
                self.closeConnection(error: nil)
                continuation.resume()
            }
        }
    }

    private func ensureConnected() async throws {
        if isReady {
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                if self.isReady {
                    continuation.resume()
                    return
                }

                self.connectContinuations.append(continuation)
                guard !self.isConnecting else { return }
                self.isConnecting = true
                self.connectSync()
            }
        }
    }

    private func connectSync() {
        guard !password.isEmpty else {
            finishConnect(result: .failure(RemoteFileError.missingPassword))
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
            let sshHandlerBox = SFTPSSHHandlerBox()

            let bootstrap = ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let sshHandler = NIOSSHHandler(
                            role: .client(
                                .init(
                                    userAuthDelegate: SFTPPasswordDelegate(
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
                        try channel.pipeline.syncOperations.addHandler(sshHandler)
                    }
                }
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

            let rootChannel = try bootstrap.connect(host: host.hostname, port: host.port).wait()
            self.rootChannel = rootChannel

            guard let sshHandler = sshHandlerBox.handler else {
                throw RemoteFileError.serverError("SSH handler was not installed.")
            }

            let sessionPromise = rootChannel.eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(sessionPromise) { [weak self] childChannel, channelType in
                guard let self else {
                    return childChannel.eventLoop.makeFailedFuture(
                        RemoteFileError.serverError("The SFTP connection was released during setup.")
                    )
                }

                guard channelType == .session else {
                    return childChannel.eventLoop.makeFailedFuture(TransportError.invalidChannelType)
                }

                return childChannel.eventLoop.makeCompletedFuture {
                    try childChannel.pipeline.syncOperations.addHandler(
                        SFTPChannelHandler(
                            onReady: { [weak self] in
                                self?.sendInit()
                            },
                            onPacket: { [weak self] packet in
                                self?.handlePacket(packet)
                            },
                            onDisconnect: { [weak self] error in
                                self?.requestDisconnect(error: error)
                            }
                        )
                    )
                }
            }

            sftpChannel = try sessionPromise.futureResult.wait()
            versionContinuation = nil
        } catch {
            closeConnection(error: error)
        }
    }

    private func sendInit() {
        do {
            var packet = ByteBuffer()
            packet.writeInteger(SFTPMessageType.initialize.rawValue)
            packet.writeInteger(UInt32(3))
            try writePacket(packet)
        } catch {
            closeConnection(error: error)
        }
    }

    private func handlePacket(_ packet: Data) {
        workQueue.async {
            do {
                var buffer = ByteBufferAllocator().buffer(capacity: packet.count)
                buffer.writeBytes(packet)
                guard let typeRaw = buffer.readInteger(as: UInt8.self),
                      let type = SFTPMessageType(rawValue: typeRaw) else {
                    throw RemoteFileError.protocolViolation("Received an unknown SFTP packet type.")
                }

                switch type {
                case .version:
                    _ = try self.parseVersion(buffer: &buffer)
                case .status, .handle, .data, .name, .attributes, .extendedReply:
                    let response = try SFTPResponse(type: type, buffer: &buffer)
                    guard let requestID = response.requestID else {
                        throw RemoteFileError.protocolViolation("Received a malformed SFTP response packet.")
                    }
                    guard let continuation = self.pendingRequests.removeValue(forKey: requestID) else { return }
                    continuation.resume(returning: response)
                default:
                    break
                }
            } catch {
                self.closeConnection(error: error)
            }
        }
    }

    private func parseVersion(buffer: inout ByteBuffer) throws -> UInt32 {
        guard let version = buffer.readInteger(as: UInt32.self) else {
            throw RemoteFileError.protocolViolation("Received an invalid SFTP version packet.")
        }

        supportedExtensions = []
        while buffer.readableBytes > 0 {
            guard let name = try buffer.readSSHString() else {
                throw RemoteFileError.protocolViolation("Received invalid SFTP extension metadata.")
            }
            _ = try buffer.readSSHString()
            supportedExtensions.insert(name)
        }

        isReady = true
        isConnecting = false
        versionContinuation?.resume()
        versionContinuation = nil
        finishConnect(result: .success(()))
        return version
    }

    private func sendRequest(
        _ type: SFTPMessageType,
        build: @escaping (inout ByteBuffer, UInt32) throws -> Void
    ) async throws -> SFTPResponse {
        try await ensureConnected()

        return try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                guard self.isReady else {
                    continuation.resume(throwing: RemoteFileError.serverError("SFTP subsystem is not ready."))
                    return
                }

                let requestID = self.nextRequestID
                self.nextRequestID &+= 1
                self.pendingRequests[requestID] = continuation

                do {
                    var packet = ByteBuffer()
                    packet.writeInteger(type.rawValue)
                    try build(&packet, requestID)
                    try self.writePacket(packet)
                } catch {
                    _ = self.pendingRequests.removeValue(forKey: requestID)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func writePacket(_ packet: ByteBuffer) throws {
        guard let sftpChannel else {
            throw RemoteFileError.serverError("SFTP channel is not connected.")
        }

        var frame = ByteBuffer()
        frame.writeInteger(UInt32(packet.readableBytes))
        var payload = packet
        frame.writeBuffer(&payload)
        sftpChannel.writeAndFlush(frame, promise: nil)
    }

    private func requestDisconnect(error: Error?) {
        workQueue.async {
            self.closeConnection(error: error)
        }
    }

    private func closeConnection(error: Error?) {
        let failure = error ?? RemoteFileError.serverError("SFTP connection closed.")

        if let sftpChannel {
            sftpChannel.eventLoop.execute {
                sftpChannel.close(promise: nil)
            }
            self.sftpChannel = nil
        }

        if let rootChannel {
            rootChannel.eventLoop.execute {
                rootChannel.close(promise: nil)
            }
            self.rootChannel = nil
        }

        if let group {
            self.group = nil
            try? group.syncShutdownGracefully()
        }

        isReady = false
        isConnecting = false
        supportedExtensions = []
        cachedHomePath = nil

        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: failure)
        }
        pendingRequests.removeAll()

        if let versionContinuation {
            versionContinuation.resume(throwing: failure)
            self.versionContinuation = nil
        }

        finishConnect(result: .failure(failure))
    }

    private func finishConnect(result: Result<Void, Error>) {
        let continuations = connectContinuations
        connectContinuations.removeAll()
        for continuation in continuations {
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private func openDirectory(path: String) async throws -> Data {
        let response = try await sendRequest(.openDirectory) { buffer, requestID in
            buffer.writeInteger(requestID)
            buffer.writeSSHString(path)
        }
        switch response {
        case .handle(_, let handle):
            return handle
        case .status(_, let code, _) where code == .noSuchFile:
            throw RemoteFileError.noSuchFile(path)
        case .status:
            try response.throwIfError()
            throw RemoteFileError.protocolViolation("Unexpected empty SFTP open-directory response.")
        default:
            throw RemoteFileError.protocolViolation("Unexpected SFTP response while opening a directory.")
        }
    }

    private func openFile(path: String, flags: Set<SFTPOpenFlag>) async throws -> Data {
        let response = try await sendRequest(.open) { buffer, requestID in
            buffer.writeInteger(requestID)
            buffer.writeSSHString(path)
            let rawFlags = flags.reduce(UInt32.zero) { $0 | $1.rawValue }
            buffer.writeInteger(rawFlags)
            buffer.writeSFTPAttributes(.empty)
        }

        switch response {
        case .handle(_, let handle):
            return handle
        case .status(_, let code, _) where code == .noSuchFile:
            throw RemoteFileError.noSuchFile(path)
        case .status:
            try response.throwIfError()
            throw RemoteFileError.protocolViolation("Unexpected empty SFTP open-file response.")
        default:
            throw RemoteFileError.protocolViolation("Unexpected SFTP response while opening a file.")
        }
    }

    private func closeHandle(_ handle: Data) async throws {
        try await sendRequest(.close) { buffer, requestID in
            buffer.writeInteger(requestID)
            buffer.writeSSHString(handle)
        }.throwIfError()
    }

    private func realPath(_ path: String) async throws -> String {
        let response = try await sendRequest(.realPath) { buffer, requestID in
            buffer.writeInteger(requestID)
            buffer.writeSSHString(path)
        }

        switch response {
        case .name(_, let entries):
            guard let first = entries.first else {
                throw RemoteFileError.protocolViolation("The SFTP server returned an empty realpath response.")
            }
            return first.filename
        case .status(_, let code, _) where code == .noSuchFile:
            throw RemoteFileError.noSuchFile(path)
        case .status:
            try response.throwIfError()
            throw RemoteFileError.protocolViolation("Unexpected empty SFTP realpath response.")
        default:
            throw RemoteFileError.protocolViolation("Unexpected SFTP response while resolving a path.")
        }
    }

    private func renameTemporary(from: String, to: String) async throws {
        if supportedExtensions.contains("posix-rename@openssh.com") {
            try await sendRequest(.extended) { buffer, requestID in
                buffer.writeInteger(requestID)
                buffer.writeSSHString("posix-rename@openssh.com")
                buffer.writeSSHString(from)
                buffer.writeSSHString(to)
            }.throwIfError()
            return
        }

        do {
            try await sendRequest(.remove) { buffer, requestID in
                buffer.writeInteger(requestID)
                buffer.writeSSHString(to)
            }.throwIfError()
        } catch RemoteFileError.noSuchFile {
        } catch {
        }

        try await sendRequest(.rename) { buffer, requestID in
            buffer.writeInteger(requestID)
            buffer.writeSSHString(from)
            buffer.writeSSHString(to)
        }.throwIfError()
    }

    private func deleteTemporary(path: String) async throws {
        do {
            try await sendRequest(.remove) { buffer, requestID in
                buffer.writeInteger(requestID)
                buffer.writeSSHString(path)
            }.throwIfError()
        } catch RemoteFileError.noSuchFile {
        }
    }

    private func joinPath(parent: String, child: String) -> String {
        guard !child.isEmpty else { return parent }
        if child.hasPrefix("/") { return child }
        if parent == "/" { return "/" + child }
        return parent + "/" + child
    }
}

nonisolated private enum SFTPMessageType: UInt8 {
    case initialize = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case stat = 17
    case openDirectory = 11
    case readDirectory = 12
    case remove = 13
    case makeDirectory = 14
    case removeDirectory = 15
    case realPath = 16
    case rename = 18
    case extended = 200
    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attributes = 105
    case extendedReply = 201
}

nonisolated private enum SFTPOpenFlag: UInt32 {
    case read = 0x00000001
    case write = 0x00000002
    case create = 0x00000008
    case truncate = 0x00000010
}

nonisolated private enum SFTPStatusCode: UInt32 {
    case ok = 0
    case eof = 1
    case noSuchFile = 2
    case permissionDenied = 3
    case failure = 4
}

nonisolated private struct SFTPAttributes: Sendable {
    static let empty = SFTPAttributes(size: nil, permissions: nil, modifiedAt: nil)

    let size: Int64?
    let permissions: UInt32?
    let modifiedAt: Date?

    var remoteMetadata: RemoteMetadata {
        RemoteMetadata(
            kind: kind,
            size: size,
            modifiedAt: modifiedAt,
            permissions: permissions
        )
    }

    var kind: RemoteItemKind {
        guard let permissions else { return .unknown }
        switch permissions & 0o170000 {
        case 0o040000:
            return .directory
        case 0o120000:
            return .symlink
        case 0o100000:
            return .file
        default:
            return .unknown
        }
    }

    init(size: Int64?, permissions: UInt32?, modifiedAt: Date?) {
        self.size = size
        self.permissions = permissions
        self.modifiedAt = modifiedAt
    }

    init(buffer: inout ByteBuffer) throws {
        guard let flags = buffer.readInteger(as: UInt32.self) else {
            throw RemoteFileError.protocolViolation("Received malformed SFTP attributes.")
        }

        var parsedSize: Int64?
        var parsedPermissions: UInt32?
        var parsedModifiedAt: Date?

        if flags & 0x00000001 != 0 {
            guard let size = buffer.readInteger(as: UInt64.self) else {
                throw RemoteFileError.protocolViolation("Received malformed SFTP file size.")
            }
            parsedSize = Int64(size)
        }

        if flags & 0x00000002 != 0 {
            guard buffer.readInteger(as: UInt32.self) != nil,
                  buffer.readInteger(as: UInt32.self) != nil else {
                throw RemoteFileError.protocolViolation("Received malformed SFTP owner fields.")
            }
        }

        if flags & 0x00000004 != 0 {
            guard let permissions = buffer.readInteger(as: UInt32.self) else {
                throw RemoteFileError.protocolViolation("Received malformed SFTP permission bits.")
            }
            parsedPermissions = permissions
        }

        if flags & 0x00000008 != 0 {
            guard buffer.readInteger(as: UInt32.self) != nil,
                  let modifiedSeconds = buffer.readInteger(as: UInt32.self) else {
                throw RemoteFileError.protocolViolation("Received malformed SFTP modification dates.")
            }
            parsedModifiedAt = Date(timeIntervalSince1970: TimeInterval(modifiedSeconds))
        }

        if flags & 0x80000000 != 0 {
            guard let count = buffer.readInteger(as: UInt32.self) else {
                throw RemoteFileError.protocolViolation("Received malformed SFTP extended attributes.")
            }
            for _ in 0..<count {
                _ = try buffer.readSSHString()
                _ = try buffer.readSSHData()
            }
        }

        size = parsedSize
        permissions = parsedPermissions
        modifiedAt = parsedModifiedAt
    }
}

nonisolated private struct SFTPNameEntry: Sendable {
    let filename: String
    let attributes: SFTPAttributes
}

nonisolated private enum SFTPResponse: Sendable {
    case status(requestID: UInt32, code: SFTPStatusCode, message: String)
    case handle(requestID: UInt32, data: Data)
    case data(requestID: UInt32, data: Data)
    case name(requestID: UInt32, entries: [SFTPNameEntry])
    case attributes(requestID: UInt32, attributes: SFTPAttributes)
    case extendedReply(requestID: UInt32, data: Data)

    var requestID: UInt32? {
        switch self {
        case .status(let requestID, _, _),
             .handle(let requestID, _),
             .data(let requestID, _),
             .name(let requestID, _),
             .attributes(let requestID, _),
             .extendedReply(let requestID, _):
            return requestID
        }
    }

    init(type: SFTPMessageType, buffer: inout ByteBuffer) throws {
        guard let requestID = buffer.readInteger(as: UInt32.self) else {
            throw RemoteFileError.protocolViolation("Received a malformed SFTP response.")
        }

        switch type {
        case .status:
            guard let codeRaw = buffer.readInteger(as: UInt32.self),
                  let message = try buffer.readSSHString() else {
                throw RemoteFileError.protocolViolation("Received a malformed SFTP status response.")
            }
            let code = SFTPStatusCode(rawValue: codeRaw) ?? .failure
            _ = try buffer.readSSHString()
            self = .status(requestID: requestID, code: code, message: message)
        case .handle:
            self = .handle(requestID: requestID, data: try buffer.readSSHData())
        case .data:
            self = .data(requestID: requestID, data: try buffer.readSSHData())
        case .name:
            guard let count = buffer.readInteger(as: UInt32.self) else {
                throw RemoteFileError.protocolViolation("Received a malformed SFTP name response.")
            }
            var entries: [SFTPNameEntry] = []
            entries.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let filename = try buffer.readSSHString() else {
                    throw RemoteFileError.protocolViolation("Received an invalid SFTP filename.")
                }
                _ = try buffer.readSSHString()
                entries.append(SFTPNameEntry(filename: filename, attributes: try SFTPAttributes(buffer: &buffer)))
            }
            self = .name(requestID: requestID, entries: entries)
        case .attributes:
            self = .attributes(requestID: requestID, attributes: try SFTPAttributes(buffer: &buffer))
        case .extendedReply:
            self = .extendedReply(requestID: requestID, data: try buffer.readSSHData())
        default:
            throw RemoteFileError.protocolViolation("Received an unexpected SFTP response packet.")
        }
    }

    func throwIfError() throws {
        if case let .status(_, code, message) = self, code != .ok {
            switch code {
            case .noSuchFile:
                throw RemoteFileError.noSuchFile(message.isEmpty ? "Unknown remote path." : message)
            default:
                throw RemoteFileError.serverError(message.isEmpty ? "Remote operation failed." : message)
            }
        }
    }
}

nonisolated private final class SFTPSSHHandlerBox: @unchecked Sendable {
    var handler: NIOSSHHandler?
}

nonisolated private struct SFTPPasswordDelegate: NIOSSHClientUserAuthenticationDelegate {
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
            nextChallengePromise.succeed(nil)
        }
    }
}

nonisolated private final class SFTPChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private var inboundBuffer = ByteBuffer()
    private let onReady: () -> Void
    private let onPacket: (Data) -> Void
    private let onDisconnect: (Error?) -> Void

    init(
        onReady: @escaping () -> Void,
        onPacket: @escaping (Data) -> Void,
        onDisconnect: @escaping (Error?) -> Void
    ) {
        self.onReady = onReady
        self.onPacket = onPacket
        self.onDisconnect = onDisconnect
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.SubsystemRequest(
                subsystem: "sftp",
                wantReply: false
            ),
            promise: nil
        )
        onReady()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case .byteBuffer(var bytes) = message.data else { return }

        inboundBuffer.writeBuffer(&bytes)
        while let packet = readPacket() {
            onPacket(packet)
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

    private func readPacket() -> Data? {
        guard let length = inboundBuffer.getInteger(at: inboundBuffer.readerIndex, as: UInt32.self) else {
            return nil
        }
        let totalLength = Int(length) + MemoryLayout<UInt32>.size
        guard inboundBuffer.readableBytes >= totalLength else {
            return nil
        }

        _ = inboundBuffer.readInteger(as: UInt32.self)
        guard let bytes = inboundBuffer.readBytes(length: Int(length)) else { return nil }
        return Data(bytes)
    }
}

nonisolated private extension ByteBuffer {
    mutating func writeSSHString(_ string: String) {
        let data = Data(string.utf8)
        writeInteger(UInt32(data.count))
        writeBytes(data)
    }

    mutating func writeSSHString(_ data: Data) {
        writeInteger(UInt32(data.count))
        writeBytes(data)
    }

    mutating func writeSSHData(_ data: Data) {
        writeInteger(UInt32(data.count))
        writeBytes(data)
    }

    mutating func writeSFTPAttributes(_ attributes: SFTPAttributes) {
        if attributes.size == nil && attributes.permissions == nil && attributes.modifiedAt == nil {
            writeInteger(UInt32.zero)
            return
        }

        var flags = UInt32.zero
        if attributes.size != nil { flags |= 0x00000001 }
        if attributes.permissions != nil { flags |= 0x00000004 }
        if attributes.modifiedAt != nil { flags |= 0x00000008 }
        writeInteger(flags)
        if let size = attributes.size {
            writeInteger(UInt64(size))
        }
        if let permissions = attributes.permissions {
            writeInteger(permissions)
        }
        if let modifiedAt = attributes.modifiedAt {
            let timestamp = UInt32(modifiedAt.timeIntervalSince1970)
            writeInteger(timestamp)
            writeInteger(timestamp)
        }
    }

    mutating func readSSHString() throws -> String? {
        let data = try readSSHData()
        return String(data: data, encoding: .utf8)
    }

    mutating func readSSHData() throws -> Data {
        guard let length = readInteger(as: UInt32.self),
              let bytes = readBytes(length: Int(length)) else {
            throw RemoteFileError.protocolViolation("Received a malformed SSH string payload.")
        }
        return Data(bytes)
    }
}
