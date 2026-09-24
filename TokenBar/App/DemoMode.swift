import Foundation
import SwiftData

/// Modo de demonstração para capturas de tela (só em builds de desenvolvimento).
/// Abre com `-demo YES`: usa um banco separado com dados fictícios, não lê logs nem APIs,
/// não publica o widget e abre o painel e uma prévia do popover como janelas.
enum DemoMode {
    static var isEnabled: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "demo")
        #else
        false
        #endif
    }

    /// Notificação distribuída para trocar a seção do painel: objeto = `SidebarSection.rawValue`.
    static let showSectionNotification = Notification.Name("dev.galuppo.TokenBar.demo.show")
    static let popoverWindowID = "popover-preview"
}

#if DEBUG
@MainActor
extension DemoMode {
    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "TokenBar-Demo", directoryHint: .isDirectory)
    }

    /// Recria o banco da demonstração com uso fictício dos últimos ~6 meses.
    static func seed(container: ModelContainer, planUsage: ClaudePlanUsage, localSources: LocalSources) {
        let modelContext = container.mainContext
        let prices = PriceTable.load()
        var generator = SeededGenerator(seed: 42)
        let calendar = Calendar.current
        let now = Date.now
        let today = calendar.startOfDay(for: now)

        let projects = ["aurora-web", "atlas-api", "nimbus-ios", "orbit-cli", "lumen-docs"]
        let claudeTools = ["Claude Code (VS Code)", "Claude Code (CLI)", "Claude Code (Desktop)"]
        var claudeCount = 0
        var codexCount = 0

        for dayOffset in 0..<182 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let weekend = weekday == 1 || weekday == 7
            // Mais atividade nas últimas semanas e em dias úteis.
            let activity = (dayOffset < 30 ? 0.9 : 0.45) * (weekend ? 0.35 : 1)
            guard dayOffset == 0 || Double.random(in: 0..<1, using: &generator) < activity else { continue }

            let sessions = dayOffset == 0 ? 4 : Int.random(in: 1...4, using: &generator)
            for sessionIndex in 0..<sessions {
                let hour = [9, 10, 11, 14, 15, 16, 17, 21, 23].randomElement(using: &generator)!
                var start = calendar.date(bySettingHour: hour, minute: Int.random(in: 0..<60, using: &generator), second: 0, of: day)!
                // Hoje: sessões espalhadas pelas últimas horas, a maioria no Claude.
                if dayOffset == 0 { start = now.addingTimeInterval(-Double(sessionIndex) * 5_400 - 3_600) }
                let project = projects.randomElement(using: &generator)!
                let session = "demo-\(dayOffset)-\(sessionIndex)"
                let isCodex = dayOffset == 0 ? sessionIndex == 3 : Double.random(in: 0..<1, using: &generator) < 0.2

                let roll = Double.random(in: 0..<1, using: &generator)
                let model = isCodex ? "gpt-5.4"
                    : roll < 0.68 ? "claude-sonnet-5"
                    : roll < 0.82 ? "claude-opus-5-5"
                    : roll < 0.93 ? "claude-opus-5" : "claude-haiku-4-5"
                let tool = isCodex ? "Codex (VS Code)" : claudeTools.randomElement(using: &generator)!

                var contextSize = Int.random(in: 28_000...70_000, using: &generator)
                let turns = Int.random(in: 12...55, using: &generator)
                for turn in 0..<turns {
                    let timestamp = start.addingTimeInterval(Double(turn) * Double.random(in: 40...150, using: &generator))
                    guard timestamp <= now else { break }
                    let newInput = Int.random(in: 20...2_500, using: &generator)
                    let cacheWrite = turn == 0 ? contextSize : Int.random(in: 800...6_000, using: &generator)
                    let longOutput = Double.random(in: 0..<1, using: &generator) < 0.02
                    let output = longOutput ? Int.random(in: 9_000...16_000, using: &generator)
                                            : Int.random(in: 120...2_800, using: &generator)
                    let cacheRead = turn == 0 ? 0 : contextSize
                    contextSize = min(contextSize + cacheWrite + output / 2, 420_000)

                    let tokens = TokenCounts(input: newInput, output: output, cacheWrite1h: cacheWrite, cacheRead: cacheRead)
                    // Preço ilustrativo para o Codex (a tabela real não tem os modelos da OpenAI).
                    let cost = prices.cost(model: model, tokens: tokens)
                        ?? (Double(newInput + cacheWrite) * 1.25 + Double(cacheRead) * 0.125 + Double(output) * 10) / 1_000_000
                    let prefix = isCodex ? "cx" : "cc"
                    modelContext.insert(UsageEvent(
                        externalID: "\(prefix):\(session):\(turn)",
                        timestamp: timestamp,
                        provider: isCodex ? .openai : .anthropic,
                        model: model,
                        project: project,
                        tool: tool,
                        session: session,
                        inputTokens: newInput,
                        outputTokens: output,
                        cacheWriteTokens: cacheWrite,
                        cacheReadTokens: cacheRead,
                        costUSD: cost
                    ))
                    if isCodex { codexCount += 1 } else { claudeCount += 1 }
                }
            }
        }
        try? modelContext.save()

        planUsage.setDemo(
            session: .init(utilization: 22, resetsAt: now.addingTimeInterval(2 * 3600 + 44 * 60)),
            week: .init(utilization: 64, resetsAt: now.addingTimeInterval(3 * 86_400 + 5 * 3600))
        )
        localSources.claudeCode.setDemo(eventCount: claudeCount, planLimits: nil)
        localSources.codex.setDemo(eventCount: codexCount, planLimits: LocalPlanLimits(
            observedAt: now, planType: "plus",
            windows: [
                .init(windowMinutes: 300, usedPercent: 18, resetsAt: now.addingTimeInterval(3 * 3600)),
                .init(windowMinutes: 10_080, usedPercent: 41, resetsAt: now.addingTimeInterval(4 * 86_400)),
            ]
        ))
    }
}

/// Gerador determinístico: a demonstração sai igual a cada execução.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
#endif
