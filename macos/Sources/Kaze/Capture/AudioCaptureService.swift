import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreAudio
import AudioToolbox

/// Captures system audio (ScreenCaptureKit) + microphone (AVAudioEngine), mixes them
/// into mono 16kHz 16-bit PCM WAV chunks of 30s, and inserts audio_chunk rows.
///
/// Ported in-process from native/audio-capture/ (the standalone CLI the Electron app
/// spawned). The CLI/stdout protocol is gone — chunks are reported via a callback.
/// One fix over the original: files are named/stamped with the chunk START time
/// (the CLI used the write moment, i.e. the chunk end, shifting transcripts by 30s).
final class AudioCaptureService: NSObject, @unchecked Sendable {
    private let targetSampleRate: Double = K.audioSampleRate
    private let chunkDuration: Double = K.audioChunkDuration
    private let samplesPerChunk: Int

    private let bufferLock = NSLock()
    private var micBuffer: [Float] = []
    private var systemBuffer: [Float] = []

    private var audioEngine: AVAudioEngine?
    private var scStream: SCStream?
    private var streamDelegate: StreamOutputDelegate?

    private(set) var micAvailable = false
    private(set) var systemAudioAvailable = false
    private var isRunning = false

    /// Called with (fileURL, chunkStartDate, durationSeconds) after each WAV is written.
    var onChunk: ((URL, Date, Double) -> Void)?

