import Foundation
import AppKit
import AVFoundation

/// Produces the image for a timeline frame — replaces GET /frame/:id.
/// Live screenshots are loaded from disk; encoded frames are extracted from their
/// video with AVAssetImageGenerator at exactly videoFrameIndex / 30 seconds
/// (zero tolerance — more precise than the old ffmpeg -ss keyframe seek).
/// Works with both new HEVC videos and old ffmpeg-encoded H.264 ones.
final class FrameExtractor {
    private let cache = NSCache<NSNumber, NSImage>()

    init() {
        cache.countLimit = 100 // parity with the renderer's LRU blob cache
    }

    func cachedImage(for frameID: Int64) -> NSImage? {
        cache.object(forKey: NSNumber(value: frameID))
    }

    func image(for frame: Frame) async -> NSImage? {
        if let cached = cache.object(forKey: NSNumber(value: frame.id)) {
            return cached
        }

        var result: NSImage?
        if let filename = frame.imgFilename {
            let url = Paths.screenshotsDir.appendingPathComponent(filename)
            result = NSImage(contentsOf: url)
        }
        if result == nil, let videoPath = frame.videoPath, let index = frame.videoFrameIndex {
            result = await extractFromVideo(videoPath: videoPath, frameIndex: index)
        }
        if let result {
            cache.setObject(result, forKey: NSNumber(value: frame.id))
        }
        return result
    }

    private func extractFromVideo(videoPath: String, frameIndex: Int64) async -> NSImage? {
        let url = Paths.recordingsDir.appendingPathComponent(videoPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let time = CMTime(value: frameIndex, timescale: K.encodingFrameRate)
        do {
            let cgImage = try await generator.image(at: time).image
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            Log.error("Frame extraction failed (\(videoPath) @ \(frameIndex)): \(error.localizedDescription)")
            return nil
        }
    }
}
