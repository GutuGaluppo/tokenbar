import Foundation
import SwiftData
import Observation

enum PeriodPreset: String, CaseIterable, Identifiable {
    case today, last7, last30, last90, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: String(localized: "Hoje")
        case .last7: String(localized: "7 dias")
        case .last30: String(localized: "30 dias")
        case .last90: String(localized: "90 dias")
        case .custom: String(localized: "Personalizado")
        }
    }
}

/// O que as telas medem: custo ou tokens. Leituras de cache são baratas e costumam dominar
/// o total, por isso "sem leitura de cache" é a medida de tokens padrão.
enum UsageMetric: String, CaseIterable, Identifiable {
    case cost, tokensNoCacheRead, tokensTotal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cost: String(localized: "Custo")
        case .tokensNoCacheRead: String(localized: "Tokens (sem leitura de cache)")
        case .tokensTotal: String(localized: "Tokens (total)")
        }
    }

    var shortTitle: String {
        switch self {
        case .cost: String(localized: "Custo")
        case .tokensNoCacheRead: String(localized: "Tokens")
        case .tokensTotal: String(localized: "Tokens + cache")
        }
    }

    func value(_ totals: UsageTotals) -> Double {
        switch self {
        case .cost: totals.costUSD
        case .tokensNoCacheRead: Double(totals.input + totals.output + totals.cacheWrite)
        case .tokensTotal: Double(totals.tokens)
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .cost: TokenFormat.usd(value)
        case .tokensNoCacheRead, .tokensTotal: TokenFormat.compact(Int(value))
        }
    }
}

/// Uma linha agregada (por modelo, projeto ou ferramenta).
struct GroupRow: Identifiable, Equatable {
    let id: String
    var label: String { id }
    var provider: Provider?
    var totals = UsageTotals()
    var responses = 0
    var lastUsed: Date = .distantPast

    // Propriedades comparáveis para ordenar a Table.
    var costUSD: Double { totals.costUSD }
    var input: Int { totals.input }
    var output: Int { totals.output }
    var cacheWrite: Int { totals.cacheWrite }
    var cacheRead: Int { totals.cacheRead }
    var tokens: Int { totals.tokens }
    /// Mais de um provedor na mesma linha (ex.: projeto usado com Claude e Codex).
    var mixedProviders = false
    var providerName: String { mixedProviders ? String(localized: "Vários") : provider?.displayName ?? "—" }

    mutating func add(_ event: UsageEvent) {
        totals.add(event)
        if event.totalTokens > 0 { responses += 1 }
        lastUsed = max(lastUsed, event.timestamp)
        if provider == nil && !mixedProviders {
            provider = event.provider
        } else if let current = provider, current != event.provider {
            provider = nil
            mixedProviders = true
        }
    }
}

struct SeriesPoint: Identifiable, Equatable {
    var id: String { "\(date.timeIntervalSince1970)-\(provider.rawValue)" }
    let date: Date
    let provider: Provider
    var totals = UsageTotals()
}

struct HeatCell: Identifiable, Equatable {
    var id: String { "\(row)-\(column)" }
    let row: Int      // dia da semana (0 = primeiro dia da semana do calendário)
    let column: Int   // hora (0–23)
    var totals = UsageTotals()
}

struct CalendarDay: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let weekStart: Date
    let weekdayIndex: Int
    var totals = UsageTotals()
}

/// Agregações do período selecionado para a janela principal. Só recalcula enquanto a janela
/// está aberta e agrupa rajadas de gravações (importações) numa única recarga.
@MainActor
@Observable
final class AnalyticsStore {
    var preset: PeriodPreset = .last7 { didSet { reload() } }
    var customStart: Date = Calendar.current.date(byAdding: .day, value: -13, to: .now)! { didSet { reloadIfCustom() } }
    var customEnd: Date = .now { didSet { reloadIfCustom() } }
    var metric: UsageMetric = .cost

    var isActive = false {
        didSet { if isActive && !oldValue { reload() } }
    }

    private(set) var interval = DateInterval()
    private(set) var hourly = false
    private(set) var totals = UsageTotals()
    private(set) var responses = 0
    private(set) var byModel: [GroupRow] = []
    private(set) var byProject: [GroupRow] = []
    private(set) var byTool: [GroupRow] = []
    /// Modelos usados em cada projeto (para o detalhe da tela Projetos).
    private(set) var modelsByProject: [String: [GroupRow]] = [:]
    private(set) var modelsByTool: [String: [GroupRow]] = [:]
    private(set) var series: [SeriesPoint] = []
    private(set) var heatmap: [HeatCell] = []
    /// Últimas 26 semanas, dia a dia, independente do período (gráfico de "contribuições").
    private(set) var calendar: [CalendarDay] = []

    static let noProject = String(localized: "Sem projeto (API)")
    static let calendarWeeks = 26

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var pendingReload: Task<Void, Never>?

    init(container: ModelContainer) {
        self.container = container
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
    }

