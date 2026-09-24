import Foundation
import UserNotifications

/// Notificações nativas ao cruzar 50/80/95% de um limite, uma vez por limite, período e patamar.
@MainActor
final class AlertNotifier {
    static let thresholds: [Double] = [0.5, 0.8, 0.95]
    private let firedKey = "alerts.fired"

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func evaluate(_ limits: [LimitStatus]) {
        guard !AppEnvironment.isIsolated, UserDefaults.standard.bool(forKey: BudgetKey.alertsEnabled) else { return }
        var fired = Set(UserDefaults.standard.stringArray(forKey: firedKey) ?? [])
        let before = fired.count

        for limit in limits {
            // Só o patamar mais alto cruzado gera notificação; os de baixo são marcados como vistos.
            let crossed = Self.thresholds.filter { limit.fraction >= $0 }
            guard let highest = crossed.last else { continue }
            let keys = crossed.map { "\(limit.id)|\(limit.periodID)|\($0)" }
            guard !fired.contains(keys.last!) else { continue }
            keys.forEach { fired.insert($0) }
            send(limit, threshold: highest)
        }

        if fired.count != before {
            // Mantém a lista pequena: guarda só os mais recentes.
            UserDefaults.standard.set(Array(fired.suffix(200)), forKey: firedKey)
        }
    }

    private func send(_ limit: LimitStatus, threshold: Double) {
        let content = UNMutableNotificationContent()
        content.title = "\(limit.title): \(limit.fraction.formatted(.percent.precision(.fractionLength(0))))"
        content.body = [limit.usageText, limit.resetText].compactMap { $0 }.joined(separator: " · ")
        if threshold >= 0.95 { content.sound = .default }
        let request = UNNotificationRequest(identifier: "\(limit.id)-\(limit.periodID)-\(threshold)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
