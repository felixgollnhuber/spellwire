import Foundation
import Observation
import SwiftUI
import WebKit

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
    let page: WebPage

    var state: State = .idle
    var requestedURL: URL?
    var pendingHostKeyChallenge: HostKeyChallenge?

    private var portForwardService: LocalPortForwardService?
    private var pendingTrustReply: ((Bool) -> Void)?
    private var initialLoadTask: Task<Void, Never>?
    private var pageLoadTask: Task<Void, Never>?
    private var lastLoadedURL: URL?

    init(host: HostRecord, identity: SSHDeviceIdentity, trustStore: HostTrustStore, defaultScheme: String) {
        self.host = host
        self.identity = identity
        self.trustStore = trustStore
        self.defaultScheme = defaultScheme

        var configuration = WebPage.Configuration()
        configuration.defaultNavigationPreferences.preferredContentMode = .mobile
        page = WebPage(configuration: configuration)
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
        pageLoadTask?.cancel()
        pageLoadTask = nil
        page.stopLoading()

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

    func loadRequestedURLIfNeeded() async {
        guard let requestedURL, lastLoadedURL != requestedURL else { return }

        pageLoadTask?.cancel()
        lastLoadedURL = requestedURL
        let nextState: State = host.browserUsesTunnel ? .tunnelReady : .connected
        state = nextState

        pageLoadTask = Task { [weak self] in
            guard let self else { return }

            do {
                for try await _ in page.load(requestedURL) {}
                if !Task.isCancelled {
                    state = nextState
                }
            } catch is CancellationError {
                return
            } catch {
                if Self.shouldIgnoreWebError(error) {
                    return
                }
                state = .failed(error.localizedDescription)
            }
        }
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

    private static func shouldIgnoreWebError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }
        if nsError.domain == WKError.errorDomain, nsError.code == 102 {
            return true
        }
        return false
    }
}

struct HostBrowserView: View {
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
        .navigationTitle(coordinator.host.nickname)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            coordinator.startIfNeeded()
        }
        .task(id: coordinator.requestedURL) {
            await coordinator.loadRequestedURLIfNeeded()
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
        if coordinator.requestedURL != nil || coordinator.page.url != nil {
            WebView(coordinator.page)
                .background(Color(uiColor: .systemBackground))
        } else {
            switch coordinator.state {
            case .failed(let message):
            ContentUnavailableView(
                "Couldn’t Open Browser",
                systemImage: "globe.badge.chevron.backward",
                description: Text(message)
            )
            .padding(.horizontal, 24)
            default:
                ProgressView("Preparing Browser…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
