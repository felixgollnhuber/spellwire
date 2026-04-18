import SwiftUI

struct RemoteEditorView: View {
    @State private var viewModel: EditorViewModel
    let searchRootPath: String

    @State private var isSharePresented = false
    @State private var searchText = ""
    @State private var submittedSearch: RemoteFilesSearchRequest?

    init(viewModel: EditorViewModel, searchRootPath: String) {
        _viewModel = State(initialValue: viewModel)
        self.searchRootPath = searchRootPath
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                RemoteEditorSkeleton()
            } else {
                RunestoneEditorView(
                    text: Binding(
                        get: { viewModel.text },
                        set: { viewModel.updateText($0) }
                    ),
                    language: viewModel.syntaxLanguage,
                    wrapsLines: viewModel.wrapsLines
                )
            }
        }
        .navigationTitle(viewModel.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search all files")
        .onSubmit(of: .search, submitSearch)
        .navigationDestination(item: $submittedSearch) { request in
            RemoteFilesSearchResultsView(
                browser: viewModel.browser,
                searchRootPath: searchRootPath,
                initialQuery: request.query
            )
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Reload") {
                    Task {
                        await viewModel.reloadFromRemote()
                    }
                }

                if viewModel.shareURL != nil {
                    Button {
                        isSharePresented = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }

                Button("Save") {
                    Task {
                        await viewModel.save()
                    }
                }
                .disabled(viewModel.isSaving || viewModel.session == nil)
            }
        }
        .task {
            await viewModel.loadIfNeeded()
        }
        .alert("Save Conflict", isPresented: $viewModel.hasConflict) {
            Button("Overwrite Remote", role: .destructive) {
                Task {
                    await viewModel.overwriteRemote()
                }
            }
            Button("Reload Remote") {
                Task {
                    await viewModel.reloadFromRemote()
                }
            }
            if viewModel.shareURL != nil {
                Button("Export Local Copy") {
                    isSharePresented = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The remote file changed since you opened it.")
        }
        .alert(
            "Editor Error",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sheet(isPresented: $isSharePresented) {
            if let shareURL = viewModel.shareURL {
                ActivityView(activityItems: [shareURL])
            }
        }
    }

    private func submitSearch() {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }
        submittedSearch = RemoteFilesSearchRequest(query: trimmedQuery)
    }
}
