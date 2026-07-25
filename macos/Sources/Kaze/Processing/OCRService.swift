import Foundation
import Vision

/// On-device OCR via Apple Vision — net-new in the native app (the Electron version
/// only reserved the schema for it). Runs over captured screenshots before they are
/// deleted post-encoding; results land in recognition_data, whose triggers feed the
/// text_search FTS index. This text is also the raw material for daily AI analysis.
final class OCRService {
    private let store: Store
    private let running = AtomicFlag()

    init(store: Store) {
        self.store = store
    }

    struct RecognizedLine: Codable {
        let text: String
        let confidence: Float
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    func processPendingFrames() async {
        guard running.tryAcquire() else { return }
        defer { running.release() }

        guard store.db.isOpen else { return }
        do {
            let frames = try store.framesNeedingOCR(limit: K.ocrBatchSize)
            for frame in frames {
                guard let filename = frame.imgFilename else { continue }
                let url = Paths.screenshotsDir.appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    // Image already gone — record an empty result so cleanup can proceed.
                    try store.insertRecognition(frameID: frame.id, dataJSON: nil, text: "")
                    continue
                }
                let lines = recognizeText(at: url)
                let text = lines.map(\.text).joined(separator: "\n")
                let json = K.storeOCRBoundingBoxes
                    ? (try? JSONEncoder().encode(lines)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                    : nil
                try store.insertRecognition(frameID: frame.id, dataJSON: json, text: text)
            }
        } catch {
            Log.error("OCR processing failed: \(error)")
        }
    }

    private func recognizeText(at url: URL) -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(url: url, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Log.error("Vision OCR failed for \(url.lastPathComponent): \(error.localizedDescription)")
            return []
        }

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox // normalized, origin bottom-left
            return RecognizedLine(
                text: candidate.string,
                confidence: candidate.confidence,
                x: box.origin.x,
                y: box.origin.y,
                width: box.size.width,
                height: box.size.height)
        }
    }
}
