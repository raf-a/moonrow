import AppKit
import SQLScript

/// Keys the completion list handles while it's showing.
@MainActor
protocol SQLTextViewCompletionDelegate: AnyObject {
    var isCompletionVisible: Bool { get }
    /// The user typed or deleted; refresh (or open, when `manual`) the list.
    func textViewNeedsCompletion(_ textView: SQLTextView, manual: Bool)
    func textViewMoveCompletion(by delta: Int)
    /// Returns false when nothing was selected.
    func textViewAcceptCompletion() -> Bool
    func textViewDismissCompletion()
}

/// The query editor's text view: plain text, monospaced, SQL-aware.
@MainActor
final class SQLTextView: NSTextView {
    weak var completionDelegate: SQLTextViewCompletionDelegate?
    var indent = "    "


    /// A TextKit 1 stack: line numbers and highlighting work on glyph ranges.
    static func make() -> SQLTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = SQLTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300), textContainer: container)
        view.configure()
        return view
    }

    /// The characters the last edit put in (UTF-16), for the highlighter: inserted text arrives
    /// uncoloured even where it reads the same as before.
    private(set) var lastEdit: Range<Int>?

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        let length = (replacementString as NSString?)?.length ?? 0
        lastEdit = affectedCharRange.location..<(affectedCharRange.location + length)
        return true
    }

    /// The last edit's range, once.
    func takeLastEdit() -> Range<Int>? {
        defer { lastEdit = nil }
        return lastEdit
    }

    /// The editor's own text undo; the window's undo manager holds the staged table changes.
    private let textUndo = UndoManager()
    override var undoManager: UndoManager? { textUndo }
    @objc func undo(_ sender: Any?) { textUndo.undo() }
    @objc func redo(_ sender: Any?) { textUndo.redo() }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        textUndo.validate(item) ?? super.validateMenuItem(item)
    }

    private func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        applyStyle()
        drawsBackground = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = NSSize(width: 4, height: 6)
        textContainer?.lineFragmentPadding = 4
    }

    /// Font and colours from the preferences. The caller re-highlights afterwards.
    func applyStyle() {
        let colors = AppStyle.colors
        font = AppStyle.editorFont
        typingAttributes = [.font: AppStyle.editorFont, .foregroundColor: colors.text]
        textColor = colors.text
        backgroundColor = colors.background
        insertionPointColor = colors.text
        selectedTextAttributes = [.backgroundColor: colors.selection]
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if let completion = completionDelegate, completion.isCompletionVisible {
            switch (event.keyCode, mods) {
            case (125, []): return completion.textViewMoveCompletion(by: 1)   // ↓
            case (126, []): return completion.textViewMoveCompletion(by: -1)  // ↑
            case (121, []): return completion.textViewMoveCompletion(by: 8)   // page down
            case (116, []): return completion.textViewMoveCompletion(by: -8)  // page up
            case (36, []), (76, []), (48, []):                                // Return, Enter, Tab
                if completion.textViewAcceptCompletion() { return }
            case (53, []):                                                     // Esc
                return completion.textViewDismissCompletion()
            case (123, _), (124, _), (115, _), (119, _):                       // ← → home end
                completion.textViewDismissCompletion()
            default: break
            }
        }
        if event.keyCode == 49, mods == .control {  // ⌃Space
            completionDelegate?.textViewNeedsCompletion(self, manual: true)
            return
        }
        super.keyDown(with: event)
    }

    /// ⌥Esc / F5, the system's "complete" binding.
    override func complete(_ sender: Any?) {
        completionDelegate?.textViewNeedsCompletion(self, manual: true)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        let s = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        guard let completion = completionDelegate else { return }
        if s.count == 1, let c = s.unicodeScalars.first,
           CharacterSet.alphanumerics.contains(c) || c == "_" || c == "." || c == "\"" || c == "`" {
            completion.textViewNeedsCompletion(self, manual: false)
        } else {
            completion.textViewDismissCompletion()
        }
    }

    override func deleteBackward(_ sender: Any?) {
        super.deleteBackward(sender)
        if let completion = completionDelegate, completion.isCompletionVisible {
            completion.textViewNeedsCompletion(self, manual: false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        completionDelegate?.textViewDismissCompletion()
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        completionDelegate?.textViewDismissCompletion()
        return super.resignFirstResponder()
    }

    /// Return keeps the current line's indentation.
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let caret = selectedRange().location
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        var end = lineStart
        while end < caret, let c = UnicodeScalar(text.character(at: end)), c == " " || c == "\t" { end += 1 }
        let leading = text.substring(with: NSRange(location: lineStart, length: end - lineStart))
        super.insertNewline(sender)
        if !leading.isEmpty { insertText(leading, replacementRange: selectedRange()) }
    }

    /// Tab indents with spaces; with several lines selected it indents them all.
    override func insertTab(_ sender: Any?) {
        if selectedRange().length > 0, (string as NSString).substring(with: selectedRange()).contains("\n") {
            return shiftLines(by: 1)
        }
        insertText(indent, replacementRange: selectedRange())
    }

    override func insertBacktab(_ sender: Any?) { shiftLines(by: -1) }

    private func shiftLines(by direction: Int) {
        editLines { line in
            if direction > 0 { return line.isEmpty ? line : indent + line }
            var drop = 0
            for c in line.prefix(indent.count) {
                if c == " " { drop += 1 } else { if c == "\t" { drop += 1 }; break }
            }
            return String(line.dropFirst(drop))
        }
    }

    /// ⌘/ comments out the selected lines with `-- `, or removes it when every line has it.
    @objc func toggleLineComment(_ sender: Any?) {
        let lines = selectedLines().text.components(separatedBy: "\n")
        let code = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let commented = !code.isEmpty && code.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
        let column = code.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        editLines { line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if commented {
                guard let r = line.range(of: "--") else { return line }
                var rest = line[r.upperBound...]
                if rest.first == " " { rest = rest.dropFirst() }
                return String(line[..<r.lowerBound]) + rest
            }
            let i = line.index(line.startIndex, offsetBy: min(column, line.count))
            return String(line[..<i]) + "-- " + line[i...]
        }
    }

    /// ⌥⌘/: wraps the selection in `/* … */`, or unwraps it when it already is. Without a
    /// selection it works on the cursor's line, leading indentation left outside.
    @objc func toggleBlockComment(_ sender: Any?) {
        let text = string as NSString
        var range = selectedRange()
        if range.length == 0 {
            let (lines, _) = selectedLines()
            range = lines
            // Leave the indentation outside the comment.
            while range.length > 0, [32, 9].contains(text.character(at: range.location)) {
                range.location += 1
                range.length -= 1
            }
        }
        let part = text.substring(with: range)
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement: String
        if trimmed.hasPrefix("/*"), trimmed.hasSuffix("*/"), trimmed.count >= 4 {
            var inner = String(trimmed.dropFirst(2).dropLast(2))
            if inner.hasPrefix(" ") { inner.removeFirst() }
            if inner.hasSuffix(" ") { inner.removeLast() }
            let lead = part.prefix { $0.isWhitespace }, trail = String(part.reversed().prefix { $0.isWhitespace }.reversed())
            replacement = lead + inner + trail
        } else {
            replacement = "/* " + part + " */"
        }
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: range.location, length: (replacement as NSString).length))
    }

    /// The full lines the selection touches (without the final newline).
    private func selectedLines() -> (range: NSRange, text: String) {
        let text = string as NSString
        var sel = selectedRange()
        // A selection ending just after a newline doesn't include the next line.
        if sel.length > 0, text.character(at: NSMaxRange(sel) - 1) == 10 { sel.length -= 1 }
        var range = text.lineRange(for: sel)
        var s = text.substring(with: range)
        if s.hasSuffix("\n") {
            s.removeLast()
            range.length -= 1
        }
        return (range, s)
    }

    /// Rewrites each selected line as one undoable change and keeps those lines selected.
    private func editLines(_ transform: (String) -> String) {
        let (range, text) = selectedLines()
        let replaced = text.components(separatedBy: "\n").map(transform).joined(separator: "\n")
        guard replaced != text, shouldChangeText(in: range, replacementString: replaced) else { return }
        textStorage?.replaceCharacters(in: range, with: replaced)
        didChangeText()
        setSelectedRange(NSRange(location: range.location, length: (replaced as NSString).length))
    }
}

