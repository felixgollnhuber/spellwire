import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private extension View {
    @ViewBuilder
    func threadScrollEdgeEffectsDisabled() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
    }
}

struct CodexThreadChatView: View {
    let service: CodexService
    let thread: CodexThreadSummary
    let host: HostRecord
    let identity: SSHDeviceIdentity
    let trustStore: HostTrustStore
    let browserDefaultScheme: String
    let projectPreviewPortStore: ProjectPreviewPortStore
    let fileSessionManager: FileSessionManager
    let workingCopyManager: WorkingCopyManager
    let conflictResolver: ConflictResolver
    let previewStore: PreviewStore
    let haptics: HapticsClient

    @Environment(\.colorScheme) private var colorScheme
    @State private var composerText = ""
    @State private var attachments: [ComposerAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showingPhotosPicker = false
    @State private var showingFileImporter = false
    @State private var isSending = false
    @State private var selectedModel: String?
    @State private var selectedEffort: String?
    @State private var selectedSpeedTier = "default"
    @State private var expandedToolIDs: Set<String> = []
    @State private var isNearBottom = true
    @State private var didInitialScroll = false
    @State private var activeSheet: ThreadToolDestination?
    @State private var previewPort: Int?
    @State private var showingPreviewPortPrompt = false
    @State private var previewPortDraft = ""
    @State private var attachmentStager: ChatAttachmentStager
    @State private var imageResolver: ThreadImageResolver
    @State private var activeImagePreview: ThreadImagePreview?
    @State private var pendingOlderHistoryAnchorID: String?
    @State private var lastObservedLatestItemID: String?
    @State private var composerHeight: CGFloat = 0
    @State private var lastExpandedToolScanThreadID: String?
    @State private var lastExpandedToolScanCount = 0
    @FocusState private var composerFocused: Bool

    private let latestAnchorID = "thread-latest-anchor"
    private let threadScrollSpace = "thread-scroll-space"
    private let nearLatestThreshold: CGFloat = 96
    private let edgeFadeHeight: CGFloat = 150

    init(
        service: CodexService,
        thread: CodexThreadSummary,
        host: HostRecord,
        identity: SSHDeviceIdentity,
        trustStore: HostTrustStore,
        browserDefaultScheme: String,
        projectPreviewPortStore: ProjectPreviewPortStore,
        fileSessionManager: FileSessionManager,
        workingCopyManager: WorkingCopyManager,
        conflictResolver: ConflictResolver,
        previewStore: PreviewStore,
        haptics: HapticsClient
    ) {
        self.service = service
        self.thread = thread
        self.host = host
        self.identity = identity
        self.trustStore = trustStore
        self.browserDefaultScheme = browserDefaultScheme
        self.projectPreviewPortStore = projectPreviewPortStore
        self.fileSessionManager = fileSessionManager
        self.workingCopyManager = workingCopyManager
        self.conflictResolver = conflictResolver
        self.previewStore = previewStore
        self.haptics = haptics
        _attachmentStager = State(initialValue: ChatAttachmentStager(host: host, identity: identity, trustStore: trustStore))
        _imageResolver = State(initialValue: ThreadImageResolver(host: host, identity: identity, trustStore: trustStore))
    }

    var body: some View {
        ScrollViewReader { proxy in
            threadScreen(proxy: proxy)
        }
        .onDisappear {
            service.stopGitStatusPolling()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(currentDetail?.thread.title ?? thread.title)
                        .font(.headline)
                        .foregroundStyle(threadPrimaryTextColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(currentDetail?.runtime.cwd ?? thread.cwd)
                        .font(.caption)
                        .foregroundStyle(threadSecondaryTextColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: 220)
                .multilineTextAlignment(.center)
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItemGroup(placement: .topBarTrailing) {
                if let gitStatus, gitStatus.hasChanges {
                    ThreadGitDiffPillButton(status: gitStatus) {
                        Task {
                            await openGitDiff()
                        }
                    }
                }

                Menu {
                    Button("Terminal", systemImage: "terminal") {
                        activeSheet = .terminal
                    }
                    Button("File Browser", systemImage: "folder.badge.gearshape") {
                        activeSheet = .files
                    }
                    if let previewPort {
                        Button("Web Browser", systemImage: "safari") {
                            activeSheet = .preview(port: previewPort)
                        }
                        Button("Edit Preview Port", systemImage: "pencil") {
                            previewPortDraft = String(previewPort)
                            showingPreviewPortPrompt = true
                        }
                    } else {
                        Button("Web Browser", systemImage: "safari") {
                            previewPortDraft = "3000"
                            showingPreviewPortPrompt = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(threadPrimaryTextColor)
                        .frame(minWidth: 28, minHeight: 28)
                }
                .buttonStyle(.plain)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .photosPicker(isPresented: $showingPhotosPicker, selection: $photoItems, maxSelectionCount: 8, matching: .images)
        .onChange(of: photoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                await importPhotoItems(newItems)
                photoItems = []
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task {
                    await importFileURLs(urls)
                }
            case .failure(let error):
                service.errorMessage = error.localizedDescription
                haptics.play(.error)
            }
        }
        .alert("Preview Port", isPresented: $showingPreviewPortPrompt) {
            TextField("3000", text: $previewPortDraft)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                savePreviewPort()
            }
        } message: {
            Text("Spellwire remembers this port locally on iPhone for this project.")
        }
        .sheet(item: $activeSheet) { destination in
            NavigationStack {
                switch destination {
                case .terminal:
                    TerminalSessionView(
                        host: host,
                        identity: identity,
                        trustStore: trustStore,
                        haptics: haptics,
                        context: TerminalSessionContext(
                            title: "Terminal",
                            workingDirectory: currentDetail?.runtime.cwd ?? thread.cwd,
                            prefersTmuxResume: true,
                            tmuxSessionName: tmuxSessionName
                        )
                    )
                case .files:
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
                        ),
                        initialPathOverride: currentDetail?.runtime.cwd ?? thread.cwd
                    )
                case .file(let path):
                    ThreadLinkedPathDestinationView(
                        browser: BrowserViewModel(
                            host: host,
                            identity: identity,
                            trustStore: trustStore,
                            fileSessionManager: fileSessionManager,
                            workingCopyManager: workingCopyManager,
                            conflictResolver: conflictResolver,
                            previewStore: previewStore,
                            haptics: haptics
                        ),
                        path: path
                    )
                case .preview(let port):
                    HostBrowserView(
                        host: host,
                        identity: identity,
                        trustStore: trustStore,
                        defaultScheme: browserDefaultScheme,
                        haptics: haptics,
                        title: "Preview Browser",
                        tunnelPortOverride: port
                    )
                case .gitDiff:
                    CodexGitDiffView(service: service, thread: thread)
                case .gitCommit:
                    CodexGitCommitSheet(service: service, thread: thread)
                }
            }
        }
        .fullScreenCover(item: $activeImagePreview) { preview in
            ThreadImageViewer(preview: preview)
        }
        .task {
            await service.loadModelsIfNeeded()
        }
    }

    private func threadScreen(proxy: ScrollViewProxy) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let detail = currentDetail {
                    threadScrollView(detail: detail, proxy: proxy)
                } else if service.isLoadingThread || service.isShowingCachedData {
                    threadLoadingShell
                } else {
                    ContentUnavailableView(
                        "No Timeline Yet",
                        systemImage: "ellipsis.message",
                        description: Text("Open the thread again or pull to refresh.")
                    )
                }
            }

            edgeFadeOverlay
        }
        .background(threadBackgroundColor.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composerBar
                .background(threadBackgroundColor.opacity(0.001))
        }
        .onPreferenceChange(ThreadComposerHeightPreferenceKey.self) { height in
            composerHeight = height
        }
        .refreshable {
            await service.refreshSelectedThread(userInitiated: true)
        }
        .task(id: thread.id) {
            service.prepareToOpenThread(thread)
            await service.open(thread)
            service.beginGitStatusPolling()
        }
        .onChange(of: composerFocused) { _, isFocused in
            guard isFocused else { return }
            scrollToLatest(with: proxy, animated: true)
        }
        .onChange(of: service.threadTimelineRevision) { _, _ in
            handleTimelineRevisionChange(with: proxy)
        }
        .onChange(of: service.oldestLoadedItemID) { previous, current in
            guard let anchorID = pendingOlderHistoryAnchorID else { return }
            guard previous != current else { return }
            restoreScrollPosition(afterPrependingTo: anchorID, with: proxy)
        }
    }

    private var currentDetail: CodexThreadDetail? {
        guard service.threadDetail?.thread.id == thread.id else { return nil }
        return service.threadDetail
    }

    private var gitStatus: CodexGitStatus? {
        guard service.selectedThread?.id == thread.id else { return nil }
        return service.selectedThreadGitStatus
    }

    private var threadBackgroundColor: Color {
        colorScheme == .dark ? .black : .white
    }

    private var threadPrimaryTextColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var threadSecondaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.62) : .black.opacity(0.62)
    }

    private var threadTertiaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.38) : .black.opacity(0.38)
    }

    private var inlineGitActionAnchorItemID: String? {
        guard let detail = currentDetail else { return nil }
        return CodexGitPresentation.inlineActionAnchorItemID(
            timeline: detail.timeline,
            hasChanges: gitStatus?.hasChanges == true,
            isThreadIdle: detail.activeTurnID == nil
        )
    }

    private var tmuxSessionName: String {
        let cleaned = thread.id
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "spellwire-\(cleaned.prefix(24))"
    }

    private func handleMessageLink(_ url: URL) -> OpenURLAction.Result {
        guard let path = linkedRemotePath(for: url) else {
            return .systemAction
        }

        activeSheet = .file(path: path)
        haptics.play(.selection)
        return .handled
    }

    private func linkedRemotePath(for url: URL) -> String? {
        if let scheme = url.scheme, scheme != "file" {
            return nil
        }

        let rawPath: String
        if url.isFileURL {
            rawPath = url.path(percentEncoded: false)
        } else {
            rawPath = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        }

        let candidate = strippedEditorSuffix(from: rawPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        if candidate.hasPrefix("/") {
            return candidate
        }

        let cwd = currentDetail?.runtime.cwd ?? thread.cwd
        return URL(filePath: cwd)
            .appending(path: candidate)
            .path(percentEncoded: false)
    }

    private func strippedEditorSuffix(from rawPath: String) -> String {
        guard let suffixRange = rawPath.range(
            of: #":\d+(?::\d+)?$"#,
            options: .regularExpression
        ) else {
            return rawPath
        }

        return String(rawPath[..<suffixRange.lowerBound])
    }

    private var composerBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(attachments) { attachment in
                                AttachmentChip(attachment: attachment) {
                                    attachments.removeAll { $0.id == attachment.id }
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }

                composerInputField

                HStack(alignment: .center, spacing: 10) {
                    HStack(spacing: 8) {
                        Menu {
                            Button("Photos", systemImage: "photo.on.rectangle") {
                                showingPhotosPicker = true
                            }
                            Button("Files", systemImage: "folder") {
                                showingFileImporter = true
                            }
                        } label: {
                            ComposerIconButton(symbol: "plus")
                        }
                        .buttonStyle(.plain)
                        .disabled(!service.canMutateRemotely)

                        Menu {
                            ForEach(service.availableModels) { model in
                                Button {
                                    selectedModel = model.model
                                    if selectedEffort == nil {
                                        selectedEffort = model.defaultReasoningEffort
                                    }
                                } label: {
                                    menuLabel(model.displayName, selected: resolvedModel?.model == model.model)
                                }
                            }
                        } label: {
                            ComposerChip(
                                title: resolvedModel?.displayName ?? (selectedModel ?? currentDetail?.runtime.model ?? "Model"),
                                minWidth: 92
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!service.canMutateRemotely)

                        Menu {
                            ForEach(reasoningOptions, id: \.reasoningEffort) { option in
                                Button {
                                    selectedEffort = option.reasoningEffort
                                } label: {
                                    menuLabel(option.reasoningEffort.capitalized, selected: resolvedEffort == option.reasoningEffort)
                                }
                            }
                        } label: {
                            ComposerChip(title: resolvedEffort?.capitalized ?? "Reasoning", minWidth: 74)
                        }
                        .buttonStyle(.plain)
                        .disabled(!service.canMutateRemotely)

                        Menu {
                            ForEach(speedOptions, id: \.self) { speed in
                                Button {
                                    selectedSpeedTier = speed
                                } label: {
                                    menuLabel(speedLabel(speed), selected: resolvedSpeedTier == speed)
                                }
                            }
                        } label: {
                            ComposerChip(title: speedLabel(resolvedSpeedTier), minWidth: 70)
                        }
                        .buttonStyle(.plain)
                        .disabled(!service.canMutateRemotely)
                    }

                    Spacer(minLength: 0)

                    sendButton
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .background {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.white.opacity(0.001))
                    .glassEffect(.regular.tint(.white.opacity(0.05)), in: .rect(cornerRadius: 28))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    }
            }

            HStack(spacing: 8) {
                Menu {
                    if service.availableBranches.isEmpty {
                        Button("No local branches") {}
                            .disabled(true)
                    } else {
                        ForEach(service.availableBranches) { branch in
                            Button {
                                Task {
                                    await service.switchBranch(to: branch.name)
                                }
                            } label: {
                                menuLabel(branch.name, selected: branch.isCurrent)
                            }
                        }
                    }
                } label: {
                    ComposerChip(title: currentBranchName ?? "No Branch", symbol: "point.topleft.down.curvedto.point.bottomright.up")
                }
                .disabled(!service.canMutateRemotely)

                if currentDetail?.activeTurnID != nil {
                    Button("Interrupt") {
                        Task {
                            await service.interrupt()
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(!service.canMutateRemotely)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: ThreadComposerHeightPreferenceKey.self, value: geometry.size.height)
            }
        )
    }

    private var composerInputField: some View {
        ZStack(alignment: .topLeading) {
            TextField("", text: $composerText, axis: .vertical)
                .lineLimit(1...6)
                .textInputAutocapitalization(.sentences)
                .focused($composerFocused)
                .font(.body)
                .foregroundStyle(threadPrimaryTextColor)
                .tint(threadPrimaryTextColor)
                .disabled(!service.canMutateRemotely)

            if composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Ask spellwire")
                    .font(.body)
                    .foregroundStyle(threadTertiaryTextColor)
                    .allowsHitTesting(false)
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sendButton: some View {
        Button {
            Task {
                await sendCurrentMessage()
            }
        } label: {
            Image(systemName: isSending ? "hourglass" : "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(sendDisabled ? threadSecondaryTextColor : sendForeground)
                .frame(width: 32, height: 32)
                .background {
                    Circle()
                        .fill(sendDisabled ? Color.clear : sendBackground)
                        .overlay {
                            Circle()
                                .strokeBorder(sendDisabled ? threadSecondaryTextColor.opacity(0.16) : sendBackground.opacity(0), lineWidth: 1)
                        }
                }
        }
        .buttonStyle(.plain)
        .disabled(sendDisabled)
    }

    private var sendDisabled: Bool {
        !service.canMutateRemotely || isSending || (composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
    }

    private var resolvedModel: ModelOption? {
        if let selectedModel {
            return service.availableModels.first(where: { $0.model == selectedModel })
        }
        if let runtimeModel = currentDetail?.runtime.model {
            return service.availableModels.first(where: { $0.model == runtimeModel })
        }
        return service.availableModels.first(where: { $0.isDefault }) ?? service.availableModels.first
    }

    private var reasoningOptions: [ReasoningEffortOption] {
        resolvedModel?.supportedReasoningEfforts ?? []
    }

    private var resolvedEffort: String? {
        selectedEffort ?? currentDetail?.runtime.reasoningEffort ?? resolvedModel?.defaultReasoningEffort
    }

    private var speedOptions: [String] {
        let additional = resolvedModel?.additionalSpeedTiers ?? []
        return ["default"] + additional
    }

    private var resolvedSpeedTier: String {
        if selectedSpeedTier != "default" || currentDetail?.runtime.serviceTier == nil {
            return selectedSpeedTier
        }
        return currentDetail?.runtime.serviceTier ?? "default"
    }

    private var currentBranchName: String? {
        service.availableBranches.first(where: { $0.isCurrent })?.name ?? currentDetail?.runtime.git?.branch
    }

    private func threadScrollView(detail: CodexThreadDetail, proxy: ScrollViewProxy) -> some View {
        let cacheStatusMessage = service.cacheStatusMessage
        let currentGitStatus = gitStatus
        let inlineGitAnchorItemID = inlineGitActionAnchorItemID
        let isCommitLoading = service.isExecutingGitCommit
        let reversedTimelineIndices = Array(detail.timeline.indices.reversed())

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                latestAnchor

                if let cacheStatusMessage {
                    cacheStatusBanner(cacheStatusMessage)
                        .scaleEffect(x: 1, y: -1)
                }

                ForEach(reversedTimelineIndices, id: \.self) { index in
                    transcriptRow(
                        item: detail.timeline[index],
                        activeTurnID: detail.activeTurnID,
                        inlineGitAnchorItemID: inlineGitAnchorItemID,
                        gitStatus: currentGitStatus,
                        isCommitLoading: isCommitLoading
                    )
                }

                olderHistorySection(detail: detail)
                    .scaleEffect(x: 1, y: -1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .coordinateSpace(name: threadScrollSpace)
        .threadScrollEdgeEffectsDisabled()
        .scaleEffect(x: 1, y: -1)
        .contentShape(Rectangle())
        .scrollDismissesKeyboard(.immediately)
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { _ in
                    if composerFocused {
                        composerFocused = false
                    }
                }
        )
        .background(threadBackgroundColor)
        .onPreferenceChange(ThreadLatestAnchorPreferenceKey.self) { frame in
            recomputeNearLatest(from: frame)
        }
        .onAppear {
            hydrateSelections(from: detail)
            hydratePreviewPort(for: detail.project.cwd)
            syncExpandedToolRows(with: detail)
            lastObservedLatestItemID = detail.timeline.last?.id
            if !didInitialScroll {
                scrollToLatest(with: proxy, animated: false)
            }
            service.beginGitStatusPolling()
        }
    }

    private var threadLoadingShell: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                latestAnchor
                ThreadLoadingShellCard(alignment: .trailing, width: 244)
                    .scaleEffect(x: 1, y: -1)
                ThreadLoadingShellCard(alignment: .leading, width: nil)
                    .scaleEffect(x: 1, y: -1)
                ThreadLoadingShellCard(alignment: .leading, width: 218)
                    .scaleEffect(x: 1, y: -1)
                ThreadInlineRefreshRow(title: "Opening latest messages…")
                    .scaleEffect(x: 1, y: -1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .coordinateSpace(name: threadScrollSpace)
        .threadScrollEdgeEffectsDisabled()
        .scaleEffect(x: 1, y: -1)
        .scrollDisabled(true)
        .background(threadBackgroundColor)
    }

    @ViewBuilder
    private func olderHistorySection(detail: CodexThreadDetail) -> some View {
        VStack(spacing: 10) {
            if service.isLoadingOlderHistory {
                ThreadInlineRefreshRow(title: "Loading older messages…")
            } else if let error = service.olderHistoryError {
                Button {
                    Task {
                        await requestOlderHistoryIfNeeded(for: detail)
                    }
                } label: {
                    Label(error, systemImage: "arrow.clockwise")
                        .font(.spellwireBody(13, weight: .semibold))
                        .foregroundStyle(threadSecondaryTextColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            } else if detail.hasOlderHistory {
                Color.clear
                    .frame(height: 1)
                    .task(id: detail.oldestLoadedItemID) {
                        await requestOlderHistoryIfNeeded(for: detail)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var latestAnchor: some View {
        Color.clear
            .frame(height: 1)
            .id(latestAnchorID)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ThreadLatestAnchorPreferenceKey.self,
                        value: proxy.frame(in: .named(threadScrollSpace))
                    )
                }
            )
            .scaleEffect(x: 1, y: -1)
    }

    private func requestOlderHistoryIfNeeded(for detail: CodexThreadDetail) async {
        guard detail.hasOlderHistory else { return }
        guard !service.isLoadingOlderHistory else { return }
        pendingOlderHistoryAnchorID = detail.oldestLoadedItemID
        await service.loadOlderHistory()
    }

    @ViewBuilder
    private func transcriptRow(
        item: CodexTimelineItem,
        activeTurnID: String?,
        inlineGitAnchorItemID: String?,
        gitStatus: CodexGitStatus?,
        isCommitLoading: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let inlineGitAnchorItemID, item.id == inlineGitAnchorItemID, let gitStatus {
                ThreadGitInlineActionRow(
                    status: gitStatus,
                    isCommitLoading: isCommitLoading,
                    onOpenDiff: {
                        Task {
                            await openGitDiff()
                        }
                    },
                    onCommit: {
                        Task {
                            await openGitCommitSheet()
                        }
                    }
                )
                .scaleEffect(x: 1, y: -1)
            }

            EquatableView(
                content: ThreadTimelineRow(
                    item: item,
                    imageResolver: imageResolver,
                    isExpanded: expansionBinding(for: item),
                    isCurrentTurn: item.turnID == activeTurnID,
                    onOpenImage: { preview in
                        activeImagePreview = preview
                    },
                    onOpenFileLink: { url in
                        handleMessageLink(url)
                    }
                )
            )
            .id(item.id)
            .scaleEffect(x: 1, y: -1)
        }
    }

    private func recomputeNearLatest(from frame: CGRect) {
        guard frame != .zero else { return }
        let distanceFromLatest = abs(frame.minY)
        isNearBottom = distanceFromLatest < nearLatestThreshold
    }

    @ViewBuilder
    private var edgeFadeOverlay: some View {
        GeometryReader { geometry in
            let c = threadBackgroundColor
            let bottomPadding = max(0, composerHeight + geometry.safeAreaInsets.bottom)

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [c, c.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: edgeFadeHeight)

                Spacer(minLength: 0)

                LinearGradient(
                    colors: [c.opacity(0), c],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: edgeFadeHeight)
                .padding(.bottom, bottomPadding)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea(edges: [.top, .bottom])
        .allowsHitTesting(false)
    }

    private func handleTimelineRevisionChange(with proxy: ScrollViewProxy) {
        guard let detail = currentDetail else { return }
        hydrateSelections(from: detail)
        hydratePreviewPort(for: detail.project.cwd)
        syncExpandedToolRows(with: detail)

        let latestItemID = detail.timeline.last?.id
        let latestIsPendingLocal = latestItemID?.hasPrefix("local:") == true

        if !didInitialScroll {
            scrollToLatest(with: proxy, animated: false)
        } else if latestItemID != lastObservedLatestItemID, (isNearBottom || latestIsPendingLocal) {
            scrollToLatest(with: proxy, animated: true)
        }

        lastObservedLatestItemID = latestItemID
    }

    private func restoreScrollPosition(afterPrependingTo anchorID: String, with proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(anchorID, anchor: .top)
            }
        }
        pendingOlderHistoryAnchorID = nil
    }

    private func scrollToLatest(with proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            let action = {
                proxy.scrollTo(latestAnchorID, anchor: .top)
            }
            if animated {
                withAnimation(.easeOut(duration: 0.2), action)
            } else {
                action()
            }
        }
        didInitialScroll = true
    }

    private func expansionBinding(for item: CodexTimelineItem) -> Binding<Bool> {
        Binding(
            get: {
                if item.status == "inProgress" {
                    return true
                }
                return expandedToolIDs.contains(item.id)
            },
            set: { isExpanded in
                if isExpanded {
                    expandedToolIDs.insert(item.id)
                } else {
                    expandedToolIDs.remove(item.id)
                }
            }
        )
    }

    private func syncExpandedToolRows(with detail: CodexThreadDetail) {
        if lastExpandedToolScanThreadID != detail.thread.id {
            lastExpandedToolScanThreadID = detail.thread.id
            lastExpandedToolScanCount = 0
            expandedToolIDs.removeAll()
        } else if detail.timeline.count < lastExpandedToolScanCount {
            lastExpandedToolScanCount = 0
        }

        let candidateItems: ArraySlice<CodexTimelineItem>
        if lastExpandedToolScanCount < detail.timeline.count {
            candidateItems = detail.timeline[lastExpandedToolScanCount...]
        } else {
            candidateItems = detail.timeline.suffix(6)
        }

        for item in candidateItems where item.kind != "userMessage" && item.kind != "agentMessage" && item.status == "inProgress" {
            expandedToolIDs.insert(item.id)
        }

        lastExpandedToolScanCount = detail.timeline.count
    }

    private func hydrateSelections(from detail: CodexThreadDetail) {
        if selectedModel == nil {
            selectedModel = detail.runtime.model
        }
        if selectedEffort == nil {
            selectedEffort = detail.runtime.reasoningEffort
        }
        if selectedSpeedTier == "default", let runtimeTier = detail.runtime.serviceTier {
            selectedSpeedTier = runtimeTier
        }
    }

    private func hydratePreviewPort(for cwd: String) {
        if let savedPort = try? projectPreviewPortStore.previewPort(hostID: host.id, cwd: cwd) {
            previewPort = savedPort
        } else {
            previewPort = nil
        }
    }

    private func savePreviewPort() {
        guard let cwd = currentDetail?.project.cwd ?? currentDetail?.runtime.cwd else { return }
        guard let port = Int(previewPortDraft), (1...65535).contains(port) else {
            service.errorMessage = "Preview port must be between 1 and 65535."
            haptics.play(.error)
            return
        }

        do {
            try projectPreviewPortStore.setPreviewPort(port, hostID: host.id, cwd: cwd)
            previewPort = port
            activeSheet = .preview(port: port)
            haptics.play(.success)
        } catch {
            service.errorMessage = error.localizedDescription
            haptics.play(.error)
        }
    }

    private func openGitDiff() async {
        activeSheet = .gitDiff
        await service.loadGitDiff(force: false, reportErrors: true)
    }

    private func openGitCommitSheet() async {
        activeSheet = .gitCommit
        await service.loadGitCommitPreview(force: false, reportErrors: true)
    }

    private func importPhotoItems(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let attachment = persistAttachmentData(data, suggestedExtension: "png")
            {
                attachments.append(attachment)
            }
        }
    }

    private func importFileURLs(_ urls: [URL]) async {
        for sourceURL in urls {
            let needsScoped = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if needsScoped {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            if let data = try? Data(contentsOf: sourceURL),
               let attachment = persistAttachmentData(data, suggestedExtension: sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension)
            {
                attachments.append(attachment)
            }
        }
    }

    private func persistAttachmentData(_ data: Data, suggestedExtension: String) -> ComposerAttachment? {
        let ext = suggestedExtension.isEmpty ? "png" : suggestedExtension
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: url, options: .atomic)
            return ComposerAttachment(localURL: url, previewData: data)
        } catch {
            service.errorMessage = error.localizedDescription
            haptics.play(.error)
            return nil
        }
    }

    private func sendCurrentMessage() async {
        let selectedThread = currentDetail?.thread ?? service.selectedThread ?? thread
        if service.selectedThread?.id != selectedThread.id {
            service.prepareToOpenThread(selectedThread)
        }
        isSending = true
        defer { isSending = false }

        do {
            let stagedPaths: [String]
            if attachments.isEmpty {
                stagedPaths = []
            } else {
                guard let attachmentsRootPath = service.helperStatus?.attachmentsRootPath, !attachmentsRootPath.isEmpty else {
                    throw HelperResponseErrorPayload(code: "attachment_path_missing", message: "The helper attachment path is unavailable.")
                }
                stagedPaths = try await attachmentStager.stageImages(
                    localURLs: attachments.map(\.localURL),
                    threadID: selectedThread.id,
                    attachmentsRootPath: attachmentsRootPath
                )
            }
            await service.send(
                prompt: composerText,
                attachmentPaths: stagedPaths,
                pendingAttachmentPreviewPaths: attachments.map(\.localURL),
                model: resolvedModel?.model,
                effort: resolvedEffort,
                serviceTier: resolvedSpeedTier == "default" ? nil : resolvedSpeedTier
            )
            composerText = ""
            attachments = []
        } catch {
            service.errorMessage = error.localizedDescription
            haptics.play(.error)
        }
    }

    private func menuLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            if selected {
                Spacer()
                Image(systemName: "checkmark")
            }
        }
    }

    private func speedLabel(_ speed: String) -> String {
        speed == "default" ? "Normal" : speed.capitalized
    }

    private func cacheStatusBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: service.isReadOnlyFallback ? "icloud.slash" : "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(threadPrimaryTextColor.opacity(0.82))

            Text(message)
                .font(.spellwireBody(14, weight: .medium))
                .foregroundStyle(threadPrimaryTextColor.opacity(0.82))
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(threadPrimaryTextColor.opacity(0.08))
        )
    }

    private var sendBackground: Color {
        colorScheme == .dark ? .white : .black
    }

    private var sendForeground: Color {
        colorScheme == .dark ? .black : .white
    }
}

