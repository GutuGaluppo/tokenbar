# Política de privacidade do TokenBar

*Vigente desde 24 de setembro de 2026.*

O TokenBar funciona inteiramente no seu Mac. Não há conta, servidor do TokenBar, telemetria, análise de uso nem anúncios.

## O que o app lê

| Fonte | O que é lido | O que é guardado |
| --- | --- | --- |
| Logs do Claude Code (`~/.claude/projects`) | Os arquivos de sessão, linha a linha. Eles contêm as conversas, mas o app só interpreta os campos de consumo. | Contagens de tokens, custo calculado, modelo, horário, nome da pasta do projeto, ferramenta e identificador da sessão. **Nenhum texto de conversa.** |
| Logs do Codex (`~/.codex/sessions`) | Idem. | Idem, mais os percentuais de limite do plano gravados pelo Codex. |
| Plano Claude (opcional, desligado por padrão) | O token de login que o Claude Code guarda no Keychain, somente leitura. | Os percentuais de uso do plano e os horários de reinício. O token não é copiado nem renovado. |
| APIs de uso da Anthropic e da OpenAI (opcional) | Relatórios de uso da organização, com a chave de admin que você informar. | Contagens agregadas por hora e modelo, e custo. |

## O que fica no seu Mac

- Banco de dados de uso e cursores de leitura: `~/Library/Application Support/TokenBar`
- Chaves de API que você conectar: Keychain do macOS
- Preferências (limites, opções da barra de menus): `~/Library/Preferences/dev.galuppo.TokenBar.plist`
- Resumo para o widget: `~/Library/Group Containers/<Team ID>.dev.galuppo.TokenBar`

## Conexões de rede

O app só se conecta a:

- `raw.githubusercontent.com`, uma vez por dia, para baixar a tabela de preços pública deste repositório. Nada seu é enviado; como em qualquer acesso web, o GitHub vê o endereço IP e a versão do app.
- `api.anthropic.com`, se você ativar a leitura do plano Claude ou conectar a API Anthropic, para ler os dados de uso da própria conta.
- `api.openai.com`, se você conectar a API OpenAI, idem.

Nenhum dado de uso sai do seu Mac para o TokenBar ou para terceiros.

## Como apagar tudo

1. Encerre o TokenBar e apague `/Applications/TokenBar.app`.
2. Apague as pastas `~/Library/Application Support/TokenBar` e `~/Library/Group Containers/<Team ID>.dev.galuppo.TokenBar`.
3. Rode `defaults delete dev.galuppo.TokenBar`.
4. No app Acesso às Chaves, apague os itens do serviço `dev.galuppo.TokenBar`, se tiver conectado APIs.

Os logs do Claude Code e do Codex pertencem a essas ferramentas e não são alterados pelo TokenBar.

## Contato

Dúvidas ou problemas: abra uma issue em [github.com/GutuGaluppo/tokenbar](https://github.com/GutuGaluppo/tokenbar/issues).
