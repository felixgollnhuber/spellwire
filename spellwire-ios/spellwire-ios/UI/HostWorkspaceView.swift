import SwiftUI

struct HostWorkspaceView: View {
    @Environment(AppModel.self) private var appModel

    let host: HostRecord
    let onDeleteHost: () -> Void
    let onResetEverything: () -> Void

    var body: some View {
        CodexWorkspaceView(
            host: host,
            identity: appModel.sshIdentity,
            trustStore: appModel.trustStore,
            fileSessionManager: appModel.fileSessionManager,
            workingCopyManager: appModel.workingCopyManager,
            conflictResolver: appModel.conflictResolver,
            previewStore: appModel.previewStore,
            onDeleteHost: onDeleteHost,
            onResetEverything: onResetEverything
        )
    }
}
