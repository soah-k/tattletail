import AppKit
import SwiftUI

/// A soft, breathing glow around every screen's edges that signals Tattletail is
/// actively recording (amber) or replaying (red) — visible from any app or Space
/// so you always know it's running, even when the main window is hidden.
///
/// Each screen gets a borderless, non-activating, click-through `NSPanel` that
/// floats above other apps on all Spaces. It never becomes key, ignores mouse
/// events, and draws only the perimeter — so it can't steal focus, block your
/// input, or interfere with capture or synthesized replay events.
@MainActor
final class GlowOverlayController {
    enum Kind: Equatable {
        case recording   // amber
        case replaying   // red

        /// Vivid, saturated glow colors (brighter than the muted UI accents) so
        /// the activity indicator is unmistakable on any screen content.
        var color: Color {
            switch self {
            case .recording: return Color(red: 1.0, green: 0.74, blue: 0.10)   // bright amber-yellow
            case .replaying: return Color(red: 0.97, green: 0.20, blue: 0.16)  // bright red
            }
        }
    }

    private var panels: [NSPanel] = []
    private var current: Kind?
    private var screenObserver: NSObjectProtocol?

    /// Show the glow for `kind`, or hide it when `kind` is nil.
    func setState(_ kind: Kind?) {
        guard kind != current else { return }
        current = kind
        rebuild()
    }

    private func rebuild() {
        tearDownPanels()
        guard let kind = current else {
            stopObservingScreens()
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for screen in NSScreen.screens {
            panels.append(makePanel(for: screen, color: kind.color, reduceMotion: reduceMotion))
        }
        observeScreens()
    }

    private func makePanel(for screen: NSScreen, color: Color, reduceMotion: Bool) -> NSPanel {
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver                     // above normal windows
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true                // click-through — never blocks input
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: ScreenGlowView(color: color, reduceMotion: reduceMotion))
        host.frame = CGRect(origin: .zero, size: screen.frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()                   // show without activating
        return panel
    }

    private func tearDownPanels() {
        for panel in panels {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panels.removeAll()
    }

    private func observeScreens() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    private func stopObservingScreens() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }
}

/// The glow itself: a bright, breathing halo around the screen PLUS a crisp,
/// always-opaque line flush at the very edge, so recording/replaying is
/// unmistakable on any screen content.
/// Kept deliberately flat (no GeometryReader / ignoresSafeArea / nested blurs)
/// to avoid AttributeGraph layout cycles inside the hosting panel.
private struct ScreenGlowView: View {
    let color: Color
    let reduceMotion: Bool
    @State private var bright = false

    var body: some View {
        ZStack {
            // Wide, soft halo that breathes to draw the eye inward from the edge.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(color, lineWidth: 26)
                .blur(radius: 26)
                .padding(5)
                .opacity(reduceMotion ? 0.8 : (bright ? 1.0 : 0.55))

            // Solid inner band for body/presence (constant).
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(color, lineWidth: 8)
                .blur(radius: 2)
                .padding(4)
                .opacity(0.95)

            // Dark backing hairline so the crisp colored line below stays
            // distinct even over same-colored screen content.
            Rectangle()
                .strokeBorder(Color.black.opacity(0.35), lineWidth: 5)

            // Crisp solid line at the very edge — always fully opaque, never
            // breathes, so the activity is always clearly signaled.
            Rectangle()
                .strokeBorder(color, lineWidth: 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                bright = true
            }
        }
    }
}
