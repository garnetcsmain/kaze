import Foundation
import AppKit

/// Exports a timeline frame as a downscaled JPEG for vision sampling. Works whether the
/// frame is still a PNG on disk or already encoded into a video (FrameExtractor handles
/// both). Downscaling keeps per-image token cost modest.
enum FrameJPEG {
    static func data(for frame: Frame, extractor: FrameExtractor,
                     maxDimension: CGFloat = K.visionMaxImageDimension,
                     quality: CGFloat = 0.6) async -> Data? {
        guard let image = await extractor.image(for: frame) else { return nil }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        let scale = min(1, maxDimension / max(width, height))
        let outW = Int(width * scale), outH = Int(height * scale)

        let scaled: CGImage
        if scale < 1 {
            guard let ctx = CGContext(
                data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return nil }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            guard let out = ctx.makeImage() else { return nil }
            scaled = out
        } else {
            scaled = cg
        }

        let rep = NSBitmapImageRep(cgImage: scaled)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
