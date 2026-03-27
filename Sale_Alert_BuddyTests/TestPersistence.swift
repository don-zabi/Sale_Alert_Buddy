import Foundation
import CoreData
@testable import Sale_Alert_Buddy

/// Single shared in-memory persistence controller for all unit tests.
///
/// Using one container per process prevents NSEntityDescription conflicts that arise
/// when multiple PersistentContainers try to register the same @objc classes.
enum TestPersistence {
    nonisolated(unsafe) static let shared = PersistenceController(inMemory: true)

    /// Returns a new background context on the shared in-memory store.
    /// Each test should use a fresh context for isolation.
    static func newContext() -> NSManagedObjectContext {
        let ctx = shared.newBackgroundContext()
        return ctx
    }
}
