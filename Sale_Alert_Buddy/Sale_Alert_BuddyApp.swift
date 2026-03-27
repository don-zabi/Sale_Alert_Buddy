import SwiftUI
import CoreData
import UserNotifications

@main
struct Sale_Alert_BuddyApp: App {

    let persistenceController = PersistenceController.shared

    /// Whether the user has completed first-launch language selection.
    @AppStorage("hasSelectedLanguage") private var hasSelectedLanguage = false
    /// BCP-47 language tag chosen by the user ("ja" or "zh-Hans").
    @AppStorage("selectedLanguage") private var selectedLanguage = "ja"

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if !hasSelectedLanguage {
                    LanguagePickerView()
                } else {
                    ItemListView()
                        .environment(\.managedObjectContext, persistenceController.container.viewContext)
                        .onOpenURL { url in
                            handleDeepLink(url)
                        }
                }
            }
            // Inject the user-selected locale so all Text views localise correctly.
            .environment(\.locale, Locale(identifier: selectedLanguage))
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active && hasSelectedLanguage {
                // PriceCheckService is @MainActor; calling checkAll from the main-actor-bound
                // onChange handler with viewContext is correct and thread-safe.
                Task {
                    await PriceCheckService.shared.checkAll(
                        context: persistenceController.container.viewContext
                    )
                }
            }
        }
    }

    // MARK: - Deep Links

    /// Handles deep links from notification taps.
    ///
    /// Expected URL format: `sab://item/{uuid-string}`
    ///
    /// Phase 2 will add full navigation state management;
    /// for now the app simply opens to the item list.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "sab",
              url.host == "item",
              let uuidString = url.pathComponents.dropFirst().first,
              !uuidString.isEmpty else { return }
        // TODO (Phase 2): resolve UUID to TrackingItem and push ItemDetailView
        _ = uuidString
    }
}
