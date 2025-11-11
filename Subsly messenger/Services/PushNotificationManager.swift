import Foundation
import FirebaseMessaging
import UserNotifications
import UIKit

/// A singleton responsible for requesting notification permission,
/// registering with APNs, and syncing the FCM token with Firestore via UserService.
@MainActor
final class PushNotificationManager: NSObject {
    static let shared = PushNotificationManager()

    // Holds a token received before a user is logged in.
    private var pendingToken: String?

    /// Requests permission from the user and registers for remote notifications.
    func registerForPushNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                } else if error != nil {
                    print("Notification authorization error.")
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
                pendingToken = nil
            } catch {
                print("Failed to persist pending push token.")
            }
        }
    }

    /// Clears any cached token when signing out or when we should drop state.
    func clearCachedToken() {
        pendingToken = nil
    }

    func handleAuthStateChange(uid: String?) {
        if let uid, let token = Messaging.messaging().fcmToken {
            Task {
                do {
                    try await UserService.shared.saveFCMToken(uid: uid, token: token)
                } catch {
                    print("Failed to persist push token after auth change.")
                }
            }
        } else if uid == nil {
            clearCachedToken()
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension PushNotificationManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void)
    {
        completionHandler([.banner, .sound])
    }
}

// MARK: - MessagingDelegate
extension PushNotificationManager: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken else { return }

        if let uid = SessionStore.shared.id {
            Task {
                do {
                    try await UserService.shared.saveFCMToken(uid: uid, token: token)
                } catch {
                    print("Failed to persist push token.")
                }
            }
        } else {
            pendingToken = token
        }
    }
}
