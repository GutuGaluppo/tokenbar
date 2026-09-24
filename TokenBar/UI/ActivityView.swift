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

/// Célula de mapa de calor em coordenadas numéricas: coluna e linha viram retângulos de
/// [n, n + 0,86]. Retângulos com tamanho `.ratio` só funcionam em eixos de categorias.
private struct HeatRect: Identifiable {
    let id: String
    let column: Double
    let row: Double
    let value: Double
}

private func heatMarks(_ rects: [HeatRect], metric: UsageMetric) -> some ChartContent {
    ForEach(rects) { rect in
        RectangleMark(
            xStart: .value("x0", rect.column), xEnd: .value("x1", rect.column + 0.86),
            yStart: .value("y0", rect.row), yEnd: .value("y1", rect.row + 0.86)
        )
        .foregroundStyle(by: .value(metric.shortTitle, rect.value))
        .cornerRadius(3)
    }
}

/// Linhas = dias da semana, com o primeiro dia da semana no topo.
@MainActor
private func weekdayAxis() -> some AxisContent {
    let symbols = AnalyticsStore.weekdaySymbols
    return AxisMarks(position: .leading, values: (0..<7).map { Double(6 - $0) + 0.43 }) { value in
        AxisValueLabel {
            if let y = value.as(Double.self) { Text(symbols[6 - Int(y.rounded(.down))]) }
        }
    }
}

/// Grade estilo "contribuições": colunas = semanas, linhas = dias da semana.
private struct CalendarHeatmap: View {
    @Environment(AnalyticsStore.self) private var analytics

    var body: some View {
        let metric = analytics.metric
        let days = analytics.calendar
        let firstWeek = days.first?.weekStart ?? .now
        let column: (CalendarDay) -> Double = { ($0.weekStart.timeIntervalSince(firstWeek) / (7 * 86_400)).rounded() }
        let active = days.filter { metric.value($0.totals) > 0 }
        let empty = days.filter { metric.value($0.totals) == 0 }
        // Rótulo de mês na primeira semana de cada mês.
        var monthTicks: [(column: Double, label: String)] = []
        for day in days where Calendar.current.component(.day, from: day.date) == 1 {
            monthTicks.append((column(day) + 0.43, day.date.formatted(.dateTime.month(.abbreviated))))
        }
        let weeks = Double(AnalyticsStore.calendarWeeks)

        return VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(empty) { day in
                    RectangleMark(
                        xStart: .value("x0", column(day)), xEnd: .value("x1", column(day) + 0.86),
                        yStart: .value("y0", Double(6 - day.weekdayIndex)), yEnd: .value("y1", Double(6 - day.weekdayIndex) + 0.86)
                    )
                    .foregroundStyle(Color.secondary.opacity(0.12))
                    .cornerRadius(3)
                }
                heatMarks(active.map {
                    HeatRect(id: "\($0.date.timeIntervalSince1970)", column: column($0),
                             row: Double(6 - $0.weekdayIndex), value: metric.value($0.totals))
                }, metric: metric)
            }
            .chartForegroundStyleScale(range: heatGradient)
            .chartXScale(domain: 0...weeks)
            .chartYScale(domain: 0...7)
            .chartXAxis {
                AxisMarks(values: monthTicks.map(\.column)) { value in
                    AxisValueLabel {
                        if let x = value.as(Double.self), let tick = monthTicks.first(where: { $0.column == x }) {
                            Text(tick.label)
                        }
                    }
                }
            }
            .chartYAxis { weekdayAxis() }
            .chartLegend(.hidden)
            .frame(height: 170)

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
        if analytics.heatmap.isEmpty {
            ContentUnavailableView("Sem uso no período", systemImage: "calendar")
                .frame(height: 220)
        } else {
            Chart {
                heatMarks(analytics.heatmap.map {
                    HeatRect(id: $0.id, column: Double($0.column), row: Double(6 - $0.row), value: metric.value($0.totals))
                }, metric: metric)
            }
            .chartForegroundStyleScale(range: heatGradient)
            .chartXScale(domain: 0...24)
            .chartYScale(domain: 0...7)
            .chartXAxis {
                AxisMarks(values: stride(from: 0.0, through: 21, by: 3).map { $0 + 0.43 }) { value in
                    AxisValueLabel {
                        if let x = value.as(Double.self) { Text("\(Int(x.rounded(.down)))h") }
                    }
                }
            }
            .chartYAxis { weekdayAxis() }
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
