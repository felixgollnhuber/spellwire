import Runestone
import TreeSitterBashRunestone
import TreeSitterCSSRunestone
import TreeSitterHTMLRunestone
import TreeSitterJavaScriptRunestone
import TreeSitterJSONRunestone
import TreeSitterMarkdownRunestone
import TreeSitterPythonRunestone
import TreeSitterSQLRunestone
import TreeSitterSwiftRunestone
import TreeSitterTOMLRunestone
import TreeSitterTSXRunestone
import TreeSitterTypeScriptRunestone
import TreeSitterYAMLRunestone

extension EditorSyntaxLanguage {
    var runestoneLanguage: TreeSitterLanguage {
        switch self {
        case .bash:
            return .bash
        case .css:
            return .css
        case .html:
            return .html
        case .javaScript:
            return .javaScript
        case .jsx:
            return .jsx
        case .json:
            return .json
        case .markdown:
            return .markdown
        case .python:
            return .python
        case .sql:
            return .sql
        case .swift:
            return .swift
        case .toml:
            return .toml
        case .tsx:
            return .tsx
        case .typeScript:
            return .typeScript
        case .yaml:
            return .yaml
        }
    }
}
