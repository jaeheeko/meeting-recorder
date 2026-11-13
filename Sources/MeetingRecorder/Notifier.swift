import AppKit
import UserNotifications

/// UNUserNotificationCenter 알림. 권한이 없으면 osascript 알림으로 대신 보낸다(이때 아이콘은 스크립트 편집기).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    static func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = shared
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String, open: URL? = nil) {
        let c = UNUserNotificationCenter.current()
        c.getNotificationSettings { s in
            guard s.authorizationStatus == .authorized || s.authorizationStatus == .provisional else {
                fallback(title, body); return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let open { content.userInfo = ["open": open.path] }
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            c.add(req) { err in if err != nil { fallback(title, body) } }
        }
    }

    private static func fallback(_ title: String, _ body: String) {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
        try? p.run()
    }

    // 메뉴바 앱이 앞에 있어도 배너를 보여 준다.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    // 알림을 누르면 저장된 노트를 연다.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["open"] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        completionHandler()
    }
}
