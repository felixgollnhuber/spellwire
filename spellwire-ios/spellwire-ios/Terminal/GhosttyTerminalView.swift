import SwiftUI
import UIKit

protocol TerminalCanvasViewDelegate: AnyObject {
    func terminalCanvasView(_ view: TerminalCanvasView, didInput data: Data)
    func terminalCanvasViewDidRequestArrowUp(_ view: TerminalCanvasView)
    func terminalCanvasViewDidRequestArrowDown(_ view: TerminalCanvasView)
    func terminalCanvasViewDidRequestArrowLeft(_ view: TerminalCanvasView)
    func terminalCanvasViewDidRequestArrowRight(_ view: TerminalCanvasView)
    func terminalCanvasViewDidRequestEscape(_ view: TerminalCanvasView)
    func terminalCanvasViewDidRequestTab(_ view: TerminalCanvasView)
    func terminalCanvasViewDidRequestReturn(_ view: TerminalCanvasView)
    func terminalCanvasViewDidRequestBackspace(_ view: TerminalCanvasView)
    func terminalCanvasView(_ view: TerminalCanvasView, didScrollLines delta: Int)
}

final class GhosttyTerminalViewController: UIViewController {
    private let session: TerminalSessionCoordinator
    private let canvasView = TerminalCanvasView()

    init(session: TerminalSessionCoordinator) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = canvasView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        canvasView.delegate = self
        session.terminal.onSnapshotChanged = { [weak self] snapshot in
            self?.canvasView.snapshot = snapshot
        }
        canvasView.snapshot = session.terminal.snapshot
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        canvasView.becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        session.updateViewport(viewSize: view.bounds.size, cellSize: canvasView.cellSize)
    }
}

extension GhosttyTerminalViewController: TerminalCanvasViewDelegate {
    func terminalCanvasView(_ view: TerminalCanvasView, didInput data: Data) {
        session.send(data)
    }

    func terminalCanvasViewDidRequestArrowUp(_ view: TerminalCanvasView) {
        session.sendArrowUp()
    }

    func terminalCanvasViewDidRequestArrowDown(_ view: TerminalCanvasView) {
        session.sendArrowDown()
    }

    func terminalCanvasViewDidRequestArrowLeft(_ view: TerminalCanvasView) {
        session.sendArrowLeft()
    }

    func terminalCanvasViewDidRequestArrowRight(_ view: TerminalCanvasView) {
        session.sendArrowRight()
    }

    func terminalCanvasViewDidRequestEscape(_ view: TerminalCanvasView) {
        session.sendEscape()
    }

    func terminalCanvasViewDidRequestTab(_ view: TerminalCanvasView) {
        session.sendTab()
    }

    func terminalCanvasViewDidRequestReturn(_ view: TerminalCanvasView) {
        session.sendReturn()
    }

    func terminalCanvasViewDidRequestBackspace(_ view: TerminalCanvasView) {
        session.sendBackspace()
    }

    func terminalCanvasView(_ view: TerminalCanvasView, didScrollLines delta: Int) {
        session.scroll(delta: delta)
    }
}

struct GhosttyTerminalView: UIViewControllerRepresentable {
    let session: TerminalSessionCoordinator

    func makeUIViewController(context: Context) -> GhosttyTerminalViewController {
        GhosttyTerminalViewController(session: session)
    }

    func updateUIViewController(_ uiViewController: GhosttyTerminalViewController, context: Context) {}
}

final class TerminalCanvasView: UIView, UIKeyInput {
    weak var delegate: TerminalCanvasViewDelegate?

    var snapshot: TerminalSnapshot = .empty {
        didSet { setNeedsDisplay() }
    }

    private let regularFont = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    private let boldFont = UIFont.monospacedSystemFont(ofSize: 15, weight: .semibold)
    private var panAccumulator: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool { true }

    var hasText: Bool { false }

    var cellSize: CGSize {
        let width = ceil(("M" as NSString).size(withAttributes: [.font: regularFont]).width)
        let height = ceil(regularFont.lineHeight + 2)
        return CGSize(width: max(1, width), height: max(1, height))
    }

