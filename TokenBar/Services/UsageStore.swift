import Foundation
import SwiftData
import Observation

struct UsageTotals: Equatable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
    var costUSD = 0.0

    var tokens: Int { input + output + cacheWrite + cacheRead }

    mutating func add(_ event: UsageEvent) {
        input += event.inputTokens
        output += event.outputTokens
        cacheWrite += event.cacheWriteTokens
        cacheRead += event.cacheReadTokens
        costUSD += event.costUSD
    }
}

struct ModelTotal: Identifiable, Equatable {
    var id: String { model }
    let model: String
    let provider: Provider
    var totals: UsageTotals
}

struct HourBucket: Identifiable, Equatable {
    var id: String { "\(hour.timeIntervalSince1970)-\(provider.rawValue)" }
    let hour: Date
    let provider: Provider
    var tokens: Int
}

/// Lê o banco e mantém os agregados que a UI mostra. Coletores (M1+) só gravam `UsageEvent`s;
/// o store percebe cada gravação e recalcula.
@MainActor
@Observable
final class UsageStore {
    private(set) var today = UsageTotals()
    private(set) var dailyAverageLast7Days = UsageTotals()
    private(set) var topModelsToday: [ModelTotal] = []
    private(set) var last24Hours: [HourBucket] = []
    private(set) var lastRefresh: Date = .distantPast
    private(set) var monthCostUSD = 0.0
    /// Tokens do Claude Code (sem leituras de cache) nas últimas 5 h e 7 dias, e o pico de 5 h da semana —
    /// referência para calibrar os limites estimados do plano.
    private(set) var claudeCodeLast5h = 0
    private(set) var claudeCodeLast7d = 0
    private(set) var claudeCodePeak5hLast7d = 0
    private(set) var limits: [LimitStatus] = []

    let container: ModelContainer
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let notifier = AlertNotifier()
    @ObservationIgnored private let widget = WidgetPublisher()
    /// Uso real do plano Claude (opcional); quando presente, entra na lista de limites.
    @ObservationIgnored var planUsage: ClaudePlanUsage?
    /// Fontes locais; o Codex traz os limites do plano nos próprios logs.
    @ObservationIgnored var localSources: LocalSources?
    @ObservationIgnored var remoteSources: RemoteSourcesManager?

