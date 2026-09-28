import Foundation
import os

/// Leva a dica ao vivo para a barra de status do Claude Code (opcional). O TokenBar grava uma linha
/// por sessão ativa em `live/<sessão>.txt` e um script que o Claude Code chama pela `statusLine`;
/// o script lê o `session_id` que o Claude Code manda e imprime a linha dessa sessão.
/// O TokenBar nunca edita o `~/.claude/settings.json`: o usuário cola a configuração.
@MainActor
final class StatusLineBridge {
    static let enabledKey = "liveTips.statusLine"
    private static let log = Logger(subsystem: "dev.galuppo.TokenBar", category: "StatusLine")

    static var scriptURL: URL { Persistence.directory.appending(path: "statusline.sh") }
    private static var linesDirectory: URL { Persistence.directory.appending(path: "live", directoryHint: .isDirectory) }

    /// O que colar em `~/.claude/settings.json`.
    static var settingsSnippet: String {
        """
        "statusLine": {
          "type": "command",
          "command": "'\(scriptURL.path(percentEncoded: false))'"
        }
        """
    }

    /// O `settings.json` do Claude Code já chama o script do TokenBar.
    static var isConfigured: Bool {
        let settings = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")
        guard let text = try? String(contentsOf: settings, encoding: .utf8) else { return false }
        return text.contains("TokenBar/statusline.sh")
    }

    static let script = """
        #!/bin/sh
        # TokenBar: mostra a dica ao vivo desta sessão na barra de status do Claude Code.
        # O Claude Code manda um JSON pela entrada; o TokenBar grava uma linha por sessão em live/<id>.txt.
        # Linha com mais de 45 min é de um TokenBar que já não está rodando: não mostra.
        id=$(tr -d '\\n' | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([A-Za-z0-9-]*\\)".*/\\1/p')
        file="$(dirname "$0")/live/$id.txt"
        [ -n "$id" ] && [ -n "$(find "$file" -mmin -45 2>/dev/null)" ] && cat "$file"
        exit 0

        """

    /// Linha e horário da última gravação de cada sessão.
    private var written: [String: (line: String, at: Date)] = [:]
    private var cleared = false
    /// Regrava mesmo sem mudança, para o script saber que o TokenBar continua rodando.
    private static let refreshInterval: TimeInterval = 10 * 60

    private var isEnabled: Bool {
        !AppEnvironment.isIsolated && UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func publish(_ sessions: [LiveSession]) {
        guard isEnabled else {
            if !cleared { clear() }
            return
        }
        cleared = false
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: Self.linesDirectory, withIntermediateDirectories: true)
            try installScriptIfNeeded()
        } catch {
            Self.log.error("Falha ao preparar a barra de status: \(error.localizedDescription)")
            return
        }

        var lines: [String: String] = [:]
        for session in sessions where !session.isCodex {
            lines[session.id] = Self.line(for: session)
        }
        let now = Date.now
        var updated: [String: (line: String, at: Date)] = [:]
        for (id, line) in lines {
            if let previous = written[id], previous.line == line, now.timeIntervalSince(previous.at) < Self.refreshInterval {
                updated[id] = previous
                continue
            }
            try? (line + "\n").write(to: Self.linesDirectory.appending(path: "\(id).txt"), atomically: true, encoding: .utf8)
            updated[id] = (line, now)
        }
        // Sessões que terminaram: sem arquivo, a barra do Claude Code fica vazia.
        let files = (try? fileManager.contentsOfDirectory(atPath: Self.linesDirectory.path(percentEncoded: false))) ?? []
        for file in files where file.hasSuffix(".txt") && lines[String(file.dropLast(4))] == nil {
            try? fileManager.removeItem(at: Self.linesDirectory.appending(path: file))
        }
        written = updated
    }

    /// Uma linha curta: a dica principal com o comando, ou o tamanho do contexto e o custo por chamada.
    nonisolated static func line(for session: LiveSession) -> String {
        let context = "\(TokenFormat.compact(session.context))/\(TokenFormat.compact(session.contextWindow))"
        guard let tip = session.tips.first else {
            let cost = session.warmCallCostUSD.map { String(localized: " · ≈ \(TokenFormat.usd($0))/chamada") } ?? ""
            return "TokenBar · \(context)\(cost)"
        }
        let icon = switch tip.severity {
        case .urgent: "⚠︎"
        case .attention: "●"
        case .info: "ℹ︎"
        }
        let command = tip.command.map { " → \($0.split(separator: " ").first ?? "")" } ?? ""
        return "\(icon) \(tip.title)\(command) · \(context)"
    }

    private func installScriptIfNeeded() throws {
        let url = Self.scriptURL
        if (try? String(contentsOf: url, encoding: .utf8)) == Self.script { return }
        try Self.script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    }

    private func clear() {
        if !AppEnvironment.isIsolated { try? FileManager.default.removeItem(at: Self.linesDirectory) }
        written = [:]
        cleared = true
    }
}
