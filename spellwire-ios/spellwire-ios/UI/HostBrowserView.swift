import Foundation
import Observation
import SafariServices
import SwiftUI

@MainActor
@Observable
final class HostBrowserCoordinator {
    enum State: Equatable {
        case idle
        case preparing
        case tunnelReady
        case connected
        case failed(String)

        var title: String {
            switch self {
            case .idle:
                return "Idle"
            case .preparing:
                return "Preparing"
            case .tunnelReady:
                return "Tunnel Ready"
            case .connected:
                return "Connected"
            case .failed(let message):
                return message
            }
        }
    }

    let host: HostRecord
    let identity: SSHDeviceIdentity
    let trustStore: HostTrustStore
    let defaultScheme: String

    var state: State = .idle
    var requestedURL: URL?
    var pendingHostKeyChallenge: HostKeyChallenge?

    private var portForwardService: LocalPortForwardService?
    private var pendingTrustReply: ((Bool) -> Void)?
    private var initialLoadTask: Task<Void, Never>?

    init(host: HostRecord, identity: SSHDeviceIdentity, trustStore: HostTrustStore, defaultScheme: String) {
        self.host = host
        self.identity = identity
        self.trustStore = trustStore
        self.defaultScheme = defaultScheme
    }

    func startIfNeeded() {
        guard initialLoadTask == nil else { return }
        initialLoadTask = Task { [weak self] in
            await self?.prepareInitialURL()
        }
    }

    func stop() {
        initialLoadTask?.cancel()
        initialLoadTask = nil
        requestedURL = nil
        pendingHostKeyChallenge = nil
        pendingTrustReply = nil
        state = .idle

        let service = portForwardService
        portForwardService = nil
        Task {
            await service?.stop()
        }
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

    private func prepareInitialURL() async {
        do {
            let remoteURL = try normalizedRemoteURL()
            state = .preparing

            if host.browserUsesTunnel {
                let tunnelTargetPort = host.browserForwardedPort
                guard let tunnelTargetPort else {
                    throw TransportError.connectionFailed("Configure a forwarded port for the SSH tunnel.")
                }

                let portForwardService = LocalPortForwardService(
                    host: host,
                    identity: try identity.clientIdentity(username: host.username),
                    trustedHost: trustStore.trustedHost(for: host.id),
                    onHostKeyChallenge: { [weak self] challenge, reply in
                        guard let self else { return }
                        self.state = .preparing
                        self.pendingHostKeyChallenge = challenge
                        self.pendingTrustReply = reply
                    },
                    onDisconnect: { [weak self] error in
                        guard let self, let error else { return }
                        self.state = .failed(error.localizedDescription)
                    }
                )
                self.portForwardService = portForwardService

                let localPort = try await portForwardService.start(
                    targetHost: "127.0.0.1",
                    targetPort: tunnelTargetPort
                )

                requestedURL = Self.rewriteForLocalTunnel(remoteURL: remoteURL, localPort: localPort)
                state = .tunnelReady
            } else {
                requestedURL = remoteURL
                state = .connected
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func normalizedRemoteURL() throws -> URL {
        if host.browserUsesTunnel {
            guard let port = host.browserForwardedPort else {
                throw TransportError.connectionFailed("Configure a forwarded port for this browser first.")
            }

            guard let url = URL(string: "http://127.0.0.1:\(port)") else {
                throw TransportError.connectionFailed("The forwarded browser port is invalid.")
            }
            return url
        }

        guard let rawURL = host.browserURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty else {
            throw TransportError.connectionFailed("Configure a browser URL for this host first.")
        }

        if let url = URL(string: rawURL), url.scheme != nil {
            return url
        }

        let inferredScheme = host.browserUsesTunnel ? "http" : defaultScheme

        guard let url = URL(string: "\(inferredScheme)://\(rawURL)") else {
            throw TransportError.connectionFailed("The browser URL is invalid.")
        }
        return url
    }

    private static func rewriteForLocalTunnel(remoteURL: URL, localPort: Int) -> URL {
        var components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false)
        components?.host = "127.0.0.1"
        components?.port = localPort
        return components?.url ?? remoteURL
    }
}

struct HostBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator: HostBrowserCoordinator

    init(
        host: HostRecord,
        identity: SSHDeviceIdentity,
        trustStore: HostTrustStore,
        defaultScheme: String
    ) {
        _coordinator = State(
            initialValue: HostBrowserCoordinator(
                host: host,
                identity: identity,
                trustStore: trustStore,
                defaultScheme: defaultScheme
            )
        )
    }

    var body: some View {
        browserContent
        .toolbar(.hidden, for: .navigationBar)
        .task {
            coordinator.startIfNeeded()
        }
        .alert(
            "Trust Host Key",
            isPresented: Binding(
                get: { coordinator.pendingHostKeyChallenge != nil },
                set: { if !$0 { coordinator.resolveHostKeyChallenge(approved: false) } }
            ),
            presenting: coordinator.pendingHostKeyChallenge
        ) { _ in
            Button("Reject", role: .cancel) {
                coordinator.resolveHostKeyChallenge(approved: false)
            }
            Button("Trust") {
                coordinator.resolveHostKeyChallenge(approved: true)
            }
        } message: { challenge in
            Text("\(challenge.hostLabel)\n\(challenge.fingerprint)")
        }
        .onDisappear {
            coordinator.stop()
        }
    }

    @ViewBuilder
    private var browserContent: some View {
        switch coordinator.state {
        case .failed(let message):
            ContentUnavailableView(
                "Couldn’t Open Browser",
                systemImage: "globe.badge.chevron.backward",
                description: Text(message)
            )
            .padding(.horizontal, 24)
        default:
            if let url = coordinator.requestedURL {
                SafariBrowserView(url: url) {
                    dismiss()
                }
                    .ignoresSafeArea()
            } else {
                ProgressView("Preparing Browser…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct SafariBrowserView: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onFinish()
        }
    }
}
