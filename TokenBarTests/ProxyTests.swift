import Foundation
import Network
import Testing
@testable import TokenBar

@Suite("Extrator de consumo do proxy")
struct UsageExtractorTests {
    private func extract(_ text: String) -> UsageExtractor.Result {
        var extractor = UsageExtractor()
        extractor.feed(Data(text.utf8))
        return extractor.result()
    }

    @Test("Ollama em streaming (NDJSON): contagens no objeto final")
    func ollamaStream() {
        let result = extract("""
        {"model":"gpt-oss:20b","response":"Oi","done":false}
        {"model":"gpt-oss:20b","response":"!","done":false}
        {"model":"gpt-oss:20b","done":true,"prompt_eval_count":42,"eval_count":7}
        """)
        #expect(result == .init(model: "gpt-oss:20b", input: 42, output: 7, cacheRead: 0, found: true))
    }

    @Test("Ollama sem prompt_eval_count (prompt em cache) conta entrada 0")
    func ollamaCachedPrompt() {
        let result = extract(#"{"model":"llama3","done":true,"eval_count":12}"#)
        #expect(result.found && result.input == 0 && result.output == 12)
    }

    @Test("Formato OpenAI em SSE, com cache")
    func openAISSE() {
        let result = extract("""
        data: {"model":"llama3","choices":[{"delta":{"content":"Oi"}}]}

        data: {"model":"llama3","choices":[],"usage":{"prompt_tokens":100,"completion_tokens":20,"prompt_tokens_details":{"cached_tokens":60}}}

        data: [DONE]
        """)
        #expect(result == .init(model: "llama3", input: 40, output: 20, cacheRead: 60, found: true))
    }

    @Test("Gemini: JSON formatado, array de chunks e SSE cumulativo", arguments: [
        """
        {
          "candidates": [{"content": {"parts": [{"text": "Oi"}]}}],
          "usageMetadata": {"promptTokenCount": 30, "candidatesTokenCount": 5, "thoughtsTokenCount": 3, "totalTokenCount": 38},
          "modelVersion": "gemini-2.5-flash"
        }
        """,
        """
        [{"usageMetadata": {"promptTokenCount": 30, "candidatesTokenCount": 2}, "modelVersion": "gemini-2.5-flash"},
         {"usageMetadata": {"promptTokenCount": 30, "candidatesTokenCount": 5, "thoughtsTokenCount": 3}, "modelVersion": "gemini-2.5-flash"}]
        """,
        """
        data: {"usageMetadata": {"promptTokenCount": 30, "candidatesTokenCount": 2}, "modelVersion": "gemini-2.5-flash"}

        data: {"usageMetadata": {"promptTokenCount": 30, "candidatesTokenCount": 5, "thoughtsTokenCount": 3}, "modelVersion": "gemini-2.5-flash"}
        """,
    ])
    func gemini(body: String) {
        #expect(extract(body) == .init(model: "gemini-2.5-flash", input: 30, output: 8, cacheRead: 0, found: true))
    }

    @Test("Resposta sem consumo (ex.: lista de modelos) não gera registro")
    func noUsage() {
        #expect(!extract(#"{"models":[{"name":"llama3"}]}"#).found)
    }
}

@Suite("OpenRouter")
struct OpenRouterTests {
    @Test("Linhas do /activity viram eventos ao meio-dia UTC do dia")
    func parsesActivity() throws {
        let json = """
        {"data":[{"date":"2026-09-20","model":"openai/gpt-4.1","endpoint_id":"ep-1","provider_name":"OpenAI",
                  "usage":0.015,"requests":5,"prompt_tokens":50,"completion_tokens":125,"reasoning_tokens":25}]}
        """
        let activity = try JSONDecoder().decode(OpenRouterUsageConnector.Activity.self, from: Data(json.utf8))
        let usage = try #require(OpenRouterUsageConnector.parse(activity).first)
        #expect(usage.externalID == "or:2026-09-20:ep-1")
        #expect(usage.model == "openai/gpt-4.1")
        #expect(usage.tokens.input == 50 && usage.tokens.output == 125)
        #expect(usage.costUSD == 0.015)
        #expect(usage.provider == .openrouter)
        #expect(usage.timestamp == ISODate.parse("2026-09-20T12:00:00Z"))
    }
}

/// Servidor falso que responde como o Ollama (NDJSON) ou o Gemini (JSON), para testar o proxy.
private final class MockUpstream: @unchecked Sendable {
    let listener: NWListener
    static let ollamaBody = """
    {"model":"llama3","response":"Olá","done":false}
    {"model":"llama3","done":true,"prompt_eval_count":11,"eval_count":3}

    """
    static let geminiBody = #"{"usageMetadata":{"promptTokenCount":9,"candidatesTokenCount":4},"modelVersion":"gemini-2.5-flash"}"#

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let body = request.contains("/gem/") ? Self.geminiBody : Self.ollamaBody
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
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

private actor Recorder {
    var items: [ProxyServer.Recorded] = []
    func add(_ item: ProxyServer.Recorded) { items.append(item) }
    func waitForCount(_ count: Int) async -> [ProxyServer.Recorded] {
        for _ in 0..<100 where items.count < count { try? await Task.sleep(for: .milliseconds(50)) }
        return items
    }
}

@Suite("Proxy local", .serialized)
struct ProxyServerTests {
    @Test("Repassa a resposta intacta e registra o consumo do Ollama e do Gemini")
    func forwardsAndRecords() async throws {
        let upstream = try MockUpstream()
        let upstreamPort = try await upstream.start()
        defer { upstream.listener.cancel() }

        let recorder = Recorder()
        let proxyPort = UInt16.random(in: 40_000...49_000)
        let base = URL(string: "http://127.0.0.1:\(upstreamPort)")!
        let server = ProxyServer(port: proxyPort,
                                 routes: LocalProxyManager.routes(ollama: base, gemini: base.appending(path: "gem"))) { item in
            Task { await recorder.add(item) }
        }
        try server.start { _ in }
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(300))

