import Foundation

struct Frame: Identifiable, Equatable {
    let id: Int64
    let createdAt: Double // unix seconds
    let imgFilename: String?
    let videoPath: String?
    let videoFrameIndex: Int64?
    let encodeStatus: Int64

    var date: Date { Date(timeIntervalSince1970: createdAt) }
}

struct SearchHit: Identifiable {
    let source: String // "ocr" | "audio"
    let sourceID: Int64
    let frameID: Int64?
    let audioChunkID: Int64?
    let snippet: String
    let createdAt: Double?

    var id: String { "\(source)-\(sourceID)" }
}

struct TranscriptionSegment: Identifiable {
    let id: Int64
    let text: String
    let language: String?
    let timestamp: Double // absolute unix seconds (chunk start + offset)
    let endTimestamp: Double
    let audioChunkID: Int64
}

struct PendingAudioChunk {
    let id: Int64
    let filename: String
    let startedAt: Double
}

struct EncodingTaskRow {
    let id: Int64
}

struct LibraryFile: Identifiable {
    let name: String
    let size: Int64
    let modifiedAt: Date
    var id: String { name }
}

struct LibraryStats {
    var videoFiles: [LibraryFile] = []
    var audioFiles: [LibraryFile] = []
    var videoSize: Int64 = 0
    var audioSize: Int64 = 0
    var databaseSize: Int64 = 0
    var totalSize: Int64 { videoSize + audioSize + databaseSize }
}

struct ActivityStatus {
    var encoding = false
    var framesWaiting = 0
    var transcribing = false
    var audioWaiting = 0

    var isActive: Bool { encoding || transcribing }
    var isEmpty: Bool { !encoding && !transcribing && framesWaiting == 0 && audioWaiting == 0 }
}
