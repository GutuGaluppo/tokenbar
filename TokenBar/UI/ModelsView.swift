import SwiftUI

/// Tabela ordenável de consumo por modelo no período.
struct ModelsView: View {
    @Environment(AnalyticsStore.self) private var analytics
    @State private var sortOrder = [KeyPathComparator(\GroupRow.costUSD, order: .reverse)]

    var body: some View {
        let rows = analytics.byModel.sorted(using: sortOrder)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(rows.count) modelos").font(.title3.weight(.semibold))
                PeriodCaption()
            }

            if rows.isEmpty {
                ContentUnavailableView("Sem uso no período", systemImage: "cpu")
            } else {
                Card(title: analytics.metric.shortTitle) {
                    RankingChart(rows: rows)
                }
                UsageTable(rows: rows, nameTitle: "Modelo", sortOrder: $sortOrder)
            }
        }
        .padding(20)
    }
}

/// Tabela compartilhada por Modelos e Projetos.
struct UsageTable: View {
    @Environment(AnalyticsStore.self) private var analytics
    let rows: [GroupRow]
    let nameTitle: String
    @Binding var sortOrder: [KeyPathComparator<GroupRow>]
    var selection: Binding<GroupRow.ID?>? = nil
    var showsProvider = true

    var body: some View {
        let total = analytics.totals
        let metric = analytics.metric
        Table(rows, selection: selection ?? .constant(nil), sortOrder: $sortOrder) {
            TableColumn(nameTitle, value: \.label) { row in
                HStack(spacing: 6) {
                    Circle().fill(row.provider?.tint ?? .accentColor).frame(width: 8, height: 8)
                    Text(row.label).lineLimit(1)
                }
            }
            .width(min: 160, ideal: 220)
            TableColumn("Provedor", value: \.providerName)
                .width(ideal: 90)
            TableColumn("Entrada", value: \.input) { Text(TokenFormat.compact($0.input)).monospacedDigit() }
                .width(ideal: 70)
            TableColumn("Saída", value: \.output) { Text(TokenFormat.compact($0.output)).monospacedDigit() }
                .width(ideal: 70)
            TableColumn("Escrita cache", value: \.cacheWrite) { Text(TokenFormat.compact($0.cacheWrite)).monospacedDigit() }
                .width(ideal: 90)
            TableColumn("Leitura cache", value: \.cacheRead) { Text(TokenFormat.compact($0.cacheRead)).monospacedDigit() }
                .width(ideal: 90)
            TableColumn("Respostas", value: \.responses) { Text($0.responses.formatted()).monospacedDigit() }
                .width(ideal: 80)
            TableColumn("Custo", value: \.costUSD) { Text(TokenFormat.usd($0.costUSD)).monospacedDigit() }
                .width(ideal: 80)
            TableColumn("% \(metric.shortTitle.lowercased())") { row in
                Text(share(row, of: total, metric: metric)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(ideal: 80)
            TableColumn("Último uso", value: \.lastUsed) { row in
                Text(row.lastUsed.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)
            }
            .width(ideal: 110)
        }
        .frame(minHeight: 220)
    }
}
