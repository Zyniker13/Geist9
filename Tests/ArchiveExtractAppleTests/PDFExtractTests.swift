import Foundation
import Testing
@testable import ArchiveExtractApple

/// PDF attachment text through PDFKit (DESIGN 6A, decision 0039).
/// Fixtures are minimal single-font PDFs built in-test with correct
/// xref offsets, so every expectation is about the extractor's strictness,
/// not about PDFKit's leniency toward damaged files.
@Suite struct PDFExtractTests {

    /// Builds a minimal PDF 1.4 with one Helvetica page per string, in
    /// order. Byte offsets for the xref table are tracked as objects are
    /// appended, so the table is exact; PDFKit reads it without repair.
    func pdf(_ pageTexts: [String]) -> Data {
        var body = "%PDF-1.4\n"
        var offsets: [Int] = []
        func add(_ object: String) {
            offsets.append(body.utf8.count)
            body += object
        }
        // Object numbering: 1 catalog, 2 page tree, 3 font,
        // 4...(3+count) pages, (4+count)...(3+2*count) content streams.
        let count = pageTexts.count
        add("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
        let kids = (1...count).map { "\($0 + 3) 0 R" }.joined(separator: " ")
        add("2 0 obj\n<< /Type /Pages /Kids [\(kids)] /Count \(count) >>\nendobj\n")
        add("3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n")
        // All page objects first, then their content streams, so object
        // numbers ascend and the xref table (which is in object-number
        // order) matches emission order.
        for (index, _) in pageTexts.enumerated() {
            let contentObject = 4 + count + index
            add(
                "\(4 + index) 0 obj\n"
                    + "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]"
                    + " /Contents \(contentObject) 0 R"
                    + " /Resources << /Font << /F1 3 0 R >> >> >>\nendobj\n"
            )
        }
        for (index, text) in pageTexts.enumerated() {
            let contentObject = 4 + count + index
            let stream = "BT /F1 12 Tf 72 \(720 - 24 * index) Td (\(text)) Tj ET"
            let streamBytes = stream.utf8.count
            add("\(contentObject) 0 obj\n<< /Length \(streamBytes) >>\nstream\n\(stream)\nendstream\nendobj\n")
        }
        let objectCount = 3 + 2 * count
        var xref = "xref\n0 \(objectCount + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            xref += String(format: "%010d 00000 n \n", offset)
        }
        xref += "trailer\n<< /Size \(objectCount + 1) /Root 1 0 R >>\nstartxref\n"
        xref += "\(body.utf8.count)\n%%EOF\n"
        body += xref
        return Data(body.utf8)
    }

    @Test func extractsTwoPagesInOrder() throws {
        let data = pdf(["Quarterly numbers report", "Second page findings"])
        let joined = try #require(PDFText.text(data))
        let first = try #require(joined.range(of: "Quarterly numbers report"))
        let second = try #require(joined.range(of: "Second page findings"))
        #expect(first.lowerBound < second.lowerBound)
    }

    @Test func exposesPageOrderForLaterPageAttribution() throws {
        let pages = try #require(PDFText.pages(pdf(["Agenda for Friday", "Budget review"])))
        #expect(pages.count == 2)
        #expect(pages[0].contains("Agenda for Friday") == true)
        #expect(pages[1].contains("Budget review") == true)
    }

    @Test func nilForGarbageBytes() {
        #expect(PDFText.text(Data("this is not a pdf at all".utf8)) == nil)
    }

    @Test func nilForTruncatedPDF() {
        let complete = pdf(["Quarterly numbers report"])
        let cut = Data(complete[0..<complete.count / 2])
        #expect(PDFText.text(cut) == nil)
    }

    @Test func nilWhenEveryPageIsImageOnly() {
        // A page whose content stream draws no text at all.
        let data = pdf([""])
        #expect(PDFText.text(data) == nil)
    }

    @Test func rejectsOversizedInput() {
        let oversized = Data(repeating: 0x25, count: PDFText.maxInputBytes + 1)
        #expect(PDFText.text(oversized) == nil)
    }
}
