import UIKit
import SwiftUI

struct HostEditorDraft: Equatable {
    var nickname = ""
    var hostname = ""
    var port = "22"
    var username = ""
    var browserURL = ""
    var browserUsesTunnel = false
    var browserForwardedPort = ""
    var useTmux = true
    var tmuxSessionName = "main"

    init() {}

    init(host: HostRecord?) {
        guard let host else {
            return
        }

        nickname = host.nickname
        hostname = host.hostname
        port = String(host.port)
        username = host.username
        browserURL = host.browserURLString ?? ""
        browserUsesTunnel = host.browserUsesTunnel
        browserForwardedPort = host.browserForwardedPort.map(String.init) ?? ""
        useTmux = host.prefersTmuxResume
        tmuxSessionName = host.tmuxSessionName ?? "main"
    }
}

struct HostEditorPresentation: Identifiable {
    enum Mode {
        case create
        case edit
    }

    let mode: Mode
    let host: HostRecord?

    static let create = HostEditorPresentation(mode: .create, host: nil)

    var id: String {
        switch mode {
        case .create:
            return "create"
        case .edit:
            return host?.id.uuidString ?? UUID().uuidString
        }
    }

    var title: String {
        switch mode {
        case .create:
            return "Add Host"
        case .edit:
            return "Edit Host"
        }
    }

    static func edit(_ host: HostRecord) -> HostEditorPresentation {
        HostEditorPresentation(mode: .edit, host: host)
    }
}

