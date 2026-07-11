import Foundation
import os

/// Lightweight logger: os.log (Console.app) plus a plain-text file in the data dir.
enum Log {
    private static let logger = Logger(subsystem: K.bundleID, category: "app")
    private static let fileQueue = DispatchQueue(label: "kaze.log", qos: .utility)
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write("INFO", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        write("ERROR", message)
    }

    private static func write(_ level: String, _ message: String) {
        fileQueue.async {
            let line = "\(dateFormatter.string(from: Date())) [\(level)] \(message)\n"
            let url = Paths.logsDir.appendingPathComponent("kaze.log")
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
