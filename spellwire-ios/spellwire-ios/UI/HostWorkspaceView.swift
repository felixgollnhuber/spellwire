import SwiftUI

struct HostWorkspaceView: View {
    @Environment(AppModel.self) private var appModel

    let host: HostRecord
    let onEditHost: () -> Void
    let onDeleteHost: () -> Void
    let onResetEverything: () -> Void

    var body: some View {
        CodexWorkspaceView(
            host: host,
            identity: appModel.sshIdentity,
            trustStore: appModel.trustStore,
            browserDefaultScheme: (try? appModel.browserSettingsStore.load().defaultScheme) ?? BrowserSettings.default.defaultScheme,
            projectPreviewPortStore: appModel.projectPreviewPortStore,
            fileSessionManager: appModel.fileSessionManager,
            workingCopyManager: appModel.workingCopyManager,
            conflictResolver: appModel.conflictResolver,
            previewStore: appModel.previewStore,
            onEditHost: onEditHost,
            onDeleteHost: onDeleteHost,
            onResetEverything: onResetEverything
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onEditHost) {
                    Label("Edit Host", systemImage: "slider.horizontal.3")
                }
            }
        }
    }
}
