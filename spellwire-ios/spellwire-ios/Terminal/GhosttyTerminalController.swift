import Foundation
import UIKit

@MainActor
final class GhosttyTerminalController {
    private let terminal: GhosttyTerminal
    private let renderState: GhosttyRenderState
    private let rowIterator: GhosttyRenderStateRowIterator
    private let rowCells: GhosttyRenderStateRowCells

    var onSnapshotChanged: ((TerminalSnapshot) -> Void)?
    var onWriteToPTY: ((Data) -> Void)?

    private(set) var snapshot: TerminalSnapshot = .empty
    private(set) var viewportColumns = 80
    private(set) var viewportRows = 24
    private var lastCellSize = CGSize(width: 9, height: 19)

    init?() {
        guard let terminal = ghostty_bridge_terminal_create(80, 24, 10_000),
              let renderState = ghostty_bridge_render_state_create(),
              let rowIterator = ghostty_bridge_row_iterator_create(),
              let rowCells = ghostty_bridge_row_cells_create()
        else {
            return nil
        }

        self.terminal = terminal
        self.renderState = renderState
        self.rowIterator = rowIterator
        self.rowCells = rowCells

        let background = GhosttyColorRgb(r: 12, g: 16, b: 24)
        let foreground = GhosttyColorRgb(r: 226, g: 232, b: 240)
        let cursor = GhosttyColorRgb(r: 255, g: 196, b: 77)
        _ = ghostty_bridge_terminal_set_userdata(terminal, Unmanaged.passUnretained(self).toOpaque())
        _ = ghostty_bridge_terminal_set_write_pty(terminal, ghosttyTerminalWritePtyCallback)
        ghostty_bridge_terminal_set_colors(terminal, background, foreground, cursor)
        refreshSnapshot()
    }

    deinit {
        ghostty_render_state_row_cells_free(rowCells)
        ghostty_render_state_row_iterator_free(rowIterator)
        ghostty_render_state_free(renderState)
        ghostty_terminal_free(terminal)
    }

