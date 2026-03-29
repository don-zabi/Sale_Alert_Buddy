import SwiftUI
import UserNotifications

/// Minimal settings screen for the MVP.
///
/// Covers notification permissions, background refresh info, plan tier, and app version.
struct SettingsView: View {

    @AppStorage("selectedLanguage") private var selectedLanguage = "en"
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            languageSection
            notificationsSection
            backgroundRefreshSection
            planSection
        }
        .navigationTitle(localized("settings.title", default: "Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshNotificationStatus()
        }
    }

    // MARK: - Sections

    private var languageSection: some View {
        Section {
            Picker(
                localized("settings.language.current", default: "Language"),
                selection: $selectedLanguage
            ) {
                Text(localized("languagePicker.english", default: "English")).tag("en")
                Text(localized("languagePicker.japanese", default: "日本語")).tag("ja")
                Text(localized("languagePicker.chinese", default: "中文（简体）")).tag("zh-Hans")
            }
            .pickerStyle(.menu)
        } header: {
            Text(localized("settings.section.language", default: "Language"))
        }
    }

    private var notificationsSection: some View {
        Section {
            HStack {
                Text(localized("settings.notifications.status", default: "Status"))
                Spacer()
                Text(verbatim: notificationStatusText)
                    .foregroundStyle(.secondary)
            }

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text(localized(
                    "settings.notifications.openSettings",
                    default: "Open Notification Settings"
                ))
            }
        } header: {
            Text(localized("settings.section.notifications", default: "Notifications"))
        }
    }

    private var backgroundRefreshSection: some View {
        Section {
            Text(localized(
                "settings.backgroundRefresh.info",
                default: "Sale Alert Buddy checks prices when you open the app. Background refresh is best-effort and depends on iOS system conditions."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } header: {
            Text(localized("settings.section.backgroundRefresh", default: "Background Refresh"))
        }
    }

    private var planSection: some View {
        Section {
            HStack {
                Text(localized("settings.plan.current", default: "Current Plan"))
                Spacer()
                Text(localized("settings.plan.free", default: "Free (20 items)"))
                    .foregroundStyle(.secondary)
            }
            Text(localized(
                "settings.plan.upgradeNote",
                default: "Upgrade coming soon — track up to 50 items."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } header: {
            Text(localized("settings.section.plan", default: "Plan"))
        }
    }
    // MARK: - Helpers

    private var notificationStatusText: String {
        switch notificationAuthorizationStatus {
        case .authorized:
            return localized("settings.notifications.authorized", default: "Enabled")
        case .denied:
            return localized("settings.notifications.denied", default: "Disabled")
        case .notDetermined:
            return localized("settings.notifications.notDetermined", default: "Not set")
        case .provisional:
            return localized("settings.notifications.provisional", default: "Provisional")
        case .ephemeral:
            return localized("settings.notifications.ephemeral", default: "Ephemeral")
        @unknown default:
            return localized("settings.notifications.unknown", default: "Unknown")
        }
    }

    private func localized(_ key: String, default defaultValue: String) -> String {
        guard let path = Bundle.main.path(forResource: selectedLanguage, ofType: "lproj"),
              let languageBundle = Bundle(path: path) else {
            return defaultValue
        }
        return NSLocalizedString(key, bundle: languageBundle, value: defaultValue, comment: "")
    }

    @MainActor
    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationAuthorizationStatus = settings.authorizationStatus
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SettingsView()
    }
}
