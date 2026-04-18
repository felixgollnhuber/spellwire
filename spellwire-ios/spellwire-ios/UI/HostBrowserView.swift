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

    var state: State = .idle
    var pageTitle = ""
    var displayURL: URL?
    var requestedURL: URL?
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var pendingHostKeyChallenge: HostKeyChallenge?

    fileprivate var reloadToken = 0
    fileprivate var allowsLoopbackCertificateBypass = false

    private var portForwardService: LocalPortForwardService?
    private var pendingTrustReply: ((Bool) -> Void)?
    private var initialLoadTask: Task<Void, Never>?
    private var webViewBack: (() -> Void)?
    private var webViewForward: (() -> Void)?
    private var webViewReload: (() -> Void)?

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

        let service = portForwardService
        portForwardService = nil
        Task {
            await service?.stop()
        }
    }

    func reconnect() {
        stop()
        requestedURL = nil
        displayURL = nil
        pageTitle = ""
        isLoading = false
        canGoBack = false
        canGoForward = false
        state = .idle
        pendingHostKeyChallenge = nil
        pendingTrustReply = nil
        reloadToken = 0
        startIfNeeded()
    }

    func reload() {
        reloadToken &+= 1
        webViewReload?()
    }

    func goBack() {
        webViewBack?()
    }

    func goForward() {
        webViewForward?()
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

    fileprivate func installWebViewActions(
        back: @escaping () -> Void,
        forward: @escaping () -> Void,
        reload: @escaping () -> Void
    ) {
        webViewBack = back
        webViewForward = forward
        webViewReload = reload
    }

    fileprivate func updateNavigationState(
        currentURL: URL?,
        title: String,
        isLoading: Bool,
        canGoBack: Bool,
        canGoForward: Bool
    ) {
        if let currentURL {
            displayURL = currentURL
        }
        pageTitle = title
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward

        if case .failed = state {
            return
        }

        state = host.browserUsesTunnel ? .tunnelReady : .connected
    }

    fileprivate func handleWebError(_ error: Error) {
        if Self.shouldIgnoreWebError(error) {
            return
        }
        state = .failed(error.localizedDescription)
    }

    fileprivate func shouldAcceptServerTrust(host: String) -> Bool {
        allowsLoopbackCertificateBypass && (host == "127.0.0.1" || host == "localhost")
    }

    private func prepareInitialURL() async {
        do {
            let remoteURL = try normalizedRemoteURL()
            displayURL = remoteURL
            state = .preparing

            if host.browserUsesTunnel {
                let tunnelTargetPort = remoteURL.port ?? Self.defaultPort(for: remoteURL.scheme)
                guard let tunnelTargetHost = remoteURL.host, let tunnelTargetPort else {
                    throw TransportError.connectionFailed("Browser URL must include a host and port or scheme.")
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
                    targetHost: tunnelTargetHost,
                    targetPort: tunnelTargetPort
                )

                requestedURL = Self.rewriteForLocalTunnel(remoteURL: remoteURL, localPort: localPort)
                allowsLoopbackCertificateBypass = remoteURL.scheme?.lowercased() == "https"
                state = .tunnelReady
            } else {
                requestedURL = remoteURL
                allowsLoopbackCertificateBypass = false
                state = .connected
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func normalizedRemoteURL() throws -> URL {
        guard let rawURL = host.browserURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty else {
            throw TransportError.connectionFailed("Configure a browser URL for this host first.")
        }

        if let url = URL(string: rawURL), url.scheme != nil {
            return url
        }

        guard let url = URL(string: "\(defaultScheme)://\(rawURL)") else {
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

    private static func defaultPort(for scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
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

    init(host: HostRecord, identity: SSHDeviceIdentity, trustStore: HostTrustStore, defaultScheme: String) {
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
        VStack(spacing: 0) {
            statusBar
            addressBar
            BrowserWebView(coordinator: coordinator)
                .background(Color(uiColor: .systemBackground))
        }
        .navigationTitle(coordinator.host.nickname)
        .navigationBarTitleDisplayMode(.inline)
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

    private var statusBar: some View {
        HStack(spacing: 12) {
            Label(
                coordinator.state.title,
                systemImage: coordinator.state == .failed(coordinator.state.title) ? "exclamationmark.triangle.fill" : "globe"
            )
            .font(.caption.weight(.semibold))
            Spacer()
            Button(action: coordinator.goBack) {
                Image(systemName: "chevron.backward")
            }
            .disabled(!coordinator.canGoBack)

            Button(action: coordinator.goForward) {
                Image(systemName: "chevron.forward")
            }
            .disabled(!coordinator.canGoForward)

            Button(coordinator.isLoading ? "Reloading" : "Reload") {
                coordinator.reload()
            }
            .disabled(coordinator.requestedURL == nil)

            Button("Reconnect") {
                coordinator.reconnect()
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var addressBar: some View {
        Text(coordinator.displayURL?.absoluteString ?? coordinator.host.browserURLString ?? "No URL configured")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(uiColor: .tertiarySystemBackground))
    }
}

private struct BrowserWebView: UIViewRepresentable {
    let coordinator: HostBrowserCoordinator

    func makeCoordinator() -> BrowserWebViewCoordinator {
        BrowserWebViewCoordinator(owner: coordinator)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .interactive

        coordinator.installWebViewActions(
            back: { [weak webView] in webView?.goBack() },
            forward: { [weak webView] in webView?.goForward() },
            reload: { [weak webView] in webView?.reload() }
        )

        if let url = coordinator.requestedURL {
            context.coordinator.lastRequestedURL = url
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.owner = coordinator

        if let url = coordinator.requestedURL,
           context.coordinator.lastRequestedURL != url {
            context.coordinator.lastRequestedURL = url
            webView.load(URLRequest(url: url))
        }

        if context.coordinator.lastReloadToken != coordinator.reloadToken {
            context.coordinator.lastReloadToken = coordinator.reloadToken
            if webView.url == nil, let url = coordinator.requestedURL {
                context.coordinator.lastRequestedURL = url
                webView.load(URLRequest(url: url))
            } else {
                webView.reload()
            }
        }
    }
}

private final class BrowserWebViewCoordinator: NSObject, WKNavigationDelegate {
    var owner: HostBrowserCoordinator
    var lastRequestedURL: URL?
    var lastReloadToken = 0

    init(owner: HostBrowserCoordinator) {
        self.owner = owner
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        owner.updateNavigationState(
            currentURL: webView.url,
            title: webView.title ?? "",
            isLoading: true,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner.updateNavigationState(
            currentURL: webView.url,
            title: webView.title ?? "",
            isLoading: false,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward
        )
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        owner.handleWebError(TransportError.connectionFailed("The embedded browser process exited."))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        owner.updateNavigationState(
            currentURL: webView.url,
            title: webView.title ?? "",
            isLoading: false,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward
        )
        owner.handleWebError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        owner.updateNavigationState(
            currentURL: webView.url,
            title: webView.title ?? "",
            isLoading: false,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward
        )
        owner.handleWebError(error)
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              owner.shouldAcceptServerTrust(host: challenge.protectionSpace.host),
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