// MARK: - Highlighting

/// Colours SQL tokens. After an edit only the runs that changed are re-coloured, so typing
/// stays cheap in long scripts (lexing the whole text is fast; attribute changes are not).
@MainActor
final class SQLHighlighter {
    var dialect: LexerDialect
    private var runs: [Run] = []

    struct Run: Equatable {
        var range: Range<Int>
        var style: Style
    }

    enum Style: Equatable {
        case plain, keyword, string, number, comment, identifier, parameter

        @MainActor var color: NSColor {
            let c = AppStyle.colors
            return switch self {
            case .plain: c.text
            case .keyword: c.keyword
            case .string: c.string
            case .number: c.number
            case .comment: c.comment
            case .identifier: c.identifier
            case .parameter: c.parameter
            }
        }
    }

    init(dialect: LexerDialect) {
        self.dialect = dialect
    }

    static func runs(_ text: String, dialect: LexerDialect) -> [Run] {
        var out: [Run] = []
        for token in SQLLexer(text, dialect: dialect).tokens() {
            let style: Style = switch token.kind {
            case .keyword: .keyword
            case .string: .string
            case .number: .number
            case .lineComment, .blockComment: .comment
            case .quotedIdentifier: .identifier
            case .parameter: .parameter
            default: .plain
            }
            if let last = out.last, last.style == style, last.range.upperBound == token.range.lowerBound {
                out[out.count - 1].range = last.range.lowerBound..<token.range.upperBound
            } else {
                out.append(Run(range: token.range, style: style))
            }
        }
        return out
    }