private struct ThreadInlineRefreshRow: View {
    var title = "Refreshing latest messages…"
    @Environment(\.colorScheme) private var colorScheme

    private var foregroundColor: Color {
        colorScheme == .dark ? .white.opacity(0.76) : .black.opacity(0.76)
    }

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            Text(title)
                .font(.spellwireBody(13, weight: .medium))
                .foregroundStyle(foregroundColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(foregroundColor.opacity(0.08))
        )
    }
}

private struct ThreadLoadingShellCard: View {
    @Environment(\.colorScheme) private var colorScheme

    enum HorizontalAlignment {
        case leading
        case trailing
    }

    let alignment: HorizontalAlignment
    let width: CGFloat?

    private var baseColor: Color {
        colorScheme == .dark ? .white : .black
    }

    var body: some View {
        HStack {
            if alignment == .trailing {
                Spacer(minLength: 40)
            }

            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(baseColor.opacity(0.16))
                    .frame(width: width ?? 260, height: 14)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(baseColor.opacity(0.10))
                    .frame(width: min(width ?? 260, 180), height: 12)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(baseColor.opacity(alignment == .trailing ? 0.10 : 0.06))
            )

            if alignment == .leading {
                Spacer(minLength: 40)
            }
        }
    }
}

private struct ThreadTimelineRow: View, Equatable {
    static func == (lhs: ThreadTimelineRow, rhs: ThreadTimelineRow) -> Bool {
        lhs.item == rhs.item
            && lhs.isCurrentTurn == rhs.isCurrentTurn
            && lhs.isExpanded == rhs.isExpanded
    }

