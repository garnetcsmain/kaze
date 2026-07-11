import SwiftUI
import AppKit

/// Library window — port of pages/library (Liquid Glass design):
/// storage overview, video/audio file lists, transcriptions, DB info, live status.
struct LibraryView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model = LibraryModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                StatusBarView(status: model.status)
                StorageOverview(stats: model.stats)
                FileSection(
                    title: "Screen Recordings",
                    files: model.stats.videoFiles,
                    totalSize: model.stats.videoSize,
                    folder: Paths.recordingsDir,
                    accent: .blue
                ) { model.deleteVideo($0) }
                FileSection(
                    title: "Audio Recordings",
                    files: model.stats.audioFiles,
                    totalSize: model.stats.audioSize,
                    folder: Paths.audioDir,
                    accent: .teal
                ) { model.deleteAudio($0) }
                TranscriptionsSection(model: model)
                DatabaseSection(size: model.stats.databaseSize)
                Text("Files older than \(Int(K.retentionDays)) days are automatically deleted.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
            .padding(16)
        }
        .frame(width: 660, height: 620)
        .background(LibraryBackground())
        .task {
            model.refreshAll()
            model.startStatusPolling()
        }
        .onDisappear { model.stopStatusPolling() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAll() // refresh-on-focus parity
        }
    }
}

// MARK: - Model

@MainActor
final class LibraryModel: ObservableObject {
    @Published var stats = LibraryStats()
    @Published var status = ActivityStatus()
    @Published var transcriptions: [TranscriptionSegment] = []
    @Published var copiedAll = false

    private var statusTimer: Timer?
    private var store: Store? { AppState.shared.store }

    func refreshAll() {
        refreshStats()
        refreshStatus()
        refreshTranscriptions()
    }

    func startStatusPolling() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    func stopStatusPolling() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func refreshStats() {
        var next = LibraryStats()
        next.videoFiles = listFiles(in: Paths.recordingsDir)
        next.audioFiles = listFiles(in: Paths.audioDir)
        next.videoSize = next.videoFiles.reduce(0) { $0 + $1.size }
        next.audioSize = next.audioFiles.reduce(0) { $0 + $1.size }
        let dbAttrs = try? FileManager.default.attributesOfItem(atPath: Paths.dbFile.path)
        next.databaseSize = (dbAttrs?[.size] as? Int64) ?? 0
        stats = next
    }

    private func listFiles(in dir: URL) -> [LibraryFile] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names
            .filter { !$0.hasPrefix(".") }
            .compactMap { name -> LibraryFile? in
                let url = dir.appendingPathComponent(name)
                guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
                return LibraryFile(
                    name: name,
                    size: (attrs[.size] as? Int64) ?? 0,
                    modifiedAt: (attrs[.modificationDate] as? Date) ?? .distantPast)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func refreshStatus() {
        guard let store else { return }
        status = (try? store.activityStatus()) ?? ActivityStatus()
    }

    private func refreshTranscriptions() {
        guard let store else { return }
        transcriptions = (try? store.recentTranscriptions(limit: 30)) ?? []
    }

    // MARK: Actions

    func deleteVideo(_ file: LibraryFile) {
        try? FileManager.default.removeItem(at: Paths.recordingsDir.appendingPathComponent(file.name))
        try? store?.deleteVideoRecords(filename: file.name)
        refreshAll()
    }

    func deleteAudio(_ file: LibraryFile) {
        try? FileManager.default.removeItem(at: Paths.audioDir.appendingPathComponent(file.name))
        try? store?.deleteAudioRecords(filename: file.name)
        refreshAll()
    }

    func deleteTranscription(_ id: Int64) {
        try? store?.deleteTranscription(id)
        refreshTranscriptions()
    }

    func copyTranscription(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyAllTranscriptions() {
        guard let store else { return }
        let all = (try? store.recentTranscriptions(limit: 10000)) ?? []
        let text = all.reversed().map(\.text).joined(separator: "\n") // chronological
        copyTranscription(text)
        copiedAll = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copiedAll = false
        }
    }
}

// MARK: - Background (subtle radial gradients over the window material)

private struct LibraryBackground: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            RadialGradient(colors: [.blue.opacity(0.07), .clear], center: .topLeading, startRadius: 0, endRadius: 500)
            RadialGradient(colors: [.purple.opacity(0.06), .clear], center: .topTrailing, startRadius: 0, endRadius: 500)
            RadialGradient(colors: [.green.opacity(0.05), .clear], center: .bottomLeading, startRadius: 0, endRadius: 500)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Sections

private struct GlassCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
        )
    }
}

private struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(1.1)
            .foregroundStyle(.secondary)
    }
}

private struct StatusBarView: View {
    let status: ActivityStatus

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(status.isActive ? .green : .secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var statusText: String {
        var parts: [String] = []
        if status.encoding { parts.append("Encoding video") }
        if status.framesWaiting > 0 { parts.append("\(status.framesWaiting) frames waiting") }
        if status.transcribing { parts.append("Transcribing audio") }
        if status.audioWaiting > 0 { parts.append("\(status.audioWaiting) chunks queued") }
        return parts.isEmpty ? "Idle" : parts.joined(separator: " · ")
    }
}

private struct StorageOverview: View {
    let stats: LibraryStats

    var body: some View {
        GlassCard {
            SectionLabel(text: "Storage")
            Text(ByteFormat.string(stats.totalSize))
                .font(.system(size: 24, weight: .semibold))
                .monospacedDigit()

            GeometryReader { geo in
                HStack(spacing: 2) {
                    segment(.blue, stats.videoSize, geo.size.width)
                    segment(.teal, stats.audioSize, geo.size.width)
                    segment(.orange, stats.databaseSize, geo.size.width)
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())

            HStack(spacing: 16) {
                legend(.blue, "Video", stats.videoSize)
                legend(.teal, "Audio", stats.audioSize)
                legend(.orange, "Database", stats.databaseSize)
            }
        }
    }

    private func segment(_ color: Color, _ size: Int64, _ totalWidth: CGFloat) -> some View {
        let total = max(1, stats.totalSize)
        let width = totalWidth * CGFloat(size) / CGFloat(total)
        return Rectangle().fill(color).frame(width: max(0, width))
    }

    private func legend(_ color: Color, _ label: String, _ size: Int64) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(ByteFormat.string(size)).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
    }
}

private struct FileSection: View {
    let title: String
    let files: [LibraryFile]
    let totalSize: Int64
    let folder: URL
    let accent: Color
    let onDelete: (LibraryFile) -> Void

    private let maxVisible = 15

    var body: some View {
        GlassCard {
            HStack {
                SectionLabel(text: title)
                Spacer()
                Text("\(files.count) files · \(ByteFormat.string(totalSize))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button {
                    NSWorkspace.shared.open(folder)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show in Finder")
            }

            if files.isEmpty {
                Text("No files yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(files.prefix(maxVisible)) { file in
                        FileRow(file: file, accent: accent) { onDelete(file) }
                        if file.id != files.prefix(maxVisible).last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
                if files.count > maxVisible {
                    Text("+\(files.count - maxVisible) more")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct FileRow: View {
    let file: LibraryFile
    let accent: Color
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(accent.opacity(0.7)).frame(width: 6, height: 6)
            Text(file.name)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(ByteFormat.string(file.size))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(ByteFormat.shortDate(file.modifiedAt))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(.red.opacity(hovering ? 1 : 0))
            }
            .buttonStyle(.plain)
            .frame(width: 16)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct TranscriptionsSection: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        GlassCard {
            HStack {
                SectionLabel(text: "Transcriptions")
                Spacer()
                Button {
                    model.copyAllTranscriptions()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.copiedAll ? "checkmark" : "doc.on.doc")
                        Text(model.copiedAll ? "Copied" : "Copy all")
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.copiedAll ? .green : .secondary)
            }

            if model.transcriptions.isEmpty {
                Text("No transcriptions yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.transcriptions.prefix(20)) { item in
                        TranscriptionRow(item: item, model: model)
                        if item.id != model.transcriptions.prefix(20).last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }
}

private struct TranscriptionRow: View {
    let item: TranscriptionSegment
    @ObservedObject var model: LibraryModel
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(.system(size: 12))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(ByteFormat.shortDate(Date(timeIntervalSince1970: item.timestamp)))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if let language = item.language {
                        Text(language.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if hovering {
                Button { model.copyTranscription(item.text) } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Button { model.deleteTranscription(item.id) } label: {
                    Image(systemName: "trash").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct DatabaseSection: View {
    let size: Int64

    var body: some View {
        GlassCard {
            HStack {
                SectionLabel(text: "Database")
                Spacer()
                Text(ByteFormat.string(size))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([Paths.dbFile])
                } label: {
                    Image(systemName: "folder").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show in Finder")
            }
        }
    }
}

// MARK: - Formatting helpers

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
        } else {
            formatter.dateFormat = "MMM d"
        }
        return formatter.string(from: date)
    }
}
