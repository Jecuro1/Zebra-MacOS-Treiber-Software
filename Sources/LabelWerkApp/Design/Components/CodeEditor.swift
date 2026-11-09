import AppKit
import SwiftUI
import LabelWerkKit

enum CodeLanguage {
    case zpl
    case sgd
    case plain
}

/// Code-Editor auf Basis von `NSTextView` mit Syntaxhervorhebung, Zeilennummern,
/// ZPL-Autovervollständigung (Esc bzw. ⌥Esc) und ⌘↩ zum Ausführen.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var language: CodeLanguage = .zpl
    var isEditable: Bool = true
    var fontSize: CGFloat = 12.5
    var onSubmit: (() -> Void)?

    init(text: Binding<String>, language: CodeLanguage = .zpl, isEditable: Bool = true,
         fontSize: CGFloat = 12.5, onSubmit: (() -> Void)? = nil) {
        self._text = text
        self.language = language
        self.isEditable = isEditable
        self.fontSize = fontSize
        self.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = CodeTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 4
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.language = language
        textView.onSubmit = onSubmit
        textView.string = text

        scrollView.documentView = textView
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.highlight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? CodeTextView else { return }
        textView.isEditable = isEditable
        textView.onSubmit = onSubmit
        textView.language = language
        if textView.string != text {
            let selection = textView.selectedRanges
            textView.string = text
            let length = (text as NSString).length
            let clamped = selection.map { value -> NSValue in
                let r = value.rangeValue
                let location = min(r.location, length)
                return NSValue(range: NSRange(location: location, length: min(r.length, length - location)))
            }
            textView.selectedRanges = clamped.isEmpty ? [NSValue(range: NSRange(location: length, length: 0))] : clamped
            context.coordinator.highlight()
        }
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if textView.font != font {
            textView.font = font
            context.coordinator.highlight()
        }
    }

    // MARK: Koordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: CodeTextView?
        private var pendingHighlight: DispatchWorkItem?

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            pendingHighlight?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.highlight() }
            pendingHighlight = work
            // Bei großen Dokumenten verzögert hervorheben, damit das Tippen flüssig bleibt.
            let delay = textView.string.utf16.count > 20_000 ? 0.25 : 0.02
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            SyntaxHighlighter.apply(to: storage, language: parent.language, fontSize: parent.fontSize)
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }
}

// MARK: - Textansicht

/// NSTextView mit ⌘↩ und ZPL-Vervollständigung.
final class CodeTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var language: CodeLanguage = .zpl

    override func keyDown(with event: NSEvent) {
        // ⌘↩ bzw. ⌘Enter (Ziffernblock)
        if event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override var rangeForUserCompletion: NSRange {
        guard language == .zpl else { return super.rangeForUserCompletion }
        let ns = string as NSString
        let caret = selectedRange().location
        var start = caret
        while start > 0 {
            let c = ns.character(at: start - 1)
            if c == 0x5E || c == 0x7E { start -= 1; break } // ^ oder ~
            if let scalar = UnicodeScalar(c), CharacterSet.alphanumerics.contains(scalar) || c == 0x40 { start -= 1 } else { break }
        }
        return NSRange(location: start, length: caret - start)
    }

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard language == .zpl else { return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index) }
        let partial = (string as NSString).substring(with: charRange).uppercased()
        let matches = ZPLCommandReference.entries
            .map(\.command)
            .filter { $0.uppercased().hasPrefix(partial) }
        index.pointee = matches.isEmpty ? -1 : 0
        return matches
    }
}

// MARK: - Zeilennummern

final class LineNumberRulerView: NSRulerView {
    private weak var codeView: NSTextView?

