# Recorder + Gate — the two capture surfaces

HESO's customer-side capture is **two surfaces, not one**, with different blocking
semantics. Do not conflate them:

| | **RECORDER** | **GATE** |
| --- | --- | --- |
| Hot path | **off it** — async, fire-and-forget | **on it** — the one thing that blocks |
| Job | observe every agent step; fingerprint → sign → append off-thread | intercept the *egress* call, classify-by-effect, redact, sign the commitment, forward or fail closed |
| Shape | an OpenTelemetry GenAI-semconv consumer on the OpenAI-Agents-SDK `TracingProcessor` pattern (custom batched processor + pluggable exporter) | an HTTP-client shim *inside* the SDK (mitmproxy interception shape — no proxy, no MITM CA) |
| Failure mode | never crashes the agent (swallows, logs) | **fail-closed** — blocks the call if it can't classify/sign |

The phrase **"gate-is-the-capture"** applies *only* to the gate: the egress
interception point **is** the signing point for destructive actions — there is no
separate "now record it" step that could be skipped or lag. The recorder is
best-effort observability that feeds the same kernel but **must never couple agent
latency to HESO latency.**

## Two pillars (true of both surfaces)

These are canonical here; the rest of the skill cross-links to them rather than
restating them.

- **Keys held customer-side.** Signing delegates to the native addon / wheel
  loaded from the customer keystore. **HESO never holds a minting key** — not in
  the recorder, not in the gate, not in the cloud (which only verifies signatures
  and relays detached co-signatures). This is what lets the open SDK and the open
  verifier exist without trusting HESO.
- **Redact-before-sign.** Redaction (commit-and-reveal) happens **before** the
  commitment is signed, so raw content never enters the commitment and the
  customer-held sidecar is the only place the value lives. This is a kernel
  primitive, not a footnote — see the `redaction` record in
  [receipts.md](receipts.md).

## RECORDER — async, off the hot path

The recorder does not invent a span model. It **consumes the OpenTelemetry GenAI
semantic conventions**, so any already-instrumented agent (LangChain, CrewAI,
OpenAI SDK, Pydantic AI) feeds HESO for free. The input contract:

- **Switch on `gen_ai.operation.name`** — the fixed enum `{ chat, create_agent,
  invoke_agent, execute_tool, generate_content, embeddings, retrieval,
  invoke_workflow, text_completion }`. This coarse selector picks which lane an
  event is in.
- For **`execute_tool`** spans (the natural effect-classification hook) read
  `gen_ai.tool.name` (stable id), `gen_ai.tool.call.id`, `gen_ai.tool.type`, and —
  opt-in — `gen_ai.tool.call.arguments` / `.result`. `gen_ai.tool.name` is the
  **fine label** the [taxonomy](taxonomy.md) classifies **by effect, not by name.**
- Agent/model context: `gen_ai.agent.name`/`.id`, `gen_ai.provider.name`,
  `gen_ai.request.model`.

> In 2026 these keys moved to the `open-telemetry/semantic-conventions-genai`
> repo (old pages are redirect stubs). **Pin a semconv version** in the SDK and
> gate against it in CI.

**Architecture.** A custom **batched processor** on the OpenAI-Agents-SDK
`TracingProcessor` pattern (background-thread flush, *not* OTel's own
`BatchSpanProcessor`) → a pluggable exporter that does the kernel work
(fingerprint → sign → append) off-thread. `Recorder.record(span)` enqueues and
**returns immediately** — it never blocks, signs, or relays on the agent's path.
A full queue **drops the oldest span** (back-pressure, never block), and any
exporter error is **swallowed and counted** (`RecorderStats.dropped` / `.errors`),
so a slow or failing exporter can never stall or crash the agent. Anything that
*must* be witnessed goes through the gate, not the recorder.

Registration uses `add_trace_processor(Recorder())` — the OpenAI-Agents-SDK
`add_trace_processor` shape, *additive* so it never steals the host's existing OTel
export. This hooks frameworks **without forking them**: the HESO recorder registers
as an *extra* processor alongside whatever the host already runs.

