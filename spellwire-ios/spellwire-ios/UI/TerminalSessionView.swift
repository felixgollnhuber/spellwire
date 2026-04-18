import SwiftUI

struct TerminalSessionView: View {
    @State private var coordinator: TerminalSessionCoordinator

    init(
        host: HostRecord,
        identity: SSHDeviceIdentity,
        trustStore: HostTrustStore,
        context: TerminalSessionContext? = nil
    ) {
        _coordinator = State(initialValue: TerminalSessionCoordinator(host: host, identity: identity, trustStore: trustStore, context: context)!)
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            GhosttyTerminalView(session: coordinator)
                .background(Color.black)
            accessoryRow
        }
        .navigationTitle(coordinator.context.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            coordinator.connectIfNeeded()
        }
        .alert(
            "Trust Host Key",
            isPresented: Binding(
                get: { coordinator.pendingHostKeyChallenge != nil },
                set: { if !$0 { coordinator.resolveHostKeyChallenge(approved: false) } }
            ),
            presenting: coordinator.pendingHostKeyChallenge
        ) { _ in
            Button("Reject", role: .cancel) {
                coordinator.resolveHostKeyChallenge(approved: false)
            }
            Button("Trust") {
                coordinator.resolveHostKeyChallenge(approved: true)
            }
        } message: { challenge in
            Text("\(challenge.hostLabel)\n\(challenge.fingerprint)")
        }
        .onDisappear {
            coordinator.disconnect()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Label(coordinator.state.title, systemImage: coordinator.state == .connected ? "checkmark.circle.fill" : "bolt.horizontal.circle")
                .font(.caption.weight(.semibold))
            if let exitStatus = coordinator.exitStatus {
                Text("exit \(exitStatus)")
                    .font(.caption.monospacedDigit())
            }
            Spacer()
            Button("Reconnect") {
                coordinator.reconnect()
            }
            .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var accessoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                AccessoryButton("Esc") { coordinator.sendEscape() }
                AccessoryButton("Tab") { coordinator.sendTab() }
                AccessoryButton("Ctrl-C") { coordinator.sendControl("C") }
                AccessoryButton("Ctrl-D") { coordinator.sendControl("D") }
                AccessoryButton("←") { coordinator.sendArrowLeft() }
                AccessoryButton("↑") { coordinator.sendArrowUp() }
                AccessoryButton("↓") { coordinator.sendArrowDown() }
                AccessoryButton("→") { coordinator.sendArrowRight() }
                AccessoryButton("Paste") { coordinator.pasteFromClipboard() }
                AccessoryButton("Bottom") { coordinator.scrollToBottom() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color(uiColor: .systemBackground))
    }
}

private struct AccessoryButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .font(.caption.weight(.medium))
    }
}