    @Environment(\.colorScheme) private var colorScheme
    let item: CodexTimelineItem
    let imageResolver: ThreadImageResolver
    @Binding var isExpanded: Bool
    let isCurrentTurn: Bool
    let onOpenImage: (ThreadImagePreview) -> Void
    let onOpenFileLink: (URL) -> OpenURLAction.Result

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.72) : .black.opacity(0.72)
    }

    private var tertiaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.56) : .black.opacity(0.56)
    }

    var body: some View {
        switch item.kind {
        case "userMessage":
            HStack {
                Spacer(minLength: 46)
                ThreadUserMessageBubble(
                    item: item,
                    imageResolver: imageResolver,
                    onOpenImage: onOpenImage
                )
                    .frame(maxWidth: 280, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        primaryTextColor.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
            }
        case "agentMessage":
            VStack(alignment: .leading, spacing: 8) {
                MarkdownMessageText(itemID: item.id, text: item.body, onOpenLink: onOpenFileLink)
                    .foregroundStyle(primaryTextColor)
                    .textSelection(.enabled)

                metadataRow
            }
        default:
            DisclosureGroup(isExpanded: $isExpanded) {
                if !item.body.isEmpty {
                    Text(item.body)
                        .font(.caption.monospaced())
                        .foregroundStyle(secondaryTextColor)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: iconName)
                        .foregroundStyle(secondaryTextColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(primaryTextColor)
                            .lineLimit(1)
                        metadataRow
                    }
                    Spacer()
                    if isCurrentTurn {
                        ProgressView()
                            .controlSize(.mini)
                    } else if let status = item.status {
                        Text(status.replacingOccurrences(of: "inProgress", with: "running"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(tertiaryTextColor)
                    }
                }
            }
            .tint(primaryTextColor)
            .padding(.vertical, 2)
        }
    }

    private var iconName: String {
        switch item.kind {
        case "commandExecution":
            return "terminal"
        case "fileChange":
            return "doc"
        case "reasoning":
            return "sparkles"
        case "plan":
            return "list.bullet.rectangle"
        case "mcpToolCall", "dynamicToolCall":
            return "wrench.and.screwdriver"
        default:
            return "circle.dashed"
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 8) {
            Text(item.kind)
            if let timestamp = item.timestamp {
                Text(Date(timeIntervalSince1970: timestamp), style: .time)
            }
        }
        .font(.caption2)
        .foregroundStyle(tertiaryTextColor)
    }
}

private struct ThreadUserMessageBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    let item: CodexTimelineItem
    let imageResolver: ThreadImageResolver
    let onOpenImage: (ThreadImagePreview) -> Void

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : .black
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    Text(text)
                        .font(.body)
                        .foregroundStyle(primaryTextColor)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                case .image(let part):
                    ThreadMessageImageThumbnail(
                        part: part,
                        resolver: imageResolver,
                        onOpenImage: onOpenImage
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var segments: [ThreadUserMessageSegment] {
        let content = item.content ?? []
        guard !content.isEmpty else {
            return item.body.isEmpty ? [] : [.text(item.body)]
        }

        var segments: [ThreadUserMessageSegment] = []
        var textBuffer: [String] = []

        func flushTextBuffer() {
            let joined = textBuffer
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if !joined.isEmpty {
                segments.append(.text(joined))
            }
            textBuffer.removeAll(keepingCapacity: true)
        }

        for part in content {
            switch part.type {
            case "image", "localImage":
                flushTextBuffer()
                segments.append(.image(part))
            default:
                if let text = part.fallbackText, !text.isEmpty {
                    textBuffer.append(text)
                }
            }
        }

        flushTextBuffer()
        return segments
    }
}

private enum ThreadUserMessageSegment: Hashable {
    case text(String)
    case image(CodexTimelineContentPart)
}

private struct ThreadMessageImageThumbnail: View {
    let part: CodexTimelineContentPart
    let resolver: ThreadImageResolver
    let onOpenImage: (ThreadImagePreview) -> Void

    @State private var image: UIImage?
    @State private var hasFailed = false

    var body: some View {
        Button {
            guard let image else { return }
            onOpenImage(ThreadImagePreview(image: image))
        } label: {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                        Image(systemName: hasFailed ? "photo.badge.exclamationmark" : "photo")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
            }
            .frame(width: 144, height: 108)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(image == nil)
        .task(id: cacheKey) {
            await loadImage()
        }
    }

    private var cacheKey: String {
        part.path ?? part.url ?? part.type
    }

    @MainActor
    private func loadImage() async {
        guard image == nil, !hasFailed else { return }
        if let resolvedImage = await resolver.loadImage(for: part) {
            image = resolvedImage
        } else {
            hasFailed = true
        }
    }
}

private struct ThreadImagePreview: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct ThreadImageViewer: View {
    let preview: ThreadImagePreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            Image(uiImage: preview.image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)

            Button("Done") {
                dismiss()
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.12), in: Capsule(style: .continuous))
            .padding(.top, 18)
            .padding(.trailing, 16)
        }
    }
}

