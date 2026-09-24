import Foundation
import Network
import SwiftData
import Observation
import os

// MARK: - Extração de consumo

/// Lê contagens de tokens de respostas de modelos: Ollama nativo (`prompt_eval_count`/`eval_count`),
/// formato OpenAI (`usage`, que o Ollama também oferece em /v1) e Gemini (`usageMetadata`).
/// Aceita JSON único, array de JSON, NDJSON e SSE (`data: {...}`). Em streaming os valores são
/// cumulativos ou aparecem no fim, então o último visto vale.
struct UsageExtractor {
    struct Result: Equatable {
        var model: String?
        var input = 0
        var output = 0
        var cacheRead = 0
        var found = false
    }

    /// Guarda o corpo até este tamanho; acima disso, só o final (onde o consumo aparece).
    static let maxBody = 8 * 1024 * 1024
    private(set) var body = Data()

    mutating func feed(_ data: Data) {
        body.append(data)
        if body.count > Self.maxBody {
            body = Data(body.suffix(256 * 1024))
        }
    }

    func result() -> Result {
        var result = Result()
        for object in Self.objects(in: body) {
            Self.apply(object, to: &result)
        }
        return result
    }

    private static func objects(in data: Data) -> [[String: Any]] {
        if let whole = try? JSONSerialization.jsonObject(with: data) {
            if let object = whole as? [String: Any] { return [object] }
            if let array = whole as? [[String: Any]] { return array }
        }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> [String: Any]? in
                var text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("data:") { text = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                guard text.hasPrefix("{"), let json = text.data(using: .utf8) else { return nil }
                return (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
            }
    }

    private static func apply(_ object: [String: Any], to result: inout Result) {
        func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

        if let model = object["model"] as? String ?? object["modelVersion"] as? String, !model.isEmpty {
            result.model = model
        }
        // Ollama nativo: contagens só no objeto final (done: true).
        if let prompt = int(object["prompt_eval_count"]) ?? (object["done"] as? Bool == true ? 0 : nil),
           let output = int(object["eval_count"]) {
            result.input = prompt
            result.output = output
            result.found = true
        }
        // Formato OpenAI.
        if let usage = object["usage"] as? [String: Any], let prompt = int(usage["prompt_tokens"]) {
            let cached = int((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"]) ?? 0
            result.input = max(prompt - cached, 0)
            result.cacheRead = cached
            result.output = int(usage["completion_tokens"]) ?? 0
            result.found = true
        }
        // Gemini.
        if let usage = object["usageMetadata"] as? [String: Any], let prompt = int(usage["promptTokenCount"]) {
            let cached = int(usage["cachedContentTokenCount"]) ?? 0
            result.input = max(prompt - cached, 0)
            result.cacheRead = cached
            result.output = (int(usage["candidatesTokenCount"]) ?? 0) + (int(usage["thoughtsTokenCount"]) ?? 0)
            result.found = true
        }
    }
}

// MARK: - Servidor

/// Proxy HTTP mínimo em 127.0.0.1. `/gemini/...` vai para a API do Gemini; o resto, para o Ollama.
/// Repassa a resposta em tempo real (chunked) e, ao fim, informa o consumo encontrado.
final class ProxyServer: @unchecked Sendable {
    struct Route: Sendable {
        let prefix: String       // ex.: "/gemini"; "" = padrão
        let upstream: URL
        let provider: Provider
        let tool: String
    }

    struct Recorded: Sendable {
        let route: Route
        let path: String
        let result: UsageExtractor.Result
    }

    let port: UInt16
    private let routes: [Route]
    private let onUsage: @Sendable (Recorded) -> Void
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dev.galuppo.TokenBar.proxy")
    private let session: URLSession
    private static let log = Logger(subsystem: "dev.galuppo.TokenBar", category: "Proxy")

    init(port: UInt16, routes: [Route], onUsage: @escaping @Sendable (Recorded) -> Void) {
        self.port = port
        self.routes = routes.sorted { $0.prefix.count > $1.prefix.count }
        self.onUsage = onUsage
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3_600
        session = URLSession(configuration: configuration)
    }

    func start(stateChanged: @escaping @Sendable (NWListener.State) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = stateChanged
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: Conexões

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest.parse(buffer) {
                self.forward(request, on: connection)
            } else if complete || error != nil || buffer.count > 64 * 1024 * 1024 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer)
            }
        }
    }

