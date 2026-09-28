import SwiftUI
import AppKit

/// Seção "Solução de problemas": o estado atual de cada fonte e os problemas conhecidos, com os passos
/// para resolver.
struct TroubleshootingView: View {
    @Environment(ClaudePlanUsage.self) private var planUsage
    @Environment(LocalSources.self) private var localSources
    @Environment(LocalProxyManager.self) private var proxy
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                status

                Text("Problemas conhecidos")
                    .font(.title3.weight(.semibold))
                    .padding(.top, 8)

                TroubleshootingCard(
                    symbol: "person.badge.key",
                    title: "Os limites do plano Claude sumiram ou aparece \"login expirou\"",
                    expanded: planUsage.needsAttention
                ) {
                    Text("O TokenBar lê o login que o Claude Code guarda no Keychain e nunca o renova, para não interferir nele. Quem renova é o `claude` de terminal (ou da extensão do VS Code), e só quando faz uma chamada. O app desktop do Claude usa um login próprio e **não** renova esse item: se você só usa o app desktop, o token vence em algumas horas e o login inteiro vence em alguns dias.")
                    TroubleshootingStep(number: 1, text: "Rode o Claude Code no Terminal e mande qualquer mensagem:")
                    TerminalCommand(command: "claude")
                    TroubleshootingStep(number: 2, text: "Se ele pedir login, ou se a mensagem aqui disser que o login venceu, digite `/login` dentro do Claude Code.")
                    TroubleshootingStep(number: 3, text: "Volte e clique em Atualizar agora. Se o macOS pedir acesso ao Keychain, escolha \"Sempre permitir\".")
                    if planUsage.isEnabled {
                        Button("Atualizar agora") { planUsage.refresh(force: true) }
                    }
                }

                TroubleshootingCard(
                    symbol: "lock.rotation",
                    title: "O macOS pede acesso ao Keychain de novo"
                ) {
                    Text("É esperado. Quando o Claude Code regrava o login (por exemplo depois de um `/login`), o macOS recria o item no Keychain e descarta as autorizações anteriores, incluindo o \"Sempre permitir\" do TokenBar.")
                    TroubleshootingStep(number: 1, text: "Escolha \"Sempre permitir\" no pedido. \"Permitir\" vale só uma vez, e o pedido volta a cada leitura (a cada 3 min).")
                    TroubleshootingStep(number: 2, text: "Se você clicou em Negar, clique em Atualizar agora para o pedido aparecer outra vez.")
                }

                TroubleshootingCard(
                    symbol: "tray",
                    title: "O uso de hoje não aparece ou uma fonte parou",
                    expanded: localSources.all.contains { $0.needsAttention }
                ) {
                    Text("O Claude Code e o Codex são lidos dos logs em `~/.claude/projects` e `~/.codex/sessions`, que valem para o terminal, o VS Code e o app desktop. Isso não depende de login.")
                    TroubleshootingStep(number: 1, text: "Confira o estado da fonte no alto desta página. \"Não encontrado nesta máquina\" quer dizer que a pasta não existe: a ferramenta ainda não foi usada neste Mac.")
                    TroubleshootingStep(number: 2, text: "Em Ajustes → Ferramentas locais, clique em Atualizar agora. Se os números continuarem errados, use Reimportar histórico.")
                    Button("Abrir Ajustes") { navigation.section = .settings }
                }

                TroubleshootingCard(
                    symbol: "point.3.connected.trianglepath.dotted",
                    title: "O uso do Ollama ou do Gemini não aparece"
                ) {
                    Text("O Ollama e o Gemini só são medidos pelo proxy local: chamadas que não passam por ele não são contadas.")
                    TroubleshootingStep(number: 1, text: "Em Ajustes → Proxy local, ligue o proxy e confira se ele está escutando.")
                    TroubleshootingStep(number: 2, text: "Aponte seus apps para o proxy. No terminal, antes de usar o ollama:")
                    TerminalCommand(command: "export OLLAMA_HOST=127.0.0.1:\(proxy.port)")
                    TroubleshootingStep(number: 3, text: "No Gemini, use o endereço base do proxy no SDK:")
                    TerminalCommand(command: "http://127.0.0.1:\(proxy.port)/gemini")
                }

                TroubleshootingCard(
                    symbol: "arrow.up.right.square",
                    title: "Nada disso resolveu"
                ) {
                    Text("Abra uma issue com o que aparece no alto desta página. Não inclua tokens, chaves nem conteúdo de conversas.")
                    Link(destination: URL(string: "https://github.com/GutuGaluppo/tokenbar/issues")!) {
                        Text(verbatim: "github.com/GutuGaluppo/tokenbar/issues")
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Estado atual")
                .font(.title3.weight(.semibold))
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Plano Claude (Pro/Max)").font(.callout)
                        PlanUsageStatusRow()
                    }
                    Divider()
                    ForEach(localSources.all) { source in
                        LocalSourceStatusRow(source: source)
                    }
                    if proxy.isEnabled {
                        Divider()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Proxy local").font(.callout)
                            ProxyStatusRow()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
        }
    }
}

extension ClaudePlanUsage {
    var needsAttention: Bool {
        switch phase {
        case .needsLogin, .failed: true
        default: false
        }
    }
}

private extension LocalLogSource {
    var needsAttention: Bool {
        if case .failed = phase { return true }
        return false
    }
}

/// Um problema conhecido: título, explicação e passos. Abre sozinho quando o problema está acontecendo.
struct TroubleshootingCard<Content: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    @ViewBuilder let content: Content
    @State private var isExpanded: Bool

    init(symbol: String, title: LocalizedStringKey, expanded: Bool = false, @ViewBuilder content: () -> Content) {
        self.symbol = symbol
        self.title = title
        self.content = content()
        _isExpanded = State(initialValue: expanded)
    }

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    content
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            } label: {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { isExpanded.toggle() } }
            }
            .padding(6)
        }
    }
}

struct TroubleshootingStep: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(text)
        }
    }
}

/// Comando para copiar e colar no Terminal.
private struct TerminalCommand: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(verbatim: command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Spacer()
            Button(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(copied ? "Copiado" : "Copiar")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}
