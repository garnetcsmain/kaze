import SwiftUI
import AppKit

/// Phase 2 UI: the morning digest + the observations ledger. Also lets you run analysis
/// on demand (today's or yesterday's data) and preview the compacted prompt as a dry run.
struct InsightsView: View {
    @EnvironmentObject private var state: AppState
    @State private var digests: [DailyDigest] = []
    @State private var observations: [LedgerObservation] = []
    @State private var questions: [OpenQuestion] = []
    @State private var dryRun: AnalysisService.DryRunResult?
    @State private var statusMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !APIKeyStore.hasKey(for: LLMSettings.activeProvider) {
                    noKeyBanner
                }
                if let error = state.analysis?.lastError {
                    banner(error, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }
                if let status = statusMessage {
                    banner(status, systemImage: "info.circle.fill", tint: .blue)
                }
                if let dry = dryRun {
                    dryRunCard(dry)
                }
                questionsSection
                suggestionsSection
                digestsSection
                ledgerSection
            }
            .padding(18)
        }
        .frame(width: 640, height: 680)
        .background(.regularMaterial)
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reload()
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Insights").font(.system(size: 20, weight: .semibold))
                Text("Daily workflow analysis").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if state.analysis?.isRunning == true {
                ProgressView().controlSize(.small)
            }
            Menu {
                Button("Analyze yesterday") { run(dayOffset: -1) }
                Button("Analyze today so far") { run(dayOffset: 0) }
                Divider()
                Button("Preview yesterday (dry run, no API)") { preview(dayOffset: -1) }
                Button("Preview today (dry run, no API)") { preview(dayOffset: 0) }
            } label: {
                Label("Run", systemImage: "sparkles")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 90)
            .disabled(state.analysis?.isRunning == true)
        }
    }

    private var questionsSection: some View {
        Group {
            if !questions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Needs your explanation")
                    Text("Kaze couldn't tell what these were from the screen alone. A short answer teaches it — future digests use your explanations.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(questions) { question in
                        QuestionCard(question: question) { answer in
                            state.analysis?.analysisStore.answerQuestion(question.id, answer: answer)
                            reload()
                        } onDismiss: {
                            state.analysis?.analysisStore.dismissQuestion(question.id)
                            reload()
                        }
                    }
                }
            }
        }
    }

    private var suggestionsSection: some View {
        let confirmed = observations.filter(\.isActionable)
        return Group {
            if !confirmed.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Suggested optimizations")
                    ForEach(confirmed) { obs in
                        SuggestionCard(obs: obs) {
                            state.analysis?.analysisStore.setDismissed(obs.id, true)
                            reload()
                        }
                    }
                }
            }
        }
    }

    private var digestsSection: some View {
        Group {
            if !digests.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Daily digests")
                    ForEach(digests) { digest in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(digest.day).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            Text(digest.summary).font(.system(size: 13))
                            if !digest.focusAreas.isEmpty {
                                Text(digest.focusAreas.joined(separator: " · "))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    private var ledgerSection: some View {
        let candidates = observations.filter { !$0.isActionable && !$0.dismissed }
        return Group {
            if !candidates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Watching (needs \(K.observationConfirmThreshold)+ days to confirm)")
                    ForEach(candidates) { obs in
                        HStack(spacing: 8) {
                            Text("\(obs.daysSeen)d")
                                .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 26)
                            Text(obs.behavior).font(.system(size: 12)).lineLimit(2)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
            } else if digests.isEmpty && observations.isEmpty {
                Text("No analysis yet. Add an API key in Settings, let Kaze record for a bit, then Run → Analyze.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.top, 20)
            }
        }
    }

    private func dryRunCard(_ dry: AnalysisService.DryRunResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Dry run — \(dry.day)")
            Text("\(dry.frames) frames → \(dry.segments) segments · ~\(dry.approxTokens) input tokens (\(dry.promptChars) chars)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                Text(dry.preview).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
            .padding(8)
            .background(.black.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var noKeyBanner: some View {
        banner("Add a \(LLMSettings.activeProvider.displayName) API key in Settings to enable analysis.",
               systemImage: "key.fill", tint: .orange)
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.system(size: 12))
            Spacer()
        }
        .padding(10)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold)).kerning(1.1)
            .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private func reload() {
        guard let analysis = state.analysis else { return }
        digests = analysis.analysisStore.recentDigests()
        observations = analysis.analysisStore.allObservations()
        questions = analysis.analysisStore.openQuestions()
    }

    private func run(dayOffset: Int) {
        guard let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) else { return }
        statusMessage = "Analyzing…"
        dryRun = nil
        Task {
            _ = await state.analysis?.analyze(date: date, notify: false)
            statusMessage = nil
            reload()
        }
    }

    private func preview(dayOffset: Int) {
        guard let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) else { return }
        do {
            dryRun = try state.analysis?.dryRun(date: date)
            statusMessage = nil
        } catch {
            statusMessage = "Dry run failed: \(error)"
        }
    }
}

private struct QuestionCard: View {
    let question: OpenQuestion
    let onAnswer: (String) -> Void
    let onDismiss: () -> Void

    @EnvironmentObject private var state: AppState
    @State private var answer = ""
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable().scaledToFill()
                } else {
                    Image(systemName: "questionmark.square.dashed")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 128, height: 80)
            .background(.black.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("\(question.day) \(Self.time(question.ts)) · ~\(Int(question.durationSeconds / 60))m")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss without answering")
                }
                if let hint = question.hint, !hint.isEmpty {
                    Text("Best guess: \(hint)")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack {
                    TextField("What were you doing here?", text: $answer)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit(submit)
                    Button("Save", action: submit)
                        .controlSize(.small)
                        .disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(10)
        .background(.blue.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.blue.opacity(0.25), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task {
            guard let fid = question.frameID, let store = state.store,
                  let frame = (try? store.frameByID(fid)) ?? nil else { return }
            thumbnail = await state.frameExtractor.image(for: frame)
        }
    }

    private func submit() {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAnswer(trimmed)
    }

    private static func time(_ ts: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: ts))
    }
}

private struct SuggestionCard: View {
    let obs: LedgerObservation
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                Text(obs.behavior).font(.system(size: 13, weight: .medium))
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(obs.suggestion).font(.system(size: 12)).foregroundStyle(.primary)
            HStack(spacing: 8) {
                Text(obs.category).font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.blue.opacity(0.15)).clipShape(Capsule())
                Text("seen \(obs.daysSeen) days").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.yellow.opacity(0.3), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
