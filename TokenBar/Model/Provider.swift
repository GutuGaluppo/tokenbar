import SwiftUI

enum Provider: String, CaseIterable, Identifiable, Codable {
    case anthropic
    case openai
    case google
    case openrouter
    case local
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .google: "Google"
        case .openrouter: "OpenRouter"
        case .local: "Local"
        case .other: String(localized: "Outros")
        }
    }

    /// Cor fixa por provedor, usada em todos os gráficos.
    var tint: Color {
        switch self {
        case .anthropic: .orange
        case .openai: .green
        case .google: .blue
        case .openrouter: .purple
        case .local: .teal
        case .other: .gray
        }
    }
}
