import XCTest
@testable import spellwire_ios

@MainActor
final class HostConnectionProbeTests: XCTestCase {
    func testTrustPromptAndApprovalEmitWarningThenSuccess() {
        let pair = HapticsClient.recording { _ in }
        let probe = HostConnectionProbe(haptics: pair.client)
        let challenge = HostKeyChallenge(
            hostLabel: "Mac mini",
            fingerprint: "SHA256:test",
            openSSHKey: "ssh-ed25519 AAAATEST"
        )

        probe.presentHostKeyChallenge(challenge) { _ in }
        probe.resolveHostKeyChallenge(approved: true)

        XCTAssertEqual(pair.recorder.events, [.warning, .success])
    }

    func testTransportOutcomesEmitSuccessAndError() {
        let pair = HapticsClient.recording { _ in }
        let probe = HostConnectionProbe(haptics: pair.client)

        probe.transportDidConnect()
        probe.transportDidDisconnect(error: TransportError.connectionFailed("Lost"))

        XCTAssertEqual(pair.recorder.events, [.success, .error])
    }
}

@MainActor
final class HelperRPCClientTests: XCTestCase {
    func testConcurrentRequestsShareTheInitialConnectionHandshake() async throws {
        let transport = FakeHelperRPCTransport()
        let client = HelperRPCClient(
            host: HostRecord(nickname: "Mac", hostname: "mac.local", username: "user"),
            transportFactory: { transport }
        )

        async let first: HelperRPCClientTestResponse = client.request(method: "first", params: EmptyParams())
        async let second: HelperRPCClientTestResponse = client.request(method: "second", params: EmptyParams())

        let (firstResponse, secondResponse) = try await (first, second)

        XCTAssertEqual(firstResponse.value, "first")
        XCTAssertEqual(secondResponse.value, "second")
        XCTAssertEqual(transport.connectCalls, 1)
        XCTAssertEqual(Set(transport.receivedMethods), Set(["first", "second"]))
    }

    func testBootstrapScriptSearchesCommonLinuxNodeInstallLocations() {
        let script = HelperRPCClient.helperRPCBootstrapScript()

        XCTAssertTrue(script.contains("$HOME/.nvm/versions/node"))
        XCTAssertTrue(script.contains("$HOME/.volta/bin"))
        XCTAssertTrue(script.contains("$HOME/.asdf/shims"))
        XCTAssertTrue(script.contains("$HOME/.local/share/pnpm"))
        XCTAssertTrue(script.contains("$HOME/.npm-global/bin"))
    }
}

private struct HelperRPCClientTestRequestEnvelope: Decodable {
    let id: String
    let method: String
}

private struct HelperRPCClientTestResponse: Codable, Equatable {
    let value: String
}

private struct HelperRPCClientTestSuccessEnvelope<Result: Encodable>: Encodable {
    let kind = "response"
    let id: String
    let ok = true
    let result: Result
}

private final class FakeHelperRPCTransport: HelperRPCTransport {
    weak var delegate: HelperRPCTransportDelegate?

    private(set) var connectCalls = 0
    private(set) var receivedMethods: [String] = []
    private var isConnected = false

    func connect() {
        connectCalls += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            self.isConnected = true
            self.delegate?.transportDidConnect()
        }
    }

    func send(_ data: Data) {
        guard isConnected else {
            Task { @MainActor [weak self] in
                self?.delegate?.transportDidDisconnect(error: TransportError.connectionFailed("send called before connect"))
            }
            return
        }

        do {
            let request = try JSONDecoder().decode(
                HelperRPCClientTestRequestEnvelope.self,
                from: Data(data.last == 0x0A ? data.dropLast() : data)
            )
            receivedMethods.append(request.method)
            let payload = try JSONEncoder().encode(
                HelperRPCClientTestSuccessEnvelope(
                    id: request.id,
                    result: HelperRPCClientTestResponse(value: request.method)
                )
            ) + Data([0x0A])

            Task { @MainActor [weak self] in
                self?.delegate?.transportDidReceive(data: payload)
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.delegate?.transportDidDisconnect(error: error)
            }
        }
    }

    func disconnect() {
        isConnected = false
        Task { @MainActor [weak self] in
            self?.delegate?.transportDidDisconnect(error: nil)
        }
    }
}
