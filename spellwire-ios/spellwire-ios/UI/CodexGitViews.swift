import SwiftUI

struct GitDiffCountsLabel: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("+\(additions)")
                .foregroundStyle(Color.green)
            Text("-\(deletions)")
                .foregroundStyle(Color.red)
        }
        .font(.caption.weight(.semibold))
        .monospacedDigit()
    }
}

struct ThreadGitDiffPillButton: View {
    let status: CodexGitStatus
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GitDiffCountsLabel(additions: status.additions, deletions: status.deletions)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.001))
                    .glassEffect(.regular.tint(.blue.opacity(0.18)).interactive(), in: .capsule)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
    }
}

struct ThreadGitInlineActionRow: View {
    let status: CodexGitStatus
    let isCommitLoading: Bool
    let onOpenDiff: () -> Void
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpenDiff) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text("Diff")
                    GitDiffCountsLabel(additions: status.additions, deletions: status.deletions)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(buttonBackground)
            }
            .buttonStyle(.plain)

            Button(action: onCommit) {
                HStack(spacing: 8) {
                    Image(systemName: isCommitLoading ? "hourglass" : "square.and.arrow.up")
                    Text("Commit & Push")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(buttonBackground)
            }
            .buttonStyle(.plain)
            .disabled(isCommitLoading)
        }
        .font(.body.monospaced())
        .foregroundStyle(.white)
    }

    private var buttonBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
    }
}

struct CodexGitDiffView: View {
    let service: CodexService
    let thread: CodexThreadSummary

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if service.isLoadingGitDiff && currentDiff == nil {
                ProgressView("Loading diff…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diff = currentDiff {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        diffHeader(diff)

                        ForEach(diff.files) { file in
                            GitDiffFileSection(file: file)
                        }
                    }
                    .padding(16)
                }
                .background(Color.black.ignoresSafeArea())
            } else {
                ContentUnavailableView(
                    "No Diff Available",
                    systemImage: "doc.text",
                    description: Text("Open the thread again or refresh Git status.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
            }
        }
        .navigationTitle("Diff")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .task {
            await service.loadGitDiff(force: currentDiff == nil, reportErrors: true)
        }
        .refreshable {
            await service.loadGitDiff(force: true, reportErrors: true)
        }
    }

    private var currentDiff: CodexGitDiff? {
        guard service.selectedThread?.id == thread.id else { return nil }
        return service.selectedThreadGitDiff
    }

    @ViewBuilder
    private func diffHeader(_ diff: CodexGitDiff) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(diff.branch ?? currentStatus?.branch ?? "No Branch")
                .font(.headline)
                .foregroundStyle(.white)

            Text(diff.cwd)
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.58))
                .textSelection(.enabled)

            GitDiffCountsLabel(additions: diff.additions, deletions: diff.deletions)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }
        )
    }

    private var currentStatus: CodexGitStatus? {
        guard service.selectedThread?.id == thread.id else { return nil }
        return service.selectedThreadGitStatus
    }
}

