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
        NavigationSplitView {
            HostListView(selection: Bindable(appModel).selectedHostID) {
                hostEditor = .create
            } onEdit: { host in
                hostEditor = .edit(host)
            } onDelete: { offsets in
                do {
                    try appModel.deleteHosts(at: offsets)
                } catch {
                    errorMessage = error.localizedDescription
                }
            } onDeleteHost: { host in
                hostPendingDeletion = host
            } onResetEverything: {
                showingResetConfirmation = true
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        hostEditor = .create
                    } label: {
                        Label("Add Host", systemImage: "plus")
                    }
                }

                ToolbarItem {
                    Button {
                        if let selectedHost = appModel.selectedHost {
                            hostEditor = .edit(selectedHost)
                        }
                    } label: {
                        Label("Edit Host", systemImage: "slider.horizontal.3")
                    }
                    .disabled(appModel.selectedHost == nil)
                }

                ToolbarItem {
                    Button(role: .destructive) {
                        hostPendingDeletion = appModel.selectedHost
                    } label: {
                        Label("Delete Host", systemImage: "trash")
                    }
                    .disabled(appModel.selectedHost == nil)
                }

                ToolbarItem {
                    Button(role: .destructive) {
                        showingResetConfirmation = true
                    } label: {
                        Label("Reset Everything", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(appModel.hosts.isEmpty)
                }
            }
        } detail: {
            if let selectedHost = appModel.selectedHost {
                NavigationStack {
                    HostWorkspaceView(host: selectedHost) {
                        hostPendingDeletion = selectedHost
                    } onResetEverything: {
                        showingResetConfirmation = true
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Hosts Yet",
                    systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                    description: Text("Add a host to start wiring terminal, file browser, and browser flows.")
                )
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
            Text("Remove \(host.nickname) and its saved password, trust entry, and local cache?")
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
                draft: HostEditorDraft(host: presentation.host, password: presentation.host.map { appModel.password(for: $0.id) } ?? "")
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
