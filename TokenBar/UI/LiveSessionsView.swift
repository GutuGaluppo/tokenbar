import SwiftUI

/// Cartão "Agora" do popover: as sessões ativas do Claude Code e o que fazer em cada uma.
struct LiveSessionsCard: View {
    @Environment(LiveSessionsStore.self) private var live
    /// No popover cabem poucas sessões; o resto fica na seção Dicas.
    var limit = 2

    var body: some View {
        if !live.sessions.isEmpty {
            Card(title: "Agora") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(live.sessions.prefix(limit)) { session in
                        LiveSessionView(session: session, compact: true)
                        if session.id != live.sessions.prefix(limit).last?.id { Divider() }
                    }
                }
            }
        }
    }
}

/// Uma sessão ativa: tamanho do contexto, custo da próxima chamada, estado do cache e dicas.
struct LiveSessionView: View {
    @Environment(LiveSessionsStore.self) private var live
    let session: LiveSession
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            contextGauge
            costLine
            ForEach(compact ? Array(session.tips.prefix(1)) : session.tips) { tip in
                LiveTipRow(tip: tip, compact: compact) { live.dismiss(tip, in: session) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(session.project ?? String(localized: "Sessão"))
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text(session.model)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(TokenFormat.usd(session.costUSD))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Custo da sessão até agora, com subagentes, a preços de API")
        }
    }

    private var contextGauge: some View {
        VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: session.contextFraction)
                .tint(tint)
            Text("\(TokenFormat.compact(session.context)) de \(TokenFormat.compact(session.contextWindow)) tokens de contexto")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .help("Tamanho da conversa na última chamada ao modelo. A janela é estimada quando o modelo não a informa na tabela de preços.")
    }

    /// Relê o relógio para o cache "expirar" na tela mesmo sem chamadas novas.
    private var costLine: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            costText(expired: session.cacheExpiresAt <= context.date)
        }
    }

    private func costText(expired: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: expired ? "snowflake" : "flame")
                .foregroundStyle(expired ? .blue : .orange)
            if expired {
                Text("Cache expirado")
                if let cold = session.coldCallCostUSD {
                    Text("· próxima chamada ≈ \(TokenFormat.usd(cold))")
                }
            } else {
                if let warm = session.warmCallCostUSD {
                    Text("≈ \(TokenFormat.usd(warm)) por chamada")
                }
                Text("· cache até \(session.cacheExpiresAt.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .help("Estimativa a preços de API: contexto lido do cache (quente) ou regravado nele (frio), mais a saída média das últimas chamadas.")
    }

    private var tint: Color {
        switch session.topSeverity {
        case .urgent: .red
        case .attention: .orange
        default: .green
        }
    }
}

struct LiveTipRow: View {
    @Environment(LiveSessionsStore.self) private var live
    let tip: LiveTip
    var compact = false
    let onDismiss: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(tip.title)
                    .font(.callout.weight(.semibold))
                Text(tip.detail)
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let command = tip.command {
                    Button(copied ? "Copiado" : "Copiar \(Self.commandName(command))",
                           systemImage: copied ? "checkmark" : "doc.on.doc") {
                        live.copy(command)
                        copied = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(command)
                }
            }
            Spacer(minLength: 0)
            Button("Ignorar", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help("Ignorar nesta sessão")
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    /// Só o comando, sem as instruções (ex.: "/compact").
    private static func commandName(_ command: String) -> String {
        String(command.split(separator: " ").first ?? Substring(command))
    }

    private var icon: String {
        switch tip.severity {
        case .urgent: "exclamationmark.triangle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var color: Color {
        switch tip.severity {
        case .urgent: .red
        case .attention: .orange
        case .info: .blue
        }
    }
}
