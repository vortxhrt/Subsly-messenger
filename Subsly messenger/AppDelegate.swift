import UIKit
import FirebaseCore
import FirebaseAuth
import FirebaseMessaging
import UserNotifications
import FirebaseFirestore

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {

    private var apnsTokenPollTimer: Timer?
    private var hasLoggedAPNsOnce = false

    // MARK: - App Launch
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {

        FirebaseApp.configure()

        if let opts = FirebaseApp.app()?.options {
            print("📛 Firebase projectID=\(opts.projectID ?? "nil"), senderID=\(opts.gcmSenderID ?? "nil"), bundle=\(Bundle.main.bundleIdentifier ?? "nil")")
        }

        // Print entitlements/env from embedded.mobileprovision (Debug/ad-hoc installs)
        logProvisioningProfileAPS()

        // UNUserNotificationCenter
        UNUserNotificationCenter.current().delegate = self
        debugDumpNotificationState(prefix: "🛠️ Current notif settings")

        // Ask permission then register
        requestPushPermission()

        // Show initial flag
        print("🛰️ isRegisteredForRemoteNotifications =", application.isRegisteredForRemoteNotifications)

        // Messaging delegate
        Messaging.messaging().delegate = self

        // Early FCM fetch (might fail until APNs arrives)
        fetchFCMToken(context: "initial fetch on launch")

        // Retry when app becomes active
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.fetchFCMToken(context: "didBecomeActive re-fetch")
            self?.debugDumpNotificationState(prefix: "🔁 didBecomeActive notif settings")
        }

        // Force a few re-registrations to coax APNs callback
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            UIApplication.shared.registerForRemoteNotifications()
            print("📮 Re-register attempt #1")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            UIApplication.shared.registerForRemoteNotifications()
            print("📮 Re-register attempt #2")
        }

        // Poll for APNs token inside Firebase Messaging (will be non-nil after didRegister callback)
        apnsTokenPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            if let t = Messaging.messaging().apnsToken {
                let hex = t.map { String(format: "%02.2hhx", $0) }.joined()
                if !self.hasLoggedAPNsOnce {
                    print("🛰️ apnsToken now present (from Messaging): \(hex)")
                    self.hasLoggedAPNsOnce = true
                    self.fetchFCMToken(context: "after apnsToken observed in poll")
                }
            } else {
                print("🛰️ apnsToken still nil (poll)")
            }
        }

        // Send a local notification after 3s to confirm banners actually display
        scheduleLocalDebugNotification()

        // Save token when auth changes
        Auth.auth().addStateDidChangeListener { _, user in
            if let user = user { print("👤 Auth state: signed in uid=\(user.uid)") } else { print("👤 Auth state: signed out") }
            if let token = Messaging.messaging().fcmToken {
                print("🎯 FCM token (property) currently available: \(token)")
                self.persistFCMToken(token)
            } else {
                print("⚠️ FCM token (property) not set yet after auth change – re-fetching")
                self.fetchFCMToken(context: "sync after auth state change")
            }
        }

        return true
    }

    // MARK: - Permissions
    private func requestPushPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error = error { print("🔕 Notification permission error:", error); return }
            print("🔔 Notification permission granted:", granted)
            self.debugDumpNotificationState(prefix: "🧾 Post-request settings")
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
                print("📮 Called registerForRemoteNotifications()")
            }
        }
    }

    private func debugDumpNotificationState(prefix: String) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            print("\(prefix): authStatus=\(s.authorizationStatus.rawValue) alert=\(s.alertSetting.rawValue) sound=\(s.soundSetting.rawValue) badge=\(s.badgeSetting.rawValue) lockScreen=\(s.lockScreenSetting.rawValue) notificationCenter=\(s.notificationCenterSetting.rawValue)")
        }
    }

    // MARK: - APNs Callbacks
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("📦 didRegisterForRemoteNotificationsWithDeviceToken hex=\(hex)")

        #if DEBUG
        Messaging.messaging().setAPNSToken(deviceToken, type: .sandbox)
        print("🔧 setAPNSToken: .sandbox (DEBUG build)")
        #else
        Messaging.messaging().setAPNSToken(deviceToken, type: .prod)
        print("🏁 setAPNSToken: .prod (RELEASE/TestFlight)")
        #endif

        Messaging.messaging().apnsToken = deviceToken
        print("✅ Messaging.apnsToken assigned")

        fetchFCMToken(context: "after APNs registration")
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("❌ didFailToRegisterForRemoteNotifications:", error.localizedDescription)
    }

    // MARK: - Messaging Delegate
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        if let token = fcmToken {
            print("🎯 FCM token updated (delegate): \(token)")
            persistFCMToken(token)
        } else {
            print("⚠️ didReceiveRegistrationToken with nil token")
        }
    }

    // MARK: - Notification Reception
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        print("📥 willPresent userInfo:", notification.request.content.userInfo)
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        print("📬 didReceive response userInfo:", response.notification.request.content.userInfo)
        completionHandler()
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable : Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        print("📦 didReceiveRemoteNotification (fetch) userInfo:", userInfo)
        completionHandler(.noData)
    }

    // MARK: - Token Helpers
    private func fetchFCMToken(context: String) {
        Messaging.messaging().token { token, error in
            if let error = error { print("⚠️ FCM token fetch failed (\(context)): \(error)") }
            else if let token = token { print("🎯 FCM token updated (\(context)): \(token)"); self.persistFCMToken(token) }
            else { print("⚠️ FCM token fetch returned nil (\(context))") }
        }
    }

    private func persistFCMToken(_ token: String) {
        guard let uid = Auth.auth().currentUser?.uid else {
            print("⚠️ No signed-in user; will save token after sign-in.")
            return
        }
        let db = Firestore.firestore()
        db.collection("users").document(uid).setData(
            ["fcmToken": token, "updatedAt": FieldValue.serverTimestamp()],
            merge: true
        ) { err in
            if let err = err { print("❌ Saving FCM token failed:", err.localizedDescription) }
            else { print("✅ FCM token saved to Firestore.") }
        }
    }

    // MARK: - Local debug notification
    private func scheduleLocalDebugNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Subsly Local Debug"
        content.body  = "If you see this, iOS banners work."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        let req = UNNotificationRequest(identifier: "subsly.local.debug", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req) { err in
            if let err = err { print("❌ Local notif scheduling failed:", err.localizedDescription) }
            else { print("🧪 Local notif scheduled for +3s") }
        }
    }

    // MARK: - Provisioning profile APS env logger (Debug/ad-hoc builds)
    private func logProvisioningProfileAPS() {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let raw = try? String(contentsOfFile: path, encoding: .isoLatin1) else {
            print("ℹ️ No embedded.mobileprovision found (expected for TestFlight/App Store).")
            return
        }
        if let plistStart = raw.range(of: "<plist"),
           let plistEnd = raw.range(of: "</plist>") {
            let plistString = String(raw[plistStart.lowerBound...plistEnd.upperBound])
            if let data = plistString.data(using: .utf8),
               let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
               let ent = plist["Entitlements"] as? [String: Any],
               let aps = ent["aps-environment"] as? String {
                print("🧾 embedded.mobileprovision aps-environment=\(aps)")
            } else {
                print("⚠️ Could not parse aps-environment from embedded.mobileprovision")
            }
        } else {
            print("⚠️ mobileprovision plist markers not found")
        }
    }
}