    override func draw(_ rect: CGRect) {
        snapshot.background.setFill()
        UIRectFill(bounds)

        let metrics = cellSize
        for (rowIndex, row) in snapshot.rows.enumerated() {
            for (columnIndex, cell) in row.enumerated() {
                let origin = CGPoint(x: CGFloat(columnIndex) * metrics.width, y: CGFloat(rowIndex) * metrics.height)
                let cellRect = CGRect(origin: origin, size: metrics)
                cell.background.setFill()
                UIRectFill(cellRect)

                let font = cell.bold ? boldFont : regularFont
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: cell.foreground,
                ]
                let textRect = cellRect.insetBy(dx: 1, dy: 1)
                (cell.text as NSString).draw(in: textRect, withAttributes: attributes)

                if cell.underline {
                    let underlineRect = CGRect(
                        x: cellRect.minX + 1,
                        y: cellRect.maxY - 2,
                        width: max(0, cellRect.width - 2),
                        height: 1
                    )
                    cell.foreground.setFill()
                    UIRectFill(underlineRect)
                }
            }
        }

        drawCursor(with: metrics)
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(keyArrowUp)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(keyArrowDown)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(keyArrowLeft)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(keyArrowRight)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(keyEscape)),
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(keyTab)),
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(keyReturn)),
            UIKeyCommand(input: "C", modifierFlags: .control, action: #selector(keyControlC)),
            UIKeyCommand(input: "D", modifierFlags: .control, action: #selector(keyControlD)),
            UIKeyCommand(input: "L", modifierFlags: .control, action: #selector(keyControlL)),
        ]
    }

    func insertText(_ text: String) {
        delegate?.terminalCanvasView(self, didInput: Data(text.utf8))
    }

    func deleteBackward() {
        delegate?.terminalCanvasViewDidRequestBackspace(self)
    }

    @objc private func handleTap() {
        becomeFirstResponder()
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self).y
        let delta = translation - panAccumulator
        let rows = Int(delta / max(cellSize.height, 1))
        if rows != 0 {
            delegate?.terminalCanvasView(self, didScrollLines: -rows)
            panAccumulator += CGFloat(rows) * cellSize.height
        }

        if recognizer.state == .ended || recognizer.state == .cancelled {
            panAccumulator = 0
        }
    }

    @objc private func keyArrowUp() { delegate?.terminalCanvasViewDidRequestArrowUp(self) }
    @objc private func keyArrowDown() { delegate?.terminalCanvasViewDidRequestArrowDown(self) }
    @objc private func keyArrowLeft() { delegate?.terminalCanvasViewDidRequestArrowLeft(self) }
    @objc private func keyArrowRight() { delegate?.terminalCanvasViewDidRequestArrowRight(self) }
    @objc private func keyEscape() { delegate?.terminalCanvasViewDidRequestEscape(self) }
    @objc private func keyTab() { delegate?.terminalCanvasViewDidRequestTab(self) }
    @objc private func keyReturn() { delegate?.terminalCanvasViewDidRequestReturn(self) }
    @objc private func keyControlC() { delegate?.terminalCanvasView(self, didInput: Data([0x03])) }
    @objc private func keyControlD() { delegate?.terminalCanvasView(self, didInput: Data([0x04])) }
    @objc private func keyControlL() { delegate?.terminalCanvasView(self, didInput: Data([0x0C])) }

    private func drawCursor(with metrics: CGSize) {
        guard let cursor = snapshot.cursor else { return }
        let rect = CGRect(
            x: CGFloat(cursor.x) * metrics.width,
            y: CGFloat(cursor.y) * metrics.height,
            width: metrics.width,
            height: metrics.height
        )

        switch cursor.style {
        case .block:
            cursor.color.withAlphaComponent(0.35).setFill()
            UIRectFill(rect)
        case .bar:
            cursor.color.setFill()
            UIRectFill(CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height))
        case .underline:
            cursor.color.setFill()
            UIRectFill(CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2))
        case .hollowBlock:
            let path = UIBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            cursor.color.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}
