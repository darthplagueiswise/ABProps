import SwiftUI
import UIKit

struct SourceJump: Equatable {
    let offset: Int
    let length: Int
    let serial: Int
}

/// True code editor: continuously editable UTF-8 XML, without folding arrays or cutting values.
/// UIKit/TextKit supplies native selection, keyboard shortcuts, copying and caret scrolling.
struct XMLSourceEditor: UIViewRepresentable {
    @Binding var text: String
    let jump: SourceJump?
    let fontSize: Double
    var onEdit: (String) -> Void

    func makeUIView(context: Context) -> SourceEditorHost {
        let host = SourceEditorHost()
        host.editor.delegate = context.coordinator
        host.editor.text = text
        host.setFontSize(CGFloat(fontSize))
        host.applySyntax()
        context.coordinator.host = host
        return host
    }

    func updateUIView(_ host: SourceEditorHost, context: Context) {
        context.coordinator.parent = self
        host.setFontSize(CGFloat(fontSize))
        if host.editor.text != text {
            let insertion = host.editor.selectedRange
            host.editor.text = text
            host.editor.selectedRange = NSRange(location: min(insertion.location, (text as NSString).length), length: 0)
            host.refreshLineStarts()
            host.applySyntax()
        }
        if let jump, context.coordinator.lastJump != jump {
            context.coordinator.lastJump = jump
            let length = (host.editor.text as NSString).length
            guard jump.offset >= 0, jump.offset + jump.length <= length else { return }
            host.editor.selectedRange = NSRange(location: jump.offset, length: jump.length)
            host.editor.scrollRangeToVisible(host.editor.selectedRange)
            host.gutter.setNeedsDisplay()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: XMLSourceEditor
        weak var host: SourceEditorHost?
        var lastJump: SourceJump?
        init(_ parent: XMLSourceEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            guard let host else { return }
            host.refreshLineStarts()
            host.applySyntax()
            parent.onEdit(textView.text)
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            host?.gutter.setNeedsDisplay()
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            host?.gutter.setNeedsDisplay()
        }
    }
}

final class SourceEditorHost: UIView {
    let editor = UITextView(frame: .zero)
    let gutter = SourceLineNumberGutter(frame: .zero)
    private var starts = [0]
    private let leftInset: CGFloat = 57
    var selectedFontSize: CGFloat = 12

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.060, green: 0.066, blue: 0.082, alpha: 1)
        editor.backgroundColor = .clear
        editor.textColor = UIColor(white: 0.91, alpha: 1)
        editor.tintColor = UIColor(red: 0.40, green: 0.72, blue: 1.00, alpha: 1)
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textContainerInset = UIEdgeInsets(top: 18, left: leftInset, bottom: 28, right: 18)
        editor.textContainer.lineFragmentPadding = 0
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        editor.smartInsertDeleteType = .no
        editor.autocorrectionType = .no
        editor.autocapitalizationType = .none
        editor.keyboardDismissMode = .interactive
        editor.alwaysBounceVertical = true
        editor.isScrollEnabled = true
        editor.spellCheckingType = .no
        editor.accessibilityLabel = "Editor de XML completo"
        addSubview(editor)
        gutter.backgroundColor = UIColor(red: 0.105, green: 0.115, blue: 0.135, alpha: 1)
        gutter.owner = self
        addSubview(gutter)
        refreshLineStarts()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        editor.frame = bounds
        gutter.frame = CGRect(x: 0, y: 0, width: leftInset - 12, height: bounds.height)
        gutter.setNeedsDisplay()
    }

    func setFontSize(_ size: CGFloat) {
        guard abs(size - selectedFontSize) > 0.01 else { return }
        selectedFontSize = size
        editor.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        gutter.setNeedsDisplay()
    }

    func refreshLineStarts() {
        let contents = editor.text as NSString
        let length = contents.length
        var indices: [Int] = [0]
        var cursor = 0
        while cursor < length {
            let line = contents.lineRange(for: NSRange(location: cursor, length: 0))
            let next = NSMaxRange(line)
            if next >= length { break }
            indices.append(next)
            cursor = next
        }
        starts = indices
        gutter.setNeedsDisplay()
    }

    func lineNumber(at offset: Int) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle + 1 }
            else { high = middle }
        }
        return max(1, low)
    }

    func isLineStart(_ offset: Int) -> Bool {
        let number = lineNumber(at: offset) - 1
        return starts.indices.contains(number) && starts[number] == offset
    }

    func applySyntax() {
        let storage = editor.textStorage
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        let baseColor = UIColor(red: 0.87, green: 0.89, blue: 0.93, alpha: 1)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: baseColor, range: full)
        func color(_ pattern: String, _ c: UIColor) {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
            for match in expression.matches(in: storage.string, range: full) {
                storage.addAttribute(.foregroundColor, value: c, range: match.range)
            }
        }
        color(#"</?[\w:-]+|/?>"#, UIColor(red: 0.95, green: 0.48, blue: 0.55, alpha: 1))
        color(#"<!--[\s\S]*?-->"#, UIColor(red: 0.48, green: 0.55, blue: 0.62, alpha: 1))
        color(#"(?<=<key>)[\s\S]*?(?=</key>)"#,
              UIColor(red: 0.52, green: 0.77, blue: 1.00, alpha: 1))
        color(#"(?<=<string>)[\s\S]*?(?=</string>)"#,
              UIColor(red: 0.83, green: 0.88, blue: 0.68, alpha: 1))
        color(#"(?<=<(?:integer|real)>)[\s\S]*?(?=</(?:integer|real)>)"#,
              UIColor(red: 0.90, green: 0.75, blue: 0.48, alpha: 1))
        storage.endEditing()
        gutter.setNeedsDisplay()
    }
}

final class SourceLineNumberGutter: UIView {
    weak var owner: SourceEditorHost?

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let owner, let context = UIGraphicsGetCurrentContext() else { return }
        let editor = owner.editor
        let manager = editor.layoutManager
        let area = editor.textContainer
        let visible = CGRect(
            x: 0,
            y: editor.contentOffset.y - editor.textContainerInset.top,
            width: editor.bounds.width,
            height: editor.bounds.height + 2 * editor.textContainerInset.top
        )
        let glyphs = manager.glyphRange(forBoundingRect: visible, in: area)
        context.saveGState()
        let font = UIFont.monospacedDigitSystemFont(ofSize: max(9, min(15, owner.selectedFontSize - 1)), weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(red: 0.58, green: 0.62, blue: 0.69, alpha: 1)
        ]
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, fragment, _ in
            let index = manager.characterIndexForGlyph(at: fragment.location)
            guard owner.isLineStart(index) else { return }
            let label = String(owner.lineNumber(at: index)) as NSString
            let size = label.size(withAttributes: attrs)
            let baseline = used.origin.y + editor.textContainerInset.top - editor.contentOffset.y
            let labelRect = CGRect(x: self.bounds.width - size.width - 8,
                                   y: baseline, width: size.width, height: size.height)
            if labelRect.intersects(self.bounds) {
                label.draw(in: labelRect, withAttributes: attrs)
            }
        }
        context.restoreGState()
    }
}
