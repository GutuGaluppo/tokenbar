import Foundation
import SwiftData
import Observation
import os

/// Uma fonte de logs locais (Claude Code, Codex): varredura inicial, reação a mudanças nos
/// arquivos (FSEvents) e uma varredura de segurança periódica. Expõe o status para a UI.
@MainActor
@Observable
final class LocalLogSource: Identifiable {
    enum Phase: Equatable {
        case idle
        case scanning(progress: Double)
        case unavailable   // ferramenta não encontrada nesta máquina
        case failed(String)
    }

    let id: String
    let name: String
    let externalIDPrefix: String
    let roots: [URL]

    private(set) var phase: Phase = .idle
    private(set) var eventCount = 0
    private(set) var lastScan: Date?
    private(set) var eventsWithoutPrice = 0
    /// Limites do plano lidos dos próprios logs (Codex), persistidos entre execuções.
    private(set) var planLimits: LocalPlanLimits?
    /// Chamado quando `planLimits` muda.
    @ObservationIgnored var onPlanLimitsChange: (() -> Void)?

    @ObservationIgnored private let scanner: (@escaping @Sendable (Double) -> Void) async throws -> LocalScanSummary
    @ObservationIgnored private let resetter: () async -> Void
    @ObservationIgnored private let ingestor: UsageIngestor
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var rescanRequested = false
    private static let log = Logger(subsystem: "dev.galuppo.TokenBar", category: "LocalLogSource")

    private init<Parser: JSONLLogParser>(
        id: String, name: String, externalIDPrefix: String, parser: Parser, container: ModelContainer
    ) {
        self.id = id
        self.name = name
        self.externalIDPrefix = externalIDPrefix
        self.roots = parser.roots
        let ingestor = UsageIngestor(modelContainer: container)
        self.ingestor = ingestor
        let collector = JSONLCollector(parser: parser, ingestor: ingestor, cursorsURL: Self.cursorsURL(id))
        scanner = { progress in try await collector.scan(progress: progress) }
        resetter = { await collector.reset() }
        if let data = UserDefaults.standard.data(forKey: Self.limitsKey(id)) {
            planLimits = try? JSONDecoder().decode(LocalPlanLimits.self, from: data)
        }
    }

    static func claudeCode(container: ModelContainer) -> LocalLogSource {
        LocalLogSource(id: "claude-code", name: "Claude Code", externalIDPrefix: "cc:",
                       parser: ClaudeCodeParser(prices: .load()), container: container)
    }

    static func codex(container: ModelContainer) -> LocalLogSource {
        LocalLogSource(id: "codex", name: "Codex", externalIDPrefix: "cx:",
                       parser: CodexParser(prices: .load()), container: container)
    }

    nonisolated static func cursorsURL(_ id: String) -> URL {
        Persistence.directory.appending(path: "cursors-\(id).json")
    }

    private static func limitsKey(_ id: String) -> String { "planLimits.\(id)" }

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    func start() {
        guard !roots.isEmpty else {
            phase = .unavailable
            return
        }
        watcher = FileWatcher(paths: roots.map { $0.path() }) { [weak self] in
            Task { @MainActor in self?.scan() }
        }
        // Rede de segurança caso algum evento do FSEvents se perca.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        scan()
    }

    /// Dispara uma varredura. Se já houver uma em andamento, agenda outra para logo depois.
    func scan() {
        guard !roots.isEmpty else { return }
        guard scanTask == nil else {
            rescanRequested = true
            return
        }
        scanTask = Task {
            let wasEmpty = lastScan == nil
            if wasEmpty { phase = .scanning(progress: 0) }
            do {
                let summary = try await scanner { [weak self] fraction in
                    // Só mostra progresso na primeira varredura; atualizações incrementais são silenciosas.
                    guard wasEmpty else { return }
                    Task { @MainActor in
                        guard let self, self.isScanning else { return }
                        self.phase = .scanning(progress: fraction)
                    }
                }
                eventsWithoutPrice += summary.eventsWithoutPrice
                if let limits = summary.latestLimits, limits.observedAt > (planLimits?.observedAt ?? .distantPast) {
                    planLimits = limits
                    UserDefaults.standard.set(try? JSONEncoder().encode(limits), forKey: Self.limitsKey(id))
                    onPlanLimitsChange?()
                }
                eventCount = await ingestor.count(externalIDPrefix: externalIDPrefix)
                lastScan = .now
                phase = .idle
            } catch {
                Self.log.error("Falha na varredura de \(self.name, privacy: .public): \(error.localizedDescription)")
                phase = .failed(error.localizedDescription)
            }
            scanTask = nil
            if rescanRequested {
                rescanRequested = false
                scan()
            }
        }
    }

    /// Apaga os eventos desta fonte e lê todo o histórico de novo.
    func reimport() {
        Task {
            await scanTask?.value
            await resetter()
            try? await ingestor.deleteAll(externalIDPrefix: externalIDPrefix)
            eventCount = 0
            eventsWithoutPrice = 0
            lastScan = nil
            scan()
        }
    }
}

/// As fontes locais do app, num só objeto de ambiente.
@MainActor
@Observable
final class LocalSources {
    let claudeCode: LocalLogSource
    let codex: LocalLogSource

    var all: [LocalLogSource] { [claudeCode, codex] }

    init(container: ModelContainer) {
        claudeCode = .claudeCode(container: container)
        codex = .codex(container: container)
    }

    func start() {
        all.forEach { $0.start() }
        // Mudou a regra de nome de projeto: relê o histórico uma vez para regravar os projetos.
        let key = "projectResolver.version"
        if UserDefaults.standard.integer(forKey: key) < ProjectResolver.version {
            all.filter { !$0.roots.isEmpty }.forEach { $0.reimport() }
            UserDefaults.standard.set(ProjectResolver.version, forKey: key)
        }
    }

    /// Usado quando o banco é recriado: todas as leituras recomeçam do zero.
    nonisolated static func resetAllCursors() {
        for id in ["claude-code", "codex"] {
            try? FileManager.default.removeItem(at: LocalLogSource.cursorsURL(id))
        }
    }
}
