import Foundation
import SwiftData
import AppKit

/// Exporta o histórico de uso em CSV (vírgula como separador, ponto decimal, datas ISO 8601).
enum CSVExporter {
    enum Range: String, CaseIterable, Identifiable {
        case last30, last90, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .last30: String(localized: "Últimos 30 dias")
            case .last90: String(localized: "Últimos 90 dias")
            case .all: String(localized: "Todo o histórico")
            }
        }
        var start: Date {
            switch self {
            case .last30: .now.addingTimeInterval(-30 * 86_400)
            case .last90: .now.addingTimeInterval(-90 * 86_400)
            case .all: .distantPast
            }
        }
    }

    static var header: [String] {
        [String(localized: "data"), String(localized: "fonte"), String(localized: "provedor"), String(localized: "modelo"),
         String(localized: "projeto"), String(localized: "ferramenta"), String(localized: "sessao"), String(localized: "entrada"),
         String(localized: "saida"), String(localized: "escrita_cache"), String(localized: "leitura_cache"), String(localized: "custo_usd")]
    }

    static func source(for externalID: String) -> String {
        switch externalID.prefix(3) {
        case "cc:": "Claude Code"
        case "cx:": "Codex"
        case "ant": "API Anthropic"
        case "oai": "API OpenAI"
        case "or:": "OpenRouter"
        case "px:": String(localized: "Proxy local")
        default: String(localized: "Outro")
        }
    }

    struct Row {
        let timestamp: Date
        let externalID: String
        let provider: String
        let model: String
        let project: String?
        let tool: String?
        let session: String?
        let input: Int
        let output: Int
        let cacheWrite: Int
        let cacheRead: Int
        let costUSD: Double

        init(_ event: UsageEvent) {
            timestamp = event.timestamp
            externalID = event.externalID
            provider = event.provider.displayName
            model = event.model
            project = event.project
            tool = event.tool
            session = event.session
            input = event.inputTokens
            output = event.outputTokens
            cacheWrite = event.cacheWriteTokens
            cacheRead = event.cacheReadTokens
            costUSD = event.costUSD
        }

        init(timestamp: Date, externalID: String, provider: String, model: String, project: String?, tool: String?,
             session: String?, input: Int, output: Int, cacheWrite: Int, cacheRead: Int, costUSD: Double) {
            self.timestamp = timestamp; self.externalID = externalID; self.provider = provider; self.model = model
            self.project = project; self.tool = tool; self.session = session; self.input = input; self.output = output
            self.cacheWrite = cacheWrite; self.cacheRead = cacheRead; self.costUSD = costUSD
        }
    }

    static func csv(_ rows: [Row]) -> String {
        let iso = Date.ISO8601FormatStyle()
        var lines = [header.joined(separator: ",")]
        for row in rows {
            let fields: [String] = [
                row.timestamp.formatted(iso), source(for: row.externalID), row.provider, row.model,
                row.project ?? "", row.tool ?? "", row.session ?? "",
                String(row.input), String(row.output), String(row.cacheWrite), String(row.cacheRead),
                String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), row.costUSD),
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Aspas quando o campo tem vírgula, aspas ou quebra de linha (RFC 4180).
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Pergunta onde salvar e grava o arquivo. Retorna quantas linhas foram exportadas.
    @MainActor
    static func export(range: Range, container: ModelContainer) throws -> Int? {
        let start = range.start
        let descriptor = FetchDescriptor<UsageEvent>(predicate: #Predicate { $0.timestamp >= start },
                                                     sortBy: [SortDescriptor(\.timestamp)])
        let rows = try container.mainContext.fetch(descriptor).map(Row.init)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "tokenbar-\(Date.now.formatted(.iso8601.year().month().day())).csv"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try csv(rows).write(to: url, atomically: true, encoding: .utf8)
        return rows.count
    }
}
