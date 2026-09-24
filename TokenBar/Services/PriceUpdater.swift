import Foundation
import Observation
import os

/// Busca a tabela de preços publicada no repositório uma vez por dia. Só adota a remota quando
/// ela é válida e mais recente que a em uso; o prices.json do usuário sempre prevalece.
@MainActor
@Observable
final class PriceUpdater {
    private(set) var source: PriceSource
    private(set) var asOf: String
    private(set) var lastCheck: Date?
    private(set) var lastError: String?
    private(set) var isChecking = false

    /// Chamado quando a tabela em uso muda (para recalcular custos).
    @ObservationIgnored var onChange: ((PriceTable) -> Void)?
    @ObservationIgnored private var timer: Timer?
    private static let log = Logger(subsystem: "dev.galuppo.TokenBar", category: "Prices")
    private static let lastCheckKey = "prices.lastCheck"
    private static let interval: TimeInterval = 86_400

    /// Vem do Info.plist (PRICES_URL em Config/Base.xcconfig).
    static var remoteURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "TokenBarPricesURL") as? String).flatMap(URL.init(string:))
    }

    init() {
        let current = PriceTable.loadWithSource()
        source = current.source
        asOf = current.table.asOf
        lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
    }

    func start() {
        guard !AppEnvironment.isIsolated else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        checkIfDue()
    }

    private func checkIfDue() {
        if let lastCheck, Date.now.timeIntervalSince(lastCheck) < Self.interval { return }
        Task { await check() }
    }

    func check() async {
        guard let url = Self.remoteURL, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        lastError = nil
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("TokenBar/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "")", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let remote = try JSONDecoder().decode(PriceTable.self, from: data)
            guard remote.isValid else {
                throw NSError(domain: "TokenBar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Tabela remota inválida"])
            }
            let before = PriceTable.load()
            if PriceTable.read(PriceTable.remoteCacheURL) != remote {
                try data.write(to: PriceTable.remoteCacheURL, options: .atomic)
            }
            let after = PriceTable.loadWithSource()
            source = after.source
            asOf = after.table.asOf
            if after.table != before {
                Self.log.notice("Tabela de preços atualizada para \(after.table.asOf, privacy: .public)")
                onChange?(after.table)
            }
        } catch {
            lastError = error.localizedDescription
            Self.log.error("Falha ao buscar preços: \(error.localizedDescription, privacy: .public)")
        }
        lastCheck = .now
        UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)
    }
}
