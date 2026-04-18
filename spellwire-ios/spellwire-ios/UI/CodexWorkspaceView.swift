import SwiftUI

struct CodexWorkspaceView: View {
    @State private var service: CodexService

    let host: HostRecord
    let identity: SSHDeviceIdentity
    let trustStore: HostTrustStore
    let browserDefaultScheme: String
    let fileSessionManager: FileSessionManager
    let workingCopyManager: WorkingCopyManager
    let conflictResolver: ConflictResolver
    let previewStore: PreviewStore
    let onEditHost: () -> Void
    let onDeleteHost: () -> Void
    let onResetEverything: () -> Void

    @State private var searchText = ""

    init(
        host: HostRecord,
        identity: SSHDeviceIdentity,
        trustStore: HostTrustStore,
        browserDefaultScheme: String,
        fileSessionManager: FileSessionManager,
        workingCopyManager: WorkingCopyManager,
        conflictResolver: ConflictResolver,
        previewStore: PreviewStore,
        onEditHost: @escaping () -> Void,
        onDeleteHost: @escaping () -> Void,
        onResetEverything: @escaping () -> Void
    ) {
        self.host = host
        self.identity = identity
        self.trustStore = trustStore
        self.browserDefaultScheme = browserDefaultScheme
        self.fileSessionManager = fileSessionManager
        self.workingCopyManager = workingCopyManager
        self.conflictResolver = conflictResolver
        self.previewStore = previewStore
        self.onEditHost = onEditHost
        self.onDeleteHost = onDeleteHost
        self.onResetEverything = onResetEverything
        _service = State(initialValue: CodexService(host: host, identity: identity, trustStore: trustStore))
    }

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Host", value: host.hostname)
                LabeledContent("Port", value: String(host.port))
                LabeledContent("User", value: host.username)
                LabeledContent("SSH Key", value: identity.metadata.publicKeyFingerprintSHA256)
            }

            Section("Helper") {
                if let helperStatus = service.helperStatus {
                    helperStatusRow(helperStatus)
                } else if service.isLoadingList {
                    ProgressView("Connecting to Spellwire helper…")
                }
            }

            Section("Tools") {
                NavigationLink {
                    TerminalSessionView(
                        host: host,
                        identity: identity,
                        trustStore: trustStore
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
                            previewStore: previewStore
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
                        defaultScheme: browserDefaultScheme
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

            Section("Developer") {
                Button(role: .destructive, action: onDeleteHost) {
                    Label("Delete This Host", systemImage: "trash")
                }

                Button(role: .destructive, action: onResetEverything) {
                    Label("Reset Everything and Test Onboarding", systemImage: "arrow.counterclockwise")
                }
            }

            Section("Codex") {
                if service.isLoadingList && service.threads.isEmpty {
                    ProgressView("Syncing threads…")
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if visibleProjects.isEmpty {
                    ContentUnavailableView(
                        "No Threads Yet",
                        systemImage: "ellipsis.message",
                        description: Text("Run Codex on the Mac, then pull to refresh.")
                    )
                } else {
                    ForEach(visibleProjects) { project in
                        Section(project.title) {
                            ForEach(service.threadsForProject(projectID: project.id, matching: searchText)) { thread in
                                NavigationLink {
                                    CodexThreadView(service: service, thread: thread)
                                } label: {
                                    ThreadSummaryRow(thread: thread)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(host.nickname)
        .searchable(text: $searchText, prompt: "Search threads")
        .refreshable {
            await service.refreshWorkspace()
        }
        .task {
            guard service.projects.isEmpty, service.threads.isEmpty else { return }
            await service.loadInitialData()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await service.refreshWorkspace(showArchived: !service.showsArchived)
                    }
                } label: {
                    Label(service.showsArchived ? "Hide Archive" : "Show Archive", systemImage: service.showsArchived ? "archivebox.fill" : "archivebox")
                }
            }
        }
        .alert(
            "Trust Host Key",
            isPresented: Binding(
                get: { service.pendingHostKeyChallenge != nil },
                set: { if !$0 { service.resolveHostKeyChallenge(approved: false) } }
            ),
            presenting: service.pendingHostKeyChallenge
        ) { _ in
            Button("Reject", role: .cancel) {
                service.resolveHostKeyChallenge(approved: false)
            }
            Button("Trust") {
                service.resolveHostKeyChallenge(approved: true)
            }
        } message: { challenge in
            Text("\(challenge.hostLabel)\n\(challenge.fingerprint)")
        }
        .alert("Spellwire Error", isPresented: Binding(
            get: { service.errorMessage != nil },
            set: { if !$0 { service.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(service.errorMessage ?? "")
        }
    }

    private var visibleProjects: [CodexProject] {
        service.projects.filter { service.projectIsVisible($0, query: searchText) }
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

private struct ThreadSummaryRow: View {
    let thread: CodexThreadSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(thread.title)
                    .font(.headline)
                Spacer()
                Text(thread.status.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(thread.status == "active" ? Color.green : Color.secondary)
            }

            Text(thread.preview.isEmpty ? thread.cwd : thread.preview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 10) {
                Label(thread.sourceKind, systemImage: thread.archived ? "archivebox.fill" : "ellipsis.message")
                if let nickname = thread.agentNickname {
                    Label(nickname, systemImage: "person.2.badge.gearshape")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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

private struct CodexThreadView: View {
    let service: CodexService
    let thread: CodexThreadSummary

    @State private var composerText = ""

    var body: some View {
        List {
            if service.isLoadingThread && service.threadDetail?.thread.id != thread.id {
                ProgressView("Opening thread…")
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if let detail = currentDetail {
                ForEach(detail.timeline) { item in
                    TimelineRow(item: item)
                }
            } else {
                ContentUnavailableView(
                    "No Timeline Yet",
                    systemImage: "ellipsis.message",
                    description: Text("Open the thread again or pull to refresh.")
                )
            }
        }
        .navigationTitle(thread.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await service.refreshSelectedThread()
        }
        .task(id: thread.id) {
            await service.open(thread)
        }
        .safeAreaInset(edge: .bottom) {
            composerBar
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Refresh") {
                    Task {
                        await service.refreshSelectedThread()
                    }
                }

                Button("Open on Mac") {
                    Task {
                        await service.openOnMac()
                    }
                }

                if currentDetail?.activeTurnID != nil {
                    Button("Interrupt") {
                        Task {
                            await service.interrupt()
                        }
                    }
                }
            }
        }
    }

    private var currentDetail: CodexThreadDetail? {
        guard service.threadDetail?.thread.id == thread.id else { return nil }
        return service.threadDetail
    }

    private var composerBar: some View {
        VStack(spacing: 10) {
            Divider()
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Message Codex", text: $composerText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)

                Button("Send") {
                    let prompt = composerText
                    composerText = ""
                    Task {
                        await service.send(prompt: prompt)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
            .background(.bar)
        }
    }
}

private struct TimelineRow: View {
    let item: CodexTimelineItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title)
                    .font(.headline)
                Spacer()
                if let status = item.status, !status.isEmpty {
                    Text(status.capitalized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if !item.body.isEmpty {
                Text(item.body)
                    .font(.body)
                    .textSelection(.enabled)
            }

            HStack(spacing: 10) {
                Text(item.kind)
                Text(item.source.capitalized)
                if let timestamp = item.timestamp {
                    Text(Date(timeIntervalSince1970: timestamp), style: .time)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
