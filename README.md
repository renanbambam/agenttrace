# AgentTrace

**An autonomous diagnostic agent that runs inside a Salesforce org.** You describe a technical
incident in plain language. The agent decides on its own what to investigate, opens the actual Apex
source, proves the cause by writing and running a test live, confirms the blast radius against real
data, and proposes a fix — which is applied only if you authorize it. When the problem is genuinely
out of its reach (an external network or proxy failure), it says so instead of inventing a cause.
All of its reasoning appears live, step by step, as if it were sharing its screen.

Built on **Salesforce (Apex + LWC)** and the **Claude API** with native function calling, in a real
Developer Edition org.

---

## What it does

| Incident | What the agent does |
|---|---|
| Wrong discount applied on R$100 orders | lists classes → opens the source → **writes and runs a test** that proves the bug → proposes the `>` → `>=` fix (you authorize → it **validates** the fix live) |
| Payment integration stopped working | inspects the class → **fires a live connection probe** → `Unauthorized endpoint` → locates it as org configuration, not code |
| Nightly sync stopped | **reads the debug logs** → recurring `407 Proxy` / timeout → concludes honestly: "this is external, outside my reach" — and proposes no fix |
| "How big is the damage?" | crosses **code → schema → real data** (`SELECT COUNT()`) → confirms **12 affected orders** → translates it into business impact |

Ask it for personal data and the **privacy guard** refuses, offering an aggregate count instead.

---

## How it works

```
[LWC board] → InvestigationController.start
                      │
                      ▼  enqueue once
   ┌──────────────────────────────────────────────────────────────┐
   │  InvestigationOrchestrator  —  ONE Queueable transaction      │
   │                                                              │
   │   ┌──▶ ClaudeService ──────────▶ Claude API                  │
   │   │        ▲                        │                        │
   │   │        │  tool_result           │  tool_use              │
   │   │        │                        ▼                        │
   │   │    execute the TOOL (source · data · integration · logs) │
   │   │        │                                                 │
   │   │        └── publish Investigation_Step__e                 │
   │   │              (publishBehavior = PublishImmediately)      │
   │   └──── loop, up to 8 iterations, until `concluir`           │
   └──────────────────────────────────────────────────────────────┘
                      │
                      ▼  empApi subscription
             [LWC board reacts LIVE, step by step]
```

- **Reasoning loop on native `tool_use`** (Anthropic function calling): the model picks a tool, Apex
  executes it and returns the `tool_result`, and the conversation continues until the model calls
  `concluir`.
- **13 tools** the agent selects between adaptively: inspect / test / search source, probe an
  integration, query data (SOQL), read schema, read debug logs, check failed jobs, recent config
  changes, automations and org limits.
- **Reading and running real Apex** goes through the Tooling API over a Named Credential — SOQL
  against `ApexClass` for source, `executeAnonymous` for the live, throwaway verification.
- **Action requires permission**: the agent proposes and *proves* a fix; applying it is a human
  decision, and authorizing runs `FixValidator` against the change before `CodeDeployer` ships it.
- **Every investigation is recorded** as an `Investigacao__c` — root cause, tools used, steps,
  duration, tokens and cost.

### The constraint worth reading about

The loop first ran as a **chain of Queueable jobs**, one per reasoning step. Developer Edition caps
a Queueable chain at five levels, so any investigation deeper than five steps died at the sixth with
`System.LimitException: Maximum stack depth has been reached` and never concluded.

Rewriting it as a loop inside a **single transaction** removed the limit and ran roughly 3× faster —
but it broke the live UI, because a platform event published the normal way is only delivered after
its transaction commits, and this transaction now stayed open for the whole investigation. The fix
is `publishBehavior = PublishImmediately`, the one publish mode that escapes an uncommitted
transaction. One transaction, every step still streamed live.

## Safety

- **The API key lives in the vault** (External / Named Credential) — Apex never sees it.
- **Deterministic privacy guard** — refuses any SOQL touching PII fields and answers with an
  aggregate instead. It is a hard-coded token check, not a model instruction, so it cannot be
  prompted away.
- **Read-only by default** — `testar_codigo` never performs DML; the integration probe is GET only.

## Quality

- **52 Apex test methods across 12 test classes**, ~88% coverage.
- **Eval harness:** `sf apex run --file scripts/apex/eval.apex` runs the agent against known
  scenarios and returns a score (**5/5**) — systematic verification rather than a one-off demo.

## Architecture decisions

The decisions behind this design, with the alternatives rejected and why, are recorded in
[DECISIONS.md](DECISIONS.md).

## Running it

Requires a Salesforce org with the Tooling API reachable through a Named Credential, and an
Anthropic API key stored in the `Anthropic` External Credential.

```
sf org login web --alias agenttrace
sf project deploy start --target-org agenttrace
sf apex run --file scripts/apex/seed-demo.apex --target-org agenttrace
```

Then open the **AgentTrace** app and describe an incident.

---

*Portfolio project, built solo and iterated against a real org.*
