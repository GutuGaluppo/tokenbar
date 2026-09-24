import SwiftUI

/// Overview da janela principal: hoje + limites + o período selecionado na toolbar.
struct OverviewView: View {
    @Environment(UsageStore.self) private var store
    @Environment(AnalyticsStore.self) private var analytics

    var body: some View {
        let metric = analytics.metric
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TodayHeader(large: true)

                if !store.limits.isEmpty {
                    Card(title: "Limites") { LimitsList() }
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("Período").font(.title3.weight(.semibold))
                    PeriodCaption()
                }
                .padding(.top, 4)

                Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                    GridRow {
                        Card(title: "Custo (equiv. API)") { stat(TokenFormat.usd(analytics.totals.costUSD)) }
                        Card(title: "Tokens (sem leitura de cache)") {
                            stat(TokenFormat.compact(analytics.totals.input + analytics.totals.output + analytics.totals.cacheWrite))
                        }
                        Card(title: "Leitura de cache") { stat(TokenFormat.compact(analytics.totals.cacheRead)) }
                        Card(title: "Respostas") { stat(analytics.responses.formatted()) }
                    }
                }

                Card(verbatimTitle: analytics.hourly ? String(localized: "\(metric.shortTitle) por hora")
                                                     : String(localized: "\(metric.shortTitle) por dia")) {
                    PeriodSeriesChart()
                }

                Card(title: "Modelos") {
                    if analytics.byModel.isEmpty {
                        Text("Sem uso no período").foregroundStyle(.secondary)
                    } else {
                        RankingChart(rows: analytics.byModel, limit: 5)
                    }
                }
            }
            .padding(20)
        }
    }

    private func stat(_ text: String) -> some View {
        Text(text)
            .font(.title2.weight(.semibold))
            .monospacedDigit()
            .contentTransition(.numericText())
    }
}
