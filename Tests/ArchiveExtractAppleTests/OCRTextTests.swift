import Foundation
import Testing
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
@testable import ArchiveExtractApple

/// OCR text through Vision (DESIGN 6A, decisions 0010 and 0040).
/// Fixtures are images rendered in-test with CoreGraphics, so every
/// expectation is about the extractor's contract, not about a committed
/// binary blob. The first Vision call in a process loads the recognition
/// model (~15 s); later calls are fast, so the suite keeps the fixture
/// count small.
@Suite struct OCRTextTests {

    /// Renders the given lines of text into a bitmap (white background,
    /// black CoreText lines) and returns it as PNG bytes.
    func png(_ lines: [String]) -> Data {
        let width = 900
        let height = 120 + 70 * lines.count
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        for (index, line) in lines.enumerated() {
            let attributes = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ] as CFDictionary
            let attributed = CFAttributedStringCreate(nil, line as CFString, attributes)!
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 60, y: CGFloat(height - 90 - 70 * index))
            CTLineDraw(ctLine, context)
        }
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    /// An image-only (scanned) PDF: PDFKit wraps the rendered bitmap into
    /// a one-page document, exactly the shape a scanner or a phone photo
    /// print-to-PDF produces.
    func scannedPDF(_ lines: [String]) -> Data {
        let page = PDFPage(image: NSImage(cgImage: renderedImage(from: png(lines)), size: NSSize(width: 900, height: 190)))!
        let document = PDFDocument()
        document.insert(page, at: 0)
        return document.dataRepresentation()!
    }

    func renderedImage(from data: Data) -> CGImage {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!
    }

    @Test func readsRenderedText() throws {
        let text = try #require(OCRText.text(png(["Scanned receipt from Harbor Lane"])))
        #expect(text.contains("Harbor") == true)
        #expect(text.contains("receipt") == true)
    }

    @Test func readsMultipleLinesInOrder() throws {
        let text = try #require(OCRText.text(png([
            "Scanned receipt from Harbor Lane",
            "Total due twenty dollars",
        ])))
        let first = try #require(text.range(of: "Harbor"))
        let second = try #require(text.range(of: "Total due"))
        #expect(first.lowerBound < second.lowerBound)
    }

    @Test func nilForGarbageBytes() {
        #expect(OCRText.text(Data("this is not an image at all".utf8)) == nil)
    }

    @Test func nilForOversizedInput() {
        #expect(OCRText.text(Data(repeating: 0xFF, count: OCRText.maxInputBytes + 1)) == nil)
    }

    @Test func scannedPDFPageYieldsOCRText() throws {
        let pages = try #require(OCRText.pages(scannedPDF(["Scanned receipt from Harbor Lane"])))
        #expect(pages.count == 1)
        #expect(pages[0].contains("Harbor") == true)
        let joined = try #require(OCRText.pdfText(scannedPDF(["Scanned receipt from Harbor Lane"])))
        #expect(joined.contains("receipt") == true)
    }

    @Test func textPDFPagesStillPreferEmbeddedText() throws {
        // A PDF whose pages carry real text must not be OCR'd: the per-page
        // pipeline takes the PDFKit string first and only falls back to the
        // renderer for image-only pages.
        var body = "%PDF-1.4\n"
        var offsets: [Int] = []
        func add(_ object: String) {
            offsets.append(body.utf8.count)
            body += object
        }
        let stream = "BT /F1 12 Tf 72 720 Td (Embedded typewriter text) Tj ET"
        add("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
        add("2 0 obj\n<< /Type /Pages /Kids [4 0 R] /Count 1 >>\nendobj\n")
        add("3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n")
        add("4 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 3 0 R >> >> >>\nendobj\n")
        add("5 0 obj\n<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream\nendobj\n")
        var xref = "xref\n0 6\n0000000000 65535 f \n"
        for offset in offsets {
            xref += String(format: "%010d 00000 n \n", offset)
        }
        xref += "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(body.utf8.count)\n%%EOF\n"
        body += xref
        let pages = try #require(OCRText.pages(Data(body.utf8)))
        #expect(pages.count == 1)
        #expect(pages[0].contains("Embedded typewriter text") == true)
    }
}