private actor ThreadImageResolver {
    private let fileSystem: SFTPRemoteFileSystem
    private var cache: [String: Data] = [:]

    init(host: HostRecord, identity: SSHDeviceIdentity, trustStore: HostTrustStore) {
        fileSystem = try! SFTPRemoteFileSystem(
            host: host,
            identity: identity.clientIdentity(username: host.username),
            trustedHost: trustStore.trustedHost(for: host.id)
        ) { _, reply in
            reply(false)
        }
    }

    func loadImage(for part: CodexTimelineContentPart) async -> UIImage? {
        guard let cacheKey = cacheKey(for: part) else { return nil }

        if let cached = cache[cacheKey], let image = UIImage(data: cached) {
            return image
        }

        do {
            let data = try await loadImageData(for: part)
            cache[cacheKey] = data
            return UIImage(data: data)
        } catch {
            return nil
        }
    }

    private func cacheKey(for part: CodexTimelineContentPart) -> String? {
        switch part.type {
        case "image":
            return part.url
        case "localImage":
            return part.path
        default:
            return nil
        }
    }

    private func loadImageData(for part: CodexTimelineContentPart) async throws -> Data {
        switch part.type {
        case "image":
            guard let urlString = part.url, let url = URL(string: urlString) else {
                throw URLError(.badURL)
            }
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        case "localImage":
            guard let path = part.path, !path.isEmpty else {
                throw URLError(.fileDoesNotExist)
            }

            if FileManager.default.fileExists(atPath: path) {
                return try Data(contentsOf: URL(fileURLWithPath: path))
            }

            return try await fileSystem.readFile(path: path)
        default:
            throw URLError(.unsupportedURL)
        }
    }
}

