import SwiftUI
import AppKit

// MARK: - Timeline bar (bottom glass bar with scrub track)

struct TimelineBar: View {
    @ObservedObject var model: RewindModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(timeLabel)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                if !model.frames.isEmpty {
                    Text("\(model.currentIndex + 1) / \(model.frames.count)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            scrubTrack

            if model.frames.count >= 20 {
                tickLabels
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.black.opacity(0.45))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
    }

    private var scrubTrack: some View {
        GeometryReader { geo in
            let progress = model.frames.count > 1
                ? CGFloat(model.currentIndex) / CGFloat(model.frames.count - 1)
                : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.2))
                    .frame(height: 4)
                Capsule()
                    .fill(.white.opacity(0.7))
                    .frame(width: max(4, progress * geo.size.width), height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .offset(x: progress * (geo.size.width - 12))
                    .shadow(radius: 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard model.frames.count > 1 else { return }
                        let ratio = min(1, max(0, value.location.x / geo.size.width))
                        model.setIndex(Int((ratio * CGFloat(model.frames.count - 1)).rounded()))
                    }
            )
        }
        .frame(height: 16)
    }

    private var tickLabels: some View {
        HStack {
            ForEach(tickIndices, id: \.self) { index in
                Text(shortTime(model.frames[index].date))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
                if index != tickIndices.last {
                    Spacer()
                }
            }
        }
    }

    private var tickIndices: [Int] {
        let count = model.frames.count
        guard count >= 20 else { return [] }
        return (0..<5).map { $0 * (count - 1) / 4 }
    }

    private var timeLabel: String {
        guard let frame = model.currentFrame else { return "—" }
        let date = frame.date
        let age = Date().timeIntervalSince(date)
        if age < 3600 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
        } else {
            formatter.dateFormat = "EEE, MMM d · h:mm a"
        }
        return formatter.string(from: date)
    }

    private func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}

// MARK: - Search overlay (pill input + results dropdown)

struct SearchOverlay: View {
    @ObservedObject var model: RewindModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.white.opacity(0.6))
                TextField("Search screen text and audio…", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .focused($focused)
                if model.isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else if !model.searchQuery.isEmpty {
                    Text(resultCount)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.black.opacity(0.5))
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))

            if !model.searchResults.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.searchResults) { hit in
                            SearchResultRow(hit: hit) {
                                model.jump(to: hit)
                            }
                            Divider().overlay(.white.opacity(0.08))
                        }
                    }
                }
                .frame(maxHeight: 360)
                .background(.black.opacity(0.5))
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                )
            }
        }
        .frame(width: 500)
        .onAppear { focused = true }
    }

    private var resultCount: String {
        let count = model.searchResults.count
        return count == 1 ? "1 result" : "\(count) results"
    }
}

private struct SearchResultRow: View {
    let hit: SearchHit
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: hit.source == "audio" ? "mic" : "display")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.attributedSnippet(hit.snippet))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let createdAt = hit.createdAt {
                        Text(Date(timeIntervalSince1970: createdAt), format: .dateTime.month().day().hour().minute())
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Renders FTS5 snippet() output, highlighting <mark>…</mark> spans in yellow.
    static func attributedSnippet(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(snippet)
        while let open = rest.range(of: "<mark>") {
            result += AttributedString(String(rest[..<open.lowerBound]))
            rest = rest[open.upperBound...]
            if let close = rest.range(of: "</mark>") {
                var marked = AttributedString(String(rest[..<close.lowerBound]))
                marked.backgroundColor = Color(red: 1, green: 0.84, blue: 0, opacity: 0.35)
                result += marked
                rest = rest[close.upperBound...]
            }
        }
        result += AttributedString(String(rest))
        return result
    }
}

// MARK: - Transcript panel (left side)

struct TranscriptPanel: View {
    @ObservedObject var model: RewindModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TRANSCRIPT")
                .font(.system(size: 11, weight: .semibold))
                .kerning(1.2)
                .foregroundStyle(.white.opacity(0.5))
                .padding(12)

            if model.transcripts.isEmpty {
                Text("No transcriptions in this time range.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(12)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(model.transcripts) { segment in
                                TranscriptRow(
                                    segment: segment,
                                    isActive: segment.id == model.activeTranscriptID
                                ) {
                                    model.jump(toTimestamp: segment.timestamp)
                                }
                                .id(segment.id)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: model.activeTranscriptID) { _, active in
                        if let active {
                            withAnimation { proxy.scrollTo(active, anchor: .center) }
                        }
                    }
                }
            }
        }
        .background(.black.opacity(0.5))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
    }
}

private struct TranscriptRow: View {
    let segment: TranscriptionSegment
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(Date(timeIntervalSince1970: segment.timestamp), format: .dateTime.hour().minute().second())
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.45))
                    if let language = segment.language {
                        Text(language.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.white.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                Text(segment.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(isActive ? 1 : 0.75))
                    .multilineTextAlignment(.leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? .white.opacity(0.12) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
