import SwiftUI

struct RemoteFilesSearchRequest: Identifiable, Hashable {
    let query: String
    var id: String { query }
}

struct RemoteFilesSearchResultsView: View {
    let browser: BrowserViewModel
    let searchRootPath: String
    let title: String

    @State private var query: String
    @State private var results: [RemoteItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var submittedSearch: RemoteFilesSearchRequest?

    init(browser: BrowserViewModel, searchRootPath: String, initialQuery: String, title: String = "Search") {
        self.browser = browser
        self.searchRootPath = searchRootPath
        self.title = title
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        Group {
            if isLoading && results.isEmpty {
                RemoteFilesFolderSkeleton()
            } else if let errorMessage, results.isEmpty {
                ContentUnavailableView(
                    "Search Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if results.isEmpty {
                ContentUnavailableView(
                    query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Search Remote Files" : "No Results",
                    systemImage: "magnifyingglass",
                    description: Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Enter a file name, path, kind, or extension." : "Try a different search term.")
                )
            } else {
                List {
                    ForEach(results) { item in
                        destination(for: item)
                            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search all files")
        .onSubmit(of: .search, submitSearch)
        .safeAreaInset(edge: .top, spacing: 0) {
            if isLoading && results.isEmpty {
                EmptyView()
            } else {
                HStack {
                    Text(statusText)
                    Spacer()
                    Text(searchRootPath)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
                .overlay(alignment: .bottom) {
                    Divider()
                }
            }
        }
        .task(id: query) {
            await runSearch()
        }
        .navigationDestination(item: $submittedSearch) { request in
            RemoteFilesSearchResultsView(
                browser: browser,
                searchRootPath: searchRootPath,
                initialQuery: request.query
            )
        }
    }

    private var statusText: String {
        if isLoading {
            return "Searching..."
        }
        let itemLabel = results.count == 1 ? "result" : "results"
        return "\(results.count) \(itemLabel)"
    }

    private func submitSearch() {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }
        query = trimmedQuery
    }

    private func runSearch() async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            results = []
            errorMessage = nil
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            try await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            results = try await browser.search(query: trimmedQuery, from: searchRootPath)
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }

    @ViewBuilder
    private func destination(for item: RemoteItem) -> some View {
        if item.metadata.kind == .directory {
            NavigationLink {
                RemoteFolderView(
                    viewModel: browser,
                    path: item.path,
                    title: item.name
                )
            } label: {
                RemoteListItemRow(item: item, isSelecting: false, isSelected: false)
            }
            .buttonStyle(.plain)
        } else if FileClassifier.isPreviewable(path: item.path) {
            NavigationLink {
                RemotePreviewView(browser: browser, item: item)
            } label: {
                RemoteListItemRow(item: item, isSelecting: false, isSelected: false)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                RemoteEditorView(viewModel: EditorViewModel(browser: browser, remotePath: item.path, title: item.name))
            } label: {
                RemoteListItemRow(item: item, isSelecting: false, isSelected: false)
            }
            .buttonStyle(.plain)
        }
    }
}
