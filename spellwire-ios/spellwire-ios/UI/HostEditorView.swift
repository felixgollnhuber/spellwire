import UIKit
import SwiftUI

struct HostEditorDraft: Equatable {
    var nickname = ""
    var hostname = ""
    var port = "22"
    var username = ""
    var browserURL = ""
    var browserUsesTunnel = false
    var browserForwardedPort = ""
    var useTmux = true
    var tmuxSessionName = "main"

    init() {}

    init(host: HostRecord?) {
        guard let host else {
            return
        }

        nickname = host.nickname
        hostname = host.hostname
        port = String(host.port)
        username = host.username
        browserURL = host.browserURLString ?? ""
        browserUsesTunnel = host.browserUsesTunnel
        browserForwardedPort = host.browserForwardedPort.map(String.init) ?? ""
        useTmux = host.prefersTmuxResume
        tmuxSessionName = host.tmuxSessionName ?? "main"
    }
}

struct HostEditorPresentation: Identifiable {
    enum Mode {
        case create
        case edit
    }

    let mode: Mode
    let host: HostRecord?

    static let create = HostEditorPresentation(mode: .create, host: nil)

    var id: String {
        switch mode {
        case .create:
            return "create"
        case .edit:
            return host?.id.uuidString ?? UUID().uuidString
        }
    }

    var title: String {
        switch mode {
        case .create:
            return "Add Host"
        case .edit:
            return "Edit Host"
        }
    }

    static func edit(_ host: HostRecord) -> HostEditorPresentation {
        HostEditorPresentation(mode: .edit, host: host)
    }
}

struct HostEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: HostEditorDraft
    @State private var shareItems: [Any] = []

    let title: String
    let publicKey: String
    let onSave: (HostEditorDraft) -> Void

    init(title: String, draft: HostEditorDraft, publicKey: String, onSave: @escaping (HostEditorDraft) -> Void) {
        self.title = title
        _draft = State(initialValue: draft)
        self.publicKey = publicKey
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Label", text: $draft.nickname)
                    TextField("Host", text: $draft.hostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $draft.port)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $draft.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Terminal") {
                    Toggle("Use tmux", isOn: $draft.useTmux)
                    if draft.useTmux {
                        TextField("tmux session", text: $draft.tmuxSessionName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section("Browser") {
                    Toggle("Use SSH tunnel", isOn: $draft.browserUsesTunnel)
                    if draft.browserUsesTunnel {
                        TextField("Forwarded Port", text: $draft.browserForwardedPort)
                            .keyboardType(.numberPad)
                    } else {
                        TextField("URL", text: $draft.browserURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                    }
                }

                Section("Spellwire Key") {
                    Button("Copy Public Key") {
                        UIPasteboard.general.string = publicKey
                    }

                    Button("Copy Setup Command") {
                        UIPasteboard.general.string = authorizedKeysInstallCommand
                    }

                    Button("Share Setup Command") {
                        shareItems = [authorizedKeysInstallCommand]
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                    }
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { !shareItems.isEmpty },
                    set: { if !$0 { shareItems = [] } }
                )
            ) {
                ActivityView(activityItems: shareItems)
            }
        }
    }

    private var authorizedKeysInstallCommand: String {
        SSHSetupCommand.installAuthorizedKeyCommand(for: publicKey)
    }
}
