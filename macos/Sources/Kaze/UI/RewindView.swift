import SwiftUI
import AppKit

/// Full-screen scrubable timeline — port of pages/rewind.
/// Scroll wheel / arrow keys scrub (Shift = ×10), Cmd+F or "/" searches, "t" toggles transcripts.
struct RewindView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model = RewindModel()
    @State private var window: NSWindow?
    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            FrameDisplay(image: model.currentImage)

            if model.isLoadingFrame && model.currentImage == nil {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            VStack(spacing: 0) {
                if model.searchVisible {
                    SearchOverlay(model: model)
                        .padding(.top, 48)
                }
                Spacer()
                TimelineBar(model: model)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }

            HStack {
                if model.transcriptVisible {
                    TranscriptPanel(model: model)
                        .frame(width: 300)
                        .padding(.leading, 16)
                        .padding(.vertical, 56)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Spacer()
            }
        }
        .background(WindowAccessor(window: $window))
        .animation(.easeInOut(duration: 0.2), value: model.transcriptVisible)
        .onAppear {
            if state.isReady { model.loadInitial() }
            installMonitors()
        }
        .onChange(of: state.isReady) { _, ready in
            if ready { model.loadInitial() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // Jump back to "now" when the window regains focus (visibilitychange parity).
            if let window, (note.object as? NSWindow) === window {
                model.resetToNewest()
            }
        }
        .onDisappear {
            removeMonitors()
        }
    }

    // MARK: - Event monitors (keyboard + scroll wheel)

    private func installMonitors() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === window else { return event }
            return handleKey(event) ? nil : event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.window === window else { return event }
            model.handleScroll(deltaY: event.scrollingDeltaY)
            return event
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        keyMonitor = nil
        scrollMonitor = nil
    }

    /// Returns true when the event was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        let shift = event.modifierFlags.contains(.shift)
        let cmd = event.modifierFlags.contains(.command)

        switch event.keyCode {
        case 53: // Escape
            if model.searchVisible {
                model.toggleSearch()
                return true
            }
            return false
        case 123: // Left arrow — toward newer (parity with the web UI)
            guard !model.searchVisible else { return false }
            model.navigate(shift ? -10 : -1)
            return true
        case 124: // Right arrow — toward older
            guard !model.searchVisible else { return false }
            model.navigate(shift ? 10 : 1)
            return true
        default:
            break
        }

        if cmd, event.charactersIgnoringModifiers?.lowercased() == "f" {
            model.toggleSearch()
            return true
        }
        guard !model.searchVisible else { return false }
        switch event.charactersIgnoringModifiers {
        case "/":
            model.toggleSearch()
            return true
        case "t", "T":
            model.toggleTranscript()
            return true
        default:
            return false
        }
    }
}

// MARK: - Frame display (blurred fill behind sharp contained image)

private struct FrameDisplay: View {
    let image: NSImage?

    var body: some View {
        GeometryReader { geo in
            if let image {
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: 40)
                        .opacity(0.5)
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.15), value: image)
    }
}

// MARK: - Window accessor

struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { window = nsView.window }
    }
}
