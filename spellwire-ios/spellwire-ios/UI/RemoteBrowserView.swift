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
                    title: viewModel.host.nickname
                )
            } else if let errorMessage {
                ContentUnavailableView(
                    "Could Not Open Remote Files",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Connecting…")
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

private struct RemoteFolderView: View {
    let viewModel: BrowserViewModel
    let path: String
    let title: String

    @State private var items: [RemoteItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Could Not Load Folder",
                    systemImage: "folder.badge.exclamationmark",
                    description: Text(errorMessage)
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(items) { item in
                    destination(for: item)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: path) {
            await load()
        }
    }

    @ViewBuilder
    private func destination(for item: RemoteItem) -> some View {
        if item.metadata.kind == .directory {
            NavigationLink {
                RemoteFolderView(
                    viewModel: viewModel,
                    path: item.path,
                    title: item.name
                )
            } label: {
                RemoteItemRow(item: item)
            }
        } else if FileClassifier.editorKind(for: item.path) != nil {
            NavigationLink {
                RemoteEditorView(
                    viewModel: EditorViewModel(browser: viewModel, remotePath: item.path, title: item.name)
                )
            } label: {
                RemoteItemRow(item: item)
            }
        } else if FileClassifier.isPreviewable(path: item.path) {
            NavigationLink {
                RemotePreviewView(browser: viewModel, item: item)
            } label: {
                RemoteItemRow(item: item)
            }
        } else {
            NavigationLink {
                RemoteFileDetailView(browser: viewModel, item: item)
            } label: {
                RemoteItemRow(item: item)
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil

        do {
            items = try await viewModel.list(path: path)
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}

private struct RemoteItemRow: View {
    let item: RemoteItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(item.name, systemImage: iconName)
                .font(.headline)

            Text(metadataText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch item.metadata.kind {
        case .directory:
            return "folder"
        case .symlink:
            return "arrowshape.turn.up.right"
        case .file, .unknown:
            if FileClassifier.isPreviewable(path: item.path) {
                return "doc.richtext"
            }
            return "doc.text"
        }
    }

    private var metadataText: String {
        var components: [String] = []
        if let size = item.metadata.size {
            components.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let modifiedAt = item.metadata.modifiedAt {
            components.append(modifiedAt.formatted(date: .abbreviated, time: .shortened))
        }
        return components.isEmpty ? item.path : components.joined(separator: " • ")
    }
}
