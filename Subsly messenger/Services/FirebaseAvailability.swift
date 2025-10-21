import Foundation
import FirebaseCore

enum FirebaseAvailability {
    /// Safe to call from any thread or actor.
    static func isConfigured() -> Bool {
        if Thread.isMainThread {
            return FirebaseApp.app() != nil
        }
        var result = false
        DispatchQueue.main.sync {
            result = FirebaseApp.app() != nil
        }
        return result
    }
}
