import Foundation
import Network
import Testing
@testable import TokenBar

@Suite("APIs personalizadas")
struct CustomAPITests {
    @Test("Nome vira caminho do proxy sem acento e sem colidir com rotas existentes")
    func slug() {
        #expect(CustomAPIValidator.slug(for: "Kimi (Moonshot)", taken: []) == "kimi-moonshot")
        #expect(CustomAPIValidator.slug(for: "kimi", taken: ["kimi"]) == "kimi-2")
        #expect(CustomAPIValidator.slug(for: "Gemini", taken: []) == "gemini-2")
        #expect(CustomAPIValidator.slug(for: "Visão Ótica", taken: []) == "visao-otica")
        #expect(CustomAPIValidator.slug(for: "🙂", taken: []) == "api-2")
    }

    @Test("Endereço base: https, ou http só local; sem barra no fim")
    func baseURL() {
        #expect(CustomAPIValidator.normalizedBaseURL(" https://api.moonshot.ai/v1/ ")?.absoluteString == "https://api.moonshot.ai/v1")
        #expect(CustomAPIValidator.normalizedBaseURL("http://127.0.0.1:8080/v1") != nil)
        #expect(CustomAPIValidator.normalizedBaseURL("http://api.example.com/v1") == nil)
        #expect(CustomAPIValidator.normalizedBaseURL("api.example.com") == nil)
    }

    @Test("Preço opcional: vírgula ou ponto; entrada e saída obrigatórias")
    func pricing() throws {
        let pricing = try #require(CustomAPISettings.pricing(input: "0,60", output: "2.50", cached: ""))
        #expect(pricing == CustomPricing(input: 0.6, output: 2.5, cachedInput: nil))
        #expect(CustomAPISettings.pricing(input: "1", output: "", cached: "") == nil)
        let cost = CustomPricing(input: 1, output: 4, cachedInput: 0.1).cost(TokenCounts(input: 1_000_000, output: 500_000, cacheRead: 1_000_000))
        #expect(abs(cost - 3.1) < 1e-9)
    }

    @Test("Rota casa só no segmento inteiro")
    func routeMatching() {
        let route = ProxyServer.Route(prefix: "/kimi", upstream: URL(string: "https://x")!, provider: .other, tool: "t")
        #expect(route.matches("/kimi/chat/completions"))
        #expect(route.matches("/kimi"))
        #expect(!route.matches("/kimiko/chat"))
    }
}

/// Servidor falso no formato da OpenAI: devolve o Authorization recebido no campo `model` e
/// responde 401 para a chave "ruim" e 404 fora de /v1.
private final class EchoUpstream: @unchecked Sendable {
    let listener: NWListener

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let auth = request.split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("authorization:") }
                    .map { $0.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces) } ?? "none"
                let (status, body): (String, String) =
                    !request.contains(" /v1/") ? ("404 Not Found", "{}")
                    : auth == "Bearer ruim" ? ("401 Unauthorized", "{}")
                    : request.contains("/models") ? ("200 OK", #"{"data":[{"id":"kimi-k2"},{"id":"moonshot-v1-8k"}]}"#)
                    : ("200 OK", #"{"model":"\#(auth)","usage":{"prompt_tokens":1000000,"completion_tokens":500000}}"#)
                let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    func start() async throws -> UInt16 {
        listener.start(queue: .global())
        for _ in 0..<100 {
            if listener.state == .ready, let port = listener.port { return port.rawValue }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.cannotConnectToHost)
    }
}

private actor Collected {
    var items: [ProxyServer.Recorded] = []
    func add(_ item: ProxyServer.Recorded) { items.append(item) }
    func wait(for count: Int) async -> [ProxyServer.Recorded] {
        for _ in 0..<100 where items.count < count { try? await Task.sleep(for: .milliseconds(50)) }
        return items
    }
}

@Suite("Proxy com APIs personalizadas", .serialized)
struct CustomAPIProxyTests {
    @Test("Autorização lista os modelos e reconhece chave recusada e endereço errado")
    func validation() async throws {
        let upstream = try EchoUpstream()
        let port = try await upstream.start()
        defer { upstream.listener.cancel() }
        let base = try #require(URL(string: "http://127.0.0.1:\(port)/v1"))

        #expect(try await CustomAPIValidator.models(baseURL: base, apiKey: "boa") == ["kimi-k2", "moonshot-v1-8k"])
        await #expect(throws: CustomAPIError.unauthorized) {
            try await CustomAPIValidator.models(baseURL: base, apiKey: "ruim")
        }
        await #expect(throws: CustomAPIError.noModelsEndpoint) {
            try await CustomAPIValidator.models(baseURL: URL(string: "http://127.0.0.1:\(port)")!, apiKey: "boa")
        }
    }

    @Test("Troca o token local pela chave guardada, deixa passar a chave do cliente e recusa navegador")
    func credential() async throws {
        let upstream = try EchoUpstream()
        let upstreamPort = try await upstream.start()
        defer { upstream.listener.cancel() }

        let collected = Collected()
        let proxyPort = UInt16.random(in: 30_000...39_000)
        let route = ProxyServer.Route(
            prefix: "/kimi", upstream: URL(string: "http://127.0.0.1:\(upstreamPort)/v1")!, provider: .other,
            tool: "Kimi (proxy)", credential: .init(apiKey: "sk-guardada", localToken: "tb-local-x"),
            pricing: CustomPricing(input: 1, output: 4)
        )
        let server = ProxyServer(port: proxyPort, routes: LocalProxyManager.routes(custom: [route])) { item in
            Task { await collected.add(item) }
        }
        try server.start { _ in }
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(300))

        func post(auth: String, origin: String? = nil) async throws -> (Int, String) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/kimi/chat/completions")!)
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            request.setValue(auth, forHTTPHeaderField: "Authorization")
            if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        }

        let local = try await post(auth: "Bearer tb-local-x")
        #expect(local.1.contains("Bearer sk-guardada"))
        let own = try await post(auth: "Bearer sk-do-cliente")
        #expect(own.1.contains("Bearer sk-do-cliente"))
        let browser = try await post(auth: "Bearer tb-local-x", origin: "https://site.example")
        #expect(browser.0 == 403)

        let items = await collected.wait(for: 2)
        try #require(items.count == 2)
        let usage = LocalProxyManager.parsedUsage(items[0], prices: Fixtures.prices)
        #expect(usage.tool == "Kimi (proxy)")
        #expect(usage.provider == .other)
        // 1M de entrada a US$ 1 + 500k de saída a US$ 4.
        #expect(abs(usage.costUSD - 3) < 1e-9)
    }
}
