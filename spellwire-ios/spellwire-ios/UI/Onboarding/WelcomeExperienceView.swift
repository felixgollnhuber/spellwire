import SwiftUI
import UIKit

private enum WelcomeStep {
    case welcome
    case setup
}

private enum HostSetupField: Hashable {
    case host
    case port
    case username
}

struct WelcomeExperienceView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: WelcomeStep = .welcome
    @State private var draft = HostEditorDraft()
    @State private var connectionProbe = HostConnectionProbe()
    @State private var isFinishingSetup = false
    @State private var errorMessage: String?
    @State private var showingShareSheet = false
    @FocusState private var focusedField: HostSetupField?

    var body: some View {
        ZStack {
            SpellwireWelcomeScaffold(isCompact: focusedField != nil || step == .setup) {
                SpellwireHeroView(compact: focusedField != nil || step == .setup)
                    .spellwireBlurRiseOnAppear()
            } bottomContent: {
                Group {
                    switch step {
                    case .welcome:
                        welcomeContent
                    case .setup:
                        setupContent
                    }
                }
            }
            .animation(.spring(response: 0.52, dampingFraction: 0.88), value: step)
            .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.24), value: focusedField != nil)

            if isFinishingSetup {
                WelcomeSuccessOverlay(hostname: draft.hostname.trimmingCharacters(in: .whitespacesAndNewlines))
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                    .zIndex(1)
            }
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
        .sheet(isPresented: $showingShareSheet) {
            ActivityView(activityItems: [appModel.publicKeyOpenSSH])
        }
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                WelcomeBadge(title: "SSH-only", symbol: "point.3.connected.trianglepath.dotted")
                Text("Spellwire keeps your Codex Mac one tap away.")
                    .font(.spellwireDisplay(40))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Pair your iPhone with a Mac over SSH, pin the host key, and keep the same local Codex workspace in reach.")
                    .font(.spellwireBody(17))
                    .foregroundStyle(SpellwirePalette.secondaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .spellwireBlurRiseOnAppear()

            Button {
                withAnimation(.spring(response: 0.52, dampingFraction: 0.9)) {
                    step = .setup
                }
            } label: {
                HStack {
                    Text("Set Up Your Mac")
                    Image(systemName: "arrow.right")
                }
                .font(.spellwireBody(17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
            .buttonStyle(.glassProminent)
            .tint(SpellwirePalette.accent)
            .spellwireBlurRiseOnAppear()
        }
    }

    private var setupContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button {
                    focusedField = nil
                    withAnimation(.spring(response: 0.46, dampingFraction: 0.9)) {
                        step = .welcome
                    }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.glass)
                .font(.spellwireBody(14, weight: .medium))

                Spacer()

                WelcomeBadge(title: "Auto-connect", symbol: "bolt.horizontal.fill")
            }
            .spellwireBlurRiseOnAppear()

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
                    Text("3. Add this public key to `~/.ssh/authorized_keys`.")
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
                    Button("Copy Key") {
                        UIPasteboard.general.string = appModel.publicKeyOpenSSH
                    }
                    .buttonStyle(.glass)

                    Button("Share Key") {
                        showingShareSheet = true
                    }
                    .buttonStyle(.glass)
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

            Button(action: connect) {
                HStack(spacing: 10) {
                    if connectionProbe.state == .connecting || connectionProbe.state == .trustPrompt {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                    }

                    Text(primaryButtonTitle)
                }
                .font(.spellwireBody(17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
            .buttonStyle(.glassProminent)
            .tint(SpellwirePalette.accent)
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

private struct SpellwireWelcomeScaffold<Hero: View, BottomContent: View>: View {
    let isCompact: Bool
    @ViewBuilder let hero: Hero
    @ViewBuilder let bottomContent: BottomContent

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: isCompact ? 18 : 28) {
                Spacer(minLength: 0)

                hero
                    .frame(maxWidth: .infinity)
                    .frame(height: isCompact ? min(proxy.size.height * 0.28, 250) : min(proxy.size.height * 0.42, 360))

                bottomContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .spellwireCanvas()
    }
}

private struct SpellwireHeroView: View {
    let compact: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var floatPrimary = false
    @State private var floatSecondary = false
    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: 18) {
            ZStack {
                Circle()
                    .fill(SpellwirePalette.accent.opacity(0.16))
                    .frame(width: compact ? 190 : 240, height: compact ? 190 : 240)
                    .blur(radius: 24)
                    .offset(y: compact ? 0 : -8)

                RoundedRectangle(cornerRadius: 42, style: .continuous)
                    .fill(.white.opacity(0.10))
                    .frame(width: compact ? 260 : 300, height: compact ? 170 : 220)
                    .glassEffect(.regular, in: .rect(cornerRadius: 42))

                connectionBridge

                floatingNode(symbol: "desktopcomputer", title: "Mac")
                    .offset(x: compact ? -70 : -86, y: compact ? -12 : -20)
                    .offset(y: floatPrimary ? -6 : 8)

                floatingNode(symbol: "iphone", title: "iPhone")
                    .offset(x: compact ? 70 : 86, y: compact ? 16 : 26)
                    .offset(y: floatPrimary ? 8 : -6)

                statusChip(symbol: "terminal.fill", title: "Codex")
                    .offset(x: compact ? -86 : -112, y: compact ? 62 : 86)
                    .offset(x: floatSecondary ? -5 : 7, y: floatSecondary ? -4 : 6)

                statusChip(symbol: "checkmark.shield.fill", title: "Pinned")
                    .offset(x: compact ? 82 : 110, y: compact ? -62 : -82)
                    .offset(x: floatSecondary ? 6 : -5, y: floatSecondary ? 6 : -4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                floatPrimary.toggle()
            }
            withAnimation(.easeInOut(duration: 3.6).repeatForever(autoreverses: true)) {
                floatSecondary.toggle()
            }
        }
    }

    private var connectionBridge: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(SpellwirePalette.accent.opacity(0.16))
                .frame(width: compact ? 88 : 120, height: 12)
                .blur(radius: 10)

            Capsule(style: .continuous)
                .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [8, 7]))
                .foregroundStyle(SpellwirePalette.accentSoft)
                .frame(width: compact ? 92 : 126, height: 18)
                .rotationEffect(.degrees(floatPrimary ? 4 : -4))

            Image(systemName: "bolt.horizontal.fill")
                .font(.system(size: compact ? 18 : 22, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular.tint(SpellwirePalette.accent).interactive(), in: .capsule)
                .glassEffectID("spellwire-bolt", in: glassNamespace)
        }
    }

    private func floatingNode(symbol: String, title: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 24 : 28, weight: .semibold))
            Text(title)
                .font(.spellwireBody(compact ? 12 : 13, weight: .semibold))
        }
        .foregroundStyle(.white)
        .frame(width: compact ? 90 : 108, height: compact ? 90 : 108)
        .background(Color.white.opacity(0.08), in: Circle())
        .glassEffect(.regular.interactive(), in: .circle)
    }

    private func statusChip(symbol: String, title: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.spellwireBody(compact ? 12 : 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
            .glassEffect(.regular, in: .capsule)
    }
}

private struct WelcomeBadge: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.spellwireBody(13, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
            .glassEffect(.regular, in: .capsule)
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
