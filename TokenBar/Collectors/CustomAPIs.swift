import Foundation
import Observation
import Security
import os

/// Preço de uma API personalizada, em US$ por milhão de tokens (opcional).
struct CustomPricing: Codable, Equatable, Sendable {
    var input: Double
    var output: Double
    /// Entrada lida do cache; sem valor, conta como entrada comum.
    var cachedInput: Double?

    func cost(_ tokens: TokenCounts) -> Double {
        (Double(tokens.input) * input
            + Double(tokens.output) * output
            + Double(tokens.cacheRead) * (cachedInput ?? input)) / 1_000_000
    }
}

/// Uma API compatível com o formato da OpenAI (Kimi, DeepSeek, Groq…), medida pelo proxy local.
struct CustomAPI: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// Caminho no proxy: `http://127.0.0.1:<porta>/<slug>`.
    var slug: String
    /// Endereço base da API, como no SDK (ex.: `https://api.moonshot.ai/v1`).
    var baseURL: URL
    var pricing: CustomPricing?
    /// Modelos que a chave enxerga, lidos na autorização.
    var models: [String]
    var addedAt: Date

    var keychainAccount: String { "custom-api-\(id.uuidString)" }
    var tool: String { "\(name) (proxy)" }
}

/// Provedores comuns no formato da OpenAI, para preencher o endereço base.
struct CustomAPIPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String?

    static let custom = CustomAPIPreset(id: "custom", name: String(localized: "Outra (personalizada)"), baseURL: nil)

    static let all: [CustomAPIPreset] = [
        .init(id: "kimi", name: "Kimi (Moonshot)", baseURL: "https://api.moonshot.ai/v1"),
        .init(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1"),
        .init(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1"),
        .init(id: "mistral", name: "Mistral", baseURL: "https://api.mistral.ai/v1"),
        .init(id: "xai", name: "xAI (Grok)", baseURL: "https://api.x.ai/v1"),
        .init(id: "together", name: "Together AI", baseURL: "https://api.together.xyz/v1"),
        .init(id: "fireworks", name: "Fireworks AI", baseURL: "https://api.fireworks.ai/inference/v1"),
        custom,
    ]
}

enum CustomAPIError: LocalizedError, Equatable {
    case invalidURL
    case unauthorized
    case noModelsEndpoint
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            String(localized: "Endereço inválido. Use https:// (ou http:// só para este Mac), como no SDK: https://api.exemplo.com/v1")
        case .unauthorized:
            String(localized: "O provedor recusou a chave.")
        case .noModelsEndpoint:
            String(localized: "O endereço não respondeu a /models. Confira o endereço base (geralmente termina em /v1).")
        case .http(let status):
            String(localized: "O provedor respondeu HTTP \(status).")
        }
    }
}

/// Validação de uma API: a chave precisa listar os modelos em `GET <base>/models`.
enum CustomAPIValidator {
    private struct ModelList: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    /// Normaliza o endereço base: https (ou http local), sem barra no fim.
    static func normalizedBaseURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let host = url.host(), !host.isEmpty else { return nil }
        let local = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard url.scheme == "https" || (url.scheme == "http" && local) else { return nil }
        return url
    }

    static func models(baseURL: URL, apiKey: String, session: URLSession = .shared) async throws -> [String] {
        var request = URLRequest(url: baseURL.appending(path: "models"), timeoutInterval: 20)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("TokenBar/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300:
            let list = try? JSONDecoder().decode(ModelList.self, from: data)
            return (list?.data.map(\.id) ?? []).sorted()
        case 401, 403:
            throw CustomAPIError.unauthorized
        case 404, 405:
            throw CustomAPIError.noModelsEndpoint
        case let status:
            throw CustomAPIError.http(status)
        }
    }

    /// Caminho no proxy a partir do nome: minúsculas, sem acento, sem colidir com rotas existentes.
    static func slug(for name: String, taken: Set<String>) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let words = folded.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        let base = words.isEmpty ? "api" : words.joined(separator: "-")
        let reserved: Set<String> = ["gemini", "api", "v1", "v1beta"]
        var candidate = base
        var suffix = 2
        while reserved.contains(candidate) || taken.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}

/// As APIs personalizadas do usuário. A lista fica em UserDefaults; as chaves, no Keychain.
@MainActor
@Observable
final class CustomAPIStore {
    private(set) var apis: [CustomAPI] = []
    /// Token que o app do usuário usa como "API key" para o proxy trocar pela chave guardada.
    private(set) var localToken = ""
    /// Chamado quando a lista muda (o proxy recria as rotas).
    @ObservationIgnored var onChange: (() -> Void)?

    private static let listKey = "customAPIs"
    private static let tokenAccount = "proxy-local-token"
    private static let log = Logger(subsystem: "dev.galuppo.TokenBar", category: "CustomAPIs")

    init() {
        guard !AppEnvironment.isIsolated else { return }
        if let data = UserDefaults.standard.data(forKey: Self.listKey),
           let saved = try? JSONDecoder().decode([CustomAPI].self, from: data) {
            apis = saved
        }
        localToken = KeychainStore.read(Self.tokenAccount) ?? ""
    }

    /// Valida a chave e, se funcionar, adiciona a API à lista e guarda a chave no Keychain.
    func add(name: String, baseURL text: String, apiKey: String, pricing: CustomPricing?, slugHint: String?) async throws -> CustomAPI {
        guard let baseURL = CustomAPIValidator.normalizedBaseURL(text) else { throw CustomAPIError.invalidURL }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let models = try await CustomAPIValidator.models(baseURL: baseURL, apiKey: key)

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? (baseURL.host() ?? "API") : trimmedName
        let slug = CustomAPIValidator.slug(for: slugHint ?? displayName, taken: Set(apis.map(\.slug)))
        let api = CustomAPI(id: UUID(), name: displayName, slug: slug, baseURL: baseURL,
                            pricing: pricing, models: models, addedAt: .now)
        try KeychainStore.save(key, for: api.keychainAccount)
        try ensureLocalToken()
        apis.append(api)
        save()
        return api
    }

    func remove(_ api: CustomAPI) {
        KeychainStore.delete(api.keychainAccount)
        apis.removeAll { $0.id == api.id }
        save()
    }

    /// Rotas do proxy para as APIs cadastradas, com a chave de cada uma.
    func routes() -> [ProxyServer.Route] {
        apis.compactMap { api in
            guard let key = KeychainStore.read(api.keychainAccount) else { return nil }
            return ProxyServer.Route(prefix: "/\(api.slug)", upstream: api.baseURL, provider: .other, tool: api.tool,
                                     credential: .init(apiKey: key, localToken: localToken), pricing: api.pricing)
        }
    }

    private func ensureLocalToken() throws {
        guard localToken.isEmpty else { return }
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return }
        let token = "tb-local-" + bytes.map { String(format: "%02x", $0) }.joined()
        try KeychainStore.save(token, for: Self.tokenAccount)
        localToken = token
    }

    private func save() {
        guard !AppEnvironment.isIsolated, let data = try? JSONEncoder().encode(apis) else { return }
        UserDefaults.standard.set(data, forKey: Self.listKey)
        onChange?()
    }
}