**The framework adapters are recorder hooks.** The eight Python adapters
(`langchain`, `langgraph`, `crewai`, `claude_agent`, `openai_agents`,
`pydantic_ai`, `mcp`, `mcp_proxy`) are reframed: each adapter's job is to *emit
OTel GenAI spans into the recorder*, not to drive a synchronous gate. "Register a
processor, don't fork the framework." For the lazy-namespace surface in code see
[python.md](python.md).

## GATE — egress interceptor, fail-closed

The gate is the **synchronous** surface — the only thing that blocks. It learns
mitmproxy's `request()` interception shape and replicates it **inside the SDK's
HTTP-client shim** — it does **not** ship mitmproxy (a TLS-intercepting proxy is
operationally heavy and needs a MITM CA, which is hostile to customer-side key
custody). The sequence on an outbound call:

1. **Intercept** the outbound request before it leaves the process.
2. **Classify-by-effect** via the kernel [taxonomy](taxonomy.md) → a destructive
   primitive (`move-value` / `destroy` / `change-authority` / `disclose` /
   `execute`). Structural, deterministic, deny-unknown (a `residual` fails closed).
3. **Redact-before-sign** — commit-and-reveal so raw content never enters the
   commitment.
4. **Sign the commitment** with the customer-side key (kernel signer).
5. **Forward or fail closed** — if policy denies, or if classification/signing
   cannot complete, the call **does not leave.** Fail-closed is the default, not
   an error path.

**Policy at the gate.** Classification feeds the kernel policy engine (native
first-match-wins) — this is where `default-deny` and the pinned floors bite. See
[policy.md](policy.md).

### Installing the gate — one global line on BOTH runtimes

The shim is the same idea on both runtimes and the install is **one process-wide
call** on each — not a per-client tax:

- **JavaScript (`@hesohq/gate`)** — `installGate()` arms **every** egress transport
  the SDK can reach (undici global dispatcher, `node:http`/`node:https`,
  `globalThis.fetch`, `child_process`) and runs the no-standing-key assert last:

  ```ts
  import { installGate } from '@hesohq/gate'

  installGate() // every reachable egress transport now gated, fail-closed; standing-key assert ran
  ```

  `undici` is an **optional peer dependency** loaded lazily — importing
  `@hesohq/gate` in a non-undici runtime does not throw; `installGate()` does if
  `undici` is missing. (The lower-level `hesoGate()` undici interceptor still
  exists for a host that composes its own dispatcher.)

- **Python (`heso_gate`)** — `install_gate()` is the matching one-liner: it
  auto-instruments the available clients (httpx / requests / urllib3 / aiohttp)
  process-wide and runs the no-standing-key assert first:

  ```python
  from heso_gate import install_gate

  install_gate() # httpx/requests/urllib3/aiohttp auto-instrumented; standing-key assert ran first
  ```

  Per-client shims (`HesoGateTransport` / `HesoGateAsyncTransport` on an
  `httpx.Client`, `HesoGateAdapter` mounted on a `requests.Session`) remain as a
  **fallback** for a client `install_gate()` cannot reach — not the default path.

**The floor minting is decoupled from the in-process shim.** The credential floor
mints **per kernel-classified destructive action** at the credential boundary —
transport-independent, not tied to whether a particular HTTP client got the
in-process shim. Un-mediated transports the shim never saw are therefore
**provably-flagged-after-the-fact on asymmetric rails only** (CloudTrail / PayPal,
which third parties can verify offline); **HMAC rails** (Stripe / GitHub / Slack)
degrade to **trust-the-rail** — there is no in-band proof for them, only the rail's
own ledger. The self-check below names exactly which transports are mediated and
which are not, so this gap is visible rather than hand-waved away.

### Startup self-check (escalates loudly)

Both SDKs ship a self-check that reports the **actual** install state per transport
and **escalates** every un-armed transport and every reachable standing key. It does
not return a quiet warnings array a host can ignore — an un-armed transport is
reported as un-armed, full stop, and the throw-variant refuses to boot ungated.

