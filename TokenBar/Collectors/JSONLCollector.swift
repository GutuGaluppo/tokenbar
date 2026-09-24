import Foundation
import os

struct LocalScanSummary: Sendable {
    var filesChanged = 0
    var eventsParsed = 0
    var eventsWithoutPrice = 0
    var latestLimits: LocalPlanLimits?
}

/// Um evento já extraído e precificado, pronto para virar `UsageEvent`.
struct ParsedUsage: Sendable {
    let externalID: String
    let timestamp: Date
    let provider: Provider
    let model: String
    let project: String?
    let tool: String?
    let session: String?
    let tokens: TokenCounts
    let costUSD: Double
}

/// Limites de plano gravados nos próprios logs da ferramenta (ex.: Codex).
struct LocalPlanLimits: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        let windowMinutes: Int
        let usedPercent: Double
        let resetsAt: Date?
    }

    let observedAt: Date
    let planType: String?
    let windows: [Window]
}

/// Sabe interpretar as linhas de um tipo de log JSONL. `FileState` guarda o contexto que só
/// aparece em linhas anteriores (sessão, modelo) para a leitura incremental continuar de onde parou.
protocol JSONLLogParser {
    associatedtype FileState: Codable

    var roots: [URL] { get }
    func initialState() -> FileState
    func parse(_ line: Data.SubSequence, state: inout FileState) -> (usage: ParsedUsage?, limits: LocalPlanLimits?)
}

/// Lê arquivos JSONL de forma incremental: guarda, por arquivo, até onde já leu (e o estado do
/// parser) e só processa bytes novos.
actor JSONLCollector<Parser: JSONLLogParser> {
    typealias ScanSummary = LocalScanSummary

    private struct Cursor: Codable {
        var offset: UInt64
        var inode: UInt64
        var state: Parser.FileState?
    }

    private static var log: Logger { Logger(subsystem: "dev.galuppo.TokenBar", category: "JSONLCollector") }
    private static var chunkSize: Int { 4 * 1024 * 1024 }
    private static var flushThreshold: Int { 2_000 }

    private let parser: Parser
    private let ingestor: UsageIngestor
    private let cursorsURL: URL
    private var cursors: [String: Cursor]

    init(parser: Parser, ingestor: UsageIngestor, cursorsURL: URL) {
        self.parser = parser
        self.ingestor = ingestor
        self.cursorsURL = cursorsURL
        if let data = try? Data(contentsOf: cursorsURL),
           let saved = try? JSONDecoder().decode([String: Cursor].self, from: data) {
            cursors = saved
        } else {
            cursors = [:]
        }
    }

    func reset() {
        cursors = [:]
        try? FileManager.default.removeItem(at: cursorsURL)
    }

    /// Lê tudo o que é novo desde a última varredura. `progress` recebe a fração de bytes processados.
    func scan(progress: @Sendable (Double) -> Void) async throws -> ScanSummary {
        var summary = ScanSummary()
        let pending = pendingFiles()
        let totalBytes = pending.reduce(UInt64(0)) { $0 + ($1.size - $1.startOffset) }
        var processedBytes: UInt64 = 0
        var buffer: [ParsedUsage] = []

        for file in pending {
            summary.filesChanged += 1
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            try handle.seek(toOffset: file.startOffset)

            var state = file.state ?? parser.initialState()
            var offset = file.startOffset
            var carry = Data()
            while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                carry.append(chunk)
                // Só processa linhas completas; o resto fica para a próxima leitura.
                guard let lastNewline = carry.lastIndex(of: UInt8(ascii: "\n")) else { continue }
                let complete = carry[carry.startIndex...lastNewline]
                for line in complete.split(separator: UInt8(ascii: "\n")) {
                    let result = parser.parse(line, state: &state)
                    if let usage = result.usage {
                        if usage.costUSD.isNaN { summary.eventsWithoutPrice += 1 }
                        buffer.append(usage)
                    }
                    if let limits = result.limits, limits.observedAt > (summary.latestLimits?.observedAt ?? .distantPast) {
                        summary.latestLimits = limits
                    }
                }
                let consumed = UInt64(complete.count)
                offset += consumed
                processedBytes += consumed
                carry = Data(carry[carry.index(after: lastNewline)...])

                if buffer.count >= Self.flushThreshold {
                    summary.eventsParsed += try await ingestor.upsert(buffer)
                    buffer.removeAll(keepingCapacity: true)
                    cursors[file.url.path()] = Cursor(offset: offset, inode: file.inode, state: state)
                    saveCursors()
                }
                progress(totalBytes > 0 ? Double(processedBytes) / Double(totalBytes) : 1)
            }
            cursors[file.url.path()] = Cursor(offset: offset, inode: file.inode, state: state)
        }

        if !buffer.isEmpty {
            summary.eventsParsed += try await ingestor.upsert(buffer)
        }
        saveCursors()
        progress(1)
        return summary
    }

    // MARK: - Arquivos

    private struct PendingFile {
        let url: URL
        let size: UInt64
        let inode: UInt64
        let startOffset: UInt64
        let state: Parser.FileState?
    }

    private func pendingFiles() -> [PendingFile] {
        var result: [PendingFile] = []
        for root in parser.roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path()),
                      let size = (attributes[.size] as? NSNumber)?.uint64Value,
                      let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
                else { continue }

                var start: UInt64 = 0
                var state: Parser.FileState?
                if let cursor = cursors[url.path()], cursor.inode == inode, cursor.offset <= size {
                    start = cursor.offset   // arquivo truncado ou substituído recomeça do zero
                    state = cursor.state
                }
                if start < size {
                    result.append(PendingFile(url: url, size: size, inode: inode, startOffset: start, state: state))
                }
            }
        }
        return result
    }

    private func saveCursors() {
        do {
            let data = try JSONEncoder().encode(cursors)
            try data.write(to: cursorsURL, options: .atomic)
        } catch {
            Self.log.error("Falha ao salvar cursores: \(error.localizedDescription)")
        }
    }
}

enum ISODate {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    static func parse(_ string: String) -> Date? {
        (try? fractional.parse(string)) ?? (try? plain.parse(string))
    }
}
