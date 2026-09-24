import SwiftUI

/// Linha compacta de status de uma API remota (popover).
struct RemoteSourceStatusRow: View {
    @Environment(RemoteSourcesManager.self) private var manager
    let kind: RemoteProviderKind

    var body: some View {
        let state = manager.state(kind)
        HStack(spacing: 8) {
            Circle()
                .fill(color(state.phase))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.displayName)
                Text(detail(state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if state.phase == .syncing {
                ProgressView().controlSize(.small)
            }
        }
        .font(.callout)
    }

    private func color(_ phase: RemoteSourcesManager.Phase) -> Color {
        switch phase {
        case .notConfigured: .gray
        case .syncing: .blue
        case .ok: .green
        case .failed: .red
        }
    }

    private func detail(_ state: RemoteSourcesManager.SourceState) -> String {
        switch state.phase {
        case .notConfigured: return String(localized: "Não conectada")
        case .syncing: return String(localized: "Sincronizando…")
        case .failed(let message): return String(localized: "Erro: \(message)")
        case .ok:
            let items = String(localized: "\(state.eventCount.formatted()) registros")
            guard let lastSync = state.lastSync else { return items }
            return items + " · " + lastSync.formatted(.relative(presentation: .named))
        }
    }
}

/// Configuração de uma API remota em Ajustes: status, campo da chave, conectar/desconectar.
struct RemoteSourceSettings: View {
    @Environment(RemoteSourcesManager.self) private var manager
    let kind: RemoteProviderKind
    @State private var key = ""
    @State private var connecting = false

    var body: some View {
        let state = manager.state(kind)
        VStack(alignment: .leading, spacing: 8) {
            RemoteSourceStatusRow(kind: kind)
            if state.hasKey {
                HStack {
                    Button(isFailed(state) ? String(localized: "Tentar de novo") : String(localized: "Sincronizar agora")) {
                        Task { await manager.sync(kind) }
                    }
                    Button("Desconectar", role: .destructive) { manager.disconnect(kind) }
                }
                .disabled(state.phase == .syncing)
            } else {
                HStack {
                    SecureField(kind.keyPlaceholder, text: $key)
                        .textFieldStyle(.roundedBorder)
                    Button("Conectar") {
                        connecting = true
                        Task {
                            if await manager.connect(kind, apiKey: key) { key = "" }
                            connecting = false
                        }
                    }
                    .disabled(key.isEmpty || connecting)
                }
                Text(kind.keyHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func isFailed(_ state: RemoteSourcesManager.SourceState) -> Bool {
        if case .failed = state.phase { return true }
        return false
    }
}