- **Python** — `self_check()` returns a `SelfCheckReport`. `.gated` names the
  **mediated** (auto-instrumented) clients; `.uncoverable` names the transports the
  gate **cannot** see at all (raw `socket`, `subprocess`); `.escalations` aggregates
  every un-mediated/uncoverable surface plus every reachable standing key, and
  `.ok` is true only when `.escalations` is empty. `self_check(raise_on_gap=True)`
  raises `SelfCheckGapError`. The per-client `check_httpx_client(client)` /
  `check_requests_session(session)` still exist for the fallback shims.
- **JavaScript** — `selfCheck()` returns a `SelfCheckResult` with per-transport
  booleans (`undiciGated`, `nodeHttpGated`, `fetchGated`, `childProcessGated`),
  `uncoveredTransports` (the honest gap), `standingKeys`, and `escalations`. `ok`
  is true only when every transport is armed and no FAIL-severity standing key is
  reachable. `selfCheckOrThrow()` throws and lists the escalations — the startup
  assert that refuses to boot ungated.

### Startup standing-key check (fails closed)

`install_gate()` / `installGate()` run a no-standing-key assert as part of install —
**fail-closed by default.** If a broad standing rail key (`sk_live_*`,
long-lived `AKIA*`, `ghp_*`, `xoxb-*`) is reachable in the environment, install
**throws** (`StandingKeyError` / Python `StandingKeyError`) before any shim arms,
because a standing key the floor cannot bound defeats the floor's whole guarantee.

- The detector **never logs or returns the secret value** — only the env-var name,
  the rail, a fixed marker-derived redacted shape (e.g. `sk_live_***`, never a byte
  of the secret body), and the severity (`fail` / `warn`).
- Override is **explicit and deliberate**: JS `installGate({ allowStandingKeys: true
  | string[] })` or `HESO_ALLOW_STANDING_KEYS`; Python
  `install_gate(strict_standing_key=False)`.

### The fail-closed error taxonomy

A thrown error of **any** kind is a fail-closed refusal — the wrapped call never fires.
The SDK throws **typed** errors so a caller can branch on *why* it refused. The
JavaScript surface (`@hesohq/gate`, every class `extends Error`) is the full set:

- **`BlockedError`** — refused by policy. Carries `toolName`, `ruleId`, `reason`. The
  normal "the rule said no" refusal.
- **`SuspendedError`** — gated to a human and awaiting approval; thrown so it never fires.
  Carries `toolName` and the `actionHash` the approver decides against.
- **`ApprovalRejectedError`** — a human resolved the approval as anything other than
  `approved` (`rejected` / `escalated`). Thrown by finalize **before** any assemble — a
  non-approval **never** mints an L1. Carries `actionHash` and the resolved `decision`.
- **`OperatorKeyMismatchError`** — the operator key loaded from the keystore does **not**
  match the suspended body's `agent_identity` (the key rotated). The in-core assemble
  fails closed rather than mint a receipt the verifier would reject; re-suspend under the
  new key. Carries `actionHash`, `expectedAgentIdentity`, `loadedPublicKey`.

**Python maps the same intent onto its own hierarchy** (it does not expose a named
`ApprovalRejectedError` class):

- `BlockedError` / `SuspendedError` live in `heso_engine` and subclass `RuntimeError`
  (`BlockedError` carries `tool_name` / `rule_id` / `reason`; `SuspendedError` carries
  `tool_name` / `action_hash` / `rule_id`).
- `OperatorKeyMismatchError` and `NoTransportError` live in `heso_gate` and subclass
  **`BridgeError`** — the distinct "the kernel itself failed / a relay primitive is
  missing" fail-closed signal, separate from a normal policy `BlockedError`.
- A rejected approval surfaces through the **`@gated` lifecycle**, not an exception: the
  `Gate` handle reports `denied` (a terminal decision) — see [python.md](python.md).

### The rail-boundary hard floor beneath the soft gate

