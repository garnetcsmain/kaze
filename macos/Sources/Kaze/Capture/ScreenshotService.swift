import Foundation
import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Captures the primary display every 2s via ScreenCaptureKit (replaces screenshot-desktop),
/// writes <epochMs>.png to temp/screenshots/ and inserts a `frame` row.
/// Kaze's own windows are excluded from capture (the rewind UI never records itself).
final class ScreenshotService {
    private let store: Store
    private var cachedFilter: SCContentFilter?
    private var cachedPixelSize: CGSize = .zero
    private var lastContentRefresh: Date = .distantPast
    /// True while no display is available (screen asleep/locked). Used to log the
    /// transition once rather than on every 2s tick.
    private var noDisplayLogged = false

    init(store: Store) {
        self.store = store
    }

    /// A missing display isn't an error — it means the screen is asleep or locked and
    /// there's nothing to capture. Thrown so capture() can skip the tick quietly.
    private struct NoDisplayAvailable: Error {}

    func capture() async {
        guard store.db.isOpen else { return }
        do {
            let filter = try await contentFilter()
            let config = SCStreamConfiguration()
            config.width = Int(cachedPixelSize.width)
            config.height = Int(cachedPixelSize.height)
            config.showsCursor = false
            config.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)

            let now = Date()
            let filename = "\(Int64(now.timeIntervalSince1970 * 1000)).png"
            let url = Paths.screenshotsDir.appendingPathComponent(filename)
            try writePNG(image, to: url)
            try store.insertFrame(createdAt: now.timeIntervalSince1970, imgFilename: filename)

            if noDisplayLogged {
                Log.info("Screen capture resumed.")
                noDisplayLogged = false
            }
        } catch is NoDisplayAvailable {
            // Screen asleep/locked: skip quietly, log only the first time.
            if !noDisplayLogged {
                Log.info("Screen unavailable (asleep or locked) — pausing capture until it returns.")
                noDisplayLogged = true
            }
            cachedFilter = nil // re-resolve the display when it comes back
        } catch {
            Log.error("Screenshot capture failed: \(error.localizedDescription)")
            cachedFilter = nil // force content refresh next tick (display may have changed)
        }
    }

    private func contentFilter() async throws -> SCContentFilter {
        if let cachedFilter, Date().timeIntervalSince(lastContentRefresh) < 60 {
            return cachedFilter
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NoDisplayAvailable()
        }

        // Exclude our own app so the rewind window never appears in recordings.
        let ownApps = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
                || $0.processID == pid_t(ProcessInfo.processInfo.processIdentifier)
        }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let scale = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }?.backingScaleFactor ?? 2.0

        cachedPixelSize = CGSize(width: CGFloat(display.width) * scale, height: CGFloat(display.height) * scale)
        cachedFilter = filter
        lastContentRefresh = Date()
        return filter
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw NSError(domain: K.bundleID, code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create PNG destination"])
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: K.bundleID, code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "PNG write failed"])
        }
    }
}
