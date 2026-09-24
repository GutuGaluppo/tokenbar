import Foundation
import SwiftData
import Testing
@testable import TokenBar

/// Leitura incremental de arquivos JSONL com um banco em memória.
@Suite("Coletor JSONL")
struct JSONLCollectorTests {
    let directory: URL
    let file: URL
    let container: ModelContainer
    let ingestor: UsageIngestor
    let collector: JSONLCollector<ClaudeCodeParser>

    init() throws {
        directory = try Fixtures.temporaryDirectory()
        file = directory.appending(path: "session.jsonl")
        container = try Fixtures.inMemoryContainer()
        ingestor = UsageIngestor(modelContainer: container)
        collector = JSONLCollector(
            parser: ClaudeCodeParser(prices: Fixtures.prices, roots: [directory]),
            ingestor: ingestor,
            cursorsURL: directory.appending(path: "cursors.json")
        )
    }

    private func write(_ lines: [String], terminated: Bool = true) throws {
        try (lines.joined(separator: "\n") + (terminated ? "\n" : "")).write(to: file, atomically: false, encoding: .utf8)
    }

    private func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func count() async -> Int {
        await ingestor.count(externalIDPrefix: "cc:")
    }

    private func scan() async throws {
        _ = try await collector.scan { _ in }
    }

    @Test("A mesma resposta em várias linhas conta uma vez; a última versão prevalece")
    func deduplicatesResponses() async throws {
        try write([
            Fixtures.claudeLine(id: "msg_1", output: 10),
            Fixtures.claudeLine(id: "msg_1", output: 250),   // mesmo id, bloco seguinte
            Fixtures.claudeLine(id: "msg_2", request: "req_2"),
        ])
        try await scan()
        #expect(await count() == 2)

        let context = ModelContext(container)
        let events = try context.fetch(FetchDescriptor<UsageEvent>(predicate: #Predicate { $0.externalID == "cc:msg_1:req_1" }))
        #expect(events.map(\.outputTokens) == [250])
    }

    @Test("Só lê bytes novos e espera a linha terminar antes de processá-la")
    func incrementalAndPartialLines() async throws {
        try write([Fixtures.claudeLine(id: "msg_1")])
        try await scan()
        #expect(await count() == 1)

        // Linha nova completa + uma linha pela metade (sem quebra de linha).
        let partial = Fixtures.claudeLine(id: "msg_3", request: "req_3")
        try append(Fixtures.claudeLine(id: "msg_2", request: "req_2") + "\n" + partial.prefix(40))
        try await scan()
        #expect(await count() == 2)

        try append(String(partial.dropFirst(40)) + "\n")
        try await scan()
        #expect(await count() == 3)
    }

    @Test("Arquivo substituído é relido do início, sem duplicar")
    func replacedFileIsReread() async throws {
        try write([Fixtures.claudeLine(id: "msg_1"), Fixtures.claudeLine(id: "msg_2", request: "req_2")])
        try await scan()
        #expect(await count() == 2)

        // Novo arquivo (novo inode), menor que o anterior: repete msg_1 e traz msg_9.
        try FileManager.default.removeItem(at: file)
        try write([Fixtures.claudeLine(id: "msg_1"), Fixtures.claudeLine(id: "msg_9", request: "req_9")])
        try await scan()
        #expect(await count() == 3)
    }

    @Test("Cursores persistem entre instâncias do coletor")
    func cursorsPersist() async throws {
        try write([Fixtures.claudeLine(id: "msg_1")])
        try await scan()

        let reopened = JSONLCollector(
            parser: ClaudeCodeParser(prices: Fixtures.prices, roots: [directory]),
            ingestor: ingestor,
            cursorsURL: directory.appending(path: "cursors.json")
        )
        let summary = try await reopened.scan { _ in }
        #expect(summary.filesChanged == 0)
    }
}
