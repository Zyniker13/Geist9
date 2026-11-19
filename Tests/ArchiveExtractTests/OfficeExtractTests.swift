// Office Open XML and OpenDocument text extraction (DESIGN 6A, M2.3).
// The fixtures are built with the same in-test ZIP writer as ZIPTests: the
// extractor receives container bytes exactly as they would arrive from a
// message attachment, and every safety rule is tested against hostile
// fixtures (wrong CRC, lying sizes, malformed XML), not just happy paths.

import ArchiveExtract
import Foundation
import Testing

struct OfficeExtractTests {
    private func zip(_ pairs: [(String, String)]) -> Data {
        Data(ZIPBuilder.make(entries: pairs.map { .stored($0.0, Array($0.1.utf8)) }))
    }

    // MARK: - .docx

    @Test func extractsDocxParagraphs() {
        let docx = zip([
            ("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>"),
            ("word/document.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:body>
            <w:p><w:r><w:t>Hello </w:t></w:r><w:r><w:t>world</w:t></w:r></w:p>
            <w:p><w:r><w:instrText> PAGE </w:instrText><w:t xml:space="preserve">Second paragraph</w:t></w:r></w:p>
            <w:p><w:del><w:r><w:delText>deleted</w:delText></w:r></w:del></w:p>
            </w:body></w:document>
            """),
        ])
        #expect(OfficeExtract.openXMLText(docx) == "Hello world\nSecond paragraph")
    }

    @Test func docxTabsAndBreaksBecomeWhitespace() {
        let docx = zip([
            ("word/document.xml", """
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:body>
            <w:p><w:r><w:t>before</w:t><w:tab/><w:t>after</w:t><w:br/><w:t>next line</w:t></w:r></w:p>
            </w:body></w:document>
            """),
        ])
        #expect(OfficeExtract.openXMLText(docx) == "before\tafter\nnext line")
    }

    // MARK: - .xlsx

    @Test func extractsXlsxCellText() {
        let xlsx = zip([
            ("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>"),
            ("xl/workbook.xml", "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"/>"),
            ("xl/sharedStrings.xml", """
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="2" uniqueCount="2">
            <si><t>Project Falcon</t></si>
            <si><r><t>Q</t></r><r><t>3 revenue</t></r></si>
            </sst>
            """),
            ("xl/worksheets/sheet1.xml", """
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
            <sheetData>
            <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"><v>42000</v></c></row>
            <row r="2"><c r="A2" t="inlineStr"><is><t>Inline note</t></is></c><c r="B2" t="str"><v>computed</v></c><c r="C2" t="s"><v>1</v></c></row>
            </sheetData></worksheet>
            """),
        ])
        #expect(OfficeExtract.openXMLText(xlsx) == "Project Falcon 42000\nInline note computed Q3 revenue")
    }

    // MARK: - .pptx

    @Test func extractsPptxSlidesInNumericOrder() {
        let pptx = zip([
            ("ppt/slides/slide1.xml", """
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                   xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
            <p:cSld><p:spTree>
            <p:sp><p:txBody>
            <a:p><a:r><a:t>Slide one</a:t></a:r></a:p>
            <a:p><a:r><a:t>Bullet</a:t></a:r></a:p>
            </p:txBody></p:sp>
            </p:spTree></p:cSld></p:sld>
            """),
            ("ppt/slides/slide2.xml", """
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                   xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
            <p:cSld><p:spTree>
            <p:sp><p:txBody><a:p><a:r><a:t>Slide two</a:t></a:r></a:p></p:txBody></p:sp>
            </p:spTree></p:cSld></p:sld>
            """),
            ("ppt/notesSlides/notesSlide1.xml", """
            <p:notes xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                     xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
            <p:cSld><p:spTree>
            <p:sp><p:txBody><a:p><a:r><a:t>Speaker notes</a:t></a:r></a:p></p:txBody></p:sp>
            </p:spTree></p:cSld></p:notes>
            """),
        ])
        #expect(OfficeExtract.openXMLText(pptx) == "Slide one\nBullet\nSlide two\nSpeaker notes")
    }

    // MARK: - OpenDocument

    @Test func extractsOpenDocumentParagraphs() {
        let odt = zip([
            ("content.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <office:document-content
              xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
              xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
              office:version="1.2">
            <office:body><office:text>
            <text:p>First line</text:p>
            <text:h>Heading</text:h>
            <text:p>Broken<text:line-break/>next</text:p>
            </office:text></office:body>
            </office:document-content>
            """),
        ])
        #expect(OfficeExtract.openDocumentText(odt) == "First line\nHeading\nBroken\nnext")
    }

    @Test func extractsOpenDocumentSpreadsheetCells() {
        let ods = zip([
            ("content.xml", """
            <office:document-content
              xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
              xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
              xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0">
            <office:body><office:spreadsheet>
            <table:table><table:table-row>
            <table:table-cell><text:p>Budget</text:p></table:table-cell>
            <table:table-cell><text:p>4200</text:p></table:table-cell>
            </table:table-row></table:table>
            </office:spreadsheet></office:body>
            </office:document-content>
            """),
        ])
        #expect(OfficeExtract.openDocumentText(ods) == "Budget\n4200")
    }

    @Test func odfSpansDoNotAddSeparators() {
        let odt = zip([
            ("content.xml", """
            <office:document-content
              xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
              xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
            <office:body><office:text>
            <text:p>Run one<text:span> and </text:span>run two</text:p>
            </office:text></office:body>
            </office:document-content>
            """),
        ])
        #expect(OfficeExtract.openDocumentText(odt) == "Run one and run two")
    }

    // MARK: - Safety

    @Test func rejectsWrongCRCOnDocumentPart() {
        var docx = [UInt8](zip([
            ("word/document.xml", "<w:document xmlns:w=\"urn\"><w:body><w:p><w:r><w:t>Hi</w:t></w:r></w:p></w:body></w:document>"),
        ]))
        // Flip one byte inside the stored entry's data: CRC no longer matches.
        docx[60] ^= 0xFF
        #expect(OfficeExtract.openXMLText(Data(docx)) == nil)
    }

    @Test func rejectsMalformedXML() {
        let docx = zip([
            ("word/document.xml", "<w:document><w:body><w:p><w:r><w:t>Unclosed"),
        ])
        #expect(OfficeExtract.openXMLText(docx) == nil)
    }

    @Test func returnsNilWithoutMainPart() {
        let notADocument = zip([
            ("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>"),
            ("random/data.txt", "nothing here"),
        ])
        #expect(OfficeExtract.openXMLText(notADocument) == nil)
        #expect(OfficeExtract.openDocumentText(notADocument) == nil)
    }

    @Test func returnsNilForNotAZip() {
        #expect(OfficeExtract.openXMLText(Data("plain text".utf8)) == nil)
        #expect(OfficeExtract.openDocumentText(Data("plain text".utf8)) == nil)
    }

    @Test func attachmentLimitsRejectLyingSizes() {
        // A stored entry that declares a 40 MB inflated size must hit the
        // attachment preset's per-entry cap before any bytes are produced.
        let docx = Data(ZIPBuilder.make(entries: [
            .stored(
                "word/document.xml",
                Array("<w:document xmlns:w=\"urn\"><w:body><w:p><w:r><w:t>Hi</w:t></w:r></w:p></w:body></w:document>".utf8),
                declaredInflatedSize: 40_000_000
            ),
        ]))
        #expect(OfficeExtract.openXMLText(docx) == nil)
    }
}
