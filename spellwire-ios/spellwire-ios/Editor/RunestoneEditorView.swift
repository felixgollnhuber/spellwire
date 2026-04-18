import Runestone
import SwiftUI
import UIKit

struct RunestoneEditorView: UIViewRepresentable {
    @Binding var text: String
    let language: EditorSyntaxLanguage?
    let wrapsLines: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> TextView {
        let textView = TextView()
        configure(textView, coordinator: context.coordinator)
        context.coordinator.applyState(to: textView, text: text, language: language)
        return textView
    }

    func updateUIView(_ uiView: TextView, context: Context) {
        context.coordinator.text = $text
        configure(uiView, coordinator: context.coordinator)
        context.coordinator.sync(textView: uiView, text: text, language: language)
    }

    private func configure(_ textView: TextView, coordinator: Coordinator) {
        textView.editorDelegate = coordinator
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.showLineNumbers = true
        textView.isLineWrappingEnabled = wrapsLines
        textView.backgroundColor = .secondarySystemBackground
    }

    final class Coordinator: NSObject, TextViewDelegate {
        var text: Binding<String>

        private var appliedText = ""
        private var appliedLanguage: EditorSyntaxLanguage?
        private var isApplyingState = false

        init(text: Binding<String>) {
            self.text = text
        }

        func sync(textView: TextView, text: String, language: EditorSyntaxLanguage?) {
            let needsLanguageRefresh = appliedLanguage != language
            let needsTextRefresh = textView.text != text
            guard needsLanguageRefresh || needsTextRefresh else { return }
            applyState(to: textView, text: text, language: language)
        }

        func applyState(to textView: TextView, text: String, language: EditorSyntaxLanguage?) {
            isApplyingState = true
            if let language {
                textView.setState(TextViewState(text: text, language: language.runestoneLanguage))
            } else {
                textView.setState(TextViewState(text: text))
            }
            appliedText = text
            appliedLanguage = language
            isApplyingState = false
        }

        func textViewDidChange(_ textView: TextView) {
            guard !isApplyingState else { return }
            let updatedText = textView.text
            appliedText = updatedText
            if text.wrappedValue != updatedText {
                text.wrappedValue = updatedText
            }
        }
    }
}
