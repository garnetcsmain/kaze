import Foundation

// MARK: - Argument Parsing

func printUsage() {
    let usage = """
    Usage: audio-capture --output-dir <path> [--chunk-duration <seconds>]

    Options:
      --output-dir <path>        Directory where WAV chunks will be written (required)
      --chunk-duration <seconds> Duration of each audio chunk in seconds (default: 30)
      --help                     Show this help message

    Output:
      Prints "CHUNK:<filepath>" to stdout when each chunk is written.
      Errors and warnings are printed to stderr.
    """
    fputs(usage + "\n", stderr)
}

func parseArguments() -> (outputDir: String, chunkDuration: Double)? {
    let args = CommandLine.arguments
    var outputDir: String?
    var chunkDuration: Double = 30.0

    var i = 1
    while i < args.count {
        switch args[i] {
        case "--output-dir":
            guard i + 1 < args.count else {
                fputs("ERROR: --output-dir requires a path argument.\n", stderr)
                return nil
            }
            i += 1
            outputDir = args[i]

        case "--chunk-duration":
            guard i + 1 < args.count, let duration = Double(args[i + 1]), duration > 0 else {
                fputs("ERROR: --chunk-duration requires a positive number.\n", stderr)
                return nil
            }
            i += 1
            chunkDuration = duration

        case "--help", "-h":
            printUsage()
            exit(0)

        default:
            fputs("ERROR: Unknown argument: \(args[i])\n", stderr)
            printUsage()
            return nil
        }
        i += 1
    }

    guard let dir = outputDir else {
        fputs("ERROR: --output-dir is required.\n", stderr)
        printUsage()
        return nil
    }

    return (dir, chunkDuration)
}

// MARK: - Main

guard let config = parseArguments() else {
    exit(1)
}

let manager = AudioCaptureManager(
    outputDir: config.outputDir,
    chunkDuration: config.chunkDuration
)

// MARK: - Signal Handling

let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGTERM, SIG_IGN) // Ignore default handler so DispatchSource gets it
signalSource.setEventHandler {
    fputs("INFO: Received SIGTERM, flushing and shutting down...\n", stderr)
    manager.stop()
    exit(0)
}
signalSource.resume()

let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
intSource.setEventHandler {
    fputs("INFO: Received SIGINT, flushing and shutting down...\n", stderr)
    manager.stop()
    exit(0)
}
intSource.resume()

// Start capture
fputs("INFO: Starting audio capture. Output: \(config.outputDir), Chunk: \(config.chunkDuration)s\n", stderr)

// Use a semaphore to bridge async/sync
let semaphore = DispatchSemaphore(value: 0)

Task {
    await manager.start()
    semaphore.signal()
}

semaphore.wait()

fputs("INFO: Audio capture is running. Press Ctrl+C or send SIGTERM to stop.\n", stderr)

// Keep the process alive on the main run loop
RunLoop.main.run()
