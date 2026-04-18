import SwiftUI

struct RemoteFileDetailView: View {
    let browser: BrowserViewModel
    let item: RemoteItem
    let searchRootPath: String

    @State private var shareURL: URL?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var isSharePresented = false
    @State private var searchText = ""
    @State private var submittedSearch: RemoteFilesSearchRequest?

    var body: some View {
        List {
            Section("Remote File") {
                LabeledContent("Name", value: item.name)
                LabeledContent("Path", value: item.path)
                if let size = item.metadata.size {
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
                if let modifiedAt = item.metadata.modifiedAt {
                    LabeledContent("Modified", value: modifiedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }

            Section {
                Button(isLoading ? "Downloading…" : "Export Local Copy") {
                    Task {
                        await exportFile()
                    }
                }
                .disabled(isLoading)
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack {
                RemoteFilesSearchField(text: $searchText, prompt: "Search all files", onSubmit: submitSearch)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .background(.bar)
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
        .navigationDestination(item: $submittedSearch) { request in
            RemoteFilesSearchResultsView(
                browser: browser,
                searchRootPath: searchRootPath,
                initialQuery: request.query
            )
        }
        .alert(
            "File Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $isSharePresented) {
            if let shareURL {
                ActivityView(activityItems: [shareURL])
            }
        }
    }

    private func exportFile() async {
        isLoading = true
        errorMessage = nil
        do {
            shareURL = try await browser.previewURL(path: item.path)
            isSharePresented = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func submitSearch() {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }
        submittedSearch = RemoteFilesSearchRequest(query: trimmedQuery)
    }
}
