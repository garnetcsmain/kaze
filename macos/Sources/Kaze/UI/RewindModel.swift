import Foundation
import AppKit
import SwiftUI

/// State for the rewind timeline — port of the renderer's useTimeline/useFrameLoader/
/// useSearch/useTranscriptions hooks. frames[0] is the newest capture; one index step
/// is ~2 seconds of real time.
@MainActor
final class RewindModel: ObservableObject {
    @Published var frames: [Frame] = []
    @Published var currentIndex = 0
    @Published var currentImage: NSImage?
    @Published var isLoadingFrame = false

    @Published var searchVisible = false
    @Published var searchQuery = "" {
        didSet { scheduleSearch() }
    }
    @Published var searchResults: [SearchHit] = []
    @Published var isSearching = false

    @Published var transcriptVisible = false
    @Published var transcripts: [TranscriptionSegment] = []

    private var searchTask: Task<Void, Never>?
    private var imageLoadTask: Task<Void, Never>?
    private var loadingMore = false
    private var lastTranscriptCenter: Double?
    private var lastWheelNavigation = Date.distantPast

    var currentFrame: Frame? {
        frames.indices.contains(currentIndex) ? frames[currentIndex] : nil
    }

    private var store: Store? { AppState.shared.store }
    private var extractor: FrameExtractor { AppState.shared.frameExtractor }

    // MARK: - Timeline loading

    func loadInitial() {
        guard let store else { return }
        do {
            frames = try store.timeline(limit: 50)
            currentIndex = 0
            displayCurrentFrame()
            refreshTranscriptsIfNeeded(force: true)
        } catch {
            Log.error("Timeline load failed: \(error)")
        }
    }

    /// Jump back to "now" (visibilitychange parity when the window reappears).
    func resetToNewest() {
        loadInitial()
    }

    func navigate(_ delta: Int) {
        guard !frames.isEmpty else { return }
        let target = max(0, min(frames.count - 1, currentIndex + delta))
        guard target != currentIndex else { return }
        currentIndex = target
        displayCurrentFrame()
        loadMoreIfNeeded()
        refreshTranscriptsIfNeeded()
    }

    func setIndex(_ index: Int) {
        guard !frames.isEmpty else { return }
        let clamped = max(0, min(frames.count - 1, index))
        guard clamped != currentIndex else { return }
        currentIndex = clamped
        displayCurrentFrame()
        loadMoreIfNeeded()
        refreshTranscriptsIfNeeded()
    }

    func handleScroll(deltaY: CGFloat) {
        guard Date().timeIntervalSince(lastWheelNavigation) > 0.03 else { return } // 30ms throttle
        lastWheelNavigation = Date()
        if deltaY > 0 {
            navigate(-1)
        } else if deltaY < 0 {
            navigate(1)
        }
    }

