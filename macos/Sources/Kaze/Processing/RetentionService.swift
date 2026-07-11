import Foundation

/// Deletes recordings older than 14 days — port of backend/retention.ts.
/// Runs at startup and on quit (no timer), same as the Electron app.
final class RetentionService {
    private let store: Store

    init(store: Store) {
        self.store = store
    }

    func cleanupOldRecordings() {
        guard store.db.isOpen else { return }
        let cutoff = Date().timeIntervalSince1970 - K.retentionSeconds
        cleanupOldVideos(cutoff: cutoff)
        cleanupOldAudio(cutoff: cutoff)
        cleanupOrphanedFrames(cutoff: cutoff)
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
