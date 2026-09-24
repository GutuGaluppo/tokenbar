import Foundation
import SwiftData
import Observation
import os

/// Sincroniza as APIs de uso remotas (Anthropic, OpenAI) a cada 5 minutos.
@MainActor
@Observable
final class RemoteSourcesManager {
    enum Phase: Equatable {
        case notConfigured
        case syncing
        case ok
        case failed(String)
    }

    struct SourceState: Equatable {
        var phase: Phase = .notConfigured
        var hasKey = false
        var lastSync: Date?
        var eventCount = 0
    }

    private(set) var states: [RemoteProviderKind: SourceState] = [:]

    @ObservationIgnored private let ingestor: UsageIngestor
    @ObservationIgnored private let prices = PriceTable.load()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var inFlight: Set<RemoteProviderKind> = []
    private static let log = Logger(subsystem: "dev.galuppo.TokenBar", category: "RemoteSources")

    /// Primeira sincronização busca 30 dias; as seguintes, só os 2 últimos dias (dados chegam com atraso).
    private static let initialWindow: TimeInterval = 30 * 86_400
    private static let refreshWindow: TimeInterval = 2 * 86_400

    init(container: ModelContainer) {
        ingestor = UsageIngestor(modelContainer: container)
        for kind in RemoteProviderKind.allCases {
            var state = SourceState()
            if KeychainStore.read(kind.keychainAccount) != nil {
                state.phase = .ok
                state.hasKey = true
                state.lastSync = UserDefaults.standard.object(forKey: Self.lastSyncKey(kind)) as? Date
            }
            states[kind] = state
        }
    }

    func state(_ kind: RemoteProviderKind) -> SourceState { states[kind] ?? SourceState() }

    func isConfigured(_ kind: RemoteProviderKind) -> Bool { state(kind).hasKey }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncAll() }
        }
        syncAll()
    }

    func syncAll() {
        for kind in RemoteProviderKind.allCases where isConfigured(kind) {
            Task { await sync(kind) }
        }
    }

    /// Valida a chave com uma sincronização real; só a guarda no Keychain se funcionar.
    @discardableResult
    func connect(_ kind: RemoteProviderKind, apiKey: String) async -> Bool {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        states[kind, default: SourceState()].phase = .syncing
        do {
            try await fetchAndStore(kind, apiKey: key, since: .now.addingTimeInterval(-Self.initialWindow))
            try KeychainStore.save(key, for: kind.keychainAccount)
            states[kind, default: SourceState()].hasKey = true
            return true
        } catch {
            states[kind, default: SourceState()].phase = .failed(error.localizedDescription)
            return false
        }
    }

    func disconnect(_ kind: RemoteProviderKind) {
        KeychainStore.delete(kind.keychainAccount)
        UserDefaults.standard.removeObject(forKey: Self.lastSyncKey(kind))
        states[kind] = SourceState()
        Task { try? await ingestor.deleteAll(externalIDPrefix: kind.externalIDPrefix) }
    }

    func sync(_ kind: RemoteProviderKind) async {
        guard let key = KeychainStore.read(kind.keychainAccount), !inFlight.contains(kind) else { return }
        let window = state(kind).lastSync == nil ? Self.initialWindow : Self.refreshWindow
        states[kind, default: SourceState()].phase = .syncing
        do {
            try await fetchAndStore(kind, apiKey: key, since: .now.addingTimeInterval(-window))
        } catch {
            Self.log.error("Falha ao sincronizar \(kind.rawValue): \(error.localizedDescription)")
            states[kind, default: SourceState()].phase = .failed(error.localizedDescription)
        }
    }

    private func fetchAndStore(_ kind: RemoteProviderKind, apiKey: String, since: Date) async throws {
        inFlight.insert(kind)
        defer { inFlight.remove(kind) }

        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.dateInterval(of: .hour, for: since)?.start ?? since
        let events = try await kind.makeConnector(prices: prices).fetch(from: start, to: .now, apiKey: apiKey)
        try await ingestor.upsert(events)

        let now = Date.now
        UserDefaults.standard.set(now, forKey: Self.lastSyncKey(kind))
        states[kind] = SourceState(
            phase: .ok,
            hasKey: state(kind).hasKey,
            lastSync: now,
            eventCount: await ingestor.count(externalIDPrefix: kind.externalIDPrefix)
        )
    }

    private static func lastSyncKey(_ kind: RemoteProviderKind) -> String { "lastSync.\(kind.rawValue)" }
}