    override init() {
        self.samplesPerChunk = Int(K.audioSampleRate * K.audioChunkDuration)
        super.init()
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        try? FileManager.default.createDirectory(at: Paths.audioDir, withIntermediateDirectories: true)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.startSystemAudioCapture() }
            group.addTask { await self.startMicrophoneCapture() }
        }

        if !micAvailable && !systemAudioAvailable {
            Log.error("Audio: neither microphone nor system audio available — check permissions")
        } else {
            Log.info("Audio capture started (mic: \(micAvailable), system: \(systemAudioAvailable))")
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }
        if let stream = scStream {
            stream.stopCapture { error in
                if let error {
                    Log.error("Audio: error stopping SCStream: \(error.localizedDescription)")
                }
            }
            scStream = nil
        }
        flushBuffer()
    }

    // MARK: - Microphone (AVAudioEngine)

    private func startMicrophoneCapture() async {
        // AVAudioEngine.inputNode BLOCKS its queue while the mic permission dialog is
        // unanswered (and quit then deadlocks against it) — resolve permission first.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                Log.error("Audio: microphone permission denied")
                return
            }
        default:
            Log.error("Audio: microphone permission not granted")
            return
        }

        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            Log.error("Audio: no microphone input device available")
            return
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate,
            channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        else {
            Log.error("Audio: could not create microphone converter")
            return
        }

        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.1) // 100ms buffers
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self, self.isRunning else { return }
            self.processInputBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        do {
            try engine.start()
            micAvailable = true
        } catch {
            Log.error("Audio: could not start microphone capture (permission?): \(error.localizedDescription)")
        }
    }

    private func processInputBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * (targetSampleRate / buffer.format.sampleRate)) + 1
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }

        var error: NSError?
        var allConsumed = false
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if allConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            allConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let error {
            Log.error("Audio: mic conversion error: \(error.localizedDescription)")
            return
        }
        guard convertedBuffer.frameLength > 0, let channelData = convertedBuffer.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(convertedBuffer.frameLength)))
        appendSamples(samples, to: \.micBuffer)
    }

    // MARK: - System audio (ScreenCaptureKit)

    private func startSystemAudioCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                Log.error("Audio: no display found for system audio capture")
                return
            }

            let config = SCStreamConfiguration()
            // Audio-only: SCK requires a display target, so use a 2x2 video at 1fps.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.capturesAudio = true
            config.sampleRate = Int(targetSampleRate)
            config.channelCount = 1
            config.excludesCurrentProcessAudio = true

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let delegate = StreamOutputDelegate { [weak self] sampleBuffer in
                self?.processSystemAudioBuffer(sampleBuffer)
            }
            self.streamDelegate = delegate

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            let audioQueue = DispatchQueue(label: "\(K.bundleID).system-audio")
            try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: audioQueue)
            try await stream.startCapture()
            self.scStream = stream
            systemAudioAvailable = true
        } catch {
            Log.error("Audio: could not start system audio capture (screen recording permission?): \(error.localizedDescription)")
        }
    }

    private func processSystemAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning else { return }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)

        var dataPointer: UnsafeMutablePointer<Int8>?
        var lengthAtOffset = 0
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let ptr = dataPointer else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }
        let format = asbd.pointee

        if format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let floatCount = length / MemoryLayout<Float>.size
            let floatPtr = UnsafeRawPointer(ptr).bindMemory(to: Float.self, capacity: floatCount)
            var samples: [Float]
            let channelCount = Int(format.mChannelsPerFrame)
            if channelCount > 1 {
                let frameCount = floatCount / channelCount
                samples = [Float](repeating: 0, count: frameCount)
                for frame in 0..<frameCount {
                    var sum: Float = 0
                    for ch in 0..<channelCount {
                        sum += floatPtr[frame * channelCount + ch]
                    }
                    samples[frame] = sum / Float(channelCount)
                }
            } else {
                samples = Array(UnsafeBufferPointer(start: floatPtr, count: floatCount))
            }
            appendSamples(samples, to: \.systemBuffer)
        } else if format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
            let int16Count = length / MemoryLayout<Int16>.size
            let int16Ptr = UnsafeRawPointer(ptr).bindMemory(to: Int16.self, capacity: int16Count)
            let channelCount = max(1, Int(format.mChannelsPerFrame))
            let frameCount = int16Count / channelCount
            var samples = [Float](repeating: 0, count: frameCount)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += Float(int16Ptr[frame * channelCount + ch]) / 32768.0
                }
                samples[frame] = sum / Float(channelCount)
            }
            appendSamples(samples, to: \.systemBuffer)
        }
    }

    // MARK: - Mixing & chunking

    private func appendSamples(_ samples: [Float], to keyPath: ReferenceWritableKeyPath<AudioCaptureService, [Float]>) {
        bufferLock.lock()
        self[keyPath: keyPath].append(contentsOf: samples)
        checkAndWriteChunks()
        bufferLock.unlock()
    }

    /// Mix by summing the two buffers position-by-position on a shared timeline;
    /// emit a chunk when the longer buffer reaches samplesPerChunk. (Same algorithm
    /// as the original checkAndWriteChunks; must be called with bufferLock held.)
    private func checkAndWriteChunks() {
        while max(micBuffer.count, systemBuffer.count) >= samplesPerChunk {
            let micCount = min(micBuffer.count, samplesPerChunk)
            let sysCount = min(systemBuffer.count, samplesPerChunk)

            var chunk = [Float](repeating: 0, count: samplesPerChunk)
            for i in 0..<micCount { chunk[i] += micBuffer[i] }
            for i in 0..<sysCount { chunk[i] += systemBuffer[i] }

            if micCount > 0 { micBuffer.removeFirst(micCount) }
            if sysCount > 0 { systemBuffer.removeFirst(sysCount) }

            bufferLock.unlock()
            writeChunk(chunk)
            bufferLock.lock()
        }
    }

    private func flushBuffer() {
        bufferLock.lock()
        let micRemaining = micBuffer
        let sysRemaining = systemBuffer
        micBuffer.removeAll()
        systemBuffer.removeAll()
        bufferLock.unlock()

        let count = max(micRemaining.count, sysRemaining.count)
        guard count > 0 else { return }
        var mixed = [Float](repeating: 0, count: count)
        for i in 0..<micRemaining.count { mixed[i] += micRemaining[i] }
        for i in 0..<sysRemaining.count { mixed[i] += sysRemaining[i] }
        writeChunk(mixed)
    }

    // MARK: - WAV output

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        f.timeZone = .current
        return f
    }()

    private func writeChunk(_ samples: [Float]) {
        let duration = Double(samples.count) / targetSampleRate
        let startDate = Date().addingTimeInterval(-duration)
        let filename = "\(Self.filenameFormatter.string(from: startDate)).wav"
        let url = Paths.audioDir.appendingPathComponent(filename)

        guard writeWAV(samples: samples, to: url) else {
            Log.error("Audio: failed to write WAV chunk \(filename)")
            return
        }
        onChunk?(url, startDate, duration)
    }

    private func writeWAV(samples: [Float], to url: URL) -> Bool {
        let sampleRate = UInt32(targetSampleRate)
        let numChannels: UInt16 = 1
        let bps: UInt16 = 16
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bps / 8)
        let blockAlign = numChannels * (bps / 8)
        let dataSize = UInt32(samples.count) * UInt32(bps / 8)
        let chunkSize = 36 + dataSize

        var data = Data(capacity: 44 + Int(dataSize))
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bps.littleEndian) { Array($0) })
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16Value = Int16(clamped * 32767.0)
            data.append(contentsOf: withUnsafeBytes(of: int16Value.littleEndian) { Array($0) })
        }
        return FileManager.default.createFile(atPath: url.path, contents: data)
    }
}

// MARK: - SCStream output delegate

private final class StreamOutputDelegate: NSObject, SCStreamOutput, @unchecked Sendable {
    private let handler: (CMSampleBuffer) -> Void

    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        handler(sampleBuffer)
    }
}
