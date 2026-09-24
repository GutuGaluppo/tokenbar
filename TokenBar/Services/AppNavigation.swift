import Observation

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case overview, models, projects, activity, tips, budgets, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .models: String(localized: "Modelos")
        case .projects: String(localized: "Projetos")
        case .activity: String(localized: "Atividade")
        case .tips: String(localized: "Dicas")
        case .budgets: String(localized: "Orçamentos")
        case .settings: String(localized: "Ajustes")
        }
    }

    /// Seções que usam o seletor de período e métrica da toolbar.
    var usesPeriod: Bool {
        [.overview, .models, .projects, .activity].contains(self)
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.needle"
        case .models: "cpu"
        case .projects: "folder"
        case .activity: "calendar"
        case .tips: "lightbulb"
        case .budgets: "dollarsign.circle"
        case .settings: "gearshape"
        }
    }
}

/// Estado compartilhado entre o popover e a janela, para o popover abrir o painel já na seção certa.
@MainActor
@Observable
final class AppNavigation {
    var section: SidebarSection = .overview
}
