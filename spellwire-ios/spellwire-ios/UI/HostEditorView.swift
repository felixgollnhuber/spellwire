import SwiftUI

struct HostEditorDraft: Equatable {
    var nickname = ""
    var hostname = ""
    var port = "22"
    var username = ""
    var password = ""
    var browserURL = ""
    var browserUsesTunnel = false
    var useTmux = true
    var tmuxSessionName = "main"

    init() {}

    init(host: HostRecord?, password: String) {
        guard let host else {
            self.password = password
            return
        }

        nickname = host.nickname
        hostname = host.hostname
        port = String(host.port)
        username = host.username
        self.password = password
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

    let title: String
    let onSave: (HostEditorDraft) -> Void

    init(title: String, draft: HostEditorDraft, onSave: @escaping (HostEditorDraft) -> Void) {
        self.title = title
        _draft = State(initialValue: draft)
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
                    SecureField("Password", text: $draft.password)
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
                    TextField("URL", text: $draft.browserURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    Toggle("Use SSH tunnel", isOn: $draft.browserUsesTunnel)
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
        }
    }
}
