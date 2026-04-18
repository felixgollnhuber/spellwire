import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if appModel.hosts.isEmpty {
            WelcomeExperienceView()
        } else {
            WorkspaceShellView()
        }
    }
}

private struct WorkspaceShellView: View {
    @Environment(AppModel.self) private var appModel
    @State private var hostEditor: HostEditorPresentation?
    @State private var errorMessage: String?
    @State private var hostPendingDeletion: HostRecord?
    @State private var showingResetConfirmation = false

    var body: some View {
        NavigationStack {
            HostWorkspaceView {
                hostEditor = .create
            } onEditHost: { host in
                hostEditor = .edit(host)
            } onDeleteHost: { host in
                hostPendingDeletion = host
            } onResetEverything: {
                showingResetConfirmation = true
            }
        }
        .alert("Delete Host?", isPresented: Binding(
            get: { hostPendingDeletion != nil },
            set: { if !$0 { hostPendingDeletion = nil } }
        ), presenting: hostPendingDeletion) { host in
            Button("Delete", role: .destructive) {
                do {
                    try appModel.deleteHost(id: host.id)
                } catch {
                    errorMessage = error.localizedDescription
                }
                hostPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                hostPendingDeletion = nil
            }
        } message: { host in
            Text("Remove \(host.nickname) and its pinned trust entry and local cache?")
        }
        .alert("Reset Everything?", isPresented: $showingResetConfirmation) {
            Button("Reset", role: .destructive) {
                do {
                    try appModel.resetEverything()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears every saved host and returns the app to onboarding for development and testing.")
        }
        .sheet(item: $hostEditor) { presentation in
            HostEditorView(
                title: presentation.title,
                host: presentation.host,
                draft: HostEditorDraft(host: presentation.host),
                publicKey: appModel.publicKeyOpenSSH,
                identity: appModel.sshIdentity,
                trustStore: appModel.trustStore,
                browserDefaultScheme: (try? appModel.browserSettingsStore.load().defaultScheme) ?? BrowserSettings.default.defaultScheme,
                fileSessionManager: appModel.fileSessionManager,
                workingCopyManager: appModel.workingCopyManager,
                conflictResolver: appModel.conflictResolver,
                previewStore: appModel.previewStore,
                onDeleteHost: presentation.host == nil ? nil : { hostPendingDeletion = presentation.host },
                onResetEverything: presentation.host == nil ? nil : { showingResetConfirmation = true }
            ) { draft in
                do {
                    _ = try appModel.saveHost(from: draft, existingID: presentation.host?.id)
                    hostEditor = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .alert("Could Not Save Host", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel.preview)
}