    /// Nomes curtos dos dias na ordem do calendário do usuário (dom, seg, … em pt-BR).
    static var weekdaySymbols: [String] {
        let calendar = Calendar.current
        let symbols = calendar.shortWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    private func reloadIfCustom() {
        if preset == .custom { reload() }
    }

    private func scheduleReload() {
        guard isActive else { return }
        pendingReload?.cancel()
        pendingReload = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    func reload() {
        guard isActive else { return }
        let cal = Calendar.current
        let now = Date.now
        let startOfToday = cal.startOfDay(for: now)

        let interval: DateInterval
        switch preset {
        case .today: interval = DateInterval(start: startOfToday, end: now)
        case .last7: interval = DateInterval(start: cal.date(byAdding: .day, value: -6, to: startOfToday)!, end: now)
        case .last30: interval = DateInterval(start: cal.date(byAdding: .day, value: -29, to: startOfToday)!, end: now)
        case .last90: interval = DateInterval(start: cal.date(byAdding: .day, value: -89, to: startOfToday)!, end: now)
        case .custom:
            let start = cal.startOfDay(for: min(customStart, customEnd))
            let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(customStart, customEnd)))!
            interval = DateInterval(start: start, end: min(end, now))
        }
        self.interval = interval
        hourly = interval.duration <= 86_400 + 1

        let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
        let calendarStart = cal.date(byAdding: .weekOfYear, value: -(Self.calendarWeeks - 1), to: thisWeek)!
        let from = min(interval.start, calendarStart)
        let to = interval.end

        let descriptor = FetchDescriptor<UsageEvent>(
            predicate: #Predicate { $0.timestamp >= from && $0.timestamp < to },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let events = (try? container.mainContext.fetch(descriptor)) ?? []

        var totals = UsageTotals()
        var responses = 0
        var models: [String: GroupRow] = [:]
        var projects: [String: GroupRow] = [:]
        var tools: [String: GroupRow] = [:]
        var projectModels: [String: [String: GroupRow]] = [:]
        var toolModels: [String: [String: GroupRow]] = [:]
        var series: [String: SeriesPoint] = [:]
        var heat: [String: HeatCell] = [:]
        var days: [Date: CalendarDay] = [:]

        for event in events {
            let day = cal.startOfDay(for: event.timestamp)
            let weekday = (cal.component(.weekday, from: event.timestamp) - cal.firstWeekday + 7) % 7

            if day >= calendarStart {
                let weekStart = cal.dateInterval(of: .weekOfYear, for: day)?.start ?? day
                days[day, default: CalendarDay(date: day, weekStart: weekStart, weekdayIndex: weekday)].totals.add(event)
            }

            guard interval.contains(event.timestamp) else { continue }
            totals.add(event)
            if event.totalTokens > 0 { responses += 1 }

            let project = event.project ?? Self.noProject
            let tool = event.tool ?? "—"
            models[event.model, default: GroupRow(id: event.model)].add(event)
            projects[project, default: GroupRow(id: project)].add(event)
            tools[tool, default: GroupRow(id: tool)].add(event)
            projectModels[project, default: [:]][event.model, default: GroupRow(id: event.model)].add(event)
            toolModels[tool, default: [:]][event.model, default: GroupRow(id: event.model)].add(event)

            let bucket = hourly ? (cal.dateInterval(of: .hour, for: event.timestamp)?.start ?? day) : day
            let point = SeriesPoint(date: bucket, provider: event.provider)
            series[point.id, default: point].totals.add(event)

            let hour = cal.component(.hour, from: event.timestamp)
            let cell = HeatCell(row: weekday, column: hour)
            heat[cell.id, default: cell].totals.add(event)
        }

        self.totals = totals
        self.responses = responses
        byModel = models.values.sorted { $0.costUSD > $1.costUSD }
        byProject = projects.values.sorted { $0.costUSD > $1.costUSD }
        byTool = tools.values.sorted { $0.costUSD > $1.costUSD }
        modelsByProject = projectModels.mapValues { $0.values.sorted { $0.costUSD > $1.costUSD } }
        modelsByTool = toolModels.mapValues { $0.values.sorted { $0.costUSD > $1.costUSD } }
        self.series = series.values.sorted { $0.date < $1.date }
        heatmap = heat.values.sorted { ($0.row, $0.column) < ($1.row, $1.column) }

        // Calendário completo, com os dias sem uso preenchidos.
        var calendarDays: [CalendarDay] = []
        var cursor = calendarStart
        while cursor <= startOfToday {
            let weekday = (cal.component(.weekday, from: cursor) - cal.firstWeekday + 7) % 7
            let weekStart = cal.dateInterval(of: .weekOfYear, for: cursor)?.start ?? cursor
            calendarDays.append(days[cursor] ?? CalendarDay(date: cursor, weekStart: weekStart, weekdayIndex: weekday))
            cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
        }
        calendar = calendarDays
    }
}
