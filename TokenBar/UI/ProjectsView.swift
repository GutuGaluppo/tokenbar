import SwiftUI

/// Consumo por projeto (pasta de trabalho do Claude Code) ou por ferramenta, com o detalhe
/// dos modelos da linha selecionada.
struct ProjectsView: View {
    enum Grouping: String, CaseIterable, Identifiable {
        case project, tool
        var id: String { rawValue }
        var title: String { self == .project ? String(localized: "Projeto") : String(localized: "Ferramenta") }
    }

    @Environment(AnalyticsStore.self) private var analytics
    @State private var grouping: Grouping = .project
    @State private var sortOrder = [KeyPathComparator(\GroupRow.costUSD, order: .reverse)]
    @State private var selection: GroupRow.ID?

    var body: some View {
        let rows = (grouping == .project ? analytics.byProject : analytics.byTool).sorted(using: sortOrder)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Picker("Agrupar por", selection: $grouping) {
                    ForEach(Grouping.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                PeriodCaption()
                Spacer()
            }

            if rows.isEmpty {
                ContentUnavailableView("Sem uso no período", systemImage: "folder")
            } else {
                Card(verbatimTitle: analytics.metric.shortTitle) {
                    RankingChart(rows: rows)
                }
                UsageTable(rows: rows, nameTitle: grouping.title, sortOrder: $sortOrder, selection: $selection)

                if let selection, let models = detail(for: selection) {
                    Card(title: "Modelos em \(selection)") {
                        RankingChart(rows: models, limit: 6)
                    }
                } else {
                    Text("Selecione uma linha para ver os modelos usados nela.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .onChange(of: grouping) { selection = nil }
    }

    private func detail(for key: String) -> [GroupRow]? {
        (grouping == .project ? analytics.modelsByProject : analytics.modelsByTool)[key]
    }
}
