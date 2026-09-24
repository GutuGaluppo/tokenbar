import SwiftUI
import Charts

/// Seletores de período e métrica da toolbar (Overview, Modelos, Projetos, Atividade).
struct PeriodToolbar: ToolbarContent {
    @Bindable var analytics: AnalyticsStore
    @State private var showingCustom = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Período", selection: $analytics.preset) {
                ForEach(PeriodPreset.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: analytics.preset) { _, preset in
                if preset == .custom { showingCustom = true }
            }
            .popover(isPresented: $showingCustom, arrowEdge: .bottom) {
                Form {
                    DatePicker("De", selection: $analytics.customStart, in: ...Date.now, displayedComponents: .date)
                    DatePicker("Até", selection: $analytics.customEnd, in: ...Date.now, displayedComponents: .date)
                }
                .padding()
                .frame(width: 260)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("Métrica", selection: $analytics.metric) {
                ForEach(UsageMetric.allCases) { Text($0.title).tag($0) }
            }
            .help("O que os gráficos e rankings medem")
        }
    }
}

/// Texto curto do período, ex.: "17–23 de set.".
struct PeriodCaption: View {
    @Environment(AnalyticsStore.self) private var analytics

    var body: some View {
        Text(caption)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var caption: String {
        let end = analytics.interval.end.addingTimeInterval(-1)
        let start = analytics.interval.start
        if analytics.hourly { return start.formatted(date: .complete, time: .omitted) }
        return "\(start.formatted(.dateTime.day().month())) – \(end.formatted(.dateTime.day().month().year()))"
    }
}

/// Barras do período (por hora em "Hoje", por dia nos demais), empilhadas por provedor.
struct PeriodSeriesChart: View {
    @Environment(AnalyticsStore.self) private var analytics
    var height: CGFloat = 220

    var body: some View {
        let metric = analytics.metric
        if analytics.series.isEmpty {
            ContentUnavailableView("Sem uso no período", systemImage: "chart.bar")
                .frame(height: height)
        } else {
            Chart(analytics.series) { point in
                BarMark(
                    x: .value("Data", point.date, unit: analytics.hourly ? .hour : .day),
                    y: .value(metric.shortTitle, metric.value(point.totals))
                )
                .foregroundStyle(by: .value("Provedor", point.provider.displayName))
            }
            .chartForegroundStyleScale(
                domain: Provider.allCases.map(\.displayName),
                range: Provider.allCases.map(\.tint)
            )
            .chartXScale(domain: analytics.interval.start...analytics.interval.end)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(metric.format(number)) }
                    }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: height)
        }
    }
}

/// Barras horizontais com as maiores linhas de um agrupamento, na métrica atual.
struct RankingChart: View {
    @Environment(AnalyticsStore.self) private var analytics
    let rows: [GroupRow]
    var limit = 8

    var body: some View {
        let metric = analytics.metric
        let top = Array(rows.sorted { metric.value($0.totals) > metric.value($1.totals) }.prefix(limit))
        Chart(top) { row in
            BarMark(
                x: .value(metric.shortTitle, metric.value(row.totals)),
                y: .value("Nome", row.label)
            )
            .foregroundStyle(row.provider?.tint ?? .gray)
            .annotation(position: .trailing, alignment: .leading) {
                Text(metric.format(metric.value(row.totals)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .chartYScale(domain: top.map(\.label))
        .chartXAxis(.hidden)
        .frame(height: CGFloat(max(top.count, 1)) * 28 + 8)
    }
}

/// Participação de uma linha no total do período, na métrica atual.
func share(_ row: GroupRow, of total: UsageTotals, metric: UsageMetric) -> String {
    let whole = metric.value(total)
    guard whole > 0 else { return "—" }
    return (metric.value(row.totals) / whole).formatted(.percent.precision(.fractionLength(1)))
}
