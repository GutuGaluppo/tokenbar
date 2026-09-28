import Foundation
import UserNotifications

/// Notificações das dicas ao vivo (opcionais): só as urgentes e o cache prestes a expirar — as que
/// valem mesmo com o app fechado. Uma vez por dica e sessão.
@MainActor
final class LiveTipsNotifier {
    static let enabledKey = "liveTips.notifications"
    private static let firedKey = "liveTips.fired"
    private static let timedTips: Set<String> = ["cache-expiring"]

    func evaluate(_ sessions: [LiveSession]) {
        guard !AppEnvironment.isIsolated, UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        var fired = Set(UserDefaults.standard.stringArray(forKey: Self.firedKey) ?? [])
        let before = fired.count

        for session in sessions {
            for tip in session.tips where tip.severity == .urgent || Self.timedTips.contains(tip.id) {
                // Cache: um aviso por pausa, não por sessão.
                let period = tip.id == "cache-expiring" ? "|\(Int(session.lastActivity.timeIntervalSince1970))" : ""
                let key = "\(session.id)|\(tip.id)\(period)"
                guard fired.insert(key).inserted else { continue }
                send(tip, session: session, identifier: key)
            }
        }

        if fired.count != before {
            UserDefaults.standard.set(Array(fired.suffix(200)), forKey: Self.firedKey)
        }
    }

    private func send(_ tip: LiveTip, session: LiveSession, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = tip.title
        content.subtitle = [session.project, session.agent].compactMap { $0 }.joined(separator: " · ")
        content.body = tip.detail
        if tip.severity == .urgent { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}