    private func forward(_ request: HTTPRequest, on connection: NWConnection) {
        guard let route = routes.first(where: { request.path.hasPrefix($0.prefix) }) else {
            respond(connection, status: 404, body: "no route")
            return
        }
        let upstreamPath = String(request.path.dropFirst(route.prefix.count))
        guard let url = URL(string: route.upstream.absoluteString + (upstreamPath.hasPrefix("/") ? upstreamPath : "/" + upstreamPath)) else {
            respond(connection, status: 400, body: "bad path")
            return
        }
        var upstream = URLRequest(url: url)
        upstream.httpMethod = request.method
        upstream.httpBody = request.body.isEmpty ? nil : request.body
        for (name, value) in request.headers where !Self.skippedRequestHeaders.contains(name.lowercased()) {
            upstream.addValue(value, forHTTPHeaderField: name)
        }

        let relay = Relay(connection: connection, noBody: request.method == "HEAD") { [weak self] result in
            guard let self, result.found else { return }
            self.onUsage(Recorded(route: route, path: upstreamPath, result: result))
        }
        let task = session.dataTask(with: upstream)
        task.delegate = relay
        task.resume()
    }

    private func respond(_ connection: NWConnection, status: Int, body: String) {
        let text = "HTTP/1.1 \(status) \(status == 404 ? "Not Found" : "Bad Request")\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static let skippedRequestHeaders: Set<String> = ["host", "connection", "content-length", "accept-encoding", "transfer-encoding", "proxy-connection", "keep-alive"]
}

/// Repassa a resposta do servidor de origem ao cliente, em chunks, e alimenta o extrator.
private final class Relay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: NWConnection
    private let noBody: Bool
    private let finished: (UsageExtractor.Result) -> Void
    private var extractor = UsageExtractor()
    private var chunked = true
    private var sentHead = false

    init(connection: NWConnection, noBody: Bool, finished: @escaping (UsageExtractor.Result) -> Void) {
        self.connection = connection
        self.noBody = noBody
        self.finished = finished
    }

    private static let skippedResponseHeaders: Set<String> = ["content-length", "transfer-encoding", "connection", "content-encoding", "keep-alive"]

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 502
        chunked = !(noBody || status == 204 || status == 304)
        let reason = status == 200 ? "OK" : HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (key, value) in http?.allHeaderFields ?? [:] {
            guard let name = key as? String, !Self.skippedResponseHeaders.contains(name.lowercased()) else { continue }
            head += "\(name): \(value)\r\n"
        }
        head += chunked ? "Transfer-Encoding: chunked\r\n" : "Content-Length: 0\r\n"
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .idempotent)
        sentHead = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard chunked, !data.isEmpty else { return }
        extractor.feed(data)
        var chunk = Data(String(data.count, radix: 16).utf8)
        chunk.append(contentsOf: [13, 10])
        chunk.append(data)
        chunk.append(contentsOf: [13, 10])
        connection.send(content: chunk, completion: .idempotent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Destino fora do ar antes de responder: 502 para o cliente saber o motivo.
        if let error, !sentHead {
            let body = "TokenBar proxy: \(error.localizedDescription)"
            let text = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(text.utf8), completion: .contentProcessed { [connection] _ in connection.cancel() })
            return
        }
        if error != nil && !chunked {
            connection.cancel()
            return
        }
        let end = chunked ? Data("0\r\n\r\n".utf8) : Data()
        connection.send(content: end, completion: .contentProcessed { [connection] _ in connection.cancel() })
        if error == nil { finished(extractor.result()) }
    }
}

