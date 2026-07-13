import Foundation

/// Exports the daily analysis into an Obsidian vault as Markdown — a human journal of the
/// improvements Kaze is finding. One-way and append-safe: analysis.db stays the source of
/// truth, Kaze never parses the vault back, and user edits in the notes survive re-export.
///
/// Two artifacts per journal folder:
///  - `Kaze <day>.md`      — the daily digest note. Generated content ends at a
///                           `<!-- kaze:end -->` marker; whatever the user writes below it
///                           (a "My notes" section is seeded) is preserved on re-export.
///  - `Kaze Improvements.md` — rolling checklist of confirmed suggestions. Append-only with
///                           an HTML-comment anchor per entry, so checkbox ticks and edits
///                           are never clobbered. Tick a box when you adopt a suggestion.
enum JournalExporter {
    private static let enabledKey = "kaze.journal.enabled"
    private static let pathKey = "kaze.journal.path"
    static let endMarker = "<!-- kaze:end -->"

    // MARK: - Settings

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var path: String? {
        get {
            let v = UserDefaults.standard.string(forKey: pathKey)
            return (v?.isEmpty == false) ? v : nil
        }
        set { UserDefaults.standard.set(newValue, forKey: pathKey) }
    }

    /// Vaults registered with the Obsidian app on this machine.
    static func detectVaults() -> [(name: String, path: String)] {
        let registry = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: registry),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: Any] else { return [] }
        return vaults.values.compactMap { entry in
            guard let dict = entry as? [String: Any], let path = dict["path"] as? String,
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return (name: URL(fileURLWithPath: path).lastPathComponent, path: path)
        }.sorted { $0.name < $1.name }
    }

    // MARK: - Export

    /// Writes/updates the daily note for one digest and appends new entries to the ledger.
    /// Returns the file URLs written. `folderOverride` bypasses the stored setting (used by
    /// the headless hook and tests).
    @discardableResult
    static func export(
        digest: DailyDigest,
        allObservations: [LedgerObservation],
        dayQuestions: [OpenQuestion],
        folderOverride: String? = nil
    ) throws -> [URL] {
        guard let folder = folderOverride ?? path else {
            throw NSError(domain: K.bundleID, code: 30,
                          userInfo: [NSLocalizedDescriptionKey: "No journal folder configured"])
        }
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var written: [URL] = []
        written.append(try writeDailyNote(digest: digest, observations: allObservations,
                                          questions: dayQuestions, in: dir))
        if let ledgerURL = try appendToLedger(observations: allObservations, in: dir) {
            written.append(ledgerURL)
        }
        return written
    }

    /// Re-exports every stored digest plus the ledger (Settings → "Export existing history").
    @discardableResult
    static func backfill(store: AnalysisStore, folderOverride: String? = nil) throws -> [URL] {
        let observations = store.allObservations(includeDismissed: false)
        var written: [URL] = []
        for digest in store.recentDigests(limit: 365) {
            let urls = try export(
                digest: digest, allObservations: observations,
                dayQuestions: store.questions(day: digest.day),
                folderOverride: folderOverride)
            written.append(contentsOf: urls)
        }
        // No digests yet? Still write the ledger so the vault shows something once
        // observations exist.
        if written.isEmpty, let folder = folderOverride ?? path {
            let dir = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let ledgerURL = try appendToLedger(observations: observations, in: dir) {
                written.append(ledgerURL)
            }
        }
        return Array(Set(written)).sorted { $0.path < $1.path }
    }

    // MARK: - Daily note

    private static func writeDailyNote(
        digest: DailyDigest, observations: [LedgerObservation],
        questions: [OpenQuestion], in dir: URL
    ) throws -> URL {
        let url = dir.appendingPathComponent("Kaze \(digest.day).md")

        var lines: [String] = []
        lines.append("---")
        lines.append("date: \(digest.day)")
        lines.append("tags: [kaze, digest]")
        lines.append("---")
        lines.append("")
        lines.append("# Kaze digest — \(digest.day)")
        lines.append("")
        lines.append("## Summary")
        lines.append(digest.summary.isEmpty ? "_(none)_" : digest.summary)

        if !digest.focusAreas.isEmpty {
            lines.append("")
            lines.append("## Focus areas")
            for area in digest.focusAreas { lines.append("- \(area)") }
        }

        if !digest.newlyConfirmed.isEmpty {
            lines.append("")
            lines.append("## ✅ New confirmed suggestions")
            for obs in digest.newlyConfirmed {
                lines.append("- **\(obs.behavior)**")
                lines.append("  - Suggestion: \(obs.suggestion)")
                if !obs.evidence.isEmpty { lines.append("  - Evidence: \(obs.evidence)") }
                if let implementation = obs.implementation, !implementation.isEmpty {
                    lines.append(contentsOf: implementationLines(implementation, category: obs.implementationCategory,
                                                                  caveat: obs.implementationCaveat, indent: "  "))
                }
            }
        }

        let adopted = observations.filter { $0.isAdopted && !$0.dismissed }
        if !adopted.isEmpty {
            lines.append("")
            lines.append("## 📊 Fix outcomes")
            for obs in adopted {
                lines.append(obs.stillRecurring
                    ? "- ⚠️ **Not holding** — \(obs.behavior) (seen again after you adopted the fix)"
                    : "- ✅ Holding — \(obs.behavior)")
            }
        }

        let watching = observations.filter { !$0.confirmed && !$0.dismissed }
        if !watching.isEmpty {
            lines.append("")
            lines.append("## 👀 Watching (needs \(K.observationConfirmThreshold)+ days)")
            for obs in watching.prefix(10) {
                lines.append("- [\(obs.daysSeen)d] \(obs.behavior)")
            }
        }

        if !questions.isEmpty {
            lines.append("")
            lines.append("## ❓ Unclear activity")
            let timeFmt = DateFormatter()
            timeFmt.dateFormat = "HH:mm"
            for q in questions {
                let time = timeFmt.string(from: Date(timeIntervalSince1970: q.ts))
                let mins = Int(q.durationSeconds / 60)
                if let answer = q.answer {
                    lines.append("- \(time) (~\(mins)m) — you explained: \(answer)")
                } else {
                    let hint = q.hint.map { " — best guess: \($0)" } ?? ""
                    lines.append("- \(time) (~\(mins)m) — unanswered\(hint) (open Kaze → Insights)")
                }
            }
        }

        lines.append("")
        lines.append(endMarker)

        // Preserve whatever the user wrote below the marker; seed a notes section first time.
        let tail: String
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            if let range = existing.range(of: endMarker) {
                tail = String(existing[range.upperBound...])
            } else {
                // Same-named file without our marker — keep all of it as the tail.
                tail = "\n\n" + existing
            }
        } else {
            tail = "\n\n## My notes\n\n"
        }

        let content = lines.joined(separator: "\n") + tail
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Improvements ledger (append-only)

    /// Appends confirmed observations not yet present (by anchor). Returns the URL if the
    /// file was created or changed, nil when there was nothing new to add.
    private static func appendToLedger(observations: [LedgerObservation], in dir: URL) throws -> URL? {
        // Ignored suggestions stay out of the checklist — the user already decided against
        // them (entries appended before the decision keep their line; append-only).
        let confirmed = observations.filter { $0.confirmed && !$0.dismissed && !$0.isIgnored }
        let url = dir.appendingPathComponent("Kaze Improvements.md")
        let existing = (try? String(contentsOf: url, encoding: .utf8))

        var content = existing ?? """
        ---
        tags: [kaze, improvements]
        ---

        # Kaze Improvements

        Confirmed workflow optimizations, appended as Kaze finds them. Tick a box when you \
        adopt one — Kaze never edits existing lines.

        """
        var appended = 0

        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        for obs in confirmed {
            let anchor = "<!-- kaze:\(obs.key) -->"
            guard content.contains(anchor) == false else { continue }
            let day = dayFmt.string(from: Date(timeIntervalSince1970: obs.lastSeen))
            content += "\n- [ ] **\(obs.behavior)** — \(obs.suggestion) *(confirmed \(day), seen \(obs.daysSeen)d)* \(anchor)"
            if let implementation = obs.implementation, !implementation.isEmpty {
                content += "\n" + implementationLines(implementation, category: obs.implementationCategory,
                                                        caveat: obs.implementationCaveat, indent: "  ").joined(separator: "\n")
            }
            appended += 1
        }

        guard existing == nil || appended > 0 else { return nil }
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Shared formatting

    /// Renders a drafted implementation as an indented fenced code block, with its freeform
    /// tool-category label and any risk caveat. Kept out of the checklist line itself so the
    /// line stays scannable; this is purely documentation — nothing here is ever executed.
    private static func implementationLines(_ implementation: String, category: String?, caveat: String?, indent: String) -> [String] {
        var lines: [String] = []
        let label = (category?.isEmpty == false) ? " (\(category!))" : ""
        lines.append("\(indent)- How to implement\(label):")
        if let caveat, !caveat.isEmpty {
            lines.append("\(indent)  - ⚠️ \(caveat)")
        }
        lines.append("\(indent)  ```")
        for line in implementation.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append("\(indent)  \(line)")
        }
        lines.append("\(indent)  ```")
        return lines
    }
}
