import SwiftUI
import UIKit

struct CodexWorkspaceView: View {
    @Environment(\.colorScheme) private var colorScheme

    let host: HostRecord
    let service: CodexService
    let hosts: [HostRecord]
    let identity: SSHDeviceIdentity
    let trustStore: HostTrustStore
    let browserDefaultScheme: String
    let projectPreviewPortStore: ProjectPreviewPortStore
    let fileSessionManager: FileSessionManager
    let workingCopyManager: WorkingCopyManager
    let conflictResolver: ConflictResolver
    let previewStore: PreviewStore
    let haptics: HapticsClient
    let onSelectHost: (HostRecord) -> Void
    let onCreateHost: () -> Void
    let onEditHost: () -> Void
    let onDeleteHost: () -> Void
    let onResetEverything: () -> Void

    @State private var searchText = ""
    @State private var collapsedProjectIDs = Set<CodexProject.ID>()
    @State private var initializedProjectCollapseState = false
    @State private var knownProjectIDs = Set<CodexProject.ID>()
    @State private var pendingThread: CodexThreadSummary?
    @State private var creatingProjectID: CodexProject.ID?

    private let searchHeaderHeight: CGFloat = 50
    private let searchHeaderTopSpacing: CGFloat = 115

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let cacheStatusMessage = service.cacheStatusMessage {
                        cacheStatusBanner(cacheStatusMessage)
                    }
                    workspaceContent
                }
                .padding(.horizontal, 18)
                .padding(.top, searchHeaderTopSpacing + searchHeaderHeight + 14)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                await service.refreshWorkspace(userInitiated: true)
            }

            searchHeader
        }
        .background(Color.clear)
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                headerLogo
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .principal) {
                centeredHostToolbarMenu
            }

            ToolbarItem(placement: .topBarTrailing) {
                actionsToolbarMenu
            }
        }
        .task(id: host.id) {
            if service.projects.isEmpty && service.threads.isEmpty {
                await service.loadInitialData()
            } else {
                await service.refreshWorkspace()
            }
        }
        .navigationDestination(item: $pendingThread) { thread in
            CodexThreadChatView(
                service: service,
                thread: thread,
                host: host,
                identity: identity,
                trustStore: trustStore,
                browserDefaultScheme: browserDefaultScheme,
                projectPreviewPortStore: projectPreviewPortStore,
                fileSessionManager: fileSessionManager,
                workingCopyManager: workingCopyManager,
                conflictResolver: conflictResolver,
                previewStore: previewStore,
                haptics: haptics
            )
        }
        .onChange(of: service.projects.map(\.id)) { _, projectIDs in
            guard !projectIDs.isEmpty else { return }
            let projectIDSet = Set(projectIDs)

            if !initializedProjectCollapseState {
                collapsedProjectIDs = projectIDSet
                initializedProjectCollapseState = true
            } else {
                collapsedProjectIDs = collapsedProjectIDs.intersection(projectIDSet)
                for projectID in projectIDSet.subtracting(knownProjectIDs) {
                    collapsedProjectIDs.insert(projectID)
                }
            }

            knownProjectIDs = projectIDSet
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
}

