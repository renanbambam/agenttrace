# AgentTrace

**Um agente de diagnóstico autônomo para orgs Salesforce.** Você descreve um incidente técnico em linguagem natural; o agente **decide sozinho** o que investigar, **abre o código real**, **prova a causa executando um teste ao vivo**, **confirma o impacto nos dados** — e **propõe a correção**, que só é aplicada com a sua autorização. Quando o problema está fora do alcance dele (rede/proxy externo), ele diz isso com honestidade em vez de inventar. Todo o raciocínio aparece **ao vivo, passo a passo**, como uma tela compartilhada.

Construído sobre **Salesforce (Apex + LWC)** e a **Claude API** (function calling nativo), num org de desenvolvedor real.

---

## O que ele faz (4 cenários de demo)

| Incidente | O que o agente faz |
|---|---|
| Desconto errado em pedidos de R$100 | lista classes → abre o código → **escreve e roda um teste** que prova o bug → propõe a correção `>` → `>=` (você autoriza → ele **valida** a correção ao vivo) |
| Integração de pagamento caiu | inspeciona a classe → **dispara uma sonda de conexão ao vivo** → `Unauthorized endpoint` → localiza como config no org |
| Sincronização noturna parou | **lê os logs** → `407 Proxy`/timeout recorrente → conclui honesto: "é externo, fora do meu alcance" (sem inventar correção) |
| "Qual o tamanho do estrago?" | cruza **código → schema → dados reais** (`SELECT COUNT()`) → confirma **12 pedidos afetados** + traduz em **impacto de negócio** |

E se você pedir dados pessoais, a **guarda de privacidade** recusa e oferece uma contagem agregada.

---

## Como funciona (arquitetura)

```
[Tela LWC] → InvestigationController.start → [Queueable: InvestigationOrchestrator]  ← o LOOP
                                                    |            ^
                          (tool_use nativo)  chama  |            | (tool_result)
                                                    v            |
                                            [ClaudeService] → Claude API
                                                    |
                       executa a FERRAMENTA (código / dados / integração / logs / ...)
                                                    |
                            publica um Platform Event por passo (PublishImmediately)
                                                    ↓
                                   [Tela reage AO VIVO — empApi]
```

- **Loop de raciocínio com tool_use nativo** (function calling da Anthropic): a Claude escolhe uma ferramenta, o Apex executa e devolve o `tool_result`, e a conversa segue até ela chamar `concluir`.
- **13 capacidades** que o agente escolhe adaptativamente: inspecionar/testar/buscar código, sondar integração, consultar dados (SOQL), schema, debug logs, jobs, config, automações, limites.
- **Roda numa transação só** (contorna o limite de 5 níveis de Queueable do Dev Edition) e **transmite ao vivo** via Platform Events `PublishImmediately`.
- **Ação com permissão**: o agente propõe e **prova** a correção; aplicar é decisão humana.
- **Sistema de registro**: cada investigação vira um `Investigacao__c` (causa, capacidades, passos, duração, tokens, custo).

## Segurança e responsabilidade

- **Chave da API no cofre** (External/Named Credential) — o código Apex nunca a enxerga.
- **Guarda de privacidade determinística** — recusa qualquer SOQL que toque em PII; usa contagem/agregado.
- **Só leitura por padrão** — testar código é sem DML; a sonda de integração é só GET.

## Qualidade

- **41 testes Apex, ~88% de cobertura.**
- **Harness de avaliação (evals):** `sf apex run --file scripts/apex/eval.apex` roda o agente contra cenários conhecidos e devolve um placar (**5/5**) — verificação sistemática, não anedota.

---

## Como isto mapeia "AI Builder"

Tool calls + reasoning model + ação real, com guardrails, avaliação e consciência de custo — o formato de um sistema de IA de produção, num domínio focado e totalmente dominável.

*Projeto de portfólio, construído solo e iterado num org real. Documentação de arquitetura e decisões em `ARQUITETURA.md` e `DECISOES.md`.*
