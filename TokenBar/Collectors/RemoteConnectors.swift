import Foundation

/// Provedores remotos consultados por API de uso da organização (chave de admin).
enum RemoteProviderKind: String, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openai
    case openrouter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: "API Anthropic"
        case .openai: "API OpenAI"
        case .openrouter: "OpenRouter"
        }
    }

    var provider: Provider {
        switch self {
        case .anthropic: .anthropic
        case .openai: .openai
        case .openrouter: .openrouter
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-admin01-…"
        case .openai: "sk-admin-…"
        case .openrouter: "sk-or-v1-…"
        }
    }

    var keyHelp: String {
        switch self {
        case .anthropic:
            String(localized: "Chave de Admin API (Console → Settings → Admin keys). Contas individuais não têm Admin API.")
        case .openai:
            String(localized: "Admin key da organização (Settings → Organization → Admin keys).")
        case .openrouter:
            String(localized: "Management key (Settings → Management Keys). O dia atual aparece depois que o dia UTC fecha.")
        }
    }

    /// Prefixo do `externalID` dos eventos desta fonte.
    var externalIDPrefix: String {
        switch self {
        case .anthropic: "ant:"
        case .openai: "oai:"
        case .openrouter: "or:"
        }
    }

    var keychainAccount: String { "\(rawValue)-admin-key" }

    func makeConnector(prices: PriceTable) -> any UsageConnector {
        switch self {
        case .anthropic: AnthropicUsageConnector(prices: prices)
        case .openai: OpenAIUsageConnector()
        case .openrouter: OpenRouterUsageConnector()
        }
    }
}

protocol UsageConnector: Sendable {
    func fetch(from start: Date, to end: Date, apiKey: String) async throws -> [ParsedUsage]
}

enum ConnectorError: LocalizedError {
    case unauthorized
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            String(localized: "Chave inválida ou sem permissão de admin.")
        case .http(let status, let body):
            "HTTP \(status): \(body.prefix(160))"
        }
    }
}

private enum HTTP {
    static let userAgent = "TokenBar/0.1 (macOS)"

    static func get<T: Decodable>(_ url: URL, headers: [String: String], as type: T.Type) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            return try JSONDecoder().decode(T.self, from: data)
        case 401, 403:
            throw ConnectorError.unauthorized
        default:
            throw ConnectorError.http(status, String(decoding: data, as: UTF8.self))
        }
    }
}

// MARK: - Anthropic

/// `GET /v1/organizations/usage_report/messages`, por hora, agrupado por modelo e tier.
/// O custo é calculado pela tabela de preços (tier batch com 50% de desconto).
struct AnthropicUsageConnector: UsageConnector {
    let prices: PriceTable

    private struct Report: Decodable {
        let data: [Bucket]
        let has_more: Bool
        let next_page: String?
    }

    private struct Bucket: Decodable {
        let starting_at: String
        let results: [Result]
    }

    private struct Result: Decodable {
        let model: String?
        let service_tier: String?
        let uncached_input_tokens: Int?
        let output_tokens: Int?
        let cache_read_input_tokens: Int?
        let cache_creation: CacheCreation?
    }

    private struct CacheCreation: Decodable {
        let ephemeral_1h_input_tokens: Int?
        let ephemeral_5m_input_tokens: Int?
    }

