import SwiftUI
import UserNotifications

/// Minimal settings screen for the MVP.
///
/// Covers notification permissions, background refresh info, plan tier, and app version.
struct SettingsView: View {

    @State private var notificationStatus: String = ""

    var body: some View {
        Form {
            notificationsSection
            backgroundRefreshSection
            planSection
            aboutSection
        }
        .navigationTitle(String(localized: "settings.title", defaultValue: "Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshNotificationStatus()
        }
    }

    // MARK: - Sections

    private var notificationsSection: some View {
        Section {
            HStack {
                Text(String(localized: "settings.notifications.status", defaultValue: "Status"))
                Spacer()
                Text(verbatim: notificationStatus)
                    .foregroundStyle(.secondary)
            }

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text(String(
                    localized: "settings.notifications.openSettings",
                    defaultValue: "Open Notification Settings"
                ))
            }
        } header: {
            Text(String(localized: "settings.section.notifications", defaultValue: "Notifications"))
        }
    }

    private var backgroundRefreshSection: some View {
        Section {
            Text(String(
                localized: "settings.backgroundRefresh.info",
                defaultValue: "Sale Alert Buddy checks prices when you open the app. Background refresh is best-effort and depends on iOS system conditions."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } header: {
            Text(String(localized: "settings.section.backgroundRefresh", defaultValue: "Background Refresh"))
        }
    }

    private var planSection: some View {
        Section {
            HStack {
                Text(String(localized: "settings.plan.current", defaultValue: "Current Plan"))
                Spacer()
                Text(String(localized: "settings.plan.free", defaultValue: "Free (20 items)"))
                    .foregroundStyle(.secondary)
            }
            Text(String(
                localized: "settings.plan.upgradeNote",
                defaultValue: "Upgrade coming soon — track up to 50 items."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } header: {
            Text(String(localized: "settings.section.plan", defaultValue: "Plan"))
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text(String(localized: "settings.about.version", defaultValue: "Version"))
                Spacer()
                Text(verbatim: appVersion)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(String(localized: "settings.about.build", defaultValue: "Build"))
                Spacer()
                Text(verbatim: buildNumber)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(String(localized: "settings.section.about", defaultValue: "About"))
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    @MainActor
    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized:
            notificationStatus = String(localized: "settings.notifications.authorized", defaultValue: "Enabled")
        case .denied:
            notificationStatus = String(localized: "settings.notifications.denied", defaultValue: "Disabled")
        case .notDetermined:
            notificationStatus = String(localized: "settings.notifications.notDetermined", defaultValue: "Not set")
        case .provisional:
            notificationStatus = String(localized: "settings.notifications.provisional", defaultValue: "Provisional")
        case .ephemeral:
            notificationStatus = String(localized: "settings.notifications.ephemeral", defaultValue: "Ephemeral")
        @unknown default:
            notificationStatus = String(localized: "settings.notifications.unknown", defaultValue: "Unknown")
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SettingsView()
    }
}
