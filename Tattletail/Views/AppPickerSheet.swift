import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Sheet for choosing an application for an "Activate App" step.
/// Offers currently running apps plus a Browse… fallback for any .app.
struct AppPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Called with (bundleId, path, name) when an app is picked.
    let onPick: (String, String?, String?) -> Void

    @State private var runningApps: [NSRunningApplication] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            Text("Activate which app?")
                .font(Theme.title(16))
                .foregroundStyle(Theme.ink)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        Button {
                            pick(app)
                        } label: {
                            HStack(spacing: 8) {
                                if let icon = app.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 20, height: 20)
                                }
                                Text(app.localizedName ?? app.bundleIdentifier ?? "Unknown")
                                    .font(Theme.body(13))
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 260)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .fill(Theme.inset)
            )

            HStack {
                Button("Browse…") { browse() }
                    .buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.sectionSpacing)
        .frame(width: 340)
        .background(Theme.background)
        .onAppear(perform: loadRunningApps)
    }

    private func loadRunningApps() {
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func pick(_ app: NSRunningApplication) {
        guard let bundleId = app.bundleIdentifier else { return }
        onPick(bundleId, app.bundleURL?.path, app.localizedName)
        dismiss()
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleId = bundle.bundleIdentifier else { return }
        let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        onPick(bundleId, url.path, name)
        dismiss()
    }
}
