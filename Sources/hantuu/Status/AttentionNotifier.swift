import AppKit
import Combine
import UserNotifications

/// The two notification switches in Settings. Kept in the data folder (not UserDefaults), so a
/// test copy started with --data-dir never touches the real app's settings.
final class StatusSettings: ObservableObject {
    @Published var notificationsEnabled = true { didSet { save() } }
    @Published var notifyWhenDone = true { didSet { save() } }

    private struct Stored: Codable {
        var notificationsEnabled = true
        var notifyWhenDone = true
    }

    private var loading = false
    private var file: URL { Paths.dataDir.appendingPathComponent("status-settings.json") }

    init() {
        loading = true
        if let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            notificationsEnabled = s.notificationsEnabled
            notifyWhenDone = s.notifyWhenDone
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        Paths.ensure(Paths.dataDir)
        let s = Stored(notificationsEnabled: notificationsEnabled, notifyWhenDone: notifyWhenDone)
        if let data = try? JSONEncoder.hantuu.encode(s) { try? data.write(to: file, options: .atomic) }
    }
}

struct AttentionNotice: Equatable {
    var chatID: UUID
    var title: String
    var body: String
    var isDone: Bool
}

protocol AttentionNotifying: AnyObject {
    /// Called once at startup. Must not ask for permission.
    func prepare()
    func post(_ notice: AttentionNotice)
    /// The chat was looked at: take its notification out of Notification Center.
    func withdraw(chatID: UUID)
}

/// macOS notifications through UserNotifications.
///
/// Permission is asked for the first time a notification is actually due, never at launch.
/// Test copies (--self-test, --data-dir or HANTUU_DATA_DIR) never touch UserNotifications, so
/// they can't put a permission prompt on screen. HANTUU_NOTIFY=1 opts a test copy back in.
final class SystemNotifier: NSObject, AttentionNotifying, UNUserNotificationCenterDelegate {
    var onOpen: ((UUID) -> Void)?

    static var allowedInThisProcess: Bool {
        let env = ProcessInfo.processInfo.environment
        // UserNotifications needs a real app bundle; a bare binary crashes on first use.
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundlePath.hasSuffix(".app") else { return false }
        if env["HANTUU_NOTIFY"] == "1" { return true }
        let args = CommandLine.arguments
        if args.contains("--self-test") || args.contains("--data-dir") { return false }
        if let d = env["HANTUU_DATA_DIR"], !d.isEmpty { return false }
        return true
    }

    private var center: UNUserNotificationCenter? { Self.allowedInThisProcess ? UNUserNotificationCenter.current() : nil }

    func prepare() {
        // Setting the delegate is what lets a click open the right chat. It asks for nothing.
        center?.delegate = self
    }

    func post(_ notice: AttentionNotice) {
        guard let center else {
            Log.write("notify (skipped in a test copy): \(notice.title): \(notice.body)")
            return
        }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.add(notice, to: center)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    if granted { self.add(notice, to: center) }
                }
            default:
                break
            }
        }
    }

    private func add(_ notice: AttentionNotice, to center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.threadIdentifier = notice.chatID.uuidString
        content.userInfo = ["chatID": notice.chatID.uuidString]
        if !notice.isDone { content.sound = .default }
        // One per chat: a newer state replaces the older notification instead of piling up.
        let request = UNNotificationRequest(identifier: Self.identifier(notice.chatID), content: content, trigger: nil)
        center.add(request) { error in
            if let error { Log.write("notification failed: \(error)") }
        }
    }

    func withdraw(chatID: UUID) {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.identifier(chatID)])
    }

    static func identifier(_ id: UUID) -> String { "hantuu.chat.\(id.uuidString)" }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Only posted for a chat you aren't looking at, so show it even while hantuu is in front.
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let raw = response.notification.request.content.userInfo["chatID"] as? String
        DispatchQueue.main.async {
            if let raw, let id = UUID(uuidString: raw) { self.onOpen?(id) }
            completionHandler()
        }
    }
}
