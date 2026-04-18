import SwiftUI

struct RemotePreviewView: View {
    let browser: BrowserViewModel
    let item: RemoteItem

    @State private var previewURL: URL?
    @State private var errorMessage: String?
    @State private var isSharePresented = false

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
                ProgressView("Downloading…")
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
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
}