    private func loadMoreIfNeeded() {
        guard !loadingMore, currentIndex >= frames.count - 10,
              let store, let lastID = frames.last?.id else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let more = try store.timeline(limit: 50, untilID: lastID)
            if !more.isEmpty {
                frames.append(contentsOf: more)
            }
        } catch {
            Log.error("Timeline pagination failed: \(error)")
        }
    }

    // MARK: - Frame display

    private func displayCurrentFrame() {
        guard let frame = currentFrame else { return }

        // Show the nearest already-cached neighbor while the real frame loads (±5 search).
        if let cached = extractor.cachedImage(for: frame.id) {
            currentImage = cached
            isLoadingFrame = false
        } else {
            if let fallback = nearestCachedImage() {
                currentImage = fallback
            }
            isLoadingFrame = true
        }

        let targetID = frame.id
        imageLoadTask?.cancel()
        imageLoadTask = Task { [weak self] in
            guard let self else { return }
            let image = await self.extractor.image(for: frame)
            guard !Task.isCancelled, self.currentFrame?.id == targetID else { return }
            if let image {
                self.currentImage = image
            }
            self.isLoadingFrame = false
            self.prefetchNeighbors()
        }
    }

    private func nearestCachedImage() -> NSImage? {
        for offset in 1...5 {
            for index in [currentIndex - offset, currentIndex + offset] where frames.indices.contains(index) {
                if let img = extractor.cachedImage(for: frames[index].id) {
                    return img
                }
            }
        }
        return nil
    }

    private func prefetchNeighbors() {
        for index in [currentIndex - 1, currentIndex + 1] where frames.indices.contains(index) {
            let frame = frames[index]
            guard extractor.cachedImage(for: frame.id) == nil else { continue }
            Task.detached(priority: .utility) { [extractor] in
                _ = await extractor.image(for: frame)
            }
        }
    }

    // MARK: - Search

    func toggleSearch() {
        searchVisible.toggle()
        if !searchVisible {
            searchQuery = ""
            searchResults = []
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchQuery
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000) // debounce
            guard !Task.isCancelled, let self, let store = self.store else { return }
            do {
                let hits = try store.search(query, limit: 20)
                guard !Task.isCancelled else { return }
                self.searchResults = hits
            } catch {
                Log.error("Search failed: \(error)")
                self.searchResults = []
            }
            self.isSearching = false
        }
    }

    func jump(to hit: SearchHit) {
        if let frameID = hit.frameID, let index = frames.firstIndex(where: { $0.id == frameID }) {
            setIndex(index)
        } else if let timestamp = hit.createdAt {
            jump(toTimestamp: timestamp)
        }
        searchVisible = false
    }

    /// Reloads the timeline window around an arbitrary point in time, so search hits
    /// outside the loaded page actually land (improvement over the Electron renderer,
    /// which could only snap to the nearest already-loaded frame).
    func jump(toTimestamp timestamp: Double) {
        guard let store else { return }
        do {
            let newer = try store.db.query(
                "SELECT * FROM frame WHERE createdAt > ? ORDER BY createdAt ASC LIMIT 25", [timestamp])
            let older = try store.db.query(
                "SELECT * FROM frame WHERE createdAt <= ? ORDER BY createdAt DESC LIMIT 50", [timestamp])

            func toFrame(_ row: SQLRow) -> Frame? {
                guard let id = row.int("id"), let createdAt = row.double("createdAt") else { return nil }
                return Frame(
                    id: id, createdAt: createdAt,
                    imgFilename: row.string("imgFilename"),
                    videoPath: row.string("videoPath"),
                    videoFrameIndex: row.int("videoFrameIndex"),
                    encodeStatus: row.int("encodeStatus") ?? 0)
            }

            let combined = newer.compactMap(toFrame).reversed() + older.compactMap(toFrame)
            guard !combined.isEmpty else { return }
            frames = Array(combined)
            // Land on the frame nearest the target timestamp.
            currentIndex = frames.enumerated().min {
                abs($0.element.createdAt - timestamp) < abs($1.element.createdAt - timestamp)
            }?.offset ?? 0
            displayCurrentFrame()
            refreshTranscriptsIfNeeded(force: true)
        } catch {
            Log.error("Jump to timestamp failed: \(error)")
        }
    }

    // MARK: - Transcripts

    func toggleTranscript() {
        transcriptVisible.toggle()
        if transcriptVisible {
            refreshTranscriptsIfNeeded(force: true)
        }
    }

    /// Fetch ±300s around the current frame; refetch when moved >30s from the last center.
    func refreshTranscriptsIfNeeded(force: Bool = false) {
        guard let frame = currentFrame, let store else { return }
        let center = frame.createdAt
        if !force, let last = lastTranscriptCenter, abs(center - last) < 30 { return }
        lastTranscriptCenter = center
        do {
            transcripts = try store.transcriptions(from: center - 300, to: center + 300)
        } catch {
            Log.error("Transcript fetch failed: \(error)")
        }
    }

    var activeTranscriptID: Int64? {
        guard let frame = currentFrame else { return nil }
        let t = frame.createdAt
        if let containing = transcripts.first(where: { t >= $0.timestamp && t <= $0.endTimestamp }) {
            return containing.id
        }
        return transcripts.min { abs($0.timestamp - t) < abs($1.timestamp - t) }?.id
    }
}
