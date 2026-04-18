import SwiftUI

struct RemotePreviewView: View {
    let browser: BrowserViewModel
    let item: RemoteItem
    let searchRootPath: String

    @State private var previewURL: URL?
    @State private var errorMessage: String?
    @State private var isSharePresented = false
    @State private var searchText = ""
    @State private var submittedSearch: RemoteFilesSearchRequest?

    var body: some View {
        Group {
            if let previewURL {
                QuickLookPreview(url: previewURL)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Could Not Preview File",
                    systemImage: "doc.badge.gearshape",
                    description: Text(errorMessage)
                )
            } else {
                RemotePreviewSkeleton()
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            if previewURL == nil, errorMessage == nil {
                EmptyView()
            } else {
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
        }
        .navigationDestination(item: $submittedSearch) { request in
            RemoteFilesSearchResultsView(
                browser: browser,
                searchRootPath: searchRootPath,
                initialQuery: request.query
            )
        }
        .toolbar {
            if previewURL != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isSharePresented = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .task {
            guard previewURL == nil, errorMessage == nil else { return }
            do {
                previewURL = try await browser.previewURL(path: item.path)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $isSharePresented) {
            if let previewURL {
                ActivityView(activityItems: [previewURL])
            }
        }
    }

    private func submitSearch() {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }
        submittedSearch = RemoteFilesSearchRequest(query: trimmedQuery)
    }
}
