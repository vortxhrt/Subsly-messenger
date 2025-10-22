import Foundation
import FirebaseMessaging
import UserNotifications
import UIKit

/// A singleton responsible for requesting notification permission,
/// registering with APNs, and syncing the FCM token with Firestore via UserService.
final class PushNotificationManager: NSObject {
    static let shared = PushNotificationManager()

    /// Requests permission from the user and registers for remote notifications.
    func registerForPushNotifications() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                } else {
                    if let error = error {
                        print("🔕 Notification authorization error: \(error.localizedDescription)")
                    } else {
                        print("🔕 Notification permission not granted.")
                    }
                }
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension PushNotificationManager: UNUserNotificationCenterDelegate {
    // Display banner and play sound when a notification arrives in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - MessagingDelegate
extension PushNotificationManager: MessagingDelegate {
    // Called when a new or refreshed FCM token is received.
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let uid = SessionStore.shared.id,
              let token = fcmToken else {
            return
        }
        // Persist the token to Firestore so that Cloud Functions can send push notifications.
        Task {
            do {
                try await UserService.shared.saveFCMToken(uid: uid, token: token)
                print("🔐 Saved FCM token for user \(uid)")
            } catch {
                print("❌ Failed to save FCM token: \(error.localizedDescription)")
            }
        }
    }
}
