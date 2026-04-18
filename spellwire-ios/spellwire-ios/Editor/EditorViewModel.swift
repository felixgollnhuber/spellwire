import Foundation
import Observation

@MainActor
@Observable
final class EditorViewModel {
    let title: String

    var text = ""
    var session: OpenDocumentSession?
    var isLoading = true
    var isSaving = false
    var errorMessage: String?
    var hasConflict = false
    var shareURL: URL?

    private let browser: BrowserViewModel
    private let remotePath: String
    private var persistTask: Task<Void, Never>?

    init(browser: BrowserViewModel, remotePath: String, title: String) {
        self.browser = browser
        self.remotePath = remotePath
        self.title = title
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
        } catch RemoteFileError.conflict {
            hasConflict = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    func overwriteRemote() async {
        guard let session else { return }
        hasConflict = false
        isSaving = true
        do {
            self.session = try await browser.saveTextDocument(session: session, text: text, overwriteRemote: true)
        } catch {
            errorMessage = error.localizedDescription
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
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
