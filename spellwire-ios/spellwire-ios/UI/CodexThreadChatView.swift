import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

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
    @FocusState private var composerFocused: Bool

    private let bottomAnchorID = "thread-bottom-anchor"

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
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                Group {
                    if service.isLoadingThread && currentDetail == nil {
                        ProgressView("Opening thread…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let detail = currentDetail {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 22) {
                                ForEach(detail.timeline) { item in
                                    VStack(alignment: .leading, spacing: 12) {
                                        ThreadTimelineRow(
                                            item: item,
                                            imageResolver: imageResolver,
                                            isExpanded: expansionBinding(for: item),
                                            isCurrentTurn: item.turnID == detail.activeTurnID,
                                            onOpenImage: { preview in
                                                activeImagePreview = preview
                                            }
                                        )
                                        .id(item.id)

                                        if item.id == inlineGitActionAnchorItemID, let gitStatus {
                                            ThreadGitInlineActionRow(
                                                status: gitStatus,
                                                isCommitLoading: service.isExecutingGitCommit,
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
                                        }
                                    }
                                }

                                Color.clear
                                    .frame(height: 1)
                                    .id(bottomAnchorID)
                                    .background(
                                        GeometryReader { proxyView in
                                            Color.clear.preference(
                                                key: ThreadBottomProbePreferenceKey.self,
                                                value: proxyView.frame(in: .named("thread-scroll")).maxY
                                            )
                                        }
                                    )
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 20)
                            .padding(.bottom, 12)
                        }
                        .scrollDismissesKeyboard(.immediately)
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { _ in
                                    if composerFocused {
                                        composerFocused = false
                                    }
                                }
                        )
                        .coordinateSpace(name: "thread-scroll")
                        .background(Color.black)
                        .onPreferenceChange(ThreadBottomProbePreferenceKey.self) { value in
                            isNearBottom = value <= geometry.size.height + 120
                        }
                        .onAppear {
                            hydrateSelections(from: detail)
                            hydratePreviewPort(for: detail.project.cwd)
                            scrollToBottom(with: proxy, animated: false)
                            service.beginGitStatusPolling()
                        }
                        .onChange(of: timelineSignature) { _, _ in
                            expandActiveToolRows()
                            if !didInitialScroll || isNearBottom {
                                scrollToBottom(with: proxy, animated: didInitialScroll)
                            }
                        }
                    } else {
                        ContentUnavailableView(
                            "No Timeline Yet",
                            systemImage: "ellipsis.message",
                            description: Text("Open the thread again or pull to refresh.")
                        )
                    }
                }
                .background(Color.black.ignoresSafeArea())
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    composerBar
                        .background(Color.black.opacity(0.001))
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
                    scrollToBottom(with: proxy, animated: true)
                }
            }
        }
        .onDisappear {
            service.stopGitStatusPolling()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(currentDetail?.thread.title ?? thread.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(currentDetail?.runtime.cwd ?? thread.cwd)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
            }

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
                    Button("File Browser", systemImage: "folder") {
                        activeSheet = .files
                    }
                    if let previewPort {
                        Button("Web Browser", systemImage: "globe") {
                            activeSheet = .preview(port: previewPort)
                        }
                        Button("Edit Preview Port", systemImage: "pencil") {
                            previewPortDraft = String(previewPort)
                            showingPreviewPortPrompt = true
                        }
                    } else {
                        Button("Web Browser", systemImage: "globe") {
                            previewPortDraft = "3000"
                            showingPreviewPortPrompt = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
            }
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

    private var currentDetail: CodexThreadDetail? {
        guard service.threadDetail?.thread.id == thread.id else { return nil }
        return service.threadDetail
    }

    private var gitStatus: CodexGitStatus? {
        guard service.selectedThread?.id == thread.id else { return nil }
        return service.selectedThreadGitStatus
    }

    private var timelineSignature: String {
        guard let detail = currentDetail else { return "empty" }
        return detail.timeline
            .map { "\($0.id):\($0.body.count):\($0.status ?? "")" }
            .joined(separator: "|")
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

                if currentDetail?.activeTurnID != nil {
                    Button("Interrupt") {
                        Task {
                            await service.interrupt()
                        }
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var composerInputField: some View {
        ZStack(alignment: .topLeading) {
            TextField("", text: $composerText, axis: .vertical)
                .lineLimit(1...6)
                .textInputAutocapitalization(.sentences)
                .focused($composerFocused)
                .font(.body)
                .foregroundStyle(.white)
                .tint(.white)

            if composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Ask spellwire")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.38))
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
                .foregroundStyle(sendDisabled ? .white.opacity(0.45) : sendForeground)
                .frame(width: 32, height: 32)
                .background {
                    Circle()
                        .fill(sendDisabled ? Color.clear : sendBackground)
                        .overlay {
                            Circle()
                                .strokeBorder(sendDisabled ? Color.white.opacity(0.08) : sendBackground.opacity(0), lineWidth: 1)
                        }
                }
        }
        .buttonStyle(.plain)
        .disabled(sendDisabled)
    }

    private var sendDisabled: Bool {
        isSending || (composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
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

    private func scrollToBottom(with proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            let action = {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
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

    private func expandActiveToolRows() {
        for item in currentDetail?.timeline ?? [] where item.kind != "userMessage" && item.kind != "agentMessage" && item.status == "inProgress" {
            expandedToolIDs.insert(item.id)
        }
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
        speed == "default" ? "Speed" : speed.capitalized
    }

    private var sendBackground: Color {
        colorScheme == .dark ? .white : .black
    }

    private var sendForeground: Color {
        colorScheme == .dark ? .black : .white
    }
}

private struct ThreadTimelineRow: View {
    let item: CodexTimelineItem
    let imageResolver: ThreadImageResolver
    @Binding var isExpanded: Bool
    let isCurrentTurn: Bool
    let onOpenImage: (ThreadImagePreview) -> Void

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
                        Color.white.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
            }
        case "agentMessage":
            VStack(alignment: .leading, spacing: 8) {
                MarkdownMessageText(text: item.body)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)

                metadataRow
            }
        default:
            DisclosureGroup(isExpanded: $isExpanded) {
                if !item.body.isEmpty {
                    Text(item.body)
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.72))
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: iconName)
                        .foregroundStyle(.white.opacity(0.78))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
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
                            .foregroundStyle(.white.opacity(0.56))
                    }
                }
            }
            .tint(.white)
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
        .foregroundStyle(.white.opacity(0.5))
    }
}

private struct ThreadUserMessageBubble: View {
    let item: CodexTimelineItem
    let imageResolver: ThreadImageResolver
    let onOpenImage: (ThreadImagePreview) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    Text(text)
                        .font(.body)
                        .foregroundStyle(.white)
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

private struct MarkdownMessageText: View {
    let text: String

    var body: some View {
        if let attributed = try? AttributedString(markdown: text) {
            Text(attributed)
                .font(.body)
        } else {
            Text(text)
                .font(.body)
        }
    }
}

private enum ThreadToolDestination: Identifiable {
    case terminal
    case files
    case preview(port: Int)
    case gitDiff
    case gitCommit

    var id: String {
        switch self {
        case .terminal:
            return "terminal"
        case .files:
            return "files"
        case .preview(let port):
            return "preview-\(port)"
        case .gitDiff:
            return "git-diff"
        case .gitCommit:
            return "git-commit"
        }
    }
}

private struct ThreadBottomProbePreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
