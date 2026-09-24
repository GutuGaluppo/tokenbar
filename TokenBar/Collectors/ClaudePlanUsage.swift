import Foundation
import Security
import Observation
import os

/// Uso do plano Claude (Pro/Max) direto da Anthropic: "Current session" (5 h) e limites semanais,
/// os mesmos números da tela Settings → Usage e do comando /usage do Claude Code.
///
/// Usa o login que o Claude Code guarda no Keychain ("Claude Code-credentials") e o endpoint que o
/// próprio Claude Code consulta. Não é uma API documentada: pode mudar sem aviso. O token é só lido
/// (nunca renovado, para não interferir no login do Claude Code) e só é enviado a api.anthropic.com.
@MainActor
@Observable
final class ClaudePlanUsage {
    struct Window: Equatable {
        let utilization: Double   // 0–100
        let resetsAt: Date?
    }

    enum Phase: Equatable {
        case disabled
        case loading
        case ok
        case needsLogin(String)
        case failed(String)
    }

    static let enabledKey = "planUsage.enabled"

    private(set) var phase: Phase = .disabled
    private(set) var session: Window?
    private(set) var week: Window?
    private(set) var weekSonnet: Window?
    private(set) var weekOpus: Window?
    private(set) var lastUpdate: Date?

    /// Chamado após cada atualização (o UsageStore recalcula os limites).
    @ObservationIgnored var onUpdate: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var cachedToken: (value: String, expiresAt: Date?)?
    @ObservationIgnored private var inFlight = false
    private static let log = Logger(subsystem: "dev.galuppo.TokenBar", category: "PlanUsage")
    private static let pollInterval: TimeInterval = 180

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            refresh(force: true)
        } else {
            cachedToken = nil
            session = nil; week = nil; weekSonnet = nil; weekOpus = nil
            phase = .disabled
            onUpdate?()
        }
    }

    /// Atualiza se a última leitura tem mais de 1 min (ou sempre, com `force`).
    func refresh(force: Bool = false) {
        guard !DemoMode.isEnabled else { return }   // demonstração usa valores fictícios
        guard isEnabled else {
            phase = .disabled
            return
        }
        if !force, let lastUpdate, Date.now.timeIntervalSince(lastUpdate) < 60 { return }
        guard !inFlight else { return }
        inFlight = true
        if lastUpdate == nil { phase = .loading }
        Task {
            defer { inFlight = false }
            await load()
            onUpdate?()
        }
    }

    private func load() async {
        guard let token = token() else {
            phase = .needsLogin("Login do Claude Code não encontrado no Keychain. Entre no Claude Code com sua conta Pro/Max.")
            return
        }
        if let expiresAt = token.expiresAt, expiresAt < .now {
            cachedToken = nil
            phase = .needsLogin("O login do Claude Code expirou. Abra o Claude Code (ele renova sozinho) e tente de novo.")
            return
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 10)
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("TokenBar/0.1 (macOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
                session = usage.five_hour?.window
                week = usage.seven_day?.window
                weekSonnet = usage.seven_day_sonnet?.window
                weekOpus = usage.seven_day_opus?.window
                lastUpdate = .now
                phase = .ok
                Self.log.notice("sessão \(self.session?.utilization ?? -1, privacy: .public)% · semana \(self.week?.utilization ?? -1, privacy: .public)%")
            case 401, 403:
                cachedToken = nil   // relê do Keychain na próxima vez (o Claude Code pode ter renovado)
                phase = .needsLogin("Login do Claude Code recusado (HTTP \(status)). Abra o Claude Code para renovar.")
            default:
                phase = .failed("HTTP \(status)")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    #if DEBUG
    /// Valores fictícios para o modo de demonstração.
    func setDemo(session: Window, week: Window) {
        self.session = session
        self.week = week
        lastUpdate = .now
        phase = .ok
        onUpdate?()
    }
    #endif

    // MARK: - Keychain

    private func token() -> (value: String, expiresAt: Date?)? {
        if let cachedToken, cachedToken.expiresAt.map({ $0 > .now }) ?? true { return cachedToken }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let credentials = try? JSONDecoder().decode(Credentials.self, from: data),
              let oauth = credentials.claudeAiOauth
        else { return nil }
        let expires = oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        cachedToken = (oauth.accessToken, expires)
        return cachedToken
    }

    private struct Credentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double?   // milissegundos
        }
        let claudeAiOauth: OAuth?
    }

    // MARK: - Resposta

    private struct UsageResponse: Decodable {
        let five_hour: Limit?
        let seven_day: Limit?
        let seven_day_sonnet: Limit?
        let seven_day_opus: Limit?
    }

    private struct Limit: Decodable {
        let utilization: Double?
        let resets_at: String?

        var window: Window? {
            guard let utilization else { return nil }
            return Window(utilization: utilization, resetsAt: resets_at.flatMap(Self.parseDate))
        }

        /// Aceita "2026-09-24T15:00:00Z", com frações de segundo de qualquer tamanho e fuso "+00:00".
        private static func parseDate(_ string: String) -> Date? {
            let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: trimmed)
        }
    }
}