    init(container: ModelContainer) {
        self.container = container
        refresh()

        observers.append(NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLimitsIfBudgetsChanged() }
        })

        // Recalcula a cada minuto para acompanhar a virada do dia e a janela de 24 h.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// O limite mais próximo de estourar (para o ícone da barra de menus).
    var nearestLimit: LimitStatus? { limits.max { $0.fraction < $1.fraction } }

    /// "Current session" do plano Claude, quando disponível.
    var planSession: LimitStatus? { limits.first { $0.kind == .planSession } }

    /// Variação de hoje em relação à média diária dos 7 dias anteriores (nil sem histórico).
    var changeVersusAverage: Double? {
        guard dailyAverageLast7Days.tokens > 0 else { return nil }
        return Double(today.tokens) / Double(dailyAverageLast7Days.tokens) - 1
    }

    func refresh() {
        let calendar = Calendar.current
        let now = Date.now
        let startOfToday = calendar.startOfDay(for: now)
        let startOf7Days = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
        let start24h = now.addingTimeInterval(-24 * 3600)
        let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? startOfToday
        let from = min(startOf7Days, start24h, startOfMonth)

        let descriptor = FetchDescriptor<UsageEvent>(
            predicate: #Predicate { $0.timestamp >= from },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let events = (try? container.mainContext.fetch(descriptor)) ?? []

        var today = UsageTotals()
        var previous = UsageTotals()
        var models: [String: ModelTotal] = [:]
        var buckets: [String: HourBucket] = [:]
        var monthCost = 0.0
        var claudeCode: [(date: Date, tokens: Int)] = []
        let start7d = now.addingTimeInterval(-7 * 86_400)

        for event in events {
            if event.timestamp >= startOfMonth { monthCost += event.costUSD }
            if event.isClaudeCode, event.timestamp >= start7d {
                claudeCode.append((event.timestamp, event.limitTokens))
            }

            if event.timestamp >= startOfToday {
                today.add(event)
                models[event.model, default: ModelTotal(model: event.model, provider: event.provider, totals: .init())]
                    .totals.add(event)
            } else if event.timestamp >= startOf7Days {
                previous.add(event)
            }

            if event.timestamp >= start24h,
               let hour = calendar.dateInterval(of: .hour, for: event.timestamp)?.start {
                let bucket = HourBucket(hour: hour, provider: event.provider, tokens: 0)
                buckets[bucket.id, default: bucket].tokens += event.totalTokens
            }
        }

        self.today = today
        self.dailyAverageLast7Days = UsageTotals(
            input: previous.input / 7,
            output: previous.output / 7,
            cacheWrite: previous.cacheWrite / 7,
            cacheRead: previous.cacheRead / 7,
            costUSD: previous.costUSD / 7
        )
        self.topModelsToday = models.values
            .sorted { $0.totals.tokens > $1.totals.tokens }
            .prefix(3)
            .map { $0 }
        self.last24Hours = buckets.values.sorted { $0.hour < $1.hour }
        self.lastRefresh = now
        self.monthCostUSD = monthCost

        // Blocos de 5 h como no plano do Claude: o bloco começa na primeira mensagem depois que o
        // anterior terminou e dura 5 h. Eventos já vêm ordenados por data.
        let blocks = Self.fiveHourBlocks(claudeCode)
        let currentBlock = blocks.last.flatMap { $0.start.addingTimeInterval(5 * 3600) > now ? $0 : nil }
        claudeCodeLast5h = currentBlock?.tokens ?? 0
        claudeCodeLast7d = claudeCode.reduce(0) { $0 + $1.tokens }
        claudeCodePeak5hLast7d = blocks.map(\.tokens).max() ?? 0

        let settings = BudgetSettings.load()
        var limits: [LimitStatus] = []
        let dayID = startOfToday.formatted(.iso8601.year().month().day())
        if settings.dailyUSD > 0 {
            limits.append(LimitStatus(kind: .dailyCost, used: today.costUSD, limit: settings.dailyUSD,
                                      resetsAt: calendar.date(byAdding: .day, value: 1, to: startOfToday),
                                      periodID: dayID))
        }
        if settings.monthlyUSD > 0 {
            limits.append(LimitStatus(kind: .monthlyCost, used: monthCost, limit: settings.monthlyUSD,
                                      resetsAt: calendar.date(byAdding: .month, value: 1, to: startOfMonth),
                                      periodID: startOfMonth.formatted(.iso8601.year().month())))
        }
        if settings.fiveHourTokens > 0 {
            limits.append(LimitStatus(kind: .fiveHourTokens, used: Double(claudeCodeLast5h), limit: settings.fiveHourTokens,
                                      resetsAt: currentBlock.map { $0.start.addingTimeInterval(5 * 3600) },
                                      periodID: currentBlock.map { String(Int($0.start.timeIntervalSince1970)) } ?? "none"))
        }
        if settings.weeklyTokens > 0 {
            // Janela móvel de 7 dias; alerta no máximo uma vez por semana do calendário.
            let week = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            limits.append(LimitStatus(kind: .weeklyTokens, used: Double(claudeCodeLast7d), limit: settings.weeklyTokens,
                                      resetsAt: nil,
                                      periodID: "\(week.yearForWeekOfYear ?? 0)-W\(week.weekOfYear ?? 0)"))
        }
        if let plan = planUsage {
            let windows: [(LimitStatus.Kind, ClaudePlanUsage.Window?)] = [
                (.planSession, plan.session), (.planWeek, plan.week),
                (.planWeekSonnet, plan.weekSonnet), (.planWeekOpus, plan.weekOpus),
            ]
            for case let (kind, window?) in windows {
                limits.append(LimitStatus(kind: kind, used: window.utilization, limit: 100,
                                          resetsAt: window.resetsAt,
                                          periodID: window.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? dayID))
            }
        }
        if let codex = localSources?.codex.planLimits {
            for window in codex.windows {
                // Janela já reiniciada desde a última leitura: uso zerado até o Codex registrar de novo.
                let expired = window.resetsAt.map { $0 <= now } ?? false
                let kind: LimitStatus.Kind = window.windowMinutes <= 300 ? .codexSession : .codexWeek
                limits.append(LimitStatus(kind: kind, used: expired ? 0 : window.usedPercent, limit: 100,
                                          resetsAt: expired ? nil : window.resetsAt,
                                          periodID: window.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? dayID))
            }
        }
        if let credits = remoteSources?.openRouterCredits, credits.total > 0 {
            // Alertas voltam a valer a cada recarga de créditos.
            limits.append(LimitStatus(kind: .openRouterCredits, used: credits.used, limit: credits.total,
                                      resetsAt: nil, periodID: "credits-\(Int(credits.total * 100))"))
        }
        self.limits = limits
        lastBudgets = settings
        notifier.evaluate(limits)
        widget.publish(todayTokens: today.tokens, todayCostUSD: today.costUSD, limits: limits)
    }

    @ObservationIgnored private var lastBudgets: BudgetSettings?

    private func refreshLimitsIfBudgetsChanged() {
        let settings = BudgetSettings.load()
        guard settings != lastBudgets else { return }
        refresh()
    }

    private struct Block {
        let start: Date
        var tokens: Int
    }

    private static func fiveHourBlocks(_ items: [(date: Date, tokens: Int)]) -> [Block] {
        var blocks: [Block] = []
        for item in items {
            if let last = blocks.last, item.date < last.start.addingTimeInterval(5 * 3600) {
                blocks[blocks.count - 1].tokens += item.tokens
            } else {
                blocks.append(Block(start: item.date, tokens: item.tokens))
            }
        }
        return blocks
    }
}
