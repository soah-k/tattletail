import SwiftUI

/// First-run gate: explains and requests the two TCC grants Tattletail needs.
/// Record/replay are blocked until both are granted.
struct PermissionsOnboardingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: Theme.sectionSpacing) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.accent)
                Text("Tattletail needs permission to watch")
                    .font(Theme.title(22))
                    .foregroundStyle(Theme.ink)
                Text("To record and replay your clicks and keystrokes, macOS requires two permissions. Flip both, then come back — Tattletail notices automatically.")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            VStack(spacing: Theme.spacing) {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Lets Tattletail replay clicks and keystrokes into other apps.",
                    granted: model.permissions.accessibilityGranted,
                    onRequest: { model.permissions.requestAccessibility() },
                    onOpenSettings: { model.permissions.openAccessibilitySettings() }
                )
                PermissionRow(
                    title: "Input Monitoring",
                    detail: "Lets Tattletail see your mouse and keyboard while recording.",
                    granted: model.permissions.inputMonitoringGranted,
                    onRequest: { model.permissions.requestInputMonitoring() },
                    onOpenSettings: { model.permissions.openInputMonitoringSettings() }
                )
            }
            .frame(maxWidth: 480)

            Button("Check Again") { model.permissions.refresh() }
                .buttonStyle(QuietButtonStyle())

            Text("Tip: if a toggle doesn't stick, quit and reopen Tattletail after granting.")
                .font(Theme.body(11))
                .foregroundStyle(Theme.inkSecondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: Theme.spacing) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 20))
                .foregroundStyle(granted ? Theme.sage : Theme.inkSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.label(14))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(Theme.body(11.5))
                    .foregroundStyle(Theme.inkSecondary)
            }

            Spacer()

            if !granted {
                Button("Grant…") {
                    onRequest()
                    onOpenSettings()
                }
                .buttonStyle(WarmButtonStyle())
            }
        }
        .padding(16)
        .card()
    }
}
