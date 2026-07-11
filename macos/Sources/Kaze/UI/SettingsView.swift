import SwiftUI
import AppKit
import AVFoundation

/// Settings window: About (parity with the Electron settings page, which was
/// informational only) plus native permission status — genuinely useful here since
/// capture silently degrades without Screen Recording / Microphone access.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var screenAccess = CGPreflightScreenCaptureAccess()
    @State private var micAccess = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var activeProvider = LLMSettings.activeProvider
    @State private var keyInput = ""
    @State private var modelInput = LLMSettings.model(for: LLMSettings.activeProvider)
    @State private var savedProviders: Set<LLMProviderKind> = []
    @State private var journalEnabled = JournalExporter.isEnabled
    @State private var journalPath = JournalExporter.path
    @State private var journalStatus: String?

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                Text("Kaze")
                    .font(.system(size: 20, weight: .semibold))
                Text("Version \(K.appVersion) (native)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Copyright © 2024 alikia2x")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)

            GroupBox("Permissions") {
                VStack(spacing: 10) {
                    permissionRow(
                        name: "Screen Recording",
                        granted: screenAccess,
                        pane: "Privacy_ScreenCapture"
                    )
                    Divider()
                    permissionRow(
                        name: "Microphone",
                        granted: micAccess,
                        pane: "Privacy_Microphone"
                    )
                }
                .padding(6)
            }
            .padding(.horizontal, 20)

            GroupBox("Recording") {
                VStack(spacing: 10) {
                    Toggle("Screen recording", isOn: Binding(
                        get: { state.screenRecording },
                        set: { _ in state.toggleScreenRecording() }
                    ))
                    Divider()
                    Toggle("Audio recording", isOn: Binding(
                        get: { state.audioRecording },
                        set: { _ in state.toggleAudioRecording() }
                    ))
                }
                .toggleStyle(.switch)
                .padding(6)
            }
            .padding(.horizontal, 20)

            GroupBox("AI Analysis") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Provider", selection: $activeProvider) {
                        ForEach(LLMProviderKind.allCases) { kind in
                            HStack {
                                Text(kind.displayName)
                                if savedProviders.contains(kind) { Text("✓").foregroundStyle(.green) }
                            }.tag(kind)
                        }
                    }
                    .onChange(of: activeProvider) { _, kind in
                        LLMSettings.activeProvider = kind
                        modelInput = LLMSettings.model(for: kind)
                        keyInput = ""
                    }

                    HStack {
                        Image(systemName: savedProviders.contains(activeProvider) ? "checkmark.circle.fill" : "key")
                            .foregroundStyle(savedProviders.contains(activeProvider) ? .green : .secondary)
                        Text(savedProviders.contains(activeProvider) ? "API key saved" : "No API key for this provider")
                            .font(.system(size: 12))
                        Spacer()
                        if savedProviders.contains(activeProvider) {
                            Button("Remove") {
                                APIKeyStore.clear(for: activeProvider)
                                refreshSaved()
                            }
                            .controlSize(.small)
                        }
                    }

                    HStack {
                        SecureField(activeProvider.keyHint, text: $keyInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            APIKeyStore.save(trimmed, for: activeProvider)
                            keyInput = ""
                            refreshSaved()
                        }
                        .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    HStack {
                        Text("Model").font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField(activeProvider.defaultModel, text: $modelInput)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { LLMSettings.setModel(modelInput, for: activeProvider) }
                        Button("Set") { LLMSettings.setModel(modelInput, for: activeProvider) }
                            .controlSize(.small)
                    }

                    Text("Daily digest runs at \(K.analysisHour):00 using the selected provider. Keys are stored in your macOS Keychain; you can configure several and switch here.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(6)
                .onAppear(perform: refreshSaved)
            }
            .padding(.horizontal, 20)

            GroupBox("Journal (Obsidian)") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Toggle("Write digests to my vault", isOn: $journalEnabled)
                            .toggleStyle(.switch)
                            .disabled(journalPath == nil)
                            .onChange(of: journalEnabled) { _, on in JournalExporter.isEnabled = on }
                        Spacer()
                    }

                    HStack(spacing: 8) {
                        Text(journalPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "No folder selected")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(journalPath == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        let vaults = JournalExporter.detectVaults()
                        if !vaults.isEmpty {
                            Menu("Use Vault") {
                                ForEach(vaults, id: \.path) { vault in
                                    Button(vault.name) { setJournalPath(vault.path + "/Kaze Journal") }
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                        Button("Choose Folder…") { chooseJournalFolder() }
                            .controlSize(.small)
                    }

                    HStack {
                        Button("Export existing history") { exportHistory() }
                            .controlSize(.small)
                            .disabled(journalPath == nil)
                        if let status = journalStatus {
                            Text(status).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    Text("Each analysis writes a daily note plus an append-only \"Kaze Improvements\" checklist. Your edits below the marker and ticked boxes are never touched.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }
            .padding(.horizontal, 20)

            VStack(spacing: 4) {
                Text("Open source under GPL 3.0 — based on OpenRewind")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Link("github.com/alikia2x/openrewind",
                     destination: URL(string: "https://github.com/alikia2x/openrewind")!)
                    .font(.system(size: 11))
                Text("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
            .padding(.bottom, 20)
        }
        .frame(width: 420)
        .fixedSize()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenAccess = CGPreflightScreenCaptureAccess()
            micAccess = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    private func refreshSaved() {
        savedProviders = Set(LLMProviderKind.allCases.filter { APIKeyStore.hasKey(for: $0) })
    }

    private func setJournalPath(_ path: String) {
        JournalExporter.path = path
        journalPath = path
        JournalExporter.isEnabled = true
        journalEnabled = true
        journalStatus = nil
    }

    private func chooseJournalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder inside your Obsidian vault for Kaze's journal notes."
        if panel.runModal() == .OK, let url = panel.url {
            setJournalPath(url.path)
        }
    }

    private func exportHistory() {
        guard let analysisStore = state.analysis?.analysisStore else {
            journalStatus = "Analysis service not ready."
            return
        }
        do {
            let urls = try JournalExporter.backfill(store: analysisStore)
            journalStatus = urls.isEmpty ? "Nothing to export yet." : "Exported \(urls.count) file(s)."
        } catch {
            journalStatus = "Export failed: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func permissionRow(name: String, granted: Bool, pane: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(name)
                .font(.system(size: 12))
            Spacer()
            if !granted {
                Button("Open System Settings") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
                    NSWorkspace.shared.open(url)
                }
                .controlSize(.small)
            } else {
                Text("Granted")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