private struct GitDiffFileSection: View {
    let file: GitDiffFile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(file.path)
                        .font(.body.monospaced())
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                    Spacer(minLength: 12)
                    GitDiffCountsLabel(additions: file.additions, deletions: file.deletions)
                }

                Text(file.status.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.56))
            }
            .padding(12)
            .background(Color.white.opacity(0.05))

            if file.isBinary {
                Text("Binary file")
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(12)
            } else {
                VStack(spacing: 0) {
                    ForEach(file.hunks) { hunk in
                        ForEach(hunk.lines) { line in
                            GitDiffLineRow(line: line)
                        }
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct GitDiffLineRow: View {
    let line: GitDiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(spacing: 4) {
                Text(oldLineText)
                Text(newLineText)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.42))
            .frame(width: 58, alignment: .trailing)

            Text(line.text)
                .font(.caption.monospaced())
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(backgroundColor)
    }

    private var oldLineText: String {
        line.oldLineNumber.map(String.init) ?? ""
    }

    private var newLineText: String {
        line.newLineNumber.map(String.init) ?? ""
    }

    private var foregroundColor: Color {
        switch line.kind {
        case "addition":
            return .green.opacity(0.92)
        case "deletion":
            return .red.opacity(0.92)
        case "hunk":
            return .blue.opacity(0.9)
        case "meta":
            return .white.opacity(0.58)
        default:
            return .white.opacity(0.84)
        }
    }

    private var backgroundColor: Color {
        switch line.kind {
        case "addition":
            return Color.green.opacity(0.10)
        case "deletion":
            return Color.red.opacity(0.10)
        case "hunk":
            return Color.blue.opacity(0.14)
        default:
            return Color.clear
        }
    }
}

struct CodexGitCommitSheet: View {
    let service: CodexService
    let thread: CodexThreadSummary

    @Environment(\.dismiss) private var dismiss
    @State private var commitMessageDraft = ""
    @State private var didHydrateDraft = false

    var body: some View {
        Group {
            if service.isLoadingGitCommitPreview && currentPreview == nil {
                ProgressView("Preparing commit…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let preview = currentPreview {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(preview)

                        if let warning = CodexGitPresentation.branchWarning(preview: preview) {
                            warningBanner(warning)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Commit Message")
                                .font(.headline)
                                .foregroundStyle(.white)

                            TextField("", text: $commitMessageDraft, axis: .vertical)
                                .lineLimit(2...5)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.white.opacity(0.06))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                                        }
                                )
                                .foregroundStyle(.white)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(preview.actions) { action in
                                Button {
                                    Task {
                                        await submit(action: action, preview: preview)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(action.title)
                                                .foregroundStyle(.white)
                                            Spacer()
                                            if service.isExecutingGitCommit {
                                                ProgressView()
                                                    .controlSize(.small)
                                            }
                                        }

                                        if let reason = action.reason, !action.enabled {
                                            Text(reason)
                                                .font(.caption)
                                                .foregroundStyle(.white.opacity(0.56))
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                                    .background(actionBackground(enabled: action.enabled))
                                }
                                .buttonStyle(.plain)
                                .disabled(!action.enabled || service.isExecutingGitCommit)
                            }
                        }
                    }
                    .padding(16)
                }
                .background(Color.black.ignoresSafeArea())
            } else {
                ContentUnavailableView(
                    "No Commit Available",
                    systemImage: "square.and.arrow.up",
                    description: Text("The helper could not prepare a commit for this thread.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
            }
        }
        .navigationTitle("Commit & Push")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") {
                    dismiss()
                }
            }
        }
        .task {
            await service.loadGitCommitPreview(force: currentPreview == nil, reportErrors: true)
            hydrateDraftIfNeeded()
        }
        .onChange(of: currentPreview?.defaultCommitMessage) { _, _ in
            hydrateDraftIfNeeded()
        }
    }

    private var currentPreview: GitCommitPreview? {
        guard service.selectedThread?.id == thread.id else { return nil }
        return service.selectedThreadGitCommitPreview
    }

    private func header(_ preview: GitCommitPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(preview.branch ?? "No Branch")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(preview.pushRemote ?? "No origin remote")
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.58))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func warningBanner(_ warning: String) -> some View {
        Text(warning)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.yellow)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.yellow.opacity(0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.yellow.opacity(0.26), lineWidth: 1)
                    }
            )
    }

    private func actionBackground(enabled: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(enabled ? Color.white.opacity(0.06) : Color.white.opacity(0.03))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(enabled ? 0.08 : 0.04), lineWidth: 1)
            }
    }

    private func hydrateDraftIfNeeded() {
        guard let preview = currentPreview else { return }
        guard !didHydrateDraft || commitMessageDraft.isEmpty else { return }
        commitMessageDraft = preview.defaultCommitMessage
        didHydrateDraft = true
    }

    @MainActor
    private func submit(action: GitCommitAction, preview: GitCommitPreview) async {
        let result = await service.executeGitCommit(
            action: action.id,
            commitMessage: commitMessageDraft,
            prTitle: preview.defaultPRTitle,
            prBody: preview.defaultPRBody
        )
        if result != nil {
            dismiss()
        }
    }
}
