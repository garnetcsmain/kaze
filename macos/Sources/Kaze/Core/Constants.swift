import Foundation

/// Central constants — mirrors src/electron/backend/consts.ts of the Electron app.
enum K {
    // Capture
    static let screenshotInterval: TimeInterval = 2.0 // one frame every 2s (0.5 fps)

    // Encoding: screenshot N becomes video frame N at 30 fps, so seek time = index / 30.
    static let encodingFrameRate: Int32 = 30
    static let minFramesToEncode = 90 // 3 minutes at 0.5 fps

    // Scheduler intervals (seconds)
    static let encodingCheckInterval: TimeInterval = 5
    static let encodingProcessInterval: TimeInterval = 10
    static let screenshotCleanupInterval: TimeInterval = 20
    static let transcriptionCheckInterval: TimeInterval = 10
    static let ocrInterval: TimeInterval = 10

    // Audio
    static let audioChunkDuration: TimeInterval = 30
    static let audioSampleRate: Double = 16000

    // OCR
    static let ocrBatchSize = 25

    // Retention
    static let retentionDays: Double = 14
    static var retentionSeconds: TimeInterval { retentionDays * 24 * 3600 }

    // Scheduler
    static let cpuLowPowerThreshold = 0.75 // LOW_POWER tasks deferred at >=75% CPU

    static let appVersion = "0.11.0"
    static let bundleID = "com.garnetcs.kaze"

    // Phase 2: daily AI analysis. Provider + model are chosen per-provider in Settings
    // (see LLMSettings / LLMProviderKind).
    /// Hour of day (local, 0–23) at/after which the previous day's digest is generated.
    static let analysisHour = 7
    static let analysisCheckInterval: TimeInterval = 900 // check every 15 min whether it's time
    /// A behavior confirmed once seen on this many distinct days becomes a surfaced suggestion.
    static let observationConfirmThreshold = 3
    /// Cap on compacted activity segments sent to the model (logged when it truncates).
    static let analysisMaxSegments = 400

    // Vision sampling: segments where OCR read little but real time was spent get their
    // representative frame sent as an image ("sample ~20 frames vision-only where text
    // can't tell things"). Still-unclear ones become questions for the user.
    static let visionSampleLimit = 12
    static let visionMinDwellSeconds: Double = 120
    static let visionAmbiguousTokenMax = 18
    static let visionMaxImageDimension: CGFloat = 1280
    static let maxQuestionsPerDay = 5

    /// After a fix is marked adopted, sightings within this window don't count as recurrence —
    /// the next morning's analysis covers the adoption day itself, which includes pre-adoption
    /// activity. Only analyses of days fully after adoption can flag a fix as "not holding".
    static let adoptionGraceSeconds: TimeInterval = 36 * 3600
}
