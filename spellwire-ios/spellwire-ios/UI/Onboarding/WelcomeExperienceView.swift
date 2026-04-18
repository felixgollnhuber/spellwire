import SwiftUI
import UIKit

private enum HostSetupField: Hashable {
    case host
    case port
    case username
}

struct WelcomeExperienceView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var draft = HostEditorDraft()
    @State private var connectionProbe = HostConnectionProbe()
    @State private var isFinishingSetup = false
    @State private var errorMessage: String?
    @State private var shareItems: [Any] = []
    @FocusState private var focusedField: HostSetupField?

    var body: some View {
        NavigationStack {
            welcomeScreen
        }
        .alert(
            "Trust Host Key",
            isPresented: Binding(
                get: { connectionProbe.pendingHostKeyChallenge != nil },
                set: { if !$0 { connectionProbe.resolveHostKeyChallenge(approved: false) } }
            ),
            presenting: connectionProbe.pendingHostKeyChallenge
        ) { _ in
            Button("Reject", role: .cancel) {
                connectionProbe.resolveHostKeyChallenge(approved: false)
            }
            Button("Trust") {
                connectionProbe.resolveHostKeyChallenge(approved: true)
            }
        } message: { challenge in
            Text("\(challenge.hostLabel)\n\(challenge.fingerprint)")
        }
        .onChange(of: connectionProbe.state) { _, newState in
            handleConnectionStateChange(newState)
        }
        .onChange(of: draft.hostname) { _, _ in
            resetApprovedTrust()
        }
        .onChange(of: draft.port) { _, _ in
            resetApprovedTrust()
        }
        .onDisappear {
            connectionProbe.disconnect()
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

    private var welcomeScreen: some View {
        SpellwireWelcomeScaffold(isCompact: false, pinsContentToBottom: true) {
            welcomeContent
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            WelcomeAppIcon()
                .spellwireBlurRiseOnAppear()

            VStack(alignment: .leading, spacing: 10) {
                Text("Spellwire keeps your Codex Mac one tap away.")
                    .font(.spellwireDisplay(35))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Pair your iPhone with a Mac over SSH, pin the host key, and keep the same local Codex workspace in reach.")
                    .font(.spellwireBody(17))
                    .foregroundStyle(SpellwirePalette.secondaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .spellwireBlurRiseOnAppear()

            SpellwireActionNavigationLink(
                destination: setupScreen,
                variant: .secondary,
                size: .xl,
                fullWidth: true
            ) {
                HStack(spacing: 12) {
                    Text("Set Up Your Mac")
                    Image(systemName: "arrow.right")
                }
                .frame(maxWidth: .infinity)
            }
            .spellwireBlurRiseOnAppear()
        }
    }

    private var setupScreen: some View {
        ZStack {
            SpellwireWelcomeScaffold(isCompact: focusedField != nil, pinsContentToBottom: false) {
                setupContent
            }

            if isFinishingSetup {
                WelcomeSuccessOverlay(hostname: draft.hostname.trimmingCharacters(in: .whitespacesAndNewlines))
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.24), value: focusedField != nil)
        .navigationTitle("Set Up Your Mac")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var setupContent: some View {
        VStack(alignment: .leading, spacing: 18) {

            VStack(alignment: .leading, spacing: 8) {
                Text("Connect your Mac")
                    .font(.spellwireDisplay(focusedField == nil ? 34 : 28))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Enter the SSH host, port, and username. Spellwire uses one Ed25519 key, pins the host fingerprint, and then opens the workspace.")
                    .font(.spellwireBody(16))
                    .foregroundStyle(SpellwirePalette.secondaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .spellwireBlurRiseOnAppear()

            SpellwireGlassPanel {
                VStack(spacing: 0) {
                    HostSetupRow(
                        title: "Host",
                        symbol: "server.rack",
                        text: $draft.hostname,
                        keyboardType: .URL,
                        textContentType: .URL,
                        submitLabel: .next,
                        focusedField: $focusedField,
                        field: .host,
                        isSecure: false
                    )

                    WelcomeFieldDivider()

                    HostSetupRow(
                        title: "Port",
                        symbol: "number",
                        text: $draft.port,
                        keyboardType: .numberPad,
                        textContentType: nil,
                        submitLabel: .next,
                        focusedField: $focusedField,
                        field: .port,
                        isSecure: false
                    )

                    WelcomeFieldDivider()

                    HostSetupRow(
                        title: "User",
                        symbol: "person.crop.circle",
                        text: $draft.username,
                        keyboardType: .default,
                        textContentType: .username,
                        submitLabel: .next,
                        focusedField: $focusedField,
                        field: .username,
                        isSecure: false
                    )

                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("1. Enable Remote Login on your Mac.")
                    Text("2. Install the helper from npm and run `spellwire up`.")
                    Text("3. Run the setup command on your Mac, or add this public key manually.")
                }
                .font(.spellwireBody(14, weight: .medium))
                .foregroundStyle(SpellwirePalette.secondaryForeground)

                Text(appModel.publicKeyOpenSSH)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                HStack(spacing: 12) {
                    SpellwireActionButton(variant: .secondary, size: .md) {
                        UIPasteboard.general.string = appModel.publicKeyOpenSSH
                    } label: {
                        Label("Copy Key", systemImage: "doc.on.doc")
                    }

                    SpellwireActionButton(variant: .secondary, size: .md) {
                        shareItems = [authorizedKeysInstallCommand]
                    } label: {
                        Label("Share Command", systemImage: "square.and.arrow.up")
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.spellwireBody(14, weight: .medium))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let status = statusCopy {
                    Label(status.title, systemImage: status.symbol)
                        .font(.spellwireBody(14, weight: .medium))
                        .foregroundStyle(status.color)
                }
            }
            .spellwireBlurRiseOnAppear()

            SpellwireActionButton(
                variant: .primary,
                size: .xl,
                fullWidth: true,
                isLoading: connectionProbe.state == .connecting || connectionProbe.state == .trustPrompt,
                action: connect
            ) {
                HStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                    Text(primaryButtonTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(isPrimaryButtonDisabled)
            .spellwireBlurRiseOnAppear()
        }
    }

    private var primaryButtonTitle: String {
        switch connectionProbe.state {
        case .trustPrompt:
            return "Confirm Host Key"
        case .connecting:
            return "Connecting"
        default:
            return "Connect to Mac"
        }
    }

    private var isPrimaryButtonDisabled: Bool {
        isFinishingSetup || connectionProbe.state == .connecting || connectionProbe.state == .trustPrompt
    }

    private var statusCopy: (title: String, symbol: String, color: Color)? {
        switch connectionProbe.state {
        case .idle:
            return nil
        case .connecting:
            return ("Opening SSH session...", "bolt.horizontal.circle.fill", SpellwirePalette.accent)
        case .trustPrompt:
            return ("Approve the pinned host fingerprint to continue.", "checkmark.shield.fill", SpellwirePalette.accent)
        case .connected:
            return ("Connected. Finishing setup...", "checkmark.circle.fill", SpellwirePalette.accentSuccess)
        case .reconnecting:
            return ("Reconnecting...", "bolt.horizontal.circle.fill", SpellwirePalette.accent)
        case .disconnected:
            return nil
        case .failed:
            return nil
        }
    }

    private var authorizedKeysInstallCommand: String {
        SSHSetupCommand.installAuthorizedKeyCommand(for: appModel.publicKeyOpenSSH)
    }

    private func connect() {
        errorMessage = nil
        focusedField = nil

        do {
            let host = try appModel.validatedHostRecord(from: draft)
            connectionProbe.connect(host: host, identity: appModel.sshIdentity)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleConnectionStateChange(_ state: TerminalConnectionState) {
        switch state {
        case .connected:
            finishSetup()
        case .failed(let message):
            isFinishingSetup = false
            errorMessage = message
        default:
            break
        }
    }

    private func finishSetup() {
        guard !isFinishingSetup else { return }

        isFinishingSetup = true
        errorMessage = nil

        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 220 : 1100))

            let approvedTrust = connectionProbe.approvedHostTrust
            connectionProbe.disconnect()

            do {
                let savedHost = try appModel.saveHost(from: draft, existingID: nil)
                if let approvedTrust {
                    try appModel.trustStore.saveTrust(
                        TrustedHost(
                            hostID: savedHost.id,
                            openSSHKey: approvedTrust.openSSHKey,
                            fingerprintSHA256: approvedTrust.fingerprintSHA256,
                            approvedAt: .now
                        )
                    )
                }
            } catch {
                isFinishingSetup = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func resetApprovedTrust() {
        guard connectionProbe.state != .connecting, connectionProbe.state != .trustPrompt else { return }
        connectionProbe.resetApprovedTrust()
    }
}

private struct SpellwireWelcomeScaffold<BottomContent: View>: View {
    let isCompact: Bool
    let pinsContentToBottom: Bool
    @ViewBuilder let bottomContent: BottomContent

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: isCompact ? 18 : 24) {
                if pinsContentToBottom {
                    Spacer(minLength: 0)
                }

                bottomContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .padding(.top, max(24, proxy.safeAreaInsets.top + 12))
            .padding(.bottom, 28)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: pinsContentToBottom ? .bottom : .top
            )
        }
        .spellwireCanvas()
    }
}

private struct WelcomeAppIcon: View {
    var body: some View {
        Image("icon_dark_nobg")
            .resizable()
            .scaledToFit()
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct HostSetupRow: View {
    let title: String
    let symbol: String
    @Binding var text: String
    let keyboardType: UIKeyboardType
    let textContentType: UITextContentType?
    let submitLabel: SubmitLabel
    var focusedField: FocusState<HostSetupField?>.Binding
    let field: HostSetupField
    let isSecure: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 22)
                .foregroundStyle(SpellwirePalette.accent)

            Group {
                if isSecure {
                    SecureField(title, text: $text)
                } else {
                    TextField(title, text: $text)
                }
            }
            .textInputAutocapitalization(.never)
            .keyboardType(keyboardType)
            .textContentType(textContentType)
            .submitLabel(submitLabel)
            .autocorrectionDisabled()
            .focused(focusedField, equals: field)
            .onSubmit {
                moveToNextField()
            }
        }
        .font(.spellwireBody(17, weight: .medium))
        .padding(.vertical, 16)
    }

    private func moveToNextField() {
        switch field {
        case .host:
            focusedField.wrappedValue = .port
        case .port:
            focusedField.wrappedValue = .username
        case .username:
            focusedField.wrappedValue = nil
        }
    }
}

private struct WelcomeFieldDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(height: 1)
    }
}

private struct WelcomeSuccessOverlay: View {
    let hostname: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animateCheckmark = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()

            SpellwireGlassPanel {
                VStack(spacing: 18) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 112, height: 112)
                        .background(Color.white.opacity(0.10), in: Circle())
                        .glassEffect(.regular.tint(SpellwirePalette.accentSuccess).interactive(), in: .circle)
                        .symbolEffect(.bounce, value: animateCheckmark)

                    VStack(spacing: 8) {
                        Text("Connection Ready")
                            .font(.spellwireDisplay(28))
                        Text("Signed in to \(hostname.isEmpty ? "your Mac" : hostname). Opening Spellwire now.")
                            .font(.spellwireBody(16))
                            .foregroundStyle(SpellwirePalette.secondaryForeground)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 340)
            .padding(.horizontal, 24)
        }
        .task {
            guard !reduceMotion else { return }
            animateCheckmark.toggle()
        }
    }
}

#Preview("Welcome") {
    WelcomeExperienceView()
        .environment(AppModel())
}
