import UIKit
import SwiftUI

struct HostEditorDraft: Equatable {
    var nickname = ""
    var hostname = ""
    var port = "22"
    var username = ""
    var browserURL = ""
    var browserUsesTunnel = false
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
    @State private var showingShareSheet = false

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
                    Toggle("Resume with tmux", isOn: $draft.useTmux)
                    if draft.useTmux {
                        TextField("tmux session", text: $draft.tmuxSessionName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section("Browser") {
                    TextField("URL", text: $draft.browserURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    Toggle("Use SSH tunnel", isOn: $draft.browserUsesTunnel)
                }

                Section("Spellwire Key") {
                    Text(publicKey)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)

                    Button("Copy Public Key") {
                        UIPasteboard.general.string = publicKey
                    }

                    Button("Share Public Key") {
                        showingShareSheet = true
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
            .sheet(isPresented: $showingShareSheet) {
                ActivityView(activityItems: [publicKey])
            }
        }
    }
}
