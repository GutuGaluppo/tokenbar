import SwiftUI
import Charts

/// Cartão com material translúcido e cantos de 12 pt, base de todo bloco do Overview.
struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }
}

/// Total de hoje + custo + variação contra a média diária dos 7 dias anteriores.
struct TodayHeader: View {
    @Environment(UsageStore.self) private var store
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Hoje")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(TokenFormat.compact(store.today.tokens))
                    .font(large ? .system(size: 44, weight: .semibold, design: .rounded)
                                : .system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("tokens")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(TokenFormat.usd(store.today.costUSD))
                    .monospacedDigit()
                    .help("Custo estimado a preços da API. Em planos de assinatura (Pro/Max) esse valor não é cobrado.")
                Text("equiv. API")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let change = store.changeVersusAverage {
                    Label(
                        change.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always())) + " vs. média 7d",
                        systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right"
                    )
                    .foregroundStyle(change > 0.2 ? .orange : .secondary)
                }
            }
            .font(.callout)
        }
        .animation(.default, value: store.today)
    }
}

/// Barras por hora nas últimas 24 h, empilhadas por provedor.
struct Last24HoursChart: View {
    @Environment(UsageStore.self) private var store
    var height: CGFloat = 90

    var body: some View {
        if store.last24Hours.isEmpty {
            Text("Sem consumo nas últimas 24 h")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: height)
        } else {
            Chart(store.last24Hours) { bucket in
                BarMark(
                    x: .value("Hora", bucket.hour, unit: .hour),
                    y: .value("Tokens", bucket.tokens)
                )
                .foregroundStyle(by: .value("Provedor", bucket.provider.displayName))
                .cornerRadius(2)
            }
            .chartForegroundStyleScale(
                domain: Provider.allCases.map(\.displayName),
                range: Provider.allCases.map(\.tint)
            )
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let tokens = value.as(Int.self) { Text(TokenFormat.compact(tokens)) }
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(height: height)
        }
    }
}

/// Os modelos mais usados hoje.
struct TopModelsList: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        if store.topModelsToday.isEmpty {
            Text("Nenhum modelo usado hoje")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 6) {
                ForEach(store.topModelsToday) { item in
                    HStack {
                        Circle().fill(item.provider.tint).frame(width: 8, height: 8)
                        Text(item.model).lineLimit(1)
                        Spacer()
                        Text(TokenFormat.compact(item.totals.tokens)).monospacedDigit()
                        Text(TokenFormat.usd(item.totals.costUSD))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

/// Linha de status de uma fonte de logs locais (popover e Ajustes).
struct LocalSourceStatusRow: View {
    let source: LocalLogSource

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if case .scanning(let progress) = source.phase {
                ProgressView(value: progress)
                    .frame(width: 60)
                    .controlSize(.small)
            }
        }
        .font(.callout)
    }

    private var dotColor: Color {
        switch source.phase {
        case .idle: .green
        case .scanning: .blue
        case .unavailable: .gray
        case .failed: .red
        }
    }

    private var detail: String {
        switch source.phase {
        case .unavailable:
            return "Não encontrado nesta máquina"
        case .failed(let message):
            return "Erro: \(message)"
        case .scanning(let progress):
            return "Importando histórico… \(progress.formatted(.percent.precision(.fractionLength(0))))"
        case .idle:
            let events = "\(source.eventCount.formatted()) respostas"
            guard let lastScan = source.lastScan else { return events }
            return events + " · " + lastScan.formatted(.relative(presentation: .named))
        }
    }
}
