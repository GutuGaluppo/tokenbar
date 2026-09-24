import SwiftUI

/// Seção "Dicas": recomendações ordenadas pela economia estimada.
struct TipsView: View {
    @Environment(TipsStore.self) private var tipsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if tipsStore.tips.isEmpty {
                    ContentUnavailableView(
                        "Nenhuma dica agora",
                        systemImage: "checkmark.seal",
                        description: Text("Seu uso dos últimos \(TipsEngine.windowDays) dias não mostrou nenhum padrão com economia relevante.")
                    )
                } else {
                    ForEach(tipsStore.tips) { tip in
                        TipCard(tip: tip)
                    }
                }

                if !tipsStore.realized.isEmpty {
                    Text("Aplicadas")
                        .font(.title3.weight(.semibold))
                        .padding(.top, 8)
                    ForEach(tipsStore.realized) { item in
                        AppliedTipCard(item: item)
                    }
                }

                if !tipsStore.dismissed.isEmpty {
                    DisclosureGroup("Ignoradas (\(tipsStore.dismissed.count))") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(tipsStore.dismissed) { tip in
                                HStack {
                                    Text(tip.title)
                                    Spacer()
                                    Button("Restaurar") { tipsStore.restore(tip) }
                                }
                                .font(.callout)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        let total = tipsStore.tips.compactMap(\.monthlySavingsUSD).reduce(0, +)
        return VStack(alignment: .leading, spacing: 4) {
            if total > 0 {
                Text("Economia possível: \(TokenFormat.usd(total))/mês")
                    .font(.title2.weight(.semibold))
            }
            if tipsStore.realizedTotal > 0 {
                Label("Economia realizada até agora: \(TokenFormat.usd(tipsStore.realizedTotal))", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
            }
            Text("Estimativas a partir dos últimos \(TipsEngine.windowDays) dias, projetadas para 30, a preços de API.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct TipCard: View {
    @Environment(TipsStore.self) private var tipsStore
    let tip: Tip
    var compact = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: tip.kind == .warning ? "exclamationmark.triangle.fill" : "lightbulb.fill")
                    .foregroundStyle(tip.kind == .warning ? .orange : .yellow)
                Text(tip.title)
                    .font(compact ? .callout.weight(.semibold) : .headline)
                Spacer()
                if let savings = tip.savingsText {
                    Text(savings)
                        .font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
                        .foregroundStyle(.green)
                        .monospacedDigit()
                }
            }

            Text(tip.evidence)
                .font(compact ? .caption : .callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(compact ? 3 : nil)

            if !compact {
                DisclosureGroup("Como aplicar", isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(tip.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                                Text(step).textSelection(.enabled)
                            }
                        }
                    }
                    .font(.callout)
                    .padding(.top, 4)
                }

                HStack {
                    if TipsEngine.measurableTipIDs.contains(tip.id) {
                        Button("Apliquei", systemImage: "checkmark.circle") { tipsStore.markApplied(tip) }
                            .help("Marca a dica como aplicada e passa a medir a economia real a partir de hoje")
                    }
                    Spacer()
                    Button("Ignorar por 30 dias") { tipsStore.dismiss(tip) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(compact ? 0 : 14)
        .background(compact ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary.opacity(0.5)), in: .rect(cornerRadius: 12))
    }
}

/// Uma dica aplicada e o resultado medido desde a aplicação.
struct AppliedTipCard: View {
    @Environment(TipsStore.self) private var tipsStore
    let item: RealizedSaving

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(item.tip.title)
                    .font(.headline)
                Spacer()
                if case .saved(let total, _, _) = item.status {
                    Text(TokenFormat.usd(total))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.green)
                        .monospacedDigit()
                }
            }
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Aplicada em \(item.tip.appliedAt.formatted(date: .abbreviated, time: .omitted))")
                Spacer()
                Button("Desfazer") { tipsStore.undoApplied(item.tip) }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }

    private var icon: String {
        switch item.status {
        case .saved: "checkmark.seal.fill"
        case .noSavings: "exclamationmark.circle"
        default: "hourglass"
        }
    }

    private var color: Color {
        switch item.status {
        case .saved: .green
        case .noSavings: .orange
        default: .secondary
        }
    }

    private var detail: String {
        let percent = FloatingPointFormatStyle<Double>.Percent.percent.precision(.fractionLength(0))
        switch item.status {
        case .measuring(let until):
            return "Medindo… o primeiro resultado sai \(until.formatted(.relative(presentation: .named)))."
        case .insufficientData:
            return "Ainda sem uso suficiente para comparar com os 14 dias anteriores à aplicação."
        case .saved(_, let monthly, let reduction):
            return "O desperdício que esta dica ataca caiu \(reduction.formatted(percent)) por unidade de uso. Projeção: \(TokenFormat.usd(monthly))/mês."
        case .noSavings(let change):
            return change > 0.005
                ? "Sem economia até agora: o desperdício por unidade de uso subiu \(change.formatted(percent)) em relação aos 14 dias anteriores."
                : "Sem mudança até agora em relação aos 14 dias anteriores."
        case .notMeasurable:
            return "Esta dica não tem uma medida de economia."
        }
    }
}