extension CodexWorkspaceView {
    private var searchHeader: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 18)
                .padding(.top, searchHeaderTopSpacing)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
        .background(Color.clear)
        .zIndex(1)
    }

    fileprivate var visibleProjects: [CodexProject] {
        service.projects.filter { service.projectIsVisible($0, query: searchText) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var headerLogo: some View {
        Image("SpellwireHeaderLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }

    private var centeredHostToolbarMenu: some View {
        Menu {
            Section("Hosts") {
                ForEach(hosts) { candidate in
                    Button {
                        onSelectHost(candidate)
                    } label: {
                        if candidate.id == host.id {
                            Label(candidate.nickname, systemImage: "checkmark")
                        } else {
                            Text(candidate.nickname)
                        }
                    }
                }
            }

            Section {
                Button(action: onCreateHost) {
                    Label("Add Host", systemImage: "plus")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(host.nickname)
                    .font(.spellwireBody(17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.62))
            }
            .frame(maxWidth: 220)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var actionsToolbarMenu: some View {
        Menu {
            Button {
                Task {
                    await service.refreshWorkspace(userInitiated: true)
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Button {
                Task {
                    await service.refreshWorkspace(showArchived: !service.showsArchived, userInitiated: true)
                }
            } label: {
                Label(
                    service.showsArchived ? "Hide Archive" : "Show Archive",
                    systemImage: service.showsArchived ? "archivebox.fill" : "archivebox"
                )
            }

            Button(action: onEditHost) {
                Label("Edit Host", systemImage: "slider.horizontal.3")
            }

            Button(role: .destructive, action: onDeleteHost) {
                Label("Delete Host", systemImage: "trash")
            }

            Button(role: .destructive, action: onResetEverything) {
                Label("Reset Everything", systemImage: "arrow.counterclockwise")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 28, minHeight: 28)
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        let shape = RoundedRectangle(cornerRadius: 19, style: .continuous)

        return WorkspaceSystemSearchBar(
            text: $searchText,
            placeholder: "Search conversations"
        )
        .frame(height: 38)
        .background(searchFieldBaseFill, in: shape)
        .overlay {
            shape
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        }
        .modifier(WorkspaceSearchFieldGlass(shape: shape))
    }

    private var searchFieldBaseFill: Color {
        colorScheme == .dark ? Color.black.opacity(0.04) : Color.black.opacity(0.24)
    }

    @ViewBuilder
    private var workspaceContent: some View {
        if service.isLoadingList && service.threads.isEmpty {
            WorkspaceSkeleton()
        } else if visibleProjects.isEmpty {
            ContentUnavailableView(
                normalizedSearchText.isEmpty ? "No Threads Yet" : "No Matching Threads",
                systemImage: normalizedSearchText.isEmpty ? "ellipsis.message" : "magnifyingglass",
                description: Text(
                    normalizedSearchText.isEmpty
                        ? "Run Codex on the Mac, then pull to refresh."
                        : "Try another search term or show archived chats."
                )
            )
            .foregroundStyle(.white.opacity(0.82))
            .frame(maxWidth: .infinity, minHeight: 280)
        } else {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(visibleProjects) { project in
                    projectSection(project)
                }
            }
        }
    }

    private func projectSection(_ project: CodexProject) -> some View {
        let threads = service.threadsForProject(projectID: project.id, matching: searchText)
        let isExpanded = initializedProjectCollapseState && !collapsedProjectIDs.contains(project.id)

        return VStack(alignment: .leading, spacing: isExpanded ? 10 : 0) {
            ProjectSectionHeader(
                project: project,
                isExpanded: isExpanded,
                isCreating: creatingProjectID == project.id,
                canCreate: service.canMutateRemotely
            ) {
                toggleProject(project.id)
            } onCreate: {
                createThread(in: project)
            }

            if isExpanded {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(threads.enumerated()), id: \.element.id) { index, thread in
                        Button {
                            service.prepareToOpenThread(thread)
                            pendingThread = thread
                        } label: {
                            CompactThreadRow(
                                thread: thread,
                                isSelected: service.isThreadSelected(thread),
                                indicator: threadIndicator(for: thread)
                            )
                        }
                        .buttonStyle(.plain)
                        .transition(
                            .offset(y: -10)
                                .combined(with: .opacity)
                                .animation(.snappy(duration: 0.24, extraBounce: 0).delay(Double(index) * 0.025))
                        )
                    }
                }
                .padding(.leading, 28)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    )
                )
            }
        }
        .animation(.snappy(duration: 0.28, extraBounce: 0.08), value: isExpanded)
    }

    private func toggleProject(_ projectID: CodexProject.ID) {
        withAnimation(.snappy(duration: 0.28, extraBounce: 0.08)) {
            if collapsedProjectIDs.contains(projectID) {
                collapsedProjectIDs.remove(projectID)
            } else {
                collapsedProjectIDs.insert(projectID)
            }
        }
        haptics.play(.selection)
    }

    private func createThread(in project: CodexProject) {
        guard creatingProjectID == nil else { return }
        guard service.canMutateRemotely else { return }
        creatingProjectID = project.id

        Task {
            let created = await service.createThread(in: project)
            await MainActor.run {
                creatingProjectID = nil
                if let created {
                    collapsedProjectIDs.remove(project.id)
                    pendingThread = created
                }
            }
        }
    }

    private func cacheStatusBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: service.isReadOnlyFallback ? "icloud.slash" : "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.82))

            Text(message)
                .font(.spellwireBody(14, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.82))
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }

    private func threadIndicator(for thread: CodexThreadSummary) -> ThreadRowIndicator {
        if service.isThreadRunning(thread) {
            return .running
        }
        if service.hasUnreadActivity(thread) {
            return .unread
        }
        return .none
    }
}

private struct WorkspaceSearchFieldGlass<S: Shape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular
                        .tint(colorScheme == .dark ? .black.opacity(0.12) : .black.opacity(0.38))
                        .interactive(),
                    in: shape
                )
        } else {
            content
                .clipShape(shape)
        }
    }
}

private struct ProjectSectionHeader: View {
    let project: CodexProject
    let isExpanded: Bool
    let isCreating: Bool
    let canCreate: Bool
    let onToggle: () -> Void
    let onCreate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.82))

                    Text(project.title)
                        .font(.spellwireBody(20, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Spacer(minLength: 12)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.52))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onCreate) {
                Group {
                    if isCreating {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.1))
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isCreating || !canCreate)
        }
    }
}

private struct CompactThreadRow: View {
    let thread: CodexThreadSummary
    let isSelected: Bool
    let indicator: ThreadRowIndicator

    var body: some View {
        HStack(spacing: 12) {
            ThreadIndicatorView(indicator: indicator)

            Text(thread.rowTitle)
                .font(.spellwireBody(17, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(.white.opacity(isSelected ? 0.98 : 0.88))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 10)

            Text(thread.lastUpdatedLabel)
                .font(.spellwireBody(14, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.48))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.08) : .clear)
        )
    }
}