The in-process gate is a **soft** gate (a compromised agent that bypasses the
shim could still reach a rail). Beneath it sits a **hard floor** at the credential
boundary — defense in depth, and the thing that makes [reconciliation](cloud.md)
meaningful:

- **`move-value`** → Stripe **restricted keys** (`rk_*`) — scoped per resource,
  **spend-capped.**
- **`destroy` / `change-authority`** → AWS **STS session policies** — scope-down,
  short TTL (≈15 min).
- *(optional, k8s)* → Cilium FQDN egress (eBPF) — deny-all egress except
  HESO-gated FQDNs (a coarse "where can traffic go" floor; it can't see into TLS
  to classify *effect*, so it complements the gate, never replaces it).

Credentials are provisioned by **federation** (a revocable role/trust
relationship; the gate federates in per-action for short-lived scoped credentials;
SPIFFE/SPIRE identity) — **no standing key handed to HESO.** Stripe (no
federation) falls back to customer-created capped restricted keys.

Because the floor forces every `move-value` through a capped key and every
`destroy` / `change-authority` through a scoped STS session, **anything in the
rail's own ledger (Stripe events, CloudTrail) without a matching signed commitment
is, by construction, an unwitnessed action** — the reconciliation alert. Without
the floor the diff is noise; with it the diff is the product (see
[cloud.md](cloud.md)).

### The 30-minute wall (a hard constraint on approvals)

The rail-boundary credentials are **short-lived** (STS ≈15-min TTL). A suspended
action waiting on human approval is racing that TTL: if the approver takes longer
than the credential lifetime, the finalize can no longer execute against a valid
rail credential — the action **fails closed and must be re-requested**, never
silently resumes on an expired session. The Slack approval card surfaces a live
countdown for exactly this reason (see [embeds.md](embeds.md)); quorum (k-of-n) is
harder under the wall because every co-signer must land inside one TTL window.

## MCP — the recorder observes; the egress gate enforces

MCP is split the same way the rest of the SDK is: the MCP **recorder** adapters
*observe* `tools/call` traffic, and the **synchronous enforcement** for those calls
rides the **egress gate**, not the MCP adapter. The recorder only watches and forwards.

The recorder gives you two shapes (`heso_recorder.adapters.mcp` / `.mcp_proxy`):

- **In-process** — `wrap_call_tool(handler)` wraps an MCP `call_tool(name, arguments)`
  handler so each `tools/call` **emits an `execute_tool` span** (the MCP `name` +
  `arguments`) into the recorder, then delegates to the real handler. Sync and async.
- **Out-of-process proxy** — `observe_call(frame)` emits a span for one parsed
  JSON-RPC `tools/call` frame (`params.name` / `params.arguments` / `id`). It is
  **non-blocking**: the proxy forwards the frame itself; the recorder only observes.

Because the recorder is observe-only, **anything that must be refused goes through the
egress gate** — the same fail-closed shim that gates every other outbound call. There
is no separate gating MCP binary that itself blocks `tools/call`; enforcement is the
egress gate's job. That keeps one enforcement lane (the gate) and one observability
lane (the recorder), instead of two places that could each block.

## Rollout discipline — Shadow Mode

Run the gate in **classify-and-sign-but-never-block** mode first, so a team can
measure what *would* be blocked before flipping fail-closed on. The deploy-wide
switch is Shadow Mode; its per-rule form is the rule `severity` (`allow` / `warn`
/ `deny`). The gate's effective enforcement is the **most-fail-closed of (deploy
mode, rule severity)** — deploy-wide shadow can soften a `deny` during onboarding;
it can never silently harden a `warn` into a block.

## Pointers

- Python capture surface (decorators, `wrap`, `step`, suspend/resume): [python.md](python.md)
- Node capture + verify + transport: [typescript.md](typescript.md)
- What the gate's commitment lands in: [cloud.md](cloud.md)
- The taxonomy the gate classifies against: [taxonomy.md](taxonomy.md)
- The approval surfaces (Slack card, web fallback): [embeds.md](embeds.md)