    /// Re-colours `storage`. `delta` is the change in length since the last call (0 for a full pass);
    /// runs overlapping `edited` are coloured again even when they look unchanged.
    func highlight(_ storage: NSTextStorage, delta: Int, full: Bool = false, edited: Range<Int>? = nil) {
        let new = Self.runs(storage.string, dialect: dialect)
        let old = runs
        runs = new
        var first = 0, lastNew = new.count, lastOld = old.count
        if !full {
            while first < min(new.count, old.count), new[first] == old[first] { first += 1 }
            while lastNew > first, lastOld > first {
                let o = old[lastOld - 1]
                let shifted = Run(range: (o.range.lowerBound + delta)..<(o.range.upperBound + delta), style: o.style)
                guard shifted == new[lastNew - 1] else { break }
                lastNew -= 1
                lastOld -= 1
            }
        }
        var recolour = first < lastNew ? Array(new[first..<lastNew]) : []
        if let edited, !full {
            recolour += new.filter { $0.range.overlaps(edited) || (edited.isEmpty && $0.range.contains(edited.lowerBound)) }
        }
        guard !recolour.isEmpty else { return }
        storage.beginEditing()
        for run in recolour {
            let r = NSRange(location: run.range.lowerBound, length: run.range.count)
            guard NSMaxRange(r) <= storage.length else { continue }
            storage.addAttribute(.foregroundColor, value: run.style.color, range: r)
        }
        storage.endEditing()
    }
}

// MARK: - Line numbers

/// Line numbers in the editor's gutter.
@MainActor
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    /// UTF-16 offsets where each line starts.
    private var lineStarts: [Int] = [0]
    private var font: NSFont {
        .monospacedDigitSystemFont(ofSize: max(9, AppStyle.editorFont.pointSize - 3), weight: .regular)
    }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        // NSRulerView draws its edge line through the whole dirty rect; unclipped (the default
        // since macOS 14) it shows above and below the scroll view.
        clipsToBounds = true
        ruleThickness = 36
        textChanged()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func textChanged() {
        guard let text = textView?.string.utf16 else { return }
        var starts = [0]
        var i = 0
        for u in text {
            i += 1
            if u == 10 { starts.append(i) }
        }
        lineStarts = starts
        let digits = max(2, String(starts.count).count)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let width = ceil(CGFloat(digits) * digitWidth) + 14
        if abs(ruleThickness - width) > 0.5 { ruleThickness = width }
        needsDisplay = true
    }

    /// 1-based line number holding `offset`.
    func line(at offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    func lineStart(_ line: Int) -> Int { lineStarts[max(0, min(line - 1, lineStarts.count - 1))] }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        AppStyle.colors.background.setFill()
        bounds.fill()
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let font = font
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: AppStyle.colors.lineNumber]
        let caretLine = line(at: textView.selectedRange().location)
        let inset = textView.textContainerInset.height
        var n = line(at: chars.location)
        let length = (textView.string as NSString).length
        while n <= lineStarts.count {
            let start = lineStarts[n - 1]
            if start > NSMaxRange(chars) { break }
            let rect: NSRect
            if start >= length {
                rect = layout.extraLineFragmentRect
                if rect == .zero { break }
            } else {
                let glyph = layout.glyphIndexForCharacter(at: start)
                rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
            let y = convert(NSPoint(x: 0, y: rect.minY + inset), from: textView).y
            let label = String(n) as NSString
            var a = attrs
            if n == caretLine { a[.foregroundColor] = AppStyle.colors.text }
            let size = label.size(withAttributes: a)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y + (rect.height - size.height) / 2), withAttributes: a)
            n += 1
        }
    }
}