    init(textView: NSTextView) {
        self.codeView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = 38
        NotificationCenter.default.addObserver(self, selector: #selector(needsRedraw),
                                               name: NSView.boundsDidChangeNotification,
                                               object: textView.enclosingScrollView?.contentView)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) wird nicht unterstützt")
    }

    @objc private func needsRedraw() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = codeView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        NSColor.clear.setFill()
        rect.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let text = textView.string as NSString
        // Zeilennummer des ersten sichtbaren Zeichens bestimmen.
        var lineNumber = 1
        if characterRange.location > 0 {
            let prefix = text.substring(to: min(characterRange.location, text.length))
            lineNumber = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        }
        var index = characterRange.location
        let end = NSMaxRange(characterRange)
        let inset = textView.textContainerInset.height
        while index <= end && index <= text.length {
            let lineRange = text.lineRange(for: NSRange(location: min(index, max(0, text.length - 1)), length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: min(index, max(0, text.length - 1)))
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            if text.length == 0 { lineRect = NSRect(x: 0, y: 0, width: 0, height: 16) }
            let y = convert(NSPoint(x: 0, y: lineRect.minY + inset), from: textView).y
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y + (lineRect.height - size.height) / 2),
                       withAttributes: attributes)
            lineNumber += 1
            let next = NSMaxRange(lineRange)
            if next <= index || next > text.length { break }
            index = next
            if index == text.length { break }
        }
    }
}

// MARK: - Hervorhebung

enum SyntaxHighlighter {
    private static let zplCommand = try! NSRegularExpression(pattern: "[\\^~][A-Z@][A-Z0-9@]?", options: [.caseInsensitive])
    private static let zplFieldData = try! NSRegularExpression(pattern: "(?<=\\^FD|\\^FV)[\\s\\S]*?(?=\\^FS|$)", options: [.caseInsensitive])
    private static let zplComment = try! NSRegularExpression(pattern: "\\^FX[^\\^~]*", options: [.caseInsensitive])
    private static let zplFormat = try! NSRegularExpression(pattern: "\\^X[AZ]", options: [.caseInsensitive])
    private static let numbers = try! NSRegularExpression(pattern: "(?<![A-Za-z])-?\\d+(\\.\\d+)?", options: [])
    private static let graphicData = try! NSRegularExpression(pattern: "(?<=\\^GFA,)[^\\^~]*|:Z64:[A-Za-z0-9+/=]+(:[0-9A-Fa-f]{4})?", options: [.caseInsensitive])
    private static let sgdKeyword = try! NSRegularExpression(pattern: "!\\s*U1\\s+(getvar|setvar|do)", options: [.caseInsensitive])
    private static let quoted = try! NSRegularExpression(pattern: "\"[^\"\\n]*\"", options: [])
    private static let jsonPunct = try! NSRegularExpression(pattern: "[{}\\[\\]:,]", options: [])

    static func apply(to storage: NSTextStorage, language: CodeLanguage, fontSize: CGFloat) {
        let full = NSRange(location: 0, length: storage.length)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        let text = storage.string
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: full)
        switch language {
        case .plain:
            break
        case .zpl:
            color(numbers, in: text, storage: storage, color: NSColor.systemOrange)
            color(zplCommand, in: text, storage: storage, color: NSColor.systemPurple, font: bold)
            color(zplFormat, in: text, storage: storage, color: NSColor.systemPink, font: bold)
            color(zplFieldData, in: text, storage: storage, color: NSColor.systemGreen)
            color(graphicData, in: text, storage: storage, color: NSColor.tertiaryLabelColor)
            color(zplComment, in: text, storage: storage, color: NSColor.secondaryLabelColor,
                  font: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask))
            // SGD-Befehle können in ZPL-Dateien vorkommen
            color(sgdKeyword, in: text, storage: storage, color: NSColor.systemTeal, font: bold)
        case .sgd:
            color(jsonPunct, in: text, storage: storage, color: NSColor.secondaryLabelColor)
            color(numbers, in: text, storage: storage, color: NSColor.systemOrange)
            color(quoted, in: text, storage: storage, color: NSColor.systemGreen)
            color(sgdKeyword, in: text, storage: storage, color: NSColor.systemTeal, font: bold)
            color(zplCommand, in: text, storage: storage, color: NSColor.systemPurple, font: bold)
        }
        storage.endEditing()
    }

    private static func color(_ regex: NSRegularExpression, in text: String, storage: NSTextStorage,
                              color: NSColor, font: NSFont? = nil) {
        let range = NSRange(location: 0, length: (text as NSString).length)
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, match.range.length > 0 else { return }
            storage.addAttribute(.foregroundColor, value: color, range: match.range)
            if let font { storage.addAttribute(.font, value: font, range: match.range) }
        }
    }
}
