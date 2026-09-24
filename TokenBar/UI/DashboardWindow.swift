import SwiftUI

/// Janela principal. Fechá-la não encerra o app: ele continua na barra de menus.
struct DashboardWindow: View {
    @Environment(AppNavigation.self) private var navigation
    @Environment(AnalyticsStore.self) private var analytics
    @AppStorage(PreferenceKey.showDockIconWhenWindowOpen) private var showDockIcon = false

    var body: some View {
        @Bindable var navigation = navigation

        NavigationSplitView {
            List(SidebarSection.allCases, selection: $navigation.section) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            detail(for: navigation.section)
                .navigationTitle(navigation.section.title)
                .toolbar {
                    if navigation.section.usesPeriod {
                        PeriodToolbar(analytics: analytics)
                    }
                }
        }
        .onAppear {
            analytics.isActive = true
            NSApp.bringToFront(showInDock: showDockIcon)
        }
        .onDisappear {
            // Janela fechada: para de recalcular agregações que ninguém está vendo.
            analytics.isActive = false
            // Janela fechada: volta a ser só um ícone na barra de menus.
            NSApp.setActivationPolicy(.accessory)
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: DemoMode.showSectionNotification)) { note in
            // Modo de demonstração: troca de seção para capturas de tela.
            guard DemoMode.isEnabled, let raw = note.object as? String else { return }
            NSApp.activate()
            let target = raw == "popover" ? DemoMode.popoverWindowID : WindowID.dashboard
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(target) == true }?.makeKeyAndOrderFront(nil)
            if let section = SidebarSection(rawValue: raw) { navigation.section = section }
        }
        .onChange(of: showDockIcon) { _, show in
            NSApp.setActivationPolicy(show ? .regular : .accessory)
        }
    }

    @ViewBuilder
    private func detail(for section: SidebarSection) -> some View {
        switch section {
        case .overview:
            OverviewView()
        case .settings:
            SettingsView()
        case .models:
            ModelsView()
        case .projects:
            ProjectsView()
        case .activity:
            ActivityView()
        case .tips:
            TipsView()
        case .budgets:
            BudgetsView()
        }
    }
}
