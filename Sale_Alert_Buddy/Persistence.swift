import CoreData

struct PersistenceController {
    static let shared = PersistenceController()

    static let appGroupID = "group.com.anbery.SaleAlertBuddy"

    @MainActor
    static let preview: PersistenceController = {
        let result = PersistenceController(inMemory: true)
        let viewContext = result.container.viewContext
        let item = TrackingItem.create(in: viewContext)
        item.originalUrl = "https://www.amazon.co.jp/dp/B008IO6DH4"
        item.currentUrl = "https://www.amazon.co.jp/dp/B008IO6DH4"
        item.domain = "amazon.co.jp"
        item.productTitle = "コカ・コーラ いろはす 天然水 340ml PET×24本"
        item.baselinePriceDecimal = 1980
        item.baselineCurrency = "JPY"
        item.latestPriceDecimal = 1780
        item.latestCurrency = "JPY"
        item.lastCheckedAt = Date()
        item.lastSuccessAt = Date()
        item.itemStatus = .ok
        do {
            try viewContext.save()
        } catch {
            let nsError = error as NSError
            fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
        }
        return result
    }()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "Sale_Alert_Buddy")

        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        } else {
            // Store in App Group container so WidgetKit extension can access the same data.
            if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) {
                let storeURL = groupURL.appendingPathComponent("Sale_Alert_Buddy.sqlite")
                let description = NSPersistentStoreDescription(url: storeURL)
                description.shouldMigrateStoreAutomatically = true
                description.shouldInferMappingModelAutomatically = true
                // Encrypt the store file; decrypts when device is unlocked (background access included).
                description.setOption(FileProtectionType.completeUnlessOpen as NSObject,
                                      forKey: NSPersistentStoreFileProtectionKey)
                container.persistentStoreDescriptions = [description]
            } else {
                // This typically means the App Group entitlement is missing or mismatched.
                // Data will be stored in the app sandbox and WidgetKit will not see it.
                assertionFailure("App Group container '\(Self.appGroupID)' not available — check entitlements and provisioning profile.")
            }
        }

        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                // In production builds, log and continue with a degraded state rather than
                // crashing. The app will be non-functional for data operations, but the
                // process remains alive so the OS can present an error UI.
                // In debug builds, crash immediately to surface misconfiguration early.
                assertionFailure("Core Data store failed to load: \(error), \(error.userInfo)")
                print("Core Data store failed to load: \(error), \(error.userInfo)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }

    @discardableResult
    func save(context: NSManagedObjectContext) -> Bool {
        guard context.hasChanges else { return true }
        do {
            try context.save()
            return true
        } catch {
            let nsError = error as NSError
            print("Core Data save error: \(nsError), \(nsError.userInfo)")
            return false
        }
    }
}
