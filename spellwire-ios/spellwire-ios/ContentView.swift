import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @State private var hostEditor: HostEditorPresentation?
    @State private var errorMessage: String?

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
            }
        } detail: {
            if let selectedHost = appModel.selectedHost {
                NavigationStack {
                    HostWorkspaceView(host: selectedHost)
                }
            } else {
                ContentUnavailableView(
                    "No Hosts Yet",
                    systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                    description: Text("Add a host to start wiring terminal, file browser, and browser flows.")
                )
            }
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