    func fetch(from start: Date, to end: Date, apiKey: String) async throws -> [ParsedUsage] {
        let iso = Date.ISO8601FormatStyle()
        var events: [ParsedUsage] = []
        var page: String?
        repeat {
            var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/usage_report/messages")!
            components.queryItems = [
                URLQueryItem(name: "starting_at", value: start.formatted(iso)),
                URLQueryItem(name: "ending_at", value: end.formatted(iso)),
                URLQueryItem(name: "bucket_width", value: "1h"),
                URLQueryItem(name: "group_by[]", value: "model"),
                URLQueryItem(name: "group_by[]", value: "service_tier"),
                URLQueryItem(name: "limit", value: "168"),
            ] + (page.map { [URLQueryItem(name: "page", value: $0)] } ?? [])

            let report = try await HTTP.get(components.url!, headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
            ], as: Report.self)

            for bucket in report.data {
                guard let timestamp = try? iso.parse(bucket.starting_at) else { continue }
                for result in bucket.results {
                    let model = result.model ?? "desconhecido"
                    let tier = result.service_tier ?? "standard"
                    let tokens = TokenCounts(
                        input: result.uncached_input_tokens ?? 0,
                        output: result.output_tokens ?? 0,
                        cacheWrite5m: result.cache_creation?.ephemeral_5m_input_tokens ?? 0,
                        cacheWrite1h: result.cache_creation?.ephemeral_1h_input_tokens ?? 0,
                        cacheRead: result.cache_read_input_tokens ?? 0
                    )
                    guard tokens.input + tokens.output + tokens.cacheWrite + tokens.cacheRead > 0 else { continue }
                    let tierMultiplier = tier == "batch" ? 0.5 : 1
                    let cost = prices.cost(model: model, tokens: tokens).map { $0 * tierMultiplier }
                    events.append(ParsedUsage(
                        externalID: "ant:u:\(bucket.starting_at):\(model):\(tier)",
                        timestamp: timestamp,
                        provider: .anthropic,
                        model: model,
                        project: nil,
                        tool: tier == "batch" ? "API Anthropic (batch)" : "API Anthropic",
                        session: nil,
                        tokens: tokens,
                        costUSD: cost ?? .nan
                    ))
                }
            }
            page = report.has_more ? report.next_page : nil
        } while page != nil
        return events
    }
}

// MARK: - OpenAI

/// Tokens: `GET /v1/organization/usage/completions` por hora e modelo.
/// Custo: `GET /v1/organization/costs` (oficial, diário, por item de cobrança).
struct OpenAIUsageConnector: UsageConnector {
    private struct Page<Result: Decodable>: Decodable {
        let data: [Bucket<Result>]
        let has_more: Bool
        let next_page: String?
    }

    private struct Bucket<Result: Decodable>: Decodable {
        let start_time: Int
        let end_time: Int
        let result: [Result]
    }

    private struct CompletionsResult: Decodable {
        let model: String?
        let batch: Bool?
        let input_tokens: Int?
        let input_cached_tokens: Int?
        let output_tokens: Int?
        let input_audio_tokens: Int?
        let output_audio_tokens: Int?
    }

    private struct CostsResult: Decodable {
        struct Amount: Decodable {
            let value: Double?
            let currency: String?
        }
        let amount: Amount?
        let line_item: String?
    }

    func fetch(from start: Date, to end: Date, apiKey: String) async throws -> [ParsedUsage] {
        let headers = ["Authorization": "Bearer \(apiKey)"]
        var events: [ParsedUsage] = []

        let usage: [Bucket<CompletionsResult>] = try await pages(
            path: "usage/completions",
            items: [
                URLQueryItem(name: "bucket_width", value: "1h"),
                URLQueryItem(name: "group_by", value: "model"),
                URLQueryItem(name: "group_by", value: "batch"),
                URLQueryItem(name: "limit", value: "168"),
            ],
            start: start, end: end, headers: headers
        )
        for bucket in usage {
            for result in bucket.result {
                let model = result.model ?? "desconhecido"
                let cached = result.input_cached_tokens ?? 0
                let tokens = TokenCounts(
                    input: max((result.input_tokens ?? 0) - cached, 0) + (result.input_audio_tokens ?? 0),
                    output: (result.output_tokens ?? 0) + (result.output_audio_tokens ?? 0),
                    cacheRead: cached
                )
                guard tokens.input + tokens.output + tokens.cacheRead > 0 else { continue }
                let batch = result.batch == true
                events.append(ParsedUsage(
                    externalID: "oai:u:\(bucket.start_time):\(model):\(batch)",
                    timestamp: Date(timeIntervalSince1970: TimeInterval(bucket.start_time)),
                    provider: .openai,
                    model: model,
                    project: nil,
                    tool: batch ? "API OpenAI (batch)" : "API OpenAI",
                    session: nil,
                    tokens: tokens,
                    costUSD: 0   // o custo vem do endpoint de custos, abaixo
                ))
            }
        }

        let costs: [Bucket<CostsResult>] = try await pages(
            path: "costs",
            items: [
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "group_by", value: "line_item"),
                URLQueryItem(name: "limit", value: "31"),
            ],
            start: start, end: end, headers: headers
        )
        for bucket in costs {
            // Buckets diários são em UTC. Posiciona o custo no fim do bucket (ou agora, no dia em curso)
            // para cair no dia local em que a maior parte do gasto aconteceu.
            let timestamp = min(Date(timeIntervalSince1970: TimeInterval(bucket.end_time - 1)), .now)
            for result in bucket.result {
                guard let value = result.amount?.value, value != 0 else { continue }
                let item = result.line_item ?? "OpenAI"
                events.append(ParsedUsage(
                    externalID: "oai:c:\(bucket.start_time):\(item)",
                    timestamp: timestamp,
                    provider: .openai,
                    model: item,
                    project: nil,
                    tool: "API OpenAI",
                    session: nil,
                    tokens: TokenCounts(),
                    costUSD: value
                ))
            }
        }
        return events
    }

    private func pages<Result: Decodable>(
        path: String, items: [URLQueryItem], start: Date, end: Date, headers: [String: String]
    ) async throws -> [Bucket<Result>] {
        var buckets: [Bucket<Result>] = []
        var page: String?
        repeat {
            var components = URLComponents(string: "https://api.openai.com/v1/organization/\(path)")!
            components.queryItems = [
                URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
                URLQueryItem(name: "end_time", value: String(Int(end.timeIntervalSince1970))),
            ] + items + (page.map { [URLQueryItem(name: "page", value: $0)] } ?? [])
            let response = try await HTTP.get(components.url!, headers: headers, as: Page<Result>.self)
            buckets += response.data
            page = response.has_more ? response.next_page : nil
        } while page != nil
        return buckets
    }
}

