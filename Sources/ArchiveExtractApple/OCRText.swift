import Foundation
import PDFKit
import Vision

/// OCR text via Vision (DESIGN 6A, decisions 0010 and 0040). Strictness
/// mirrors PDFText: input that cannot be read as an image yields nil, and
/// a scanned PDF yields per-page strings where pages that carry embedded
/// text keep their PDFKit text and image-only pages are rendered to a
/// bitmap and OCR'd. The caller stores nothing rather than a misleading
/// empty row.
public enum OCRText {
    /// Same attachment byte budget as the other extractors (ZIP.Limits.attachments).
    public static let maxInputBytes = 24_000_000
    /// Hard ceiling on indexed characters, same as PDFText.
    public static let maxOutputCharacters = 1_000_000
    /// Scanned pages are rendered at 2.5x PDF space, ~180 DPI: inside the
    /// 150-300 DPI band decision 0010 fixed for legibility without waste.
    static let pdfRenderScale: CGFloat = 2.5
    /// Wall-clock bound for one Vision recognition call. Vision performs
    /// synchronously, and a call that never returns (seen on CI runners
    /// when recognition assets cannot load) must not wedge indexing. On
    /// deadline the pass yields nil; the message's bytes stay archived
    /// and a later version bump can extract again.
    static let recognitionTimeout: TimeInterval = 90

    /// OCRs image bytes (PNG, JPEG, HEIC, TIFF, GIF...). Returns nil when
    /// the data is not a readable image or nothing legible was found.
    public static func text(_ data: Data) -> String? {
        guard data.count <= maxInputBytes else { return nil }
        let handler = VNImageRequestHandler(data: data, options: [:])
        let request = makeRequest()
        guard let observations = performBounded(handler, request: request) else { return nil }
        return joinedLines(from: observations)
    }

    /// Per-page text of a PDF: embedded text when the page has any, OCR of
    /// the rendered page when it does not. nil when the PDF cannot open.
    public static func pages(_ data: Data) -> [String]? {
        guard data.count <= maxInputBytes else { return nil }
        guard let document = PDFDocument(data: data) else { return nil }
        var texts: [String] = []
        var budget = maxOutputCharacters
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            var pageText = page.string ?? ""
            if pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pageText = ocr(page: page) ?? ""
            }
            if pageText.count > budget {
                pageText = String(pageText.prefix(budget))
            }
            budget -= pageText.count + 1
            texts.append(pageText)
            if budget <= 0 { break }
        }
        return texts
    }

    /// All pages of a PDF joined the way PDFText.text joins them, so a
    /// scanned PDF behaves like a text PDF for the caller. nil when no
    /// page yields any text.
    public static func pdfText(_ data: Data) -> String? {
        guard let pages = pages(data) else { return nil }
        let joined = pages.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    // MARK: - Internals

    private static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest { _, _ in }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        return request
    }

    private static func joinedLines(from observations: [VNRecognizedTextObservation]) -> String? {
        var lines: [String] = []
        var budget = maxOutputCharacters
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            var line = candidate.string
            if line.count > budget {
                line = String(line.prefix(budget))
            }
            budget -= line.count + 1
            lines.append(line)
            if budget <= 0 { break }
        }
        let joined = lines.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    private static func ocr(page: PDFPage) -> String? {
        guard let image = rendered(page: page) else { return nil }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = makeRequest()
        guard let observations = performBounded(handler, request: request) else { return nil }
        return joinedLines(from: observations)
    }

    /// Runs one recognition call on a worker thread and waits at most
    /// `recognitionTimeout` for it. Vision objects stay confined to the
    /// worker thread that runs them; only the outcome crosses back
    /// through the locked box. nil on error or deadline.
    static func performBounded(
        _ handler: VNImageRequestHandler,
        request: VNRecognizeTextRequest
    ) -> [VNRecognizedTextObservation]? {
        final class Job: @unchecked Sendable {
            let handler: VNImageRequestHandler
            let request: VNRecognizeTextRequest
            init(handler: VNImageRequestHandler, request: VNRecognizeTextRequest) {
                self.handler = handler
                self.request = request
            }
        }
        final class Outcome: @unchecked Sendable {
            private let lock = NSLock()
            private let done = DispatchSemaphore(value: 0)
            private var failed = false
            private var lines: [VNRecognizedTextObservation]?
            func finish(_ lines: [VNRecognizedTextObservation]) {
                lock.lock()
                self.lines = lines
                lock.unlock()
                done.signal()
            }
            func fail() {
                lock.lock()
                failed = true
                lock.unlock()
                done.signal()
            }
            /// nil when the deadline passed or the call errored.
            func take(after timeout: TimeInterval) -> [VNRecognizedTextObservation]? {
                if done.wait(timeout: .now() + timeout) == .timedOut { return nil }
                lock.lock()
                defer { lock.unlock() }
                return failed ? nil : lines
            }
        }
        let outcome = Outcome()
        let job = Job(handler: handler, request: request)
        let worker = Thread {
            do {
                try job.handler.perform([job.request])
                outcome.finish(job.request.results ?? [])
            } catch {
                outcome.fail()
            }
        }
        worker.name = "bristlecone-ocr"
        worker.qualityOfService = .userInitiated
        worker.start()
        return outcome.take(after: recognitionTimeout)
    }

    private static func rendered(page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }
        let size = CGSize(width: bounds.width * pdfRenderScale, height: bounds.height * pdfRenderScale)
        guard let context = CGContext(
            data: nil,
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded()),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: pdfRenderScale, y: pdfRenderScale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
