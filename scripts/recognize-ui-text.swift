import Foundation
import ImageIO
import Vision

// Read existing native-test captures only. This tool never captures the desktop,
// edits an image, or treats OCR absence as proof of visual clipping.
guard CommandLine.arguments.count == 3 else {
    fputs("Usage: swift recognize-ui-text.swift <native-screenshot.png> <result.json>\n", stderr)
    exit(2)
}
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
do {
    guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
        throw NSError(domain: "TetherDesignAudit", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot read the native screenshot"])
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    let supported = try request.supportedRecognitionLanguages()
    request.recognitionLanguages = ["ko-KR", "en-US"].filter(supported.contains)
    request.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    let lines: [[String: Any]] = (request.results ?? []).compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let r = observation.boundingBox
        return ["text": candidate.string, "confidence": Double(candidate.confidence),
                "normalizedBounds": ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height]]
    }
    let result: [String: Any] = ["schemaVersion": 1, "source": source.path,
        "method": "Apple Vision VNRecognizeTextRequest accurate",
        "imageWidth": image.width, "imageHeight": image.height,
        "recognitionLanguages": request.recognitionLanguages,
        "lines": lines, "absenceProvesClipping": false,
        "notMeasured": ["fontSize", "foregroundBackgroundContrast", "fullAccessibilityCompliance"]]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: destination, options: .atomic)
    print("Recognized \(lines.count) lines; evidence: \(destination.path)")
} catch {
    fputs("UI text recognition failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
