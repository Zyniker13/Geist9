// Attachment text extraction for container formats (DESIGN 6A, M2.3).
//
// The extractor turns Office Open XML (.docx/.xlsx/.pptx) and OpenDocument
// (.odt/.ods/.odp/.odg) attachment bytes into plain search text. It is a
// preview extractor: it never rewrites stored bytes, and anything it cannot
// read strictly — a wrong CRC, a lying size, malformed XML — yields no text
// rather than text that may not match the document. Extraction runs with the
// attachment limits preset, so a hostile container is bounded before any
// bytes are inflated (decision 0036) and again while text is captured.

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum OfficeExtract {
    /// Text preview of an Office Open XML package (.docx/.xlsx/.pptx).
    /// Dispatches on the package layout by entry name; returns nil when the
    /// container is not readable strictly or holds no document part.
    public static func openXMLText(_ data: Data, limits: ZIP.Limits = .attachments) -> String? {
        guard let entries = try? ZIP.open(data, limits: limits) else { return nil }
        var parts: [String: Data] = [:]
        for entry in entries {
            if let entryData = entry.data { parts[entry.name] = entryData }
        }

        // .docx: the main document part carries the body text.
        if let document = parts["word/document.xml"] {
            return XMLTextSink(kind: .docx).run(document)
        }

        // .pptx: slides in numeric order, then notes slides in numeric order.
        let slides = entries.map(\.name).filter { name in
            name.hasPrefix("ppt/slides/slide") && name.hasSuffix(".xml")
        }
        let notes = entries.map(\.name).filter { name in
            name.hasPrefix("ppt/notesSlides/notesSlide") && name.hasSuffix(".xml")
        }
        if !slides.isEmpty {
            var pieces: [String] = []
            for name in slides.sorted(by: numericNameOrder) {
                guard let text = XMLTextSink(kind: .pptx).run(parts[name]) else { return nil }
                if !text.isEmpty { pieces.append(text) }
            }
            for name in notes.sorted(by: numericNameOrder) {
                guard let text = XMLTextSink(kind: .pptx).run(parts[name]) else { return nil }
                if !text.isEmpty { pieces.append(text) }
            }
            return joined(pieces)
        }

        // .xlsx: shared strings are referenced by index from the sheets.
        if parts["xl/workbook.xml"] != nil {
            var shared: [String] = []
            if let sharedStrings = parts["xl/sharedStrings.xml"] {
                guard let list = XMLTextSink(kind: .sharedStrings).runList(sharedStrings) else { return nil }
                shared = list
            }
            var lines: [String] = []
            let sheets = entries.map(\.name).filter { name in
                name.hasPrefix("xl/worksheets/") && name.hasSuffix(".xml")
            }
            for name in sheets.sorted(by: numericNameOrder) {
                guard let text = XMLTextSink(kind: .xlsx).runRows(parts[name], shared: shared) else { return nil }
                if !text.isEmpty { lines.append(text) }
            }
            return joined(lines)
        }

        return nil
    }

    /// Text preview of an OpenDocument package (.odt/.ods/.odp/.odg): the
    /// text inside `text:p`, `text:h`, and `text:span` elements of
    /// content.xml, whatever body kind it sits in.
    public static func openDocumentText(_ data: Data, limits: ZIP.Limits = .attachments) -> String? {
        guard let entries = try? ZIP.open(data, limits: limits) else { return nil }
        for entry in entries where entry.name == "content.xml" {
            return XMLTextSink(kind: .odf).run(entry.data)
        }
        return nil
    }

    /// Order "slide2.xml" before "slide10.xml": numeric suffix when both
    /// names end in digits, plain lexicographic otherwise.
    private static func numericNameOrder(_ a: String, _ b: String) -> Bool {
        let aNumber = trailingNumber(a)
        let bNumber = trailingNumber(b)
        switch (aNumber, bNumber) {
        case let (an?, bn?):
            return an == bn ? a < b : an < bn
        case (.some, .none):
            return false
        case (.none, .some):
            return true
        case (.none, .none):
            return a < b
        }
    }

    private static func trailingNumber(_ name: String) -> Int? {
        let stem = (name as NSString).deletingPathExtension
        var digits = ""
        for character in stem.reversed() {
            guard character.isNumber else { break }
            digits = String(character) + digits
        }
        return digits.isEmpty ? nil : Int(digits)
    }

    private static func joined(_ pieces: [String]) -> String? {
        let text = pieces.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}

/// Accumulates extracted text through an XMLParser pass. Text is captured
/// only inside the elements each format defines as content; a parse error
/// poisons the whole result.
private final class XMLTextSink: NSObject, XMLParserDelegate {
    enum Kind { case docx, pptx, xlsx, sharedStrings, odf }

    private let kind: Kind
    private var pieces: [String] = []
    private var current: String = ""
    private var parserError: Error?
    private var captureOverflow = false

    // XLSX state: the open cell's declared type and its raw value text.
    // The value resolves against the shared-string table (t="s"), is taken
    // raw (t="str", numbers), or the inline string element carries the text
    // directly (t="inlineStr"). Cell texts join with spaces, rows with
    // newlines.
    private var cellType: String?
    private var cellValue: String?
    private var rowParts: [String] = []
    private var sharedStrings: [String] = []

    // DOCX ancestors whose text is not document content: field instructions
    // and tracked-change deletions.
    private var skipDepth = 0

    private var stack: [String] = []

    /// Hard cap on captured text, independent of the ZIP limits: entity
    /// expansion inside XML can multiply bytes, so the sink also bounds its
    /// own output.
    private static let maxCapturedBytes = 4_000_000

    init(kind: Kind) {
        self.kind = kind
        super.init()
    }

    // MARK: - Entry points

    /// Run the parser and return the captured text, or nil on any error.
    func run(_ data: Data?) -> String? {
        guard let data else { return nil }
        parse(data)
        return result()
    }

    /// Parse a shared-strings part into its string list.
    func runList(_ data: Data) -> [String]? {
        parse(data)
        guard parserError == nil else { return nil }
        return sharedStrings
    }

    /// Parse a worksheet into row text, resolving shared-string cells.
    func runRows(_ data: Data?, shared: [String]) -> String? {
        guard let data else { return nil }
        sharedStrings = shared
        parse(data)
        return result()
    }

    private func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        parser.parse()
    }

    private func result() -> String? {
        guard parserError == nil else { return nil }
        let text = pieces.joined()
        let trimmed = text.trimmingWhitespaceEdges()
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Capture helpers

    private var localName: String { stack.last ?? "" }
    private var parentName: String { stack.count >= 2 ? stack[stack.count - 2] : "" }

    private var capturingText: Bool {
        switch kind {
        case .docx:
            return localName == "t" && skipDepth == 0
        case .pptx, .sharedStrings:
            return localName == "t"
        case .xlsx:
            // Inline strings: <c t="inlineStr"><is><t>text</t></is></c>.
            return localName == "t" && parentName == "is"
        case .odf:
            return localName == "p" || localName == "h" || localName == "span"
        }
    }

    private func capture(_ text: String) {
        guard !captureOverflow else { return }
        current += text
        if current.utf8.count > Self.maxCapturedBytes {
            captureOverflow = true
            current = String(current.prefix(Self.maxCapturedBytes / 4))
        }
    }

    /// Close the current capture, adding the separator after it. Empty
    /// paragraphs still contribute a newline so paragraph boundaries survive.
    private func closePiece() {
        pieces.append(current + "\n")
        current = ""
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = Self.local(elementName)
        stack.append(name)
        switch kind {
        case .docx:
            switch name {
            case "delText", "instrText": skipDepth += 1
            case "tab": capture("\t")
            case "br": capture("\n")
            default: break
            }
        case .odf:
            switch name {
            case "line-break": capture("\n")
            case "tab": capture("\t")
            case "s": capture(" ")
            default: break
            }
        case .xlsx:
            if name == "c" {
                cellType = attributeDict["t"] ?? "n"
                cellValue = ""
            }
        case .pptx, .sharedStrings:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = Self.local(elementName)
        switch kind {
        case .docx:
            switch name {
            case "delText", "instrText": skipDepth = max(0, skipDepth - 1)
            case "p": closePiece()
            default: break
            }
        case .pptx:
            if name == "p" { closePiece() }
        case .sharedStrings:
            if name == "si" {
                sharedStrings.append(current)
                current = ""
            }
        case .xlsx:
            switch name {
            case "is":
                // Inline string text was captured into `current`.
                cellValue = current
                current = ""
                resolveCellValue()
            case "v":
                resolveCellValue()
            case "c":
                break // resolution already happened at v/is end
            case "row":
                let row = rowParts.joined(separator: " ")
                if !row.isEmpty { pieces.append(row + "\n") }
                rowParts = []
            default: break
            }
        case .odf:
            if name == "p" || name == "h" { closePiece() }
        }
        if !stack.isEmpty { stack.removeLast() }
    }

    private func resolveCellValue() {
        let value = cellValue ?? ""
        cellValue = nil
        let resolved: String?
        switch cellType {
        case "s":
            resolved = Int(value).flatMap { sharedStrings.indices.contains($0) ? sharedStrings[$0] : nil }
        case "inlineStr":
            resolved = value
        case "str", "n":
            resolved = value
        default:
            resolved = value.isEmpty ? nil : value
        }
        if let resolved, !resolved.isEmpty {
            rowParts.append(resolved)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingText {
            capture(string)
            return
        }
        // Raw worksheet values are data, not prose: collected regardless of
        // the capturing rule so shared-string and numeric cells resolve.
        if kind == .xlsx, localName == "v", cellValue != nil {
            cellValue = (cellValue ?? "") + string
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { return }
        if capturingText {
            capture(text)
            return
        }
        if kind == .xlsx, localName == "v", cellValue != nil {
            cellValue = (cellValue ?? "") + text
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        parserError = error
    }

    private static func local(_ elementName: String) -> String {
        elementName.split(separator: ":").last.map(String.init) ?? elementName
    }
}

extension String {
    /// Trim whitespace only at the ends; interior spacing is kept as parsed.
    func trimmingWhitespaceEdges() -> String {
        var start = startIndex
        var end = endIndex
        while start < end, self[start].isWhitespace { start = index(after: start) }
        while start < end, self[index(before: end)].isWhitespace { end = index(before: end) }
        return String(self[start..<end])
    }
}
