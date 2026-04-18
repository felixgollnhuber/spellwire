import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOSSH

nonisolated final class SSHHandlerBox: @unchecked Sendable {
    var handler: NIOSSHHandler?
}

nonisolated final class SSHClientPublicKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    private var privateKey: NIOSSHPrivateKey?

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey), let privateKey else {
            nextChallengePromise.succeed(nil)
            return
        }

        self.privateKey = nil
        nextChallengePromise.succeed(
            .init(
                username: username,
                serviceName: "ssh-connection",
                offer: .privateKey(.init(privateKey: privateKey))
            )
        )
    }
}
