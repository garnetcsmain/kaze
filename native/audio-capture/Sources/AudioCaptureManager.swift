import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreAudio
import AudioToolbox

/// Manages capturing system audio via ScreenCaptureKit and microphone audio via AVAudioEngine,
/// mixing them into mono 16kHz 16-bit PCM WAV chunks.
final class AudioCaptureManager: NSObject, @unchecked Sendable {

    // MARK: - Configuration

    private let outputDir: String
    private let chunkDuration: Double
    private let targetSampleRate: Double = 16000.0
    private let targetChannels: UInt32 = 1
    private let bitsPerSample: UInt32 = 16

    // MARK: - State

    private let bufferLock = NSLock()
    /// Separate buffers for each audio source, keyed by time-based sample index.
    /// Both are written into the same timeline so they can be summed for mixing.
    private var micBuffer: [Float] = []
    private var systemBuffer: [Float] = []
    /// How many samples have been consumed (written out) so far.
    private var samplesConsumed: Int = 0
    private let samplesPerChunk: Int

    private var audioEngine: AVAudioEngine?
    private var scStream: SCStream?
    private var streamDelegate: StreamOutputDelegate?

    private var micAvailable = false
    private var systemAudioAvailable = false
    private var isRunning = false

    // MARK: - Init

    init(outputDir: String, chunkDuration: Double) {
        self.outputDir = outputDir
        self.chunkDuration = chunkDuration
        self.samplesPerChunk = Int(16000.0 * chunkDuration)
        super.init()
    }

    // MARK: - Public API

    func start() async {
        isRunning = true

        // Ensure output directory exists
        try? FileManager.default.createDirectory(
            atPath: outputDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Start both capture sources concurrently
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.startSystemAudioCapture() }
            group.addTask { await self.startMicrophoneCapture() }
        }

