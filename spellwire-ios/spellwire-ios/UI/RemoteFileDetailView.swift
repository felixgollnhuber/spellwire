import SwiftUI

struct RemoteFileDetailView: View {
    let browser: BrowserViewModel
    let item: RemoteItem

    @State private var shareURL: URL?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var isSharePresented = false

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
}
