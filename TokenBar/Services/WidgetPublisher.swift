import Foundation
import WidgetKit
import os

/// Grava o resumo para o widget no App Group e pede recarga só quando algo relevante muda
/// (no máximo uma vez por minuto, para respeitar o orçamento de recargas do WidgetKit).
@MainActor
final class WidgetPublisher {
    private var last: WidgetSnapshot?
    private var lastReload: Date = .distantPast
    private static let log = Logger(subsystem: "dev.galuppo.TokenBar", category: "Widget")

    func publish(todayTokens: Int, todayCostUSD: Double, limits: [LimitStatus]) {
        // Destaque: sessão do plano Claude; depois os demais limites do mais usado ao menos usado.
        let ordered = limits.filter { $0.kind == .planSession }
            + limits.filter { $0.kind != .planSession }.sorted { $0.fraction > $1.fraction }
        let snapshot = WidgetSnapshot(
            updatedAt: .now,
            todayTokens: todayTokens,
            todayCostUSD: todayCostUSD,
            limits: ordered.map {
                .init(id: $0.id, title: $0.shortTitle, fraction: $0.fraction, resetsAt: $0.resetsAt)
            }
        )

        // Ignora a data ao comparar: só republica se os números mudaram.
        if var previous = last {
            previous.updatedAt = snapshot.updatedAt
            if previous == snapshot { return }
        }
        do {
            try snapshot.save()
        } catch {
            Self.log.error("Falha ao gravar o resumo do widget: \(error.localizedDescription)")
            return
        }
        last = snapshot

        if Date.now.timeIntervalSince(lastReload) >= 60 {
            lastReload = .now
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
        }
    }
}
