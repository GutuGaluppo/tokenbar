import Foundation

enum PreferenceKey {
    static let menuBarDisplay = "menuBarDisplay"
    static let showDockIconWhenWindowOpen = "showDockIconWhenWindowOpen"
}

enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case iconOnly, tokensToday, costToday
    case nearestLimit       // % restante (mantém o rawValue antigo para quem já tinha escolhido)
    case nearestLimitUsed
    case planSessionUsed, planSessionRemaining

    var usesLimit: Bool { self == .nearestLimit || self == .nearestLimitUsed }
    var usesPlan: Bool { self == .planSessionUsed || self == .planSessionRemaining }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iconOnly: String(localized: "Somente ícone")
        case .tokensToday: String(localized: "Tokens de hoje")
        case .costToday: String(localized: "Custo de hoje")
        case .nearestLimit: String(localized: "% restante do limite mais próximo")
        case .nearestLimitUsed: String(localized: "% usado do limite mais próximo")
        case .planSessionUsed: String(localized: "Sessão atual do plano Claude (% usado)")
        case .planSessionRemaining: String(localized: "Sessão atual do plano Claude (% restante)")
        }
    }
}
