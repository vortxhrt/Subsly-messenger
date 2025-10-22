import Foundation
import FirebaseMessaging
import UserNotifications
import UIKit

/// A singleton responsible for requesting notification permission,
/// registering with APNs, and syncing the FCM token with Firestore via UserService.
final class PushNotificationManager: NSObject {
    static let shared = PushNotificationManager()

    // Holds a token received before a user is logged in.
    private var pendingToken: String?

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

    /// Saves a pending FCM token (if any) once a user ID becomes available.
    func savePendingToken(for uid: String) {
        guard let token = pendingToken else { return }
        Task {
            do {
                try await UserService.shared.saveFCMToken(uid: uid, token: token)
                print("🔐 Saved pending FCM token for user \(uid)")
                pendingToken = nil
            } catch {
                print("❌ Failed to save pending FCM token: \(error.localizedDescription)")
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
        guard let token = fcmToken else { return }

        if let uid = SessionStore.shared.id {
            // User is signed in; save immediately.
            Task {
                do {
                    try await UserService.shared.saveFCMToken(uid: uid, token: token)
                    print("🔐 Saved FCM token for user \(uid)")
                } catch {
                    print("❌ Failed to save FCM token: \(error.localizedDescription)")
                }
            }
        } else {
            // User not signed in yet; store token until login.
            pendingToken = token
        }
    }
}
