import XCTest
@testable import spellwire_ios

@MainActor
final class EditorViewModelTests: XCTestCase {
    func testSaveEmitsSuccess() async {
        let pair = HapticsClient.recording { _ in }
        let browser = FakeEditorBrowser(haptics: pair.client)
        let viewModel = EditorViewModel(browser: browser, remotePath: "/tmp/test.swift", title: "test.swift")
        viewModel.session = makeSession()
        viewModel.text = "print(\"hi\")"

        await viewModel.save()

        XCTAssertEqual(pair.recorder.events, [.success])
    }

    func testConflictEmitsWarning() async {
        let pair = HapticsClient.recording { _ in }
        let browser = FakeEditorBrowser(haptics: pair.client)
        browser.saveResult = .failure(RemoteFileError.conflict(expected: nil, current: nil))
        let viewModel = EditorViewModel(browser: browser, remotePath: "/tmp/test.swift", title: "test.swift")
        viewModel.session = makeSession()
        viewModel.text = "print(\"hi\")"

        await viewModel.save()

        XCTAssertTrue(viewModel.hasConflict)
        XCTAssertEqual(pair.recorder.events, [.warning])
    }

    func testReloadFailureEmitsError() async {
        let pair = HapticsClient.recording { _ in }
        let browser = FakeEditorBrowser(haptics: pair.client)
        browser.reloadResult = .failure(RemoteFileError.serverError("Nope"))
        let viewModel = EditorViewModel(browser: browser, remotePath: "/tmp/test.swift", title: "test.swift")

        await viewModel.reloadFromRemote()

        XCTAssertEqual(viewModel.errorMessage, "Nope")
        XCTAssertEqual(pair.recorder.events, [.error])
    }

    private func makeSession() -> OpenDocumentSession {
        OpenDocumentSession(
            id: UUID(),
            hostID: UUID(),
            remotePath: "/tmp/test.swift",
            localRelativePath: "test.swift",
            documentKind: .swift,
            lastKnownRevision: nil,
            dirty: false,
            lastOpenedAt: .now
        )
    }
}

@MainActor
private final class FakeEditorBrowser: EditorBrowserClient {
    let haptics: HapticsClient
    var saveResult: Result<OpenDocumentSession, Error>
    var reloadResult: Result<OpenedTextDocument, Error>

    init(haptics: HapticsClient) {
        self.haptics = haptics
        let session = OpenDocumentSession(
            id: UUID(),
            hostID: UUID(),
            remotePath: "/tmp/test.swift",
            localRelativePath: "test.swift",
            documentKind: .swift,
            lastKnownRevision: nil,
            dirty: false,
            lastOpenedAt: .now
        )
        saveResult = .success(session)
        reloadResult = .success(
            OpenedTextDocument(
                session: session,
                text: "print(\"ok\")",
                localURL: URL(fileURLWithPath: "/tmp/test.swift")
            )
        )
    }

    func updateWorkingCopy(text: String, session: OpenDocumentSession) async throws -> OpenDocumentSession {
        session
    }

    func saveTextDocument(
        session: OpenDocumentSession,
        text: String,
        overwriteRemote: Bool
    ) async throws -> OpenDocumentSession {
        try saveResult.get()
    }

    func reloadTextDocument(path: String) async throws -> OpenedTextDocument {
        try reloadResult.get()
    }
}