private struct ComposerAttachment: Identifiable, Hashable {
    let id = UUID()
    let localURL: URL
    let previewData: Data
}

private struct AttachmentChip: View {
    let attachment: ComposerAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = UIImage(data: attachment.previewData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .background(Color.black.opacity(0.55), in: Circle())
            }
            .offset(x: 4, y: -4)
        }
    }
}

private struct ComposerChip: View {
    let title: String
    var symbol: String?
    var minWidth: CGFloat?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
            }
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minWidth: minWidth)
        .background {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay {
                    Capsule(style: .continuous)
                        .fill(.white.opacity(0.001))
                        .glassEffect(.regular.tint(.white.opacity(0.04)).interactive(), in: .capsule)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
        }
    }
}

private struct ComposerIconButton: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background {
                Circle()
                    .fill(.white.opacity(0.001))
                    .glassEffect(.regular.tint(.white.opacity(0.04)).interactive(), in: .circle)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    }
            }
    }
}

@MainActor
private final class ThreadMarkdownCache {
    static let shared = ThreadMarkdownCache()

    private var cache: [MarkdownCacheKey: AttributedString] = [:]

    func attributedString(itemID: String, text: String, colorScheme: ColorScheme) -> AttributedString? {
        let key = MarkdownCacheKey(itemID: itemID, text: text, theme: colorScheme == .dark ? .dark : .light)
        if let cached = cache[key] {
            return cached
        }
        guard let parsed = try? AttributedString(markdown: text) else {
            return nil
        }
        let foregroundColor: Color = colorScheme == .dark ? .white : .black
        var display = parsed
        for run in display.runs {
            let range = run.range
            if display[range].foregroundColor == nil {
                display[range].foregroundColor = foregroundColor
            }
        }
        cache[key] = display
        return display
    }