/// Requisição HTTP/1.1 com Content-Length (suficiente para as APIs de modelos).
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [(String, String)]
    let body: Data

    /// nil enquanto a requisição não chegou inteira.
    static func parse(_ buffer: Data) -> HTTPRequest? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [(String, String)] = []
        var length = 0
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
            if name.lowercased() == "content-length" { length = Int(value) ?? 0 }
        }
        let bodyStart = separator.upperBound
        guard buffer.count - bodyStart >= length else { return nil }
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers,
                           body: Data(buffer[bodyStart..<(bodyStart + length)]))
    }
}

// MARK: - Gerenciador

/// Liga e desliga o proxy (Ajustes) e grava o consumo que passa por ele.
@MainActor
@Observable
final class LocalProxyManager {
    enum Phase: Equatable {
        case off
        case listening
        case failed(String)
    }

    static let enabledKey = "proxy.enabled"
    static let portKey = "proxy.port"
    static let defaultPort: UInt16 = 11435
    nonisolated static let externalIDPrefix = "px:"

    private(set) var phase: Phase = .off
    private(set) var recordedCount = 0
    private(set) var lastRecorded: Date?

    @ObservationIgnored private var server: ProxyServer?
    @ObservationIgnored private let ingestor: UsageIngestor
    private static let log = Logger(subsystem: "dev.galuppo.TokenBar", category: "Proxy")

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var port: UInt16 {
        let value = UserDefaults.standard.integer(forKey: Self.portKey)
        return (1024...65535).contains(value) ? UInt16(value) : Self.defaultPort
    }

    nonisolated static func routes(ollama: URL = URL(string: "http://127.0.0.1:11434")!,
                       gemini: URL = URL(string: "https://generativelanguage.googleapis.com")!) -> [ProxyServer.Route] {
        [
            .init(prefix: "/gemini", upstream: gemini, provider: .google, tool: "Gemini API (proxy)"),
            .init(prefix: "", upstream: ollama, provider: .local, tool: "Ollama (proxy)"),
        ]
    }

    init(container: ModelContainer) {
        ingestor = UsageIngestor(modelContainer: container)
    }

    func start() {
        guard !AppEnvironment.isIsolated else { return }
        if isEnabled { launch() }
        Task { recordedCount = await ingestor.count(externalIDPrefix: Self.externalIDPrefix) }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        enabled ? launch() : shutdown()
    }

    func setPort(_ port: Int) {
        UserDefaults.standard.set(port, forKey: Self.portKey)
        if isEnabled { launch() }
    }

    private func launch() {
        shutdown()
        let ingestor = self.ingestor
        let prices = PriceTable.load()
        let server = ProxyServer(port: port, routes: Self.routes()) { [weak self] recorded in
            let usage = Self.parsedUsage(recorded, prices: prices)
            Task { @MainActor in
                _ = try? await ingestor.upsert([usage])
                self?.recordedCount += 1
                self?.lastRecorded = .now
            }
        }
        do {
            try server.start { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.phase = .listening
                    case .failed(let error): self?.phase = .failed(error.localizedDescription)
                    case .cancelled: self?.phase = .off
                    default: break
                    }
                }
            }
            self.server = server
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func shutdown() {
        server?.stop()
        server = nil
        phase = .off
    }

    nonisolated static func parsedUsage(_ recorded: ProxyServer.Recorded, prices: PriceTable) -> ParsedUsage {
        let result = recorded.result
        // Gemini: o modelo também está no caminho (/v1beta/models/<modelo>:generateContent).
        let pathModel = recorded.path.split(separator: "/").last.map { String($0.split(separator: ":").first ?? $0) }
        let model = result.model ?? pathModel ?? "desconhecido"
        let tokens = TokenCounts(input: result.input, output: result.output, cacheRead: result.cacheRead)
        let cost = recorded.route.provider == .local ? 0 : (prices.cost(model: model, tokens: tokens) ?? 0)
        return ParsedUsage(
            externalID: "\(externalIDPrefix)\(UUID().uuidString)",
            timestamp: .now,
            provider: recorded.route.provider,
            model: model,
            project: nil,
            tool: recorded.route.tool,
            session: nil,
            tokens: tokens,
            costUSD: cost
        )
    }
}
