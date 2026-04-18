import SwiftUI

struct RemoteBrowserView: View {
    @State private var viewModel: BrowserViewModel
    @State private var rootPath: String?
    @State private var errorMessage: String?

    init(viewModel: BrowserViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            if let rootPath {
                RemoteFolderView(
                    viewModel: viewModel,
                    path: rootPath,
                    title: viewModel.host.nickname,
                    searchRootPath: rootPath
                )
            } else if let errorMessage {
                ContentUnavailableView(
                    "Could Not Open Remote Files",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                RemoteFilesFolderSkeleton()
            }
        }
        .navigationTitle("Remote Files")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard rootPath == nil, errorMessage == nil else { return }
            do {
                rootPath = try await viewModel.initialPath()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert(
            "Trust Host Key",
            isPresented: Binding(
                get: { viewModel.pendingHostKeyChallenge != nil },
                set: { if !$0 { viewModel.resolveHostKeyChallenge(approved: false) } }
            ),
            presenting: viewModel.pendingHostKeyChallenge
        ) { _ in
            Button("Reject", role: .cancel) {
                viewModel.resolveHostKeyChallenge(approved: false)
            }
            Button("Trust") {
                viewModel.resolveHostKeyChallenge(approved: true)
            }
        } message: { challenge in
            Text("\(challenge.hostLabel)\n\(challenge.fingerprint)")
        }
    }
}

struct RemoteFolderView: View {
    let viewModel: BrowserViewModel
    let path: String
    let title: String
    let searchRootPath: String

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var items: [RemoteItem] = []
    @State private var searchText = ""
    @State private var submittedSearch: RemoteFilesSearchRequest?
    @State private var filter = BrowserFilter.all
    @State private var displayMode = BrowserDisplayMode.list
    @State private var sortKey = BrowserSortKey.name
    @State private var sortDirection = BrowserSortDirection.ascending
    @State private var isLoading = true
    @State private var isSelecting = false
    @State private var selectedItemIDs: Set<RemoteItem.ID> = []
    @State private var errorMessage: String?
    @State private var actionMessage: String?
    @State private var showingNewFolderPrompt = false
    @State private var newFolderName = ""
    @State private var showingDeleteConfirmation = false

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                RemoteFilesFolderSkeleton()
            } else if let errorMessage, items.isEmpty {
                ContentUnavailableView(
                    "Could Not Load Folder",
                    systemImage: "folder.badge.exclamationmark",
                    description: Text(errorMessage)
                )
            } else if visibleItems.isEmpty {
                emptyState
            } else {
                browserContent
            }
        }
        .navigationTitle(isSelecting ? selectionTitle : title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            if isLoading && items.isEmpty {
                EmptyView()
            } else {
                controlsHeader
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                selectionBar
            }
        }
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        endSelection()
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Actions") {
                        Button(isSelecting ? "Done" : "Select", systemImage: "checkmark.circle") {
                            isSelecting ? endSelection() : beginSelection()
                        }

                        Button("New Folder", systemImage: "folder.badge.plus") {
                            showingNewFolderPrompt = true
                        }

                        Button("Scan Documents", systemImage: "document.viewfinder") {
                            actionMessage = "Document scanning is not wired into the SSH file browser yet."
                        }

                        Button("Connect to Server", systemImage: "rectangle.connected.to.line.below") {
                            actionMessage = "Host onboarding still lives in the host list. This browser stays attached to the current SSH host."
                        }
                    }

                    Section("View As") {
                        ForEach(BrowserDisplayMode.allCases) { mode in
                            Button {
                                displayMode = mode
                            } label: {
                                menuRow(title: mode.title, systemImage: mode.systemImage, isSelected: displayMode == mode)
                            }
                        }
                    }

                    Section("Sort By") {
                        ForEach(BrowserSortKey.allCases) { key in
                            Button {
                                sortKey = key
                            } label: {
                                menuRow(title: key.title, systemImage: key.systemImage, isSelected: sortKey == key)
                            }
                        }

                        Button {
                            sortDirection.toggle()
                        } label: {
                            menuRow(title: sortDirection.title, systemImage: sortDirection.systemImage, isSelected: false)
                        }

                        Button("Tags", systemImage: "tag") {
                            actionMessage = "Remote SSH listings do not expose Apple Files tags yet."
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3.weight(.semibold))
                }
            }
        }
        .task(id: path) {
            await load()
        }
        .navigationDestination(item: $submittedSearch) { request in
            RemoteFilesSearchResultsView(
                browser: viewModel,
                searchRootPath: searchRootPath,
                initialQuery: request.query
            )
        }
        .refreshable {
            await load()
        }
        .alert("New Folder", isPresented: $showingNewFolderPrompt) {
            TextField("Folder Name", text: $newFolderName)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {
                newFolderName = ""
            }
            Button("Create") {
                Task {
                    await createFolder()
                }
            }
        } message: {
            Text("Create a folder inside \(title).")
        }
        .alert(
            "Files Action",
            isPresented: Binding(
                get: { actionMessage != nil },
                set: { if !$0 { actionMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionMessage ?? "")
        }
        .confirmationDialog("Delete Selected Items?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await deleteSelectedItems()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected remote items from \(title).")
        }
    }

    private var browserContent: some View {
        Group {
            if displayMode == .list {
                List {
                    ForEach(visibleItems) { item in
                        itemView(for: item, style: .list)
                            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    }
                }
                .listStyle(.plain)
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 20) {
                        ForEach(visibleItems) { item in
                            itemView(for: item, style: .icon)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .padding(.bottom, isSelecting ? 72 : 0)
                }
            }
        }
    }

    private var controlsHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            RemoteFilesSearchField(text: $searchText, prompt: "Search all files", onSubmit: submitSearch)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(BrowserFilter.allCases) { browseFilter in
                        Button {
                            filter = browseFilter
                        } label: {
                            VStack(spacing: 6) {
                                Text(browseFilter.title)
                                    .font(.subheadline.weight(filter == browseFilter ? .semibold : .regular))
                                Rectangle()
                                    .fill(filter == browseFilter ? Color.accentColor : Color.clear)
                                    .frame(height: 2)
                            }
                            .foregroundStyle(filter == browseFilter ? Color.primary : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }

            HStack {
                Text(resultSummary)
                Spacer()
                Text(sortSummary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var selectionBar: some View {
        HStack {
            Text(selectionTitle)
                .font(.subheadline.weight(.semibold))

            Spacer()

            Button("Delete", role: .destructive) {
                showingDeleteConfirmation = true
            }
            .disabled(selectedItemIDs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptySystemImage)
        } description: {
            Text(emptyDescription)
        } actions: {
            Button("New Folder") {
                showingNewFolderPrompt = true
            }
        }
    }

    private var resultSummary: String {
        let itemLabel = visibleItems.count == 1 ? "item" : "items"
        if filter == .all {
            return "\(visibleItems.count) \(itemLabel)"
        }
        return "\(visibleItems.count) \(filter.title.lowercased())"
    }

    private var sortSummary: String {
        "\(sortKey.title), \(sortDirection.title.lowercased())"
    }

    private var selectionTitle: String {
        let count = selectedItemIDs.count
        return count == 0 ? "Select Items" : "\(count) Selected"
    }

    private var emptyTitle: String {
        if items.isEmpty {
            return "Folder Is Empty"
        }
        return "Nothing Matches This Filter"
    }

    private var emptySystemImage: String {
        if items.isEmpty {
            return "folder"
        }
        return "magnifyingglass"
    }

    private var emptyDescription: String {
        if items.isEmpty {
            return "Create a folder or pull to refresh this remote location."
        }
        return "Try a different filter or sort option."
    }

    private var gridColumns: [GridItem] {
        let columnCount = horizontalSizeClass == .compact ? 3 : 5
        return Array(repeating: GridItem(.flexible(), spacing: 20), count: columnCount)
    }

    private var visibleItems: [RemoteItem] {
        items
            .filter { filter.includes($0) }
            .sorted(by: compareItems(_:_:))
    }

    @ViewBuilder
    private func itemView(for item: RemoteItem, style: BrowserItemStyle) -> some View {
        let content = itemContent(for: item, style: style)

        if isSelecting {
            Button {
                toggleSelection(for: item)
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            destination(for: item, style: style)
        }
    }

    @ViewBuilder
    private func destination(for item: RemoteItem, style: BrowserItemStyle) -> some View {
        if item.metadata.kind == .directory {
            NavigationLink {
                RemoteFolderView(viewModel: viewModel, path: item.path, title: item.name, searchRootPath: searchRootPath)
            } label: {
                itemContent(for: item, style: style)
            }
            .buttonStyle(.plain)
        } else if FileClassifier.editorKind(for: item.path) != nil {
            NavigationLink {
                RemoteEditorView(
                    viewModel: EditorViewModel(browser: viewModel, remotePath: item.path, title: item.name),
                    searchRootPath: searchRootPath
                )
            } label: {
                itemContent(for: item, style: style)
            }
            .buttonStyle(.plain)
        } else if FileClassifier.isPreviewable(path: item.path) {
            NavigationLink {
                RemotePreviewView(browser: viewModel, item: item, searchRootPath: searchRootPath)
            } label: {
                itemContent(for: item, style: style)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                RemoteFileDetailView(browser: viewModel, item: item, searchRootPath: searchRootPath)
            } label: {
                itemContent(for: item, style: style)
            }
            .buttonStyle(.plain)
        }
    }

    private func itemContent(for item: RemoteItem, style: BrowserItemStyle) -> some View {
        Group {
            switch style {
            case .list:
                RemoteListItemRow(
                    item: item,
                    isSelecting: isSelecting,
                    isSelected: selectedItemIDs.contains(item.id)
                )
            case .icon:
                RemoteIconItemRow(
                    item: item,
                    isSelecting: isSelecting,
                    isSelected: selectedItemIDs.contains(item.id)
                )
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil

        do {
            items = try await viewModel.list(path: path)
        } catch {
            errorMessage = error.localizedDescription
        }

        selectedItemIDs.removeAll()
        isLoading = false
    }

    private func createFolder() async {
        do {
            try await viewModel.createFolder(named: newFolderName, in: path)
            newFolderName = ""
            await load()
        } catch {
            actionMessage = error.localizedDescription
        }
    }

    private func deleteSelectedItems() async {
        let paths = selectedItemIDs.sorted()
        guard !paths.isEmpty else { return }

        do {
            try await viewModel.delete(paths: paths)
            endSelection()
            await load()
        } catch {
            actionMessage = error.localizedDescription
        }
    }

    private func beginSelection() {
        isSelecting = true
    }

    private func endSelection() {
        isSelecting = false
        selectedItemIDs.removeAll()
    }

    private func toggleSelection(for item: RemoteItem) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    private func submitSearch() {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }
        submittedSearch = RemoteFilesSearchRequest(query: trimmedQuery)
    }

    private func compareItems(_ lhs: RemoteItem, _ rhs: RemoteItem) -> Bool {
        if sortKey == .name, lhs.metadata.kind != rhs.metadata.kind {
            return lhs.metadata.kind == .directory
        }

        let comparison: ComparisonResult = switch sortKey {
        case .name:
            lhs.name.localizedStandardCompare(rhs.name)
        case .kind:
            FileClassifier.kindDescription(for: lhs).localizedStandardCompare(FileClassifier.kindDescription(for: rhs))
        case .date:
            compareOptionals(lhs.metadata.modifiedAt, rhs.metadata.modifiedAt)
        case .size:
            compareOptionals(lhs.metadata.size, rhs.metadata.size)
        }

        if comparison == .orderedSame {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        return sortDirection == .ascending
            ? comparison == .orderedAscending
            : comparison == .orderedDescending
    }

    private func compareOptionals<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            if lhs < rhs { return .orderedAscending }
            if lhs > rhs { return .orderedDescending }
            return .orderedSame
        case (nil, nil):
            return .orderedSame
        case (nil, _?):
            return .orderedDescending
        case (_?, nil):
            return .orderedAscending
        }
    }

    private func menuRow(title: String, systemImage: String, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
            Text(title)
            Spacer(minLength: 16)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
            }
        }
    }
}

struct RemoteListItemRow: View {
    let item: RemoteItem
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: FileClassifier.browseSymbolName(for: item))
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(metadataText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            } else if item.metadata.kind == .directory {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var metadataText: String {
        var components = [FileClassifier.kindDescription(for: item)]
        if let size = item.metadata.size, item.metadata.kind != .directory {
            components.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let modifiedAt = item.metadata.modifiedAt {
            components.append(modifiedAt.formatted(date: .abbreviated, time: .shortened))
        }
        return components.joined(separator: "  ")
    }

    private var iconColor: Color {
        switch FileClassifier.browserCategory(for: item) {
        case .folder:
            return .accentColor
        case .image:
            return .green
        case .pdf:
            return .red
        case .code:
            return .orange
        case .archive:
            return .yellow
        case .hidden, .alias, .document, .other:
            return .secondary
        }
    }
}

private struct RemoteIconItemRow: View {
    let item: RemoteItem
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: FileClassifier.browseSymbolName(for: item))
                    .font(.system(size: 32))
                    .foregroundStyle(iconColor)
                    .frame(maxWidth: .infinity, minHeight: 44)

                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
            }

            VStack(spacing: 4) {
                Text(item.name)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                Text(FileClassifier.kindDescription(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 8)
    }

    private var iconColor: Color {
        switch FileClassifier.browserCategory(for: item) {
        case .folder:
            return .accentColor
        case .image:
            return .green
        case .pdf:
            return .red
        case .code:
            return .orange
        case .archive:
            return .yellow
        case .hidden, .alias, .document, .other:
            return .secondary
        }
    }
}

private enum BrowserItemStyle {
    case list
    case icon
}

private enum BrowserDisplayMode: String, CaseIterable, Identifiable {
    case list
    case icons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list:
            return "List"
        case .icons:
            return "Icons"
        }
    }

    var systemImage: String {
        switch self {
        case .list:
            return "list.bullet"
        case .icons:
            return "square.grid.2x2"
        }
    }
}