    func ingest(_ data: Data) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            ghostty_terminal_vt_write(terminal, baseAddress, rawBuffer.count)
        }

        refreshSnapshot()
    }

    func resize(to viewSize: CGSize, cellSize: CGSize) {
        let width = max(cellSize.width, 1)
        let height = max(cellSize.height, 1)
        lastCellSize = cellSize

        let cols = max(Int(floor(viewSize.width / width)), 1)
        let rows = max(Int(floor(viewSize.height / height)), 1)
        guard cols != viewportColumns || rows != viewportRows else {
            return
        }

        viewportColumns = cols
        viewportRows = rows
        ghostty_terminal_resize(
            terminal,
            UInt16(cols),
            UInt16(rows),
            UInt32(max(1, Int(width))),
            UInt32(max(1, Int(height)))
        )
        ghostty_bridge_terminal_scroll_bottom(terminal)
        refreshSnapshot()
    }

    func scroll(delta: Int) {
        guard delta != 0 else { return }
        ghostty_bridge_terminal_scroll_delta(terminal, Int(delta))
        refreshSnapshot()
    }

    func scrollToBottom() {
        ghostty_bridge_terminal_scroll_bottom(terminal)
        refreshSnapshot()
    }

    func sizeForRemote() -> (cols: Int, rows: Int, pixelSize: CGSize) {
        (
            cols: viewportColumns,
            rows: viewportRows,
            pixelSize: CGSize(
                width: CGFloat(viewportColumns) * lastCellSize.width,
                height: CGFloat(viewportRows) * lastCellSize.height
            )
        )
    }

    private func refreshSnapshot() {
        guard ghostty_render_state_update(renderState, terminal) == GHOSTTY_SUCCESS else {
            return
        }

        var colors = GhosttyRenderStateColors()
        guard ghostty_bridge_render_state_colors(renderState, &colors) == GHOSTTY_SUCCESS else {
            return
        }

        var iterator = rowIterator
        guard ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator) == GHOSTTY_SUCCESS else {
            return
        }

        var rowSnapshots: [[TerminalSnapshot.Cell]] = []
        var columns = 0
        while ghostty_render_state_row_iterator_next(iterator) {
            var cellsHandle = rowCells
            guard ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cellsHandle) == GHOSTTY_SUCCESS else {
                continue
            }

            var row: [TerminalSnapshot.Cell] = []
            while ghostty_render_state_row_cells_next(cellsHandle) {
                var style = GhosttyStyle()
                style.size = MemoryLayout<GhosttyStyle>.size
                _ = ghostty_render_state_row_cells_get(cellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)

                let fg = resolvedColor(for: cellsHandle, key: GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, fallback: colors.foreground)
                let bg = resolvedColor(for: cellsHandle, key: GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, fallback: colors.background)
                let text = graphemeString(for: cellsHandle)
                row.append(
                    .init(
                        text: text.isEmpty ? " " : text,
                        foreground: UIColor(rgb: fg),
                        background: UIColor(rgb: bg),
                        bold: style.bold,
                        underline: style.underline != 0
                    )
                )
            }

            columns = max(columns, row.count)
            rowSnapshots.append(row)
        }

        let cursor = makeCursor(colors: colors)
        snapshot = TerminalSnapshot(
            columns: columns,
            rows: rowSnapshots,
            background: UIColor(rgb: colors.background),
            foreground: UIColor(rgb: colors.foreground),
            cursor: cursor
        )
        onSnapshotChanged?(snapshot)
    }

    private func graphemeString(for cells: GhosttyRenderStateRowCells?) -> String {
        var graphemeLength: UInt32 = 0
        guard ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &graphemeLength) == GHOSTTY_SUCCESS,
              graphemeLength > 0
        else {
            return ""
        }

        var buffer = Array(repeating: UInt32.zero, count: Int(graphemeLength))
        buffer.withUnsafeMutableBufferPointer { pointer in
            _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, pointer.baseAddress)
        }

        let scalars = buffer.compactMap(UnicodeScalar.init)
        return String(String.UnicodeScalarView(scalars))
    }

    private func resolvedColor(for cells: GhosttyRenderStateRowCells?, key: GhosttyRenderStateRowCellsData, fallback: GhosttyColorRgb) -> GhosttyColorRgb {
        var color = GhosttyColorRgb()
        return ghostty_render_state_row_cells_get(cells, key, &color) == GHOSTTY_SUCCESS ? color : fallback
    }

    private func makeCursor(colors: GhosttyRenderStateColors) -> TerminalSnapshot.Cursor? {
        var visible = false
        var inViewport = false
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible)
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &inViewport)
        guard visible, inViewport else { return nil }

        var x: UInt16 = 0
        var y: UInt16 = 0
        var style = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &x)
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &y)
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &style)

        let mappedStyle: TerminalSnapshot.Cursor.Style
        switch style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
            mappedStyle = .bar
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
            mappedStyle = .underline
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
            mappedStyle = .hollowBlock
        default:
            mappedStyle = .block
        }

        let cursorColor = colors.cursor_has_value ? UIColor(rgb: colors.cursor) : UIColor(red: 1, green: 0.77, blue: 0.3, alpha: 1)
        return .init(x: Int(x), y: Int(y), style: mappedStyle, color: cursorColor)
    }
}

private let ghosttyTerminalWritePtyCallback: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = { _, userdata, bytes, count in
    guard let userdata,
          let bytes,
          count > 0
    else {
        return
    }

    let controller = Unmanaged<GhosttyTerminalController>.fromOpaque(userdata).takeUnretainedValue()
    controller.onWriteToPTY?(Data(bytes: bytes, count: count))
}

private extension UIColor {
    convenience init(rgb: GhosttyColorRgb) {
        self.init(
            red: CGFloat(rgb.r) / 255,
            green: CGFloat(rgb.g) / 255,
            blue: CGFloat(rgb.b) / 255,
            alpha: 1
        )
    }
}
