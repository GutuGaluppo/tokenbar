import SwiftUI
import Charts

/// Quando você usa: calendário de 26 semanas e mapa dia da semana × hora do período.
struct ActivityView: View {
    @Environment(AnalyticsStore.self) private var analytics

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "Últimas \(AnalyticsStore.calendarWeeks) semanas · \(analytics.metric.shortTitle.lowercased())") {
                    CalendarHeatmap()
                }

                Card(title: "Dia da semana × hora") {
                    HStack(alignment: .firstTextBaseline) {
                        PeriodCaption()
                        Spacer()
                        if let peak = peakCell {
                            Text("Pico: \(AnalyticsStore.weekdaySymbols[peak.row]) \(peak.column)h")
                                .font(.callout.weight(.medium))
                        }
                    }
                    WeekHourHeatmap()
                }

                if !analytics.heatmap.isEmpty {
                    Card(title: "Por hora do dia") {
                        HourProfileChart()
                    }
                }
            }
            .padding(20)
        }
    }

    private var peakCell: HeatCell? {
        analytics.heatmap.max { analytics.metric.value($0.totals) < analytics.metric.value($1.totals) }
    }
}

private let heatGradient = Gradient(colors: [Color.accentColor.opacity(0.12), Color.accentColor])

/// Grade estilo "contribuições": colunas = semanas, linhas = dias da semana.
private struct CalendarHeatmap: View {
    @Environment(AnalyticsStore.self) private var analytics

    var body: some View {
        let metric = analytics.metric
        let symbols = AnalyticsStore.weekdaySymbols
        let active = analytics.calendar.filter { metric.value($0.totals) > 0 }
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                // Fundo neutro para dias sem uso.
                ForEach(analytics.calendar) { day in
                    RectangleMark(
                        x: .value("Semana", day.weekStart, unit: .weekOfYear),
                        y: .value("Dia", symbols[day.weekdayIndex]),
                        width: .ratio(0.85),
                        height: .ratio(0.85)
                    )
                    .foregroundStyle(Color.secondary.opacity(0.12))
                    .cornerRadius(2)
                }
                ForEach(active) { day in
                    RectangleMark(
                        x: .value("Semana", day.weekStart, unit: .weekOfYear),
                        y: .value("Dia", symbols[day.weekdayIndex]),
                        width: .ratio(0.85),
                        height: .ratio(0.85)
                    )
                    .foregroundStyle(by: .value(metric.shortTitle, metric.value(day.totals)))
                    .cornerRadius(2)
                }
            }
            .chartForegroundStyleScale(range: heatGradient)
            .chartYScale(domain: symbols)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
            .chartLegend(.hidden)
            .frame(height: 150)

            Text("\(active.count) dias com uso · total \(metric.format(active.reduce(0) { $0 + metric.value($1.totals) }))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Mapa de calor dia da semana × hora do período selecionado.
private struct WeekHourHeatmap: View {
    @Environment(AnalyticsStore.self) private var analytics

    var body: some View {
        let metric = analytics.metric
        let symbols = AnalyticsStore.weekdaySymbols
        if analytics.heatmap.isEmpty {
            ContentUnavailableView("Sem uso no período", systemImage: "calendar")
                .frame(height: 220)
        } else {
            Chart(analytics.heatmap) { cell in
                RectangleMark(
                    x: .value("Hora", cell.column),
                    y: .value("Dia", symbols[cell.row]),
                    width: .ratio(0.9),
                    height: .ratio(0.9)
                )
                .foregroundStyle(by: .value(metric.shortTitle, metric.value(cell.totals)))
                .cornerRadius(3)
            }
            .chartForegroundStyleScale(range: heatGradient)
            .chartXScale(domain: -0.5...23.5)
            .chartYScale(domain: symbols)
            .chartXAxis {
                AxisMarks(values: Array(stride(from: 0, through: 23, by: 3))) { value in
                    AxisValueLabel { if let hour = value.as(Int.self) { Text("\(hour)h") } }
                }
            }
            .chartLegend(.hidden)
            .frame(height: 220)
        }
    }
}

/// Soma por hora do dia no período (todas as semanas juntas).
private struct HourProfileChart: View {
    @Environment(AnalyticsStore.self) private var analytics

    var body: some View {
        let metric = analytics.metric
        let byHour = Dictionary(grouping: analytics.heatmap, by: \.column)
            .map { hour, cells in (hour: hour, value: cells.reduce(0) { $0 + metric.value($1.totals) }) }
            .sorted { $0.hour < $1.hour }
        Chart(byHour, id: \.hour) { item in
            BarMark(x: .value("Hora", item.hour), y: .value(metric.shortTitle, item.value))
                .foregroundStyle(Color.accentColor.gradient)
        }
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis {
            AxisMarks(values: Array(stride(from: 0, through: 23, by: 3))) { value in
                AxisValueLabel { if let hour = value.as(Int.self) { Text("\(hour)h") } }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { if let number = value.as(Double.self) { Text(metric.format(number)) } }
            }
        }
        .frame(height: 140)
    }
}
