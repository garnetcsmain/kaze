import Foundation
import AVFoundation
import CoreVideo
import ImageIO

/// Batches captured screenshots into videos — replaces the ffmpeg concat pipeline.
/// Screenshot N of a task becomes video frame N at 30 fps (HEVC via VideoToolbox),
/// preserving the original seek math: time = videoFrameIndex / 30.
///
/// Grouping parity with checkFramesForEncoding: a chunk boundary is cut when frame
/// resolution changes or the buffer reaches 90 frames; the trailing partial buffer
/// stays pending until flushPendingFrames() (called on stop/quit).
final class EncodingService {
    private let store: Store
    private let encoding = AtomicFlag() // CONCURRENCY = 1

    init(store: Store) {
        self.store = store
    }

    // MARK: - Queueing

    func checkFramesForEncoding() async {
        await groupPendingFrames(flush: false)
    }

    /// Encode all leftover frames regardless of the 90-frame minimum (tray stop / app quit).
    func flushPendingFrames() async {
        await groupPendingFrames(flush: true)
        await processEncodingTasks()
    }

    private func groupPendingFrames(flush: Bool) async {
        guard store.db.isOpen else { return }
        do {
            let frames = try store.pendingFramesForEncoding()
            var buffer: [Frame] = []
            var previousSize: CGSize?

            func enqueue() throws {
                guard !buffer.isEmpty else { return }
                _ = try store.createEncodingTask(frameIDs: buffer.map(\.id))
                buffer = []
            }

            for frame in frames {
                guard let filename = frame.imgFilename else { continue }
                let url = Paths.screenshotsDir.appendingPathComponent(filename)
                guard let size = imagePixelSize(url) else {
                    // File missing or unreadable — drop the row like the Electron app did.
                    try store.deleteFrame(frame.id)
                    continue
                }
                if let prev = previousSize, prev != size {
                    try enqueue()
                }
                buffer.append(frame)
                previousSize = size
                if buffer.count >= K.minFramesToEncode {
                    try enqueue()
                }
            }
            if flush {
                try enqueue()
            }
        } catch {
            Log.error("checkFramesForEncoding failed: \(error)")
        }
    }

    private func imagePixelSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    // MARK: - Encoding

    func processEncodingTasks() async {
        guard encoding.tryAcquire() else { return }
        defer { encoding.release() }

        guard store.db.isOpen else { return }
        do {
            for task in try store.pendingEncodingTasks() {
                try await encode(taskID: task.id)
            }
        } catch {
            Log.error("processEncodingTasks failed: \(error)")
        }
    }

    private func encode(taskID: Int64) async throws {
        let frames = try store.framesForEncodingTask(taskID)
        guard !frames.isEmpty else {
            try store.setEncodingTaskStatus(taskID, status: 2)
            return
        }
        try store.setEncodingTaskStatus(taskID, status: 1)

        let videoFilename = "\(taskID).mp4"
        let outputURL = Paths.recordingsDir.appendingPathComponent(videoFilename)
        try? FileManager.default.removeItem(at: outputURL)

        do {
            let encodedIDs = try await writeVideo(frames: frames, to: outputURL)
            try store.completeEncodingTask(taskID, videoPath: videoFilename, orderedFrameIDs: encodedIDs)
            Log.info("Encoded task \(taskID): \(encodedIDs.count) frames -> \(videoFilename)")
        } catch {
            // Reset to pending for retry (the Electron app left these stuck at status=1).
            try? store.setEncodingTaskStatus(taskID, status: 0)
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    /// Renders each screenshot as one 1/30s video frame using AVAssetWriter + HEVC hardware encoding.
    private func writeVideo(frames: [Frame], to url: URL) async throws -> [Int64] {
        // Determine dimensions from the first readable frame.
        var firstSize: CGSize?
        for frame in frames {
            if let filename = frame.imgFilename {
                let fileURL = Paths.screenshotsDir.appendingPathComponent(filename)
                if let size = imagePixelSize(fileURL) {
                    firstSize = size
                    break
                }
            }
        }
        guard let size = firstSize else {
            throw NSError(domain: K.bundleID, code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "No readable frames in task"])
        }
        // HEVC requires even dimensions.
        let width = Int(size.width) - (Int(size.width) % 2)
        let height = Int(size.height) - (Int(size.height) % 2)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: K.bundleID, code: 11,
                                          userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter failed to start"])
        }
        writer.startSession(atSourceTime: .zero)

        var encodedIDs: [Int64] = []
        var frameIndex: Int64 = 0

        for frame in frames {
            guard let filename = frame.imgFilename else { continue }
            let fileURL = Paths.screenshotsDir.appendingPathComponent(filename)
            guard let image = loadCGImage(fileURL) else { continue }

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }

            guard let pool = adaptor.pixelBufferPool else {
                throw NSError(domain: K.bundleID, code: 12,
                              userInfo: [NSLocalizedDescriptionKey: "No pixel buffer pool"])
            }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let buffer = pixelBuffer else {
                throw NSError(domain: K.bundleID, code: 13,
                              userInfo: [NSLocalizedDescriptionKey: "Pixel buffer allocation failed"])
            }

            render(image, into: buffer, width: width, height: height)

            let time = CMTime(value: frameIndex, timescale: K.encodingFrameRate)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? NSError(domain: K.bundleID, code: 14,
                                              userInfo: [NSLocalizedDescriptionKey: "Frame append failed"])
            }
            encodedIDs.append(frame.id)
            frameIndex += 1
        }

        guard !encodedIDs.isEmpty else {
            input.markAsFinished()
            writer.cancelWriting()
            throw NSError(domain: K.bundleID, code: 15,
                          userInfo: [NSLocalizedDescriptionKey: "All frame images unreadable"])
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? NSError(domain: K.bundleID, code: 16,
                                          userInfo: [NSLocalizedDescriptionKey: "finishWriting failed"])
        }
        return encodedIDs
    }

    private func loadCGImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func render(_ image: CGImage, into buffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    // MARK: - Screenshot cleanup (delete-screenshots task)

    /// Deletes PNGs whose frames are encoded AND OCR'd, then nulls imgFilename.
    func deleteUnnecessaryScreenshots() async {
        guard store.db.isOpen else { return }
        do {
            for frame in try store.framesReadyForScreenshotDeletion() {
                guard let filename = frame.imgFilename else { continue }
                let url = Paths.screenshotsDir.appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: url)
                try store.clearFrameImage(frame.id)
            }
        } catch {
            Log.error("deleteUnnecessaryScreenshots failed: \(error)")
        }
    }
}
