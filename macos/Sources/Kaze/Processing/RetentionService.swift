import Foundation

/// Deletes recordings older than 14 days — port of backend/retention.ts.
/// Runs at startup and on quit (no timer), same as the Electron app.
final class RetentionService {
    private let store: Store

    /// Whether a day (`yyyy-MM-dd`) already has a digest. Set by AppState once the analysis
    /// service exists; while it is nil no video is deleted ahead of the normal window.
    var hasDigest: ((String) -> Bool)?

    init(store: Store) {
        self.store = store
    }

    func cleanupOldRecordings() {
        guard store.db.isOpen else { return }
        let cutoff = Date().timeIntervalSince1970 - K.retentionSeconds
        cleanupDigestedVideos()
        cleanupOldVideos(cutoff: cutoff)
        cleanupOldAudio(cutoff: cutoff)
        cleanupOrphanedFrames(cutoff: cutoff)
    }

    /// Screen recordings exist to be scrubbed through and to give the analyzer something to
    /// look at. Once a day has been analyzed and has had `videoDigestGraceDays` to be
    /// reviewed, its videos are dead weight: the digest, the OCR text and the search index
    /// all outlive them. Only the imagery goes — the frame rows stay, so that day is still
    /// searchable until the normal retention window closes.
    ///
    /// A day the analyzer never got to (no API key, no credit, offline) has no digest, so it
    /// is left alone entirely.
    private func cleanupDigestedVideos() {
        guard let hasDigest else { return }
        let cutoff = Date().timeIntervalSince1970 - K.videoDigestGraceDays * 24 * 3600
        let calendar = Calendar.current

        do {
            var count = 0
            var bytes: Int64 = 0
            for video in try store.videosLastSeenBefore(cutoff) {
                // Attributed by its last frame, so a clip spanning midnight counts as the
                // later day and is kept until that day is analyzed too.
                let day = DayLabel.string(
                    from: calendar.startOfDay(for: Date(timeIntervalSince1970: video.lastAt)))
                guard hasDigest(day) else { continue }

                let url = Paths.recordingsDir.appendingPathComponent(video.path)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path))
                    .flatMap { $0[.size] as? Int64 } ?? 0
                try? FileManager.default.removeItem(at: url)
                try store.clearVideoReferences(videoPath: video.path)
                count += 1
                bytes += size
            }
            if count > 0 {
                Log.info("Retention: removed \(count) video(s) from analyzed days, freeing \(bytes / 1_048_576) MB — text and search kept")
            }
        } catch {
            Log.error("Retention (analyzed videos) failed: \(error)")
        }
    }

    private func cleanupOldVideos(cutoff: Double) {
        do {
            for videoPath in try store.videosOlderThan(cutoff: cutoff) {
                let url = Paths.recordingsDir.appendingPathComponent(videoPath)
                try? FileManager.default.removeItem(at: url)
                try store.clearVideoReferences(videoPath: videoPath)
                Log.info("Retention: deleted video \(videoPath)")
            }
        } catch {
            Log.error("Retention (videos) failed: \(error)")
        }
    }

    private func cleanupOldAudio(cutoff: Double) {
        do {
            for chunk in try store.audioChunksOlderThan(cutoff: cutoff) {
                let url = Paths.audioDir.appendingPathComponent(chunk.filename)
                try? FileManager.default.removeItem(at: url)
                try store.deleteAudioChunkCascade(chunk.id)
            }
        } catch {
            Log.error("Retention (audio) failed: \(error)")
        }
    }

    private func cleanupOrphanedFrames(cutoff: Double) {
        do {
            try store.deleteOrphanedFrames(cutoff: cutoff)
        } catch {
            Log.error("Retention (frames) failed: \(error)")
        }
    }
}
