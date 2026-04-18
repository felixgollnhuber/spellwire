import UIKit

struct TerminalSnapshot {
    struct Cell {
        var text: String
        var foreground: UIColor
        var background: UIColor
        var bold: Bool
        var underline: Bool
    }

    struct Cursor {
        enum Style {
            case block
            case bar
            case underline
            case hollowBlock
        }

        var x: Int
        var y: Int
        var style: Style
        var color: UIColor
    }

    var columns: Int
    var rows: [[Cell]]
    var background: UIColor
    var foreground: UIColor
    var cursor: Cursor?

    static let empty = TerminalSnapshot(
        columns: 0,
        rows: [],
        background: UIColor(red: 0.05, green: 0.07, blue: 0.1, alpha: 1),
        foreground: UIColor(red: 0.88, green: 0.91, blue: 0.95, alpha: 1),
        cursor: nil
    )
}
