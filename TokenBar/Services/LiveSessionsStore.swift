import AppKit
import Foundation
import SwiftData
import Observation

/// Mantém as sessões ativas do Claude Code e do Codex e as dicas ao vivo de cada uma. Recalcula a cada
/// gravação no banco e a cada 30 s, porque regras como a do cache dependem só do relógio.
@MainActor
@Observable
final class LiveSessionsStore {
    /// Sessões ativas, com as dicas ignoradas já removidas.
    private(set) var sessions: [LiveSession] = []

    /// Alguma sessão pede ação imediata (para o ícone da barra de menus).
    var hasUrgentTip: Bool { sessions.contains { $0.topSeverity == .urgent } }

    /// Economia estimada das dicas de contexto aplicadas (compactações), nos últimos 30 dias.
    private(set) var savedLast30Days = 0.0
    private(set) var savedSessions = 0

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let store: UsageStore
    @ObservationIgnored private let signals: SessionSignals?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// Dicas ignoradas, por sessão e regra. Valem até a sessão terminar (só em memória).
    @ObservationIgnored private var dismissed: Set<String> = []
    /// Quando cada sessão recebeu a primeira dica de contexto (para medir a economia depois).
    @ObservationIgnored private var contextTipShownAt: [String: Date] = [:]
    @ObservationIgnored private var ledger = LiveSavingsLedger.load()
    @ObservationIgnored private let notifier = LiveTipsNotifier()
    @ObservationIgnored private let statusLine = StatusLineBridge()

    init(container: ModelContainer, store: UsageStore, signals: SessionSignals? = nil) {
        self.container = container
        self.store = store
        self.signals = signals
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
        let context = LiveContext(planSession: store.planSession,
                                  codexSession: store.limits.first { $0.kind == .codexSession },
                                  dailyBudgetUSD: budgets.dailyUSD, todayCostUSD: store.today.costUSD)
        let engine = LiveSessionsEngine(prices: prices)

        let events = fetchActiveEvents(now: now)
        let activity = (signals?.signals(for: Set(events.map(\.session))) ?? [:])
            .mapValues { SessionActivity(signals: $0, now: now) }
        var result = engine.sessions(from: events, activity: activity, context: context, now: now)
        measureSavings(result, events: events, prices: prices, now: now)
        for index in result.indices {
            let id = result[index].id
            result[index].tips.removeAll { dismissed.contains(Self.key(id, $0.id)) }
        }
        // Esquece o que foi ignorado em sessões que já terminaram.
        let active = Set(result.map(\.id))
        dismissed = dismissed.filter { active.contains(String($0.split(separator: "|").first ?? "")) }
        contextTipShownAt = contextTipShownAt.filter { active.contains($0.key) }

        if result != sessions { sessions = result }
        notifier.evaluate(result)
        statusLine.publish(result)
    }

    /// Conversa que encolheu depois de uma dica de contexto: soma a releitura de cache que deixou de acontecer.
    private func measureSavings(_ sessions: [LiveSession], events: [LiveInput], prices: PriceTable, now: Date) {
        let main = Dictionary(grouping: events.filter { !$0.isSidechain }, by: \.session)
        var changed = false
        for session in sessions {
            if contextTipShownAt[session.id] == nil, session.tips.contains(where: { LiveSavings.contextTipIDs.contains($0.id) }) {
                contextTipShownAt[session.id] = now
            }
            guard let shownAt = contextTipShownAt[session.id],
                  let calls = main[session.id]?.sorted(by: { $0.timestamp < $1.timestamp }) else { continue }
            let saved = LiveSavings.saved(main: calls, tipShownAt: shownAt, prices: prices)
            if ledger.update(session: session.id, savedUSD: saved, now: now) { changed = true }
        }
        if changed { ledger.save() }
        let total = ledger.total
        if total != savedLast30Days { savedLast30Days = total }
        if ledger.entries.count != savedSessions { savedSessions = ledger.entries.count }
    }

    /// Todos os eventos das sessões do Claude Code com atividade recente — a sessão inteira, para
    /// saber como ela começou.
    private func fetchActiveEvents(now: Date) -> [LiveInput] {
        let context = container.mainContext
        let since = now.addingTimeInterval(-(3_600 + LiveSessionsEngine.idleGrace))
        let recent = FetchDescriptor<UsageEvent>(
            predicate: #Predicate { $0.timestamp >= since && ($0.externalID.starts(with: "cc:") || $0.externalID.starts(with: "cx:")) }
        )
        let ids = Set(((try? context.fetch(recent)) ?? []).compactMap(\.session))

        var events: [LiveInput] = []
        for id in ids {
            let descriptor = FetchDescriptor<UsageEvent>(predicate: #Predicate { $0.session == id })
            for event in (try? context.fetch(descriptor)) ?? [] where event.isClaudeCode || event.isCodex {
                events.append(LiveInput(
                    timestamp: event.timestamp, model: event.model, project: event.project, tool: event.tool,
                    session: id, isSidechain: event.isSidechain,
                    input: event.inputTokens, output: event.outputTokens,
                    cacheWrite: event.cacheWriteTokens, cacheWrite1h: event.cacheWrite1hTokens,
                    cacheRead: event.cacheReadTokens, costUSD: event.costUSD, isCodex: event.isCodex
                ))
            }
        }
        return events
    }

    private static func key(_ session: String, _ tip: String) -> String { "\(session)|\(tip)" }
}
