import Foundation

/// Transcribes pending audio chunks with the bundled whisper.cpp CLI + base-q5_0 model
/// (CoreML encoder is auto-detected from the same models/ directory).
/// Invocation and JSON parsing match src/electron/backend/transcription.ts exactly.
final class TranscriptionService {
    private let store: Store
    private let running = AtomicFlag() // CONCURRENCY = 1

    init(store: Store) {
        self.store = store
    }

    private struct WhisperOutput: Decodable {
        struct Segment: Decodable {
            struct Offsets: Decodable {
                let from: Double // milliseconds
                let to: Double
            }
            let offsets: Offsets
            let text: String
        }
        struct Result: Decodable {
            let language: String?
        }
        let transcription: [Segment]
        let result: Result?
    }

    func processPendingChunks() async {
        guard running.tryAcquire() else { return }
        defer { running.release() }

        guard store.db.isOpen else { return }
        guard let whisper = Paths.whisperBinary, let model = Paths.whisperModel,
              FileManager.default.fileExists(atPath: whisper.path),
              FileManager.default.fileExists(atPath: model.path)
        else {
            return // whisper not available (logged once at startup)
        }

        do {
            for chunk in try store.pendingAudioChunks() {
                guard store.db.isOpen else { return }
                let wavURL = Paths.audioDir.appendingPathComponent(chunk.filename)
                guard FileManager.default.fileExists(atPath: wavURL.path) else {
                    try store.setTranscribeStatus(chunk.id, status: 3) // error: file missing
                    continue
                }
                try store.setTranscribeStatus(chunk.id, status: 1)
                await transcribe(chunk: chunk, wavURL: wavURL, whisper: whisper, model: model)
            }
        } catch {
            Log.error("Transcription queue processing failed: \(error)")
        }
    }

    private func transcribe(chunk: PendingAudioChunk, wavURL: URL, whisper: URL, model: URL) async {
        let outputBase = wavURL.deletingPathExtension()
        let jsonURL = outputBase.appendingPathExtension("json")

        do {
            try await runProcess(
                executable: whisper,
                arguments: [
                    "-m", model.path,
                    "-f", wavURL.path,
                    "-l", "auto",
                    "--output-json",
                    "--output-file", outputBase.path,
                    "--no-prints",
                ],
                timeout: 180)

            let data = try Data(contentsOf: jsonURL)
            let output = try JSONDecoder().decode(WhisperOutput.self, from: data)
            let language = output.result?.language

            let segments = output.transcription.compactMap { seg -> (Double, Double, String, String?)? in
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return (seg.offsets.from / 1000.0, seg.offsets.to / 1000.0, text, language)
            }
            try store.insertTranscriptions(chunkID: chunk.id, segments: segments)
            try? FileManager.default.removeItem(at: jsonURL)
        } catch {
            Log.error("Transcription failed for \(chunk.filename): \(error.localizedDescription)")
            try? store.setTranscribeStatus(chunk.id, status: 3)
            try? FileManager.default.removeItem(at: jsonURL)
        }
    }

    private func runProcess(executable: URL, arguments: [String], timeout: TimeInterval) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // Process is thread-safe for terminate/isRunning; box it for @Sendable closures.
        let box = ProcessBox(process)
        let timedOut = AtomicFlag()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if box.process.isRunning {
                    _ = timedOut.tryAcquire()
                    box.process.terminate()
                }
            }
        }

        if timedOut.isSet {
            throw NSError(domain: K.bundleID, code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "whisper timed out"])
        }
        guard process.terminationStatus == 0 else {
            throw NSError(domain: K.bundleID, code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "whisper exited with status \(process.terminationStatus)"])
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}
