import Foundation

/// Turns a day of raw OCR frames + transcripts into a compact activity timeline the model
/// can read cheaply. Kaze captures a frame every 2s (~14k+ frames in a workday), so the
/// key job is collapsing runs of near-identical screens into segments — "text, so it's
/// basically free" only holds after de-duplication.
final class DayCompactor {
    private let store: Store

    init(store: Store) {
        self.store = store
    }

    struct DayData {
        let day: String
        let segments: [ActivitySegment]
        let transcriptLines: [String]
        let frameCount: Int
        let truncated: Bool
    }

    /// Local day bounds for a given date.
    static func dayBounds(_ date: Date) -> (start: Double, end: Double, label: String) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return (start.timeIntervalSince1970, end.timeIntervalSince1970, fmt.string(from: start))
    }

    func compact(for date: Date) throws -> DayData {
        let (start, end, label) = Self.dayBounds(date)

        // OCR text per frame, in order (frame id kept for vision sampling).
        let rows = try store.db.query("""
            SELECT f.id AS fid, f.createdAt AS ts, r.text AS text
            FROM frame f JOIN recognition_data r ON r.frameID = f.id
            WHERE f.createdAt >= ? AND f.createdAt < ? AND r.text IS NOT NULL AND length(r.text) > 0
            ORDER BY f.createdAt
            """, [start, end])

        var segments: [ActivitySegment] = []
        var frameCount = 0
        var curStart: Date?
        var curEnd = Date()
        var curText = ""
        var curTokens = Set<String>()
        var curFrameIDs: [Int64] = []

        func flush() {
            guard let s = curStart, !curText.isEmpty else { return }
            segments.append(ActivitySegment(
                start: s, end: curEnd, appHint: Self.appHint(from: curText),
                text: Self.trim(curText),
                tokenCount: curTokens.count,
                representativeFrameID: curFrameIDs.isEmpty ? nil : curFrameIDs[curFrameIDs.count / 2]))
        }

        for row in rows {
            guard let ts = row.double("ts"), let text = row.string("text") else { continue }
            frameCount += 1
            let date = Date(timeIntervalSince1970: ts)
            let tokens = Self.tokenize(text)

            if let _ = curStart, Self.similar(curTokens, tokens) {
                // Same screen — extend the current segment.
                curEnd = date
                if let fid = row.int("fid") { curFrameIDs.append(fid) }
            } else {
                flush()
                curStart = date
                curEnd = date
                curText = text
                curTokens = tokens
                curFrameIDs = row.int("fid").map { [$0] } ?? []
            }
        }
        flush()

        // Keep the longest-dwell segments if we exceed the cap (those are where time went).
        var truncated = false
        if segments.count > K.analysisMaxSegments {
            truncated = true
            let kept = segments.sorted { $0.durationSeconds > $1.durationSeconds }
                .prefix(K.analysisMaxSegments)
            segments = kept.sorted { $0.start < $1.start }
            Log.info("Analysis: truncated \(label) to \(K.analysisMaxSegments) of \(rows.count) segments by dwell time")
        }

        // Transcripts for the day.
        let transcripts = try store.transcriptions(from: start, to: end, limit: 500)
        let transcriptLines = transcripts
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return DayData(day: label, segments: segments, transcriptLines: transcriptLines,
                       frameCount: frameCount, truncated: truncated)
    }

    /// Render the compacted day as the user-turn text for the model. `visuals` maps a
    /// segment's representative frame ID to a vision-model description of that screen.
    static func renderPrompt(_ data: DayData, visuals: [Int64: String] = [:]) -> String {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        var lines: [String] = []
        lines.append("# Activity timeline for \(data.day)")
        lines.append("(\(data.frameCount) screen captures collapsed into \(data.segments.count) segments" +
                     (data.truncated ? ", truncated to the longest-dwell segments)" : ")"))
        lines.append("")
        for seg in data.segments {
            let dur = Int(seg.durationSeconds)
            let durLabel = dur >= 60 ? "\(dur / 60)m" : "\(dur)s"
            let app = seg.appHint.map { "[\($0)] " } ?? ""
            var suffix = ""
            if let fid = seg.representativeFrameID, let visual = visuals[fid] {
                suffix = " [visual: \(visual)]"
            } else if seg.isAmbiguous {
                suffix = " [low-text screen — content unclear from OCR]"
            }
            lines.append("\(timeFmt.string(from: seg.start))–\(timeFmt.string(from: seg.end)) (\(durLabel)) \(app)\(seg.text)\(suffix)")
        }
        if !data.transcriptLines.isEmpty {
            lines.append("")
            lines.append("# Audio transcript excerpts")
            lines.append(contentsOf: data.transcriptLines.prefix(200))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Text heuristics

    private static func tokenize(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count > 2 }.map(String.init))
    }

    /// Two screens are "the same" only if their salient tokens are nearly identical
    /// (Jaccard ≥ 0.85). A high bar matters: merging distinct screens (e.g. different
    /// sites in a morning polling loop) would erase the very repetition the analysis
    /// exists to detect. Better to keep a few extra segments than to lose the pattern.
    private static func similar(_ a: Set<String>, _ b: Set<String>) -> Bool {
        if a.isEmpty && b.isEmpty { return true }
        let inter = a.intersection(b).count
        let union = a.union(b).count
        guard union > 0 else { return true }
        return Double(inter) / Double(union) >= 0.85
    }

    /// Best-effort app/window name — the macOS menu bar OCRs as the first line and usually
    /// starts with the frontmost app's name.
    private static func appHint(from text: String) -> String? {
        guard let first = text.split(separator: "\n").first else { return nil }
        let words = first.split(separator: " ").prefix(2).joined(separator: " ")
        let cleaned = words.trimmingCharacters(in: .whitespaces)
        return cleaned.count >= 2 && cleaned.count <= 40 ? cleaned : nil
    }

    /// Keep a segment's text compact — first ~500 chars of de-newlined content.
    private static func trim(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " · ")
            .replacingOccurrences(of: "  ", with: " ")
        return String(collapsed.prefix(500))
    }
}