    private struct MarkdownCacheKey: Hashable {
        let itemID: String
        let text: String
        let theme: Theme
    }

    private enum Theme: Hashable {
        case light
        case dark
    }
}

private struct MarkdownMessageText: View {
    @Environment(\.colorScheme) private var colorScheme
    let itemID: String
    let text: String
    let onOpenLink: (URL) -> OpenURLAction.Result

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : .black
    }

    var body: some View {
        if let attributed = ThreadMarkdownCache.shared.attributedString(
            itemID: itemID,
            text: text,
            colorScheme: colorScheme
        ) {
            Text(attributed)
                .font(.body)
                .environment(\.openURL, OpenURLAction(handler: onOpenLink))
        } else {
            Text(text)
                .font(.body)
                .foregroundStyle(primaryTextColor)
        }
    }
}

private enum ThreadToolDestination: Identifiable {
    case terminal
    case files
    case file(path: String)
    case preview(port: Int)
    case gitDiff
    case gitCommit

    var id: String {
        switch self {
        case .terminal:
            return "terminal"
        case .files:
            return "files"
        case .file(let path):
            return "file-\(path)"
        case .preview(let port):
            return "preview-\(port)"
        case .gitDiff:
            return "git-diff"
        case .gitCommit:
            return "git-commit"
        }
    }
}

