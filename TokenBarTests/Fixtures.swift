import Foundation
import SwiftData
@testable import TokenBar

/// Linhas de log de exemplo (anonimizadas) e utilidades comuns aos testes.
enum Fixtures {
    /// Uma linha de resposta do Claude Code no formato de `~/.claude/projects/**/*.jsonl`.
    static func claudeLine(
        id: String = "msg_1",
        request: String = "req_1",
        type: String = "assistant",
        model: String = "claude-sonnet-5",
        input: Int = 10,
        output: Int = 100,
        cacheWrite5m: Int = 0,
        cacheWrite1h: Int = 0,
        cacheRead: Int = 0,
        speed: String = "standard",
        timestamp: String = "2026-09-20T10:00:00.000Z",
        cwd: String = "/nonexistent-tokenbar/demo-project",
        entrypoint: String = "claude-vscode",
        session: String = "session-1"
    ) -> String {
        json([
            "type": type,
            "timestamp": timestamp,
            "requestId": request,
            "sessionId": session,
            "cwd": cwd,
            "entrypoint": entrypoint,
            "message": [
                "id": id,
                "model": model,
                "usage": [
                    "input_tokens": input,
                    "output_tokens": output,
                    "cache_creation_input_tokens": cacheWrite5m + cacheWrite1h,
                    "cache_read_input_tokens": cacheRead,
                    "cache_creation": [
                        "ephemeral_5m_input_tokens": cacheWrite5m,
                        "ephemeral_1h_input_tokens": cacheWrite1h,
                    ],
                    "speed": speed,
                ],
            ],
        ])
    }

    static func codexSessionMeta(id: String = "codex-session-1", cwd: String = "/nonexistent-tokenbar/codex-project",
                                 originator: String = "codex_cli_rs") -> String {
        json(["timestamp": "2026-09-20T10:00:00.000Z", "type": "session_meta",
              "payload": ["id": id, "cwd": cwd, "originator": originator]])
    }

    static func codexTurnContext(model: String = "gpt-5.4") -> String {
        json(["timestamp": "2026-09-20T10:00:01.000Z", "type": "turn_context",
              "payload": ["model": model, "cwd": "/nonexistent-tokenbar/codex-project"]])
    }

    static func codexTokenCount(total: Int, input: Int, cached: Int, output: Int,
                                withInfo: Bool = true, primaryUsed: Double = 17, secondaryUsed: Double = 74) -> String {
        var payload: [String: Any] = [
            "type": "token_count",
            "rate_limits": [
                "primary": ["used_percent": primaryUsed, "window_minutes": 300, "resets_at": 1_790_204_298],
                "secondary": ["used_percent": secondaryUsed, "window_minutes": 10_080, "resets_at": 1_790_506_806],
                "plan_type": "plus",
            ],
        ]
        payload["info"] = withInfo ? [
            "total_token_usage": ["total_tokens": total],
            "last_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output],
        ] as [String: Any] : NSNull()
        return json(["timestamp": "2026-09-20T10:00:05.000Z", "type": "event_msg", "payload": payload])
    }

    static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func bytes(_ line: String) -> Data.SubSequence {
        Data(line.utf8)[...]
    }

    /// Pasta temporária exclusiva de um teste.
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "TokenBarTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(for: UsageEvent.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    static let prices = PriceTable.load()
}
