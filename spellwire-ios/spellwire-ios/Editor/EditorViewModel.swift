import Foundation
import Observation

@MainActor
protocol EditorBrowserClient: AnyObject {
    var haptics: HapticsClient { get }
    func updateWorkingCopy(text: String, session: OpenDocumentSession) async throws -> OpenDocumentSession
    func saveTextDocument(
        session: OpenDocumentSession,
        text: String,
        overwriteRemote: Bool
    ) async throws -> OpenDocumentSession
    func reloadTextDocument(path: String) async throws -> OpenedTextDocument
}

@MainActor
@Observable
final class EditorViewModel {
    let title: String
    let syntaxLanguage: EditorSyntaxLanguage?
    let wrapsLines: Bool
    private let playsSuccessHapticOnLoad: Bool

    var text = ""
    var session: OpenDocumentSession?
    var isLoading = true
    var isSaving = false
    var errorMessage: String?
    var hasConflict = false
    var shareURL: URL?

    let browser: any EditorBrowserClient
    private let remotePath: String
    private var persistTask: Task<Void, Never>?

    var haptics: HapticsClient { browser.haptics }

    init(
        browser: any EditorBrowserClient,
        remotePath: String,
        title: String,
        playsSuccessHapticOnLoad: Bool = true
    ) {
        self.browser = browser
        self.remotePath = remotePath
        self.title = title
        self.syntaxLanguage = FileClassifier.syntaxLanguage(for: remotePath)
        self.wrapsLines = FileClassifier.prefersWrappedLines(for: remotePath)
        self.playsSuccessHapticOnLoad = playsSuccessHapticOnLoad
    }

    func loadIfNeeded() async {
        guard session == nil else { return }
        await reloadFromRemote()
    }

    func updateText(_ value: String) {
        text = value
        guard let session else { return }

        persistTask?.cancel()
        persistTask = Task { [browser, text = value] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let updatedSession = try? await browser.updateWorkingCopy(text: text, session: session)
            await MainActor.run {
                if let updatedSession {
                    self.session = updatedSession
                }
            }
        }
    }

    func save() async {
        guard let session else { return }
        isSaving = true
        errorMessage = nil
        do {
            self.session = try await browser.saveTextDocument(session: session, text: text, overwriteRemote: false)
            haptics.play(.success)
        } catch RemoteFileError.conflict {
            hasConflict = true
            haptics.play(.warning)
        } catch {
            errorMessage = error.localizedDescription
            haptics.play(.error)
        }
        isSaving = false
    }

    func overwriteRemote() async {
        guard let session else { return }
        hasConflict = false
        isSaving = true
        do {
            self.session = try await browser.saveTextDocument(session: session, text: text, overwriteRemote: true)
            haptics.play(.success)
        } catch {
            errorMessage = error.localizedDescription
            haptics.play(.error)
        }
        isSaving = false
    }

    func reloadFromRemote() async {
        isLoading = true
        errorMessage = nil
        do {
            let document = try await browser.reloadTextDocument(path: remotePath)
            text = document.text
            session = document.session
            shareURL = document.localURL
            if playsSuccessHapticOnLoad {
                haptics.play(.success)
            }
        } catch {
            errorMessage = error.localizedDescription
            haptics.play(.error)
        }
        isLoading = false
    }
}