        var ollama = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/api/generate")!)
        ollama.httpMethod = "POST"
        ollama.httpBody = Data(#"{"model":"llama3","prompt":"Oi"}"#.utf8)
        let (ollamaData, ollamaResponse) = try await URLSession.shared.data(for: ollama)
        #expect((ollamaResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: ollamaData, as: UTF8.self) == MockUpstream.ollamaBody)

        var gemini = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/gemini/v1beta/models/gemini-2.5-flash:generateContent")!)
        gemini.httpMethod = "POST"
        gemini.httpBody = Data("{}".utf8)
        let (geminiData, _) = try await URLSession.shared.data(for: gemini)
        #expect(String(decoding: geminiData, as: UTF8.self) == MockUpstream.geminiBody)

        let items = await recorder.waitForCount(2)
        try #require(items.count == 2)
        let ollamaItem = try #require(items.first { $0.route.provider == .local })
        #expect(ollamaItem.result == .init(model: "llama3", input: 11, output: 3, cacheRead: 0, found: true))
        let geminiItem = try #require(items.first { $0.route.provider == .google })
        #expect(geminiItem.result.input == 9 && geminiItem.result.output == 4)

        let usage = LocalProxyManager.parsedUsage(geminiItem, prices: Fixtures.prices)
        #expect(usage.model == "gemini-2.5-flash")
        #expect(usage.tool == "Gemini API (proxy)")
        #expect(usage.externalID.hasPrefix("px:"))
    }
}

@Suite("Proxy local: destino fora do ar", .serialized)
struct ProxyUpstreamDownTests {
    @Test("Responde 502 quando o destino não responde")
    func badGateway() async throws {
        let proxyPort = UInt16.random(in: 50_000...59_000)
        // Porta 9 (discard) em 127.0.0.1: conexão recusada.
        let dead = URL(string: "http://127.0.0.1:9")!
        let server = ProxyServer(port: proxyPort, routes: LocalProxyManager.routes(ollama: dead, gemini: dead)) { _ in }
        try server.start { _ in }
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(300))
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(proxyPort)/api/tags")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 502)
        #expect(String(decoding: data, as: UTF8.self).hasPrefix("TokenBar proxy:"))
    }
}
