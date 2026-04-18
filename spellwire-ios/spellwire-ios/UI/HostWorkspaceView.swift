import SwiftUI

struct HostWorkspaceView: View {
    @Environment(AppModel.self) private var appModel
    let host: HostRecord
    let onDeleteHost: () -> Void
    let onResetEverything: () -> Void

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Host", value: host.hostname)
                LabeledContent("Port", value: String(host.port))
                LabeledContent("User", value: host.username)
                LabeledContent("tmux", value: host.prefersTmuxResume ? (host.tmuxSessionName ?? "enabled") : "disabled")
            }

            Section("Workspace") {
                NavigationLink {
                    TerminalSessionView(
                        host: host,
                        password: appModel.password(for: host.id),
                        trustStore: appModel.trustStore
                    )
                } label: {
                    workspaceRow(
                        title: "Terminal",
                        systemImage: "terminal",
                        description: "SSH terminal over Ghostty VT using the saved host credentials."
                    )
                }

                NavigationLink {
                    RemoteBrowserView(
                        viewModel: BrowserViewModel(
                            host: host,
                            password: appModel.password(for: host.id),
                            trustStore: appModel.trustStore,
                            fileSessionManager: appModel.fileSessionManager,
                            workingCopyManager: appModel.workingCopyManager,
                            conflictResolver: appModel.conflictResolver,
                            previewStore: appModel.previewStore
                        )
                    )
                } label: {
                    workspaceRow(
                        title: "Remote Files",
                        systemImage: "folder.badge.gearshape",
                        description: "Browse remote folders, edit local working copies, and preview PDFs or images."
                    )
                }

                workspaceRow(
                    title: "Browser",
                    systemImage: host.browserUsesTunnel ? "point.3.connected.trianglepath.dotted" : "safari",
                    description: host.browserURLString ?? "Configure a remote URL to add the Safari or SSH tunnel flow."
                )
            }

            Section("Next Build Steps") {
                Text("1. Add an SFTP-backed file browser and working-copy editor.")
                Text("2. Reuse the same host/trust model across terminal, files, and browser.")
                Text("3. Add the browser and SSH tunnel flow.")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Section("Developer") {
                Button(role: .destructive, action: onDeleteHost) {
                    Label("Delete This Host", systemImage: "trash")
                }

                Button(role: .destructive, action: onResetEverything) {
                    Label("Reset Everything and Test Onboarding", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .navigationTitle(host.nickname)
    }

    private func workspaceRow(title: String, systemImage: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