private enum ThreadRowIndicator {
    case none
    case running
    case unread
}

private struct ThreadIndicatorView: View {
    let indicator: ThreadRowIndicator

    var body: some View {
        ZStack {
            switch indicator {
            case .none:
                Color.clear
            case .running:
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white.opacity(0.82))
                    .scaleEffect(0.72)
            case .unread:
                Circle()
                    .fill(Color.green.opacity(0.95))
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 14, height: 14)
    }
}

private struct WorkspaceSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(ProjectThreadSkeleton.projects) { skeleton in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color.white.opacity(0.16))
                            .frame(width: 14, height: 14)

                        Text(skeleton.title)
                            .font(.spellwireBody(20, weight: .semibold))
                            .redacted(reason: .placeholder)

                        Spacer()

                        Circle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 30, height: 30)
                    }
                    .modifier(ShimmerEffect())

                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(skeleton.rows) { row in
                            HStack {
                                Text(row.title)
                                    .font(.spellwireBody(17, weight: .medium))
                                    .redacted(reason: .placeholder)
                                Spacer()
                                Text("1h")
                                    .font(.spellwireBody(14, weight: .medium))
                                    .redacted(reason: .placeholder)
                            }
                            .padding(.leading, 28)
                            .padding(.vertical, 10)
                            .modifier(ShimmerEffect())
                        }
                    }
                }
            }
        }
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

private struct WorkspaceSystemSearchBar: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UISearchTextField {
        let textField = UISearchTextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.returnKeyType = .search
        textField.enablesReturnKeyAutomatically = false
        textField.clearButtonMode = .whileEditing
        textField.leftViewMode = .always
        textField.backgroundColor = .clear
        configure(textField)
        return textField
    }

    func updateUIView(_ uiView: UISearchTextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        configure(uiView)
    }

    private func configure(_ textField: UISearchTextField) {
        textField.backgroundColor = .clear
        textField.textColor = .label
        textField.borderStyle = .none
        textField.clearButtonMode = .whileEditing
        textField.font = .systemFont(ofSize: 17, weight: .regular)
        textField.defaultTextAttributes = [
            .foregroundColor: UIColor.label,
            .font: UIFont.systemFont(ofSize: 17, weight: .regular),
        ]
        textField.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: WorkspaceSearchBarPalette.placeholderColor,
                .font: UIFont.systemFont(ofSize: 17, weight: .regular),
            ]
        )

        if let searchIconView = textField.leftView as? UIImageView {
            searchIconView.tintColor = WorkspaceSearchBarPalette.placeholderColor
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            text = textField.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}

private enum WorkspaceSearchBarPalette {
    static let placeholderColor = UIColor { traitCollection in
        if traitCollection.userInterfaceStyle == .dark {
            return UIColor(white: 0.62, alpha: 1)
        } else {
            return UIColor(white: 0.34, alpha: 1)
        }
    }
}

private struct ProjectThreadSkeleton: Identifiable {
    struct Row: Identifiable {
        let id = UUID()
        let title: String
    }

    let id = UUID()
    let title: String
    let rows: [Row]

    static let projects: [ProjectThreadSkeleton] = [
        ProjectThreadSkeleton(
            title: "spellwire",
            rows: [
                Row(title: "Loading recent thread"),
                Row(title: "Loading running thread"),
                Row(title: "Loading archived thread"),
            ]
        ),
        ProjectThreadSkeleton(
            title: "workspace",
            rows: [
                Row(title: "Loading recent thread"),
                Row(title: "Loading running thread"),
            ]
        ),
    ]
}

private struct ShimmerEffect: ViewModifier {
    @State private var phase: CGFloat = -0.8

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [
                            .clear,
                            .white.opacity(0.22),
                            .clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .rotationEffect(.degrees(24))
                    .offset(x: geometry.size.width * phase)
                    .blendMode(.plusLighter)
                    .mask(content)
                }
                .allowsHitTesting(false)
            }
            .task {
                guard phase == -0.8 else { return }
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    phase = 1.2
                }
            }
    }
}

private extension CodexThreadSummary {
    var rowTitle: String {
        let candidates = [title, preview, cwd]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return candidates.first ?? "Untitled Thread"
    }
    var isRunning: Bool {
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalizedStatus {
        case "active", "running", "inprogress":
            return true
        default:
            return false
        }
    }

    var lastUpdatedLabel: String {
        CompactRelativeTimeFormatter.string(from: updatedAt)
    }
}

private enum CompactRelativeTimeFormatter {
    static func string(from unixTime: TimeInterval) -> String {
        let delta = max(0, Int(Date().timeIntervalSince1970 - unixTime))

        switch delta {
        case 0..<60:
            return "now"
        case 60..<(60 * 60):
            return "\(delta / 60)m"
        case (60 * 60)..<(60 * 60 * 24):
            return "\(delta / (60 * 60))h"
        case (60 * 60 * 24)..<(60 * 60 * 24 * 7):
            return "\(delta / (60 * 60 * 24))d"
        default:
            return "\(delta / (60 * 60 * 24 * 7))w"
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