private struct ThreadLinkedPathDestinationView: View {
    let browser: BrowserViewModel
    let path: String

    @State private var item: RemoteItem?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let item {
                destination(for: item)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Could Not Open File",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Opening File…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: path) {
            guard item == nil, errorMessage == nil else { return }
            do {
                item = try await browser.item(at: path)
            } catch {
                errorMessage = error.localizedDescription
                browser.haptics.play(.error)
            }
        }
        .alert(
            "Trust Host Key",
            isPresented: Binding(
                get: { browser.pendingHostKeyChallenge != nil },
                set: { if !$0 { browser.resolveHostKeyChallenge(approved: false) } }
            ),
            presenting: browser.pendingHostKeyChallenge
        ) { _ in
            Button("Reject", role: .cancel) {
                browser.resolveHostKeyChallenge(approved: false)
            }
            Button("Trust") {
                browser.resolveHostKeyChallenge(approved: true)
            }
        } message: { challenge in
            Text("\(challenge.hostLabel)\n\(challenge.fingerprint)")
        }
    }

    @ViewBuilder
    private func destination(for item: RemoteItem) -> some View {
        switch item.metadata.kind {
        case .directory:
            RemoteFolderView(viewModel: browser, path: item.path, title: item.name)
        case .file, .symlink, .unknown:
            if FileClassifier.isPreviewable(path: item.path) {
                RemotePreviewView(browser: browser, item: item)
            } else {
                RemoteEditorView(
                    viewModel: EditorViewModel(
                        browser: browser,
                        remotePath: item.path,
                        title: item.name,
                        playsSuccessHapticOnLoad: false
                    )
                )
            }
        }
    }
}

private struct ThreadLatestAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct ThreadComposerHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