        if !micAvailable && !systemAudioAvailable {
            fputs("ERROR: Neither microphone nor system audio capture is available. Check permissions.\n", stderr)
        } else {
            if micAvailable {
                fputs("INFO: Microphone capture started.\n", stderr)
            }
            if systemAudioAvailable {
                fputs("INFO: System audio capture started.\n", stderr)
            }
        }
    }

    func stop() {
        isRunning = false

        // Stop microphone
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }

        // Stop system audio
        if let stream = scStream {
            stream.stopCapture { error in
                if let error = error {
                    fputs("WARNING: Error stopping SCStream: \(error.localizedDescription)\n", stderr)
                }
            }
            scStream = nil
        }

        // Flush remaining buffer as partial chunk
        flushBuffer()
    }

    // MARK: - Microphone Capture (AVAudioEngine)

    private func startMicrophoneCapture() async {
        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            fputs("WARNING: No microphone input device available.\n", stderr)
            return
        }

        // Target format: mono 16kHz Float32 for mixing
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: AVAudioChannelCount(targetChannels),
            interleaved: false
        ) else {
            fputs("WARNING: Could not create target audio format for microphone.\n", stderr)
            return
        }

        // Create a converter from input format to target format
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            fputs("WARNING: Could not create audio converter for microphone.\n", stderr)
            return
        }

        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.1) // 100ms buffers
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) {
            [weak self] (buffer, _) in
            guard let self = self, self.isRunning else { return }
            self.processInputBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        do {
            try engine.start()
            micAvailable = true
        } catch {
            fputs("WARNING: Could not start microphone capture: \(error.localizedDescription)\n", stderr)
            fputs("WARNING: Microphone permission may not be granted.\n", stderr)
        }
    }

    private func processInputBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * (targetSampleRate / buffer.format.sampleRate)
        ) + 1

        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: frameCapacity
        ) else { return }

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

        if let error = error {
            fputs("WARNING: Microphone audio conversion error: \(error.localizedDescription)\n", stderr)
            return
        }

        guard convertedBuffer.frameLength > 0,
              let channelData = convertedBuffer.floatChannelData else { return }

        let samples = Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(convertedBuffer.frameLength)
        ))

        appendMicSamples(samples)
    }

    // MARK: - System Audio Capture (ScreenCaptureKit)

    private func startSystemAudioCapture() async {
        do {
            // Get shareable content - this will prompt for screen recording permission if needed
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )

            guard let display = content.displays.first else {
                fputs("WARNING: No display found for system audio capture.\n", stderr)
                return
            }

            let config = SCStreamConfiguration()
            // Audio-only: disable video capture
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // minimize video overhead
            config.capturesAudio = true
            config.sampleRate = Int(targetSampleRate)
            config.channelCount = Int(targetChannels)
            // Exclude the current process's audio to avoid feedback
            config.excludesCurrentProcessAudio = true

            let filter = SCContentFilter(display: display, excludingWindows: [])

            let delegate = StreamOutputDelegate { [weak self] sampleBuffer in
                self?.processSystemAudioBuffer(sampleBuffer)
            }
            self.streamDelegate = delegate

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            let audioQueue = DispatchQueue(label: "com.garnetcs.kaze.audio-capture.system-audio")
            try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: audioQueue)

            try await stream.startCapture()
            self.scStream = stream
            systemAudioAvailable = true
        } catch {
            fputs("WARNING: Could not start system audio capture: \(error.localizedDescription)\n", stderr)
            fputs("WARNING: Screen recording permission may not be granted.\n", stderr)
        }
    }

    private func processSystemAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)

        var dataPointer: UnsafeMutablePointer<Int8>?
        var lengthAtOffset: Int = 0
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: nil,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let ptr = dataPointer else { return }

        // Determine format from the sample buffer's format description
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        let format = asbd.pointee

        if format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            // Float32 samples
            let floatCount = length / MemoryLayout<Float>.size
            let floatPtr = UnsafeRawPointer(ptr).bindMemory(to: Float.self, capacity: floatCount)
            var samples: [Float]

            if Int(format.mChannelsPerFrame) > 1 {
                // Downmix to mono
                let channelCount = Int(format.mChannelsPerFrame)
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

            appendSystemSamples(samples)
        } else if format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
            // Int16 samples
            let int16Count = length / MemoryLayout<Int16>.size
            let int16Ptr = UnsafeRawPointer(ptr).bindMemory(to: Int16.self, capacity: int16Count)

            let channelCount = Int(format.mChannelsPerFrame)
            let frameCount = int16Count / channelCount

            var samples = [Float](repeating: 0, count: frameCount)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += Float(int16Ptr[frame * channelCount + ch]) / 32768.0
                }
                samples[frame] = sum / Float(channelCount)
            }

            appendSystemSamples(samples)
        }
    }

    // MARK: - Buffer Management

    private func appendMicSamples(_ samples: [Float]) {
        bufferLock.lock()
        micBuffer.append(contentsOf: samples)
        checkAndWriteChunks()
        bufferLock.unlock()
    }

    private func appendSystemSamples(_ samples: [Float]) {
        bufferLock.lock()
        systemBuffer.append(contentsOf: samples)
        checkAndWriteChunks()
        bufferLock.unlock()
    }

    /// Check if we have enough samples from at least one source to produce a chunk.
    /// Mix the two buffers by summing overlapping samples, then write the chunk.
    private func checkAndWriteChunks() {
        // The chunk is ready when the longest buffer has enough samples.
        // We mix by summing whatever both buffers have at each position.
        while max(micBuffer.count, systemBuffer.count) >= samplesPerChunk {
            let micCount = min(micBuffer.count, samplesPerChunk)
            let sysCount = min(systemBuffer.count, samplesPerChunk)

            var chunk = [Float](repeating: 0, count: samplesPerChunk)

            // Add mic samples
            for i in 0..<micCount {
                chunk[i] += micBuffer[i]
            }

            // Add system audio samples
            for i in 0..<sysCount {
                chunk[i] += systemBuffer[i]
            }

            // Remove consumed samples from both buffers
            if micCount > 0 {
                micBuffer.removeFirst(micCount)
            }
            if sysCount > 0 {
                systemBuffer.removeFirst(sysCount)
            }

            samplesConsumed += samplesPerChunk

            bufferLock.unlock()
            writeChunk(chunk)
            bufferLock.lock()
        }
    }

    /// Flush remaining buffer (called on shutdown)
    private func flushBuffer() {
        bufferLock.lock()
        let micRemaining = micBuffer
        let sysRemaining = systemBuffer
        micBuffer.removeAll()
        systemBuffer.removeAll()
        bufferLock.unlock()

        let count = max(micRemaining.count, sysRemaining.count)
        if count > 0 {
            var mixed = [Float](repeating: 0, count: count)
            for i in 0..<min(micRemaining.count, count) {
                mixed[i] += micRemaining[i]
            }
            for i in 0..<min(sysRemaining.count, count) {
                mixed[i] += sysRemaining[i]
            }
            writeChunk(mixed)
        }
    }

    // MARK: - WAV Writing

    private func writeChunk(_ samples: [Float]) {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.timeZone = TimeZone.current
        let filename = "\(formatter.string(from: now)).wav"
        let filepath = (outputDir as NSString).appendingPathComponent(filename)

        guard writeWAV(samples: samples, to: filepath) else {
            fputs("ERROR: Failed to write WAV chunk to \(filepath)\n", stderr)
            return
        }

        // Notify parent process
        print("CHUNK:\(filepath)")
        fflush(stdout)
    }

    private func writeWAV(samples: [Float], to path: String) -> Bool {
        let sampleRate: UInt32 = UInt32(targetSampleRate)
        let numChannels: UInt16 = UInt16(targetChannels)
        let bps: UInt16 = UInt16(bitsPerSample)
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bps / 8)
        let blockAlign = numChannels * (bps / 8)
        let dataSize = UInt32(samples.count) * UInt32(bps / 8)
        let chunkSize = 36 + dataSize

        var data = Data()

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)

        // fmt sub-chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // sub-chunk size
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM format
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bps.littleEndian) { Array($0) })

        // data sub-chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        // Convert Float32 samples to Int16 PCM
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16Value = Int16(clamped * 32767.0)
            data.append(contentsOf: withUnsafeBytes(of: int16Value.littleEndian) { Array($0) })
        }

        return FileManager.default.createFile(atPath: path, contents: data, attributes: nil)
    }
}

// MARK: - SCStream Output Delegate

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