private enum BrowserSortKey: String, CaseIterable, Identifiable {
    case name
    case kind
    case date
    case size

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }

    var systemImage: String {
        switch self {
        case .name:
            return "textformat"
        case .kind:
            return "square.stack.3d.up"
        case .date:
            return "calendar"
        case .size:
            return "arrow.up.left.and.arrow.down.right"
        }
    }
}

private enum BrowserSortDirection {
    case ascending
    case descending

    mutating func toggle() {
        self = self == .ascending ? .descending : .ascending
    }

    var title: String {
        switch self {
        case .ascending:
            return "Ascending"
        case .descending:
            return "Descending"
        }
    }

    var systemImage: String {
        switch self {
        case .ascending:
            return "arrow.up"
        case .descending:
            return "arrow.down"
        }
    }
}

private enum BrowserFilter: String, CaseIterable, Identifiable {
    case all
    case folders
    case documents
    case code
    case images
    case pdf
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .folders:
            return "Folders"
        case .documents:
            return "Documents"
        case .code:
            return "Code"
        case .images:
            return "Images"
        case .pdf:
            return "PDF"
        case .hidden:
            return "Hidden"
        }
    }

    func includes(_ item: RemoteItem) -> Bool {
        switch self {
        case .all:
            return true
        case .folders:
            return item.metadata.kind == .directory && !FileClassifier.isHidden(name: item.name)
        case .documents:
            return FileClassifier.browserCategory(for: item) == .document
        case .code:
            return FileClassifier.browserCategory(for: item) == .code
        case .images:
            return FileClassifier.browserCategory(for: item) == .image
        case .pdf:
            return FileClassifier.browserCategory(for: item) == .pdf
        case .hidden:
            return FileClassifier.browserCategory(for: item) == .hidden
        }
    }
}
