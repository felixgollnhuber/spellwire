import SwiftUI

struct HostWorkspaceView: View {
    @Environment(AppModel.self) private var appModel

    let onCreateHost: () -> Void
    let onEditHost: (HostRecord) -> Void
    let onDeleteHost: (HostRecord) -> Void
    let onResetEverything: () -> Void

    var body: some View {
        Group {
            if let selectedHost = appModel.selectedHost {
                CodexWorkspaceView(
                    host: selectedHost,
                    service: appModel.codexService(for: selectedHost),
                    hosts: appModel.hosts,
                    identity: appModel.sshIdentity,
                    trustStore: appModel.trustStore,
                    browserDefaultScheme: (try? appModel.browserSettingsStore.load().defaultScheme) ?? BrowserSettings.default.defaultScheme,
                    projectPreviewPortStore: appModel.projectPreviewPortStore,
                    fileSessionManager: appModel.fileSessionManager,
                    workingCopyManager: appModel.workingCopyManager,
                    conflictResolver: appModel.conflictResolver,
                    previewStore: appModel.previewStore,
                    haptics: appModel.haptics,
                    onSelectHost: { host in
                        appModel.selectedHostID = host.id
                        appModel.haptics.play(.confirmation)
                    },
                    onCreateHost: onCreateHost,
                    onEditHost: {
                        onEditHost(selectedHost)
                    },
                    onDeleteHost: {
                        onDeleteHost(selectedHost)
                    },
                    onResetEverything: onResetEverything
                )
            } else {
                ContentUnavailableView(
                    "No Host Selected",
                    systemImage: "server.rack",
                    description: Text("Add a host to start browsing projects and chats.")
                )
                .overlay(alignment: .bottom) {
                    Button(action: onCreateHost) {
                        Label("Add Host", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 32)
                }
            }
        }
        .task(id: appModel.hosts.map(\.id)) {
            if appModel.selectedHostID == nil {
                appModel.selectedHostID = appModel.hosts.first?.id
            }
        }
    }
}
