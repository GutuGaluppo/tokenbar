import AppKit
import Foundation
import SwiftData
import Observation

/// Mantém as sessões ativas do Claude Code e as dicas ao vivo de cada uma. Recalcula a cada
/// gravação no banco e a cada 30 s, porque regras como a do cache dependem só do relógio.
@MainActor
@Observable
final class LiveSessionsStore {
    /// Sessões ativas, com as dicas ignoradas já removidas.
    private(set) var sessions: [LiveSession] = []

    /// Alguma sessão pede ação imediata (para o ícone da barra de menus).
    var hasUrgentTip: Bool { sessions.contains { $0.topSeverity == .urgent } }

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let store: UsageStore
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// Dicas ignoradas, por sessão e regra. Valem até a sessão terminar (só em memória).
    @ObservationIgnored private var dismissed: Set<String> = []

    init(container: ModelContainer, store: UsageStore) {
        self.container = container
        self.store = store
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRun() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.run() }
        }
        run()
    }

    func dismiss(_ tip: LiveTip, in session: LiveSession) {
        dismissed.insert(Self.key(session.id, tip.id))
        run()
    }

    func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// Várias gravações seguidas durante uma importação viram um só cálculo.
    private func scheduleRun() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.run()
        }
    }

    func run(now: Date = .now) {
        let prices = PriceTable.load()
        let budgets = BudgetSettings.load()
        let context = LiveContext(planSession: store.planSession, dailyBudgetUSD: budgets.dailyUSD, todayCostUSD: store.today.costUSD)
        let engine = LiveSessionsEngine(prices: prices)

        var result = engine.sessions(from: fetchActiveEvents(now: now), context: context, now: now)
        for index in result.indices {
            let id = result[index].id
            result[index].tips.removeAll { dismissed.contains(Self.key(id, $0.id)) }
        }
        // Esquece o que foi ignorado em sessões que já terminaram.
        let active = Set(result.map(\.id))
        dismissed = dismissed.filter { active.contains(String($0.split(separator: "|").first ?? "")) }

        if result != sessions { sessions = result }
    }

    /// Todos os eventos das sessões do Claude Code com atividade recente — a sessão inteira, para
    /// saber como ela começou.
    private func fetchActiveEvents(now: Date) -> [LiveInput] {
        let context = container.mainContext
        let since = now.addingTimeInterval(-(3_600 + LiveSessionsEngine.idleGrace))
        let recent = FetchDescriptor<UsageEvent>(
            predicate: #Predicate { $0.timestamp >= since && $0.externalID.starts(with: "cc:") }
        )
        let ids = Set(((try? context.fetch(recent)) ?? []).compactMap(\.session))

        var events: [LiveInput] = []
        for id in ids {
            let descriptor = FetchDescriptor<UsageEvent>(predicate: #Predicate { $0.session == id })
            for event in (try? context.fetch(descriptor)) ?? [] where event.isClaudeCode {
                events.append(LiveInput(
                    timestamp: event.timestamp, model: event.model, project: event.project, tool: event.tool,
                    session: id, isSidechain: event.isSidechain,
                    input: event.inputTokens, output: event.outputTokens,
                    cacheWrite: event.cacheWriteTokens, cacheWrite1h: event.cacheWrite1hTokens,
                    cacheRead: event.cacheReadTokens, costUSD: event.costUSD
                ))
            }
        }
        return events
    }

    private static func key(_ session: String, _ tip: String) -> String { "\(session)|\(tip)" }
}