// MARK: - OpenRouter

/// `GET /api/v1/activity` (Management key): tokens, custo e requisições por dia UTC e modelo, nos
/// últimos 30 dias encerrados. `GET /api/v1/credits`: créditos comprados e usados.
struct OpenRouterUsageConnector: UsageConnector {
    struct Activity: Decodable {
        let data: [Item]
        struct Item: Decodable {
            let date: String
            let model: String
            let endpoint_id: String?
            let provider_name: String?
            let usage: Double?
            let requests: Int?
            let prompt_tokens: Int?
            let completion_tokens: Int?
            let reasoning_tokens: Int?
        }
    }

    struct Credits: Decodable, Equatable {
        struct Data: Decodable, Equatable {
            let total_credits: Double
            let total_usage: Double
        }
        let data: Data
    }

    private static let base = "https://openrouter.ai/api/v1"

    func fetch(from start: Date, to end: Date, apiKey: String) async throws -> [ParsedUsage] {
        let activity = try await HTTPGet.json(URL(string: "\(Self.base)/activity")!, apiKey: apiKey, as: Activity.self)
        return Self.parse(activity).filter { $0.timestamp >= start.addingTimeInterval(-86_400) }
    }

    static func credits(apiKey: String) async throws -> Credits.Data {
        try await HTTPGet.json(URL(string: "\(base)/credits")!, apiKey: apiKey, as: Credits.self).data
    }

    /// Cada linha é um dia UTC encerrado: o evento fica ao meio-dia UTC, para cair no dia local certo.
    static func parse(_ activity: Activity) -> [ParsedUsage] {
        let day = Date.ISO8601FormatStyle().year().month().day()
        return activity.data.compactMap { item in
            guard let date = try? day.parse(item.date) else { return nil }
            let tokens = TokenCounts(input: item.prompt_tokens ?? 0, output: item.completion_tokens ?? 0)
            return ParsedUsage(
                externalID: "or:\(item.date):\(item.endpoint_id ?? item.model)",
                timestamp: date.addingTimeInterval(12 * 3_600),
                provider: .openrouter,
                model: item.model,
                project: nil,
                tool: "OpenRouter",
                session: nil,
                tokens: tokens,
                costUSD: item.usage ?? 0
            )
        }
    }
}

/// GET autenticado com Bearer, compartilhado pelo OpenRouter.
enum HTTPGet {
    static func json<T: Decodable>(_ url: URL, apiKey: String, as type: T.Type) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("TokenBar (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return try JSONDecoder().decode(T.self, from: data)
        case 401, 403: throw ConnectorError.unauthorized
        default: throw ConnectorError.http(status, String(decoding: data, as: UTF8.self))
        }
    }
}