struct HostEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: HostEditorDraft
    @State private var shareItems: [Any] = []
    @State private var service: CodexService?

    let title: String
    let host: HostRecord?
    let publicKey: String
    let identity: SSHDeviceIdentity
    let trustStore: HostTrustStore
    let browserDefaultScheme: String
    let fileSessionManager: FileSessionManager
    let workingCopyManager: WorkingCopyManager
    let conflictResolver: ConflictResolver
    let previewStore: PreviewStore
    let haptics: HapticsClient
    let onDeleteHost: (() -> Void)?
    let onResetEverything: (() -> Void)?
    let onSave: (HostEditorDraft) -> Void

    init(
        title: String,
        host: HostRecord?,
        draft: HostEditorDraft,
        publicKey: String,
        identity: SSHDeviceIdentity,
        trustStore: HostTrustStore,
        browserDefaultScheme: String,
        fileSessionManager: FileSessionManager,
        workingCopyManager: WorkingCopyManager,
        conflictResolver: ConflictResolver,
        previewStore: PreviewStore,
        haptics: HapticsClient,
        onDeleteHost: (() -> Void)? = nil,
        onResetEverything: (() -> Void)? = nil,
        onSave: @escaping (HostEditorDraft) -> Void
    ) {
        self.title = title
        self.host = host
        _draft = State(initialValue: draft)
        self.publicKey = publicKey
        self.identity = identity
        self.trustStore = trustStore
        self.browserDefaultScheme = browserDefaultScheme
        self.fileSessionManager = fileSessionManager
        self.workingCopyManager = workingCopyManager
        self.conflictResolver = conflictResolver
        self.previewStore = previewStore
        self.haptics = haptics
        self.onDeleteHost = onDeleteHost
        self.onResetEverything = onResetEverything
        self.onSave = onSave
        _service = State(initialValue: host.map { CodexService(host: $0, identity: identity, trustStore: trustStore, haptics: haptics) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Label", text: $draft.nickname)
                    TextField("Host", text: $draft.hostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $draft.port)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $draft.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Terminal") {
                    Toggle("Use tmux", isOn: $draft.useTmux)
                    if draft.useTmux {
                        TextField("tmux session", text: $draft.tmuxSessionName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section("Browser") {
                    Toggle("Use SSH tunnel", isOn: $draft.browserUsesTunnel)
                    if draft.browserUsesTunnel {
                        TextField("Forwarded Port", text: $draft.browserForwardedPort)
                            .keyboardType(.numberPad)
                    } else {
                        TextField("URL", text: $draft.browserURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                    }
                }

                Section("Spellwire Key") {
                    Button("Copy Public Key") {
                        UIPasteboard.general.string = publicKey
                        haptics.play(.success)
                    }

                    Button("Copy Setup Command") {
                        UIPasteboard.general.string = authorizedKeysInstallCommand
                        haptics.play(.success)
                    }

                    Button("Share Setup Command") {
                        shareItems = [authorizedKeysInstallCommand]
                    }
                }

                if let host {
                    Section("Helper") {
                        if let helperStatus = service?.helperStatus {
                            helperStatusRow(helperStatus)
                        } else if service?.isLoadingList == true {
                            ProgressView("Connecting to Spellwire helper…")
                        } else {
                            Text("Pull to refresh helper status.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Tools") {
                        NavigationLink {
                            TerminalSessionView(
                                host: host,
                                identity: identity,
                                trustStore: trustStore,
                                haptics: haptics
                            )
                        } label: {
                            ToolRow(
                                title: "Terminal",
                                systemImage: "terminal",
                                description: "Open a real SSH PTY on the same pinned host."
                            )
                        }

                        NavigationLink {
                            RemoteBrowserView(
                                viewModel: BrowserViewModel(
                                    host: host,
                                    identity: identity,
                                    trustStore: trustStore,
                                    fileSessionManager: fileSessionManager,
                                    workingCopyManager: workingCopyManager,
                                    conflictResolver: conflictResolver,
                                    previewStore: previewStore,
                                    haptics: haptics
                                )
                            )
                        } label: {
                            ToolRow(
                                title: "Remote Files",
                                systemImage: "folder.badge.gearshape",
                                description: "Browse and edit remote files over SFTP."
                            )
                        }

                        NavigationLink {
                            HostBrowserView(
                                host: host,
                                identity: identity,
                                trustStore: trustStore,
                                defaultScheme: browserDefaultScheme,
                                haptics: haptics
                            )
                        } label: {
                            ToolRow(
                                title: "Preview Browser",
                                systemImage: host.browserUsesTunnel ? "point.3.connected.trianglepath.dotted" : "safari",
                                description: host.browserUsesTunnel
                                    ? (host.browserForwardedPort.map { "Forward localhost:\($0) from the Mac." } ?? "Configure a forwarded preview port.")
                                    : (host.browserURLString ?? "Preview discovery moves through the helper and SSH tunnels.")
                            )
                        }
                    }
                }

                if onDeleteHost != nil || onResetEverything != nil {
                    Section("Developer") {
                        if let onDeleteHost {
                            Button(role: .destructive) {
                                dismiss()
                                onDeleteHost()
                            } label: {
                                Label("Delete This Host", systemImage: "trash")
                            }
                        }

                        if let onResetEverything {
                            Button(role: .destructive) {
                                dismiss()
                                onResetEverything()
                            } label: {
                                Label("Reset Everything and Test Onboarding", systemImage: "arrow.counterclockwise")
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await service?.refreshWorkspace(userInitiated: true)
            }
            .task(id: host?.id) {
                guard let service, service.projects.isEmpty, service.threads.isEmpty else { return }
                await service.refreshWorkspace()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                    }
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { !shareItems.isEmpty },
                    set: { if !$0 { shareItems = [] } }
                )
            ) {
                ActivityView(activityItems: shareItems)
            }
            .alert(
                "Trust Host Key",
                isPresented: Binding(
                    get: { service?.pendingHostKeyChallenge != nil },
                    set: { if !$0 { service?.resolveHostKeyChallenge(approved: false) } }
                ),
                presenting: service?.pendingHostKeyChallenge
            ) { _ in
                Button("Reject", role: .cancel) {
                    service?.resolveHostKeyChallenge(approved: false)
                }
                Button("Trust") {
                    service?.resolveHostKeyChallenge(approved: true)
                }
            } message: { challenge in
                Text("\(challenge.hostLabel)\n\(challenge.fingerprint)")
            }
            .alert("Spellwire Error", isPresented: Binding(
                get: { service?.errorMessage != nil },
                set: { if !$0 { service?.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(service?.errorMessage ?? "")
            }
        }
    }

    private var authorizedKeysInstallCommand: String {
        SSHSetupCommand.installAuthorizedKeyCommand(for: publicKey)
    }

    private func helperStatusRow(_ status: HelperStatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(status.appServerRunning ? "Helper Connected" : "Helper Waiting", systemImage: status.appServerRunning ? "checkmark.circle.fill" : "bolt.horizontal.circle")
                .font(.headline)
            Text(status.lastActiveCwd ?? status.codexHome ?? "No active workspace yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let startedAt = status.startedAt {
                Text("Started \(startedAt)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ToolRow: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
