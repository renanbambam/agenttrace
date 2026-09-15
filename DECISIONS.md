# Architecture decisions — AgentTrace

Each entry records what I decided, why, and why not the alternatives. Where a later decision
reverses an earlier one, the earlier entry stays and the reversal is recorded explicitly — the log
is the history, not a summary of the current state.

---

## 2026-08-13 — How Apex reads source and runs code at runtime

**Context.** The agent's flagship capability is opening the real Apex source of a suspect class and
proving a hypothesis by executing something against it. Neither is possible with ordinary Apex.

**Decision.** Both go through the **Tooling API**, reached over a Named Credential with an OAuth
client-credentials flow:

- reading source — SOQL against `ApexClass.Body`, which Apex can query natively;
- live verification — an `executeAnonymous` callout, run and discarded, never deployed.

**Why.** The verification has to be throwaway. A real Apex test class would have to be deployed to
the org, would sit in the repository afterwards, and would go through the platform's asynchronous
test queue — slow and unpredictable during a live investigation. `executeAnonymous` runs now,
returns a real result, and leaves nothing behind.

**Why not the alternatives.** Deploying a generated test class means a metadata deploy per
hypothesis, which is both slow and a permanent mutation of the org for a throwaway check. Static
analysis of the source alone would let the agent *claim* a cause without proving it, which is the
opposite of the point.

---

## 2026-08-15 — How the model returns its next step *(superseded 2026-08-21)*

**Decision.** The model returns a structured JSON object naming the next capability and its
arguments, which Apex parses and dispatches on.

**Why.** It works with any model and keeps parsing under my control, with no dependency on a
provider-specific calling convention.

**Superseded by the 2026-08-21 entry below.**

---

## 2026-08-21 — Reasoning loop moved to native `tool_use`

**Context.** The hand-rolled JSON protocol worked, but every malformed response became my parsing
problem, and multi-step argument passing had to be re-invented by hand.

**Decision.** The loop uses Anthropic's **native function calling**. Tools are declared with JSON
schemas, the model emits a `tool_use` block, Apex executes the capability and appends a
`tool_result` block to the message array, and the conversation continues until the model calls the
`concluir` tool.

**Why.** The model is constrained by the tool schema instead of asked politely to produce valid
JSON, so malformed calls largely stop happening. The message array becomes the conversation state —
the full reasoning trace is the transcript, which is also exactly what needs to be shown on screen.

**Why not keep the custom protocol.** Portability across providers was the argument for it, and it
was not worth the cost: I was maintaining a parser and a retry path to approximate something the
API already guarantees.

---

## 2026-08-20 — Privacy as a hard boundary, not a prompt instruction

**Context.** The agent has deliberately wide reach — 13 capabilities spanning source, data,
integrations, runtime logs, automations, limits, jobs and configuration. Wide reach over an org's
data needs an explicit boundary, not an implicit one.

**Decision.** `consultar_dados` refuses any SOQL touching PII. The guard is **double**: the system
prompt directs the agent toward `COUNT()` and aggregates ("how many", never "who"), and a
deterministic denylist in Apex (`PII_TOKENS` — email, phone, cpf, rg, birthdate, address and so on)
rejects the query regardless of what the model asked for.

**Why.** A prompt is guidance, not a guarantee. The Apex check turns "the model should not" into
"the system will not", which is the only version that survives a security review. Verified against
the org: an explicit request for customer emails was refused, explained as PII, and answered with
an aggregate count instead.

**Why not prompt-only.** One prompt injection, or one model slip, and there is nothing between the
request and the data.

---

## 2026-08-18 — Authorizing a fix validates it live

**Context.** An agent that proposes a fix is only half a loop. The proposal is a claim until
something checks it.

**Decision.** Authorizing a proposed fix runs `FixValidator`, which applies the change in a
throwaway execution and re-runs the failing verification against it before anything is written.

**Why.** It closes the evidence loop: the agent proved the bug by running a test, and now proves
the fix by running the same test against the corrected code. The human still authorizes; what they
authorize is a validated change rather than a suggestion.

---

## 2026-08-21 — Applying the fix actually deploys it

**Decision.** After validation passes, `CodeDeployer` performs a real metadata deploy of the
corrected class.

**Why.** Stopping at "validated but not applied" leaves the most interesting half of the problem
untouched. The safety comes from the gate, not from refusing to act: only code the project owns is
targeted, validation must pass first, and a human has to authorize.

**Why not automatic application.** The cost of a wrong diagnosis is a conversation; the cost of a
wrong automatic deploy is a production change nobody asked for. Autonomy is sized by the cost of
the error.

---

## 2026-08-27 — The reasoning loop runs in a single transaction *(reverses the chained-async design of 2026-08-15)*

**Context.** The original design ran the loop as a **Queueable that re-enqueued itself**, one
asynchronous transaction per reasoning step.

**What changed.** `InvestigationOrchestrator.execute()` now runs all of its (up to 8) iterations —
reason → execute capability → return `tool_result` — inside **one Queueable transaction**. There is
no per-step re-enqueue.

**Why it changed.** Developer Edition caps a Queueable chain at five levels. Any investigation
deeper than five steps failed at the sixth with `System.LimitException: Maximum stack depth has
been reached` and never reached a conclusion. A single transaction removes the ceiling entirely and
runs about 3× faster.

**The consequence, stated honestly.** The old justification — "each event comes from a separate
async job, so it is genuinely streamed" — no longer holds. Liveness now comes from the platform
event `Investigation_Step__e` published with `publishBehavior = PublishImmediately`, the one publish
mode delivered before its transaction commits. It is still one event per step arriving in real
time; the mechanism is immediate publication, not spaced-out async jobs.

---

## 2026-08-25 — The investigation map uses a deterministic layout

**Context.** The centre of the UI is a live map: one node per capability, lighting up when chosen,
greying out when ruled out, converging on the cause.

**Decision.** Fixed columns with calculated positions — symptom on the left, capabilities in the
middle one per row, cause on the right. Explicitly **not** a force-directed graph.

**Why.** A physics-driven graph re-positions itself as nodes arrive, and can overlap or visibly
thrash at exactly the moment someone is watching it. Deterministic positioning cannot.
