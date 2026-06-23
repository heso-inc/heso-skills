# Recorder + Gate — the two capture surfaces

HESO's customer-side capture is **two surfaces, not one**, with different blocking
semantics. Do not conflate them:

| | **RECORDER** | **GATE** |
| --- | --- | --- |
| Hot path | **off it** — async, fire-and-forget | **on it** — the one thing that blocks |
| Job | observe every agent step; fingerprint → sign → append off-thread | intercept the *egress* call, classify-by-effect, redact, sign the commitment, forward or fail closed |
| Shape | an OpenTelemetry GenAI-semconv consumer (`BatchSpanProcessor` + pluggable exporter) | an HTTP-client shim *inside* the SDK (mitmproxy interception shape — no proxy, no MITM CA) |
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

**Architecture.** A custom `BatchSpanProcessor` (background-thread flush) → a
pluggable exporter that does the kernel work (fingerprint → sign → append)
off-thread. Registration (`add_trace_processor`-shape) hooks frameworks
**without forking them** — the HESO recorder registers as an *extra* processor on
the host's existing OTel provider.

**The framework adapters are recorder hooks.** The eight Python adapters
(`langchain`, `langgraph`, `crewai`, `claude_agent`, `openai_agents`,
`pydantic_ai`, `mcp`, `mcp_proxy`) are reframed: each adapter's job is to *emit
OTel GenAI spans into the recorder*, not to drive a synchronous gate. "Register a
processor, don't fork the framework." For the lazy-namespace surface in code see
[python.md](python.md).

## GATE — egress interceptor, fail-closed

The gate is the **synchronous** surface — the only thing that blocks. It learns
mitmproxy's `request()` / `response()` interception shape and replicates it
**inside the SDK's HTTP-client shim** — it does **not** ship mitmproxy (a
TLS-intercepting proxy is operationally heavy and needs a MITM CA, which is hostile
to customer-side key custody). The sequence on an outbound call:

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

## `heso-mcp` — gate-is-the-capture, concretely

`heso-mcp` is the gate in its most concrete form: govern an agent you don't want
to touch by pointing any MCP client (Claude Desktop, Cursor, VS Code) at the
proxy instead of the real stdio server. It spawns the real server after `--`,
forwards every message verbatim, and intercepts only `tools/call` — running each
through the same gate **before** it reaches the server.

```bash
heso-mcp --project-root ~/agent -- npx -y @some/mcp-server --its --own --flags
```

- **allowed** → the request is forwarded untouched; a signed commitment is
  produced and the server's result binds back as a follow-up.
- **blocked / suspended** → the request is **never forwarded**; the client gets a
  proper MCP tool result with `isError: true` carrying the actionable reason (the
  responsible rule for a block; the `action_hash` to approve for a suspension).
- an engine fault **fails closed** — the call is refused, never forwarded ungated.
- `--observe` is mirror-only (capture + sign, never refuse) — the per-deploy
  **Shadow Mode** of the gate.

Everything that isn't a `tools/call` (`initialize`, `tools/list`, notifications,
server stderr) passes through byte-for-byte, so the proxy is invisible to both
sides. This is the cleanest demonstration that the egress interception point *is*
the witnessing point.

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
