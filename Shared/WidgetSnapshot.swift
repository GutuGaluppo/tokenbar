import Foundation

/// O que o app publica para o widget, num JSON dentro do App Group compartilhado.
struct WidgetSnapshot: Codable, Equatable {
    struct Limit: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        /// Fração usada (0–1+).
        let fraction: Double
        let resetsAt: Date?

        var remaining: Double { max(1 - fraction, 0) }
    }

    var updatedAt: Date
    var todayTokens: Int
    var todayCostUSD: Double
    /// O primeiro é o destaque (sessão do plano Claude, quando disponível).
    var limits: [Limit]
    /// Idioma em uso no app, para o widget (outro processo) mostrar os textos no mesmo idioma.
    var language: String? = nil

    /// Vem do Info.plist (APP_GROUP_ID em Config/Base.xcconfig), igual no app e no widget.
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "TokenBarAppGroup") as? String ?? ""
    static let widgetKind = "TokenBarUsage"

    static var fileURL: URL? {
        guard !appGroup.isEmpty else { return nil }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "widget-snapshot.json")
    }

    static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() throws {
        guard let url = Self.fileURL else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// Conteúdo de exemplo para a galeria de widgets.
    static let placeholder = WidgetSnapshot(
        updatedAt: .now,
        todayTokens: 1_240_000,
        todayCostUSD: 18.4,
        limits: [
            Limit(id: "planSession", title: String(localized: "Sessão Claude"), fraction: 0.25, resetsAt: .now.addingTimeInterval(2 * 3600)),
            Limit(id: "planWeek", title: String(localized: "Semana Claude"), fraction: 0.68, resetsAt: .now.addingTimeInterval(3 * 86_400)),
            Limit(id: "codexSession", title: String(localized: "Codex 5 h"), fraction: 0.17, resetsAt: .now.addingTimeInterval(4 * 3600)),
        ]
    )
}
