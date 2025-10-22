import UIKit
import FirebaseCore
import FirebaseMessaging

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {

        // Print your bundle identifier for verification
        let bundleID = Bundle.main.bundleIdentifier ?? "nil"
        print("📦 BUNDLE ID => \(bundleID)")

        // Configure Firebase if the plist is present
        if let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
           let options = FirebaseOptions(contentsOfFile: path) {
            FirebaseApp.configure(options: options)
            print("✅ Firebase configured with projectID=\(options.projectID ?? "unknown")")

            // Set FCM delegate to PushNotificationManager
            Messaging.messaging().delegate = PushNotificationManager.shared

            // Register for push notifications
            PushNotificationManager.shared.registerForPushNotifications()
        } else {
            print("❌ Missing GoogleService-Info.plist. App will run in local/offline mode.")
        }

        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // Pass device token to Firebase Messaging so notifications can be delivered
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable : Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // Handle silent notifications / background updates (optional)
        completionHandler(.newData)
    }
}
