import BackgroundTasks
import CoreData

/// Registers, schedules, and handles the two background price-check tasks.
///
/// - **bgrefresh** (`BGAppRefreshTask`): iOS wakes the app periodically (system-decided,
///   typically a few times per day) to check the 3 most-stale items within 30 seconds.
/// - **bgprocessing** (`BGProcessingTask`): runs a full check of all items when the device
///   has network connectivity. iOS defers this to a convenient time (idle, charging, etc.).
///
/// Call `registerHandlers()` exactly once from `App.init()`, before the first scene is shown.
/// Call `scheduleAll()` every time the app becomes active so the tasks stay scheduled.
enum BackgroundTaskService {

    static let refreshTaskID    = "com.anbery.Sale-Alert-Buddy.bgrefresh"
    static let processingTaskID = "com.anbery.Sale-Alert-Buddy.bgprocessing"

    // MARK: - Registration

    /// Registers both task handlers with `BGTaskScheduler`.
    ///
    /// Must be called before the app finishes launching (i.e. from `App.init()`).
    static func registerHandlers() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: refreshTaskID, using: nil
        ) { task in
            handleAppRefresh(task: task as! BGAppRefreshTask)
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: processingTaskID, using: nil
        ) { task in
            handleProcessing(task: task as! BGProcessingTask)
        }
    }

    // MARK: - Scheduling

    /// Submits both task requests. Safe to call repeatedly; iOS deduplicates.
    static func scheduleAll() {
        scheduleRefresh()
        scheduleProcessing()
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        // Hint to iOS: don't run sooner than 15 minutes. Actual timing is up to iOS.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        // Hint to iOS: don't run sooner than 1 hour.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - Handlers

    /// Checks the 3 most-stale active items within the 30-second BGAppRefreshTask window.
    private static func handleAppRefresh(task: BGAppRefreshTask) {
        // Reschedule before doing work so the next run is always queued.
        scheduleRefresh()

        let context = PersistenceController.shared.container.viewContext

        let checkTask = Task { @MainActor in
            let request = TrackingItem.activeItemsFetchRequest()
            // Most stale items first (nil lastCheckedAt sorts to the top via .distantPast default).
            request.sortDescriptors = [NSSortDescriptor(key: "lastCheckedAt", ascending: true)]
            request.fetchLimit = 3

            guard let items = try? context.fetch(request), !items.isEmpty else {
                task.setTaskCompleted(success: true)
                return
            }

            // Sequential to stay well within the 30-second time budget.
            for item in items {
                await PriceCheckService.shared.checkItem(item, context: context, timeout: 10)
            }
            task.setTaskCompleted(success: true)
        }

        // iOS calls this when time is up — cancel work and mark done.
        task.expirationHandler = {
            checkTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    /// Checks all active items. iOS runs this when the device is idle and connected.
    private static func handleProcessing(task: BGProcessingTask) {
        scheduleProcessing()

        let context = PersistenceController.shared.container.viewContext

        let checkTask = Task { @MainActor in
            await PriceCheckService.shared.checkAll(
                context: context,
                maxConcurrent: 3,
                timeout: 20
            )
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            checkTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
