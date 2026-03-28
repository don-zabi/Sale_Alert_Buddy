import SwiftUI

/// Full-screen language selection shown on first launch.
///
/// The user picks English, Japanese, or Chinese Simplified. The selection is stored in
/// `@AppStorage("selectedLanguage")` and applied via `.environment(\.locale, ...)`
/// in `Sale_Alert_BuddyApp`. Once confirmed, `hasSelectedLanguage` is set to `true`
/// and this screen is never shown again.
///
/// All displayed strings use `Text(LocalizedStringKey)` so they react dynamically
/// to `.environment(\.locale, ...)` as the user taps each option — giving an
/// instant preview of the chosen language before confirming.
struct LanguagePickerView: View {

    @AppStorage("selectedLanguage") private var selectedLanguage = "en"
    @AppStorage("hasSelectedLanguage") private var hasSelectedLanguage = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // App icon area
            VStack(spacing: 16) {
                Image(systemName: "tag.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.tint)

                Text(verbatim: "Sale Alert Buddy")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)

                // Title + subtitle react to the selected language via the injected locale
                Text("languagePicker.title")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text("languagePicker.subtitle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer().frame(height: 40)

            // Language options
            VStack(spacing: 12) {
                languageRow(
                    code: "en",
                    label: "English",
                    sublabel: "English"
                )
                languageRow(
                    code: "ja",
                    label: "日本語",
                    sublabel: "Japanese"
                )
                languageRow(
                    code: "zh-Hans",
                    label: "中文（简体）",
                    sublabel: "Chinese Simplified"
                )
            }
            .padding(.horizontal, 32)

            Spacer().frame(height: 48)

            // Confirm button — label uses LocalizedStringKey so it updates with selection
            Button {
                hasSelectedLanguage = true
            } label: {
                Text("languagePicker.confirm")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)

            Spacer()
        }
        .animation(.easeInOut(duration: 0.18), value: selectedLanguage)
        .onAppear {
            guard !hasSelectedLanguage else { return }
            selectedLanguage = normalizedLanguageCode(Locale.preferredLanguages.first ?? "en")
        }
    }

    // MARK: - Private helpers

    /// Language option card row.
    @ViewBuilder
    private func languageRow(code: String, label: String, sublabel: String) -> some View {
        let isSelected = selectedLanguage == code
        Button {
            selectedLanguage = code
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    Text(sublabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color(.systemGray3))
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color(.systemGray6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func normalizedLanguageCode(_ languageIdentifier: String) -> String {
        let lower = languageIdentifier.lowercased()
        if lower.hasPrefix("ja") { return "ja" }
        if lower.hasPrefix("zh") { return "zh-Hans" }
        return "en"
    }
}

// MARK: - Preview

#Preview("Japanese selected") {
    LanguagePickerView()
        .environment(\.locale, Locale(identifier: "ja"))
}

#Preview("Chinese selected") {
    LanguagePickerView()
        .environment(\.locale, Locale(identifier: "zh-Hans"))
}
