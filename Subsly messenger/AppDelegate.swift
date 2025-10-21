import UIKit
import FirebaseCore

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {

        // Print your bundle identifier so you can copy it into Firebase
        let bundleID = Bundle.main.bundleIdentifier ?? "nil"
        print("📦 BUNDLE ID => \(bundleID)")

        // Configure Firebase if the plist is present; don't crash if it's not.
        if let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
           let options = FirebaseOptions(contentsOfFile: path) {
            FirebaseApp.configure(options: options)
            print("✅ Firebase configured with projectID=\(options.projectID ?? "unknown")")
        } else {
            print("❌ Missing GoogleService-Info.plist. App will run in local/offline mode.")
        }
        return true
    }
}
