import Foundation
import Vision
import CoreGraphics

guard CommandLine.arguments.count > 1 else {
    print("Usage: vision_ocr <image_path>")
    exit(1)
}

let imagePath = CommandLine.arguments[1]
guard let data = try? Data(contentsOf: URL(fileURLWithPath: imagePath)),
      let provider = CGDataProvider(data: data as CFData),
      let source = CGImageSourceCreateWithDataProvider(provider, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("ERROR: Could not load image")
    exit(1)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true

let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
try? handler.perform([request])

if let observations = request.results {
    for obs in observations {
        if let topCandidate = obs.topCandidates(1).first {
            print(topCandidate.string)
        }
    }
}
