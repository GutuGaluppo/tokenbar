import SwiftUI

/// Popover que abre ao clicar no ícone da barra de menus.
struct OverviewPopover: View {
    @Environment(UsageStore.self) private var store
    @Environment(AppNavigation.self) private var navigation
    @Environment(TipsStore.self) private var tipsStore
    @Environment(ClaudePlanUsage.self) private var planUsage
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PreferenceKey.showDockIconWhenWindowOpen) private var showDockIcon = false
    /// Altura real dos cartões; a área de rolagem só cresce até o que cabe na tela.
    @State private var cardsHeight: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TodayHeader()

            // Cabeçalho e rodapé ficam fixos; só os cartões rolam quando não cabem na tela.
            ScrollView {
                cards
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardsHeight = $0 }
            }
            .frame(height: min(cardsHeight, maxCardsHeight))
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(cardsHeight > maxCardsHeight ? .automatic : .hidden)

            Divider()

            footer
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            store.refresh()
            planUsage.refresh()
        }
    }

    /// Espaço para os cartões: altura útil da tela menos cabeçalho, rodapé e margens.
    private var maxCardsHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(screen - 230, 280)
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card(title: "Limites") {
                if store.limits.isEmpty {
                    HStack {
                        Text("Nenhum limite definido")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Definir") { openDashboard(.budgets) }
                            .controlSize(.small)
                    }
                    .font(.callout)
                } else {
                    LimitsList()
                }
                Last24HoursStrip()
            }

            if let tip = tipsStore.featured {
                Card(title: "Dica do dia") {
                    TipCard(tip: tip, compact: true)
                    if tipsStore.realizedTotal > 0 {
                        Label("Economia realizada: \(TokenFormat.usd(tipsStore.realizedTotal))", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Button("Ver todas as dicas (\(tipsStore.tips.count))") { openDashboard(.tips) }
                        .buttonStyle(.borderless)
                        .font(.callout)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Abrir painel", systemImage: "macwindow") { openDashboard(.overview) }
            Spacer()
            Button("Ajustes", systemImage: "gearshape") { openDashboard(.settings) }
                .labelStyle(.iconOnly)
                .help("Ajustes")
            Button("Encerrar TokenBar", systemImage: "power") { NSApp.terminate(nil) }
                .labelStyle(.iconOnly)
                .keyboardShortcut("q")
                .help("Encerrar TokenBar (⌘Q)")
        }
        .buttonStyle(.borderless)
    }

    private func openDashboard(_ section: SidebarSection) {
        navigation.section = section
        openWindow(id: WindowID.dashboard)
        dismiss()
        NSApp.bringToFront(showInDock: showDockIcon)
    }
}
