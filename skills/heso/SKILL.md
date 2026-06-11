---
name: heso
description: >-
  Add HESO governance to an AI agent: gate every action against policy, sign it
  into a tamper-evident Action Receipt, route risky actions to a human approver,
  and verify receipts offline anywhere. Use when wiring HESO into a codebase,
  choosing between the heso / @hesohq/sdk / @hesohq/core / @hesohq/verify-wasm
  packages, authoring policy (importance bands, conditions, floors, simulate,
  deploy) or a heso.toml, gating tools/LLM clients, enforcing a trust level
  (L0/L1), redacting fields, handling approvals/suspend-resume, or verifying an
  Action Receipt and reading its verdict. Triggers on "gate the agent", "sign
  this action", "require approval", "verify a receipt", "trust level", "policy
  rule", "heso.toml", "Action Receipt", "redact".
metadata:
  version: 0.2.0
  homepage: https://heso.ca/docs
  source: heso-inc/heso-web
license: MIT
---

# HESO — govern, sign, and prove every agent action

HESO sits between your AI agent and the world. Every action — an LLM call, a
tool call, an HTTP request, a payment, a delete — runs through one pipeline:

```
capture → check against policy → decide (allow/block/redact/require_approval)
        → sign into an Action Receipt → hash-link into an audit chain
        → verify offline, anywhere, byte-for-byte
```

The crypto is a single Rust core compiled three ways — a Python wheel
(`heso._core`), a native Node addon (`@hesohq/core`), and a browser WASM module
(`@hesohq/verify-wasm`) — so a verdict is byte-identical whether it runs on your
server or in a reviewer's browser. Nobody re-implements canonicalization, BLAKE3,
or Ed25519 in JS or Python.

**The rule behind every design choice:** a receipt proves an action was
_authorized_ under a known policy — and at L1 that a human _approved_ it with a
device-held key. It does **not** prove the action _succeeded_ in the world. Never
write code, copy, or comments that claim more. Never synthesize governance
numbers (receipt/approval/block counts must be real or honestly empty).

All packages ship together at one version on public npm and PyPI
(`pip install heso`, `npm install @hesohq/sdk`) — check the registry for the
current release rather than trusting a number written here. Wire format:
`alg = "heso-action/v2+ed25519"`, `action_version = "heso-action/2.0"`.

## Pick the package first

One core, four surfaces. Choose by the job, not the language.

| Package | Runtime | Use it to |
| --- | --- | --- |
| `heso` | Python ≥ 3.10 | **Gate** an agent — capture, policy-check, sign, audit. The deepest capture surface (most adapters, suspend/resume). |
| `@hesohq/sdk` | Node ≥ 18 | **Gate** a Node agent (`init` + AI SDK / Mastra adapters) AND **verify** receipts + call the cloud control plane. Minting binds to `@hesohq/node`. |
| `@hesohq/core` | Node ≥ 18 (native) | Raw primitives `@hesohq/sdk` binds to (re-exports `@hesohq/node`): verify, sign/mint, BLAKE3 hashing, chain/transparency verify, redaction, Ed25519 keys. |
| `@hesohq/verify-wasm` | Browser | **Verify only**, client-side. No private key, no network. Also exposes in-browser policy parse/preview/floor-check. |

- "Gate my agent's actions" → **`heso`** (Python, deepest surface) or
  **`@hesohq/sdk`** (Node: `init()` + the AI SDK / Mastra adapters, or
  `engine.gate()` directly). Both capture, policy-check, sign, and audit
  in-process; minting on Node binds to the native `@hesohq/node` addon.
- "Trust a receipt from a Node service" → **`@hesohq/sdk`** (or raw `@hesohq/core`).
- "Show a user their receipt verifies, in the browser" → **`@hesohq/verify-wasm`**.
- Gate in Python or Node; verify anywhere — the verdict matches across every surface.

## The mental model (load before writing code)

- **Action** — one thing the agent did, typed by a **verb** (exactly seven):
  `llm_call`, `tool_call`, `http_request`, `payment`, `data_export`,
  `account_change`, `delete`. Policy and floors key off the verb.
- **Decision path** (exactly four): `allow`, `block`, `redact` (strip named
  fields, then allow), `require_approval` (route to a human).
- **Action Receipt** — the signed JSON record of one action: a signed `content`
  (the action detail, the policy outcome + plain-English `rule_display`, the
  claimed `trust_level`, the BLAKE3 `action_hash`) plus an Ed25519 `signatures`
  array. Full schema: [references/receipts.md](references/receipts.md).
- **Trust level** — `L0` = operator-signed. `L1` = operator **plus** at least one
  human approver's co-signature from a device-held key. There is no L2/L3. Trust is
  **re-derived on every verify** from the signatures that pass; a receipt
  claiming L1 with only an operator signature fails `TrustLevelMismatch`. **Never
  read `trust_level` off the wire — gate on a verified one.**
- **L1 has two shapes — both re-derive to L1, neither is higher.**
  - **Single-approver L1** — one human co-signs the *same* bytes the operator
    signed (the approver record is already embedded), so the operator vouches for
    the **whole** record, the approval included. Carried in `content.approver_decision`.
  - **Quorum L1 (k-of-n)** — e.g. 2-of-3. The operator signs an *emptied-approvers
    base* (just the action, the `threshold`, and the sorted `roster`); each approver
    separately signs only their own leg. Carried in a `content.multi_approval` block —
    that block (never the level) is how you tell quorum apart from single-approver L1.
    It is **not** a higher level and it is honestly **narrower** per approver: the
    operator vouches for the action + threshold + which keys are eligible, and for
    **nothing** about any individual approval's `reason` or `decided_at`. Do **not**
    frame quorum as "more assurance because more people signed."
- **Audit chain** — receipts BLAKE3 hash-linked; altering an earlier receipt
  breaks every link after it.
- **Trusted time** — **anchorless by default**: most receipts carry no trusted
  time and `verify` reports none. `content.captured_at` is the operator's own clock,
  **informational only** — never authoritative. An optional `content.time_anchor`
  (RFC-3161 TSA token) binds *when the assembled, post-approval body existed*
  (existed-no-later-than), **not** the instant a human decided — and an approver's
  `decided_at` is approver-claimed, never TSA-certified. When a policy marks time
  Required, an unanchored receipt fails the verifier with `AnchorRequired`.

## Gate an agent (Python)

Scaffold once, decorate the actions, init before the agent runs. Full surface
(suspend/resume, adapters, every kwarg): [references/python.md](references/python.md).

```bash
pip install heso        # or: uv add heso
heso init               # mints operator key, writes starter heso.toml, gitignores heso-local-data/
heso demo               # mint + verify your first receipts offline (no cloud, no policy edits)
```

`heso init` is zero-setup: when `HESO_KEY_PASSPHRASE` is unset it auto-generates a
**dev-only** passphrase (`heso-local-data/DEV-ONLY.passphrase`, 0600) so the
encrypted key unlocks with no env wrangling — `HESO_ENV=production` (or
`--require-passphrase`) refuses to generate one and demands a real passphrase.
The CLI is four commands: `init`, `demo`, `verify <path|hash>`, `show <hash>`.
Full detail: [references/cli-and-api.md](references/cli-and-api.md).

```python
import heso

heso.init()  # load active config once, before the agent runs

@heso.tool                       # captured as a tool_call action, gated, signed
def search(query: str) -> str:
    return web.search(query)     # body runs only if policy allows

@heso.destructive                # gated as a delete — rides a pinned floor
def delete_record(record_id: str) -> None:
    db.delete(record_id)

@heso.tool(redact=["api_key"])   # api_key commit-and-reveal redacted before signing
def call_partner_api(api_key: str, endpoint: str) -> dict:
    return requests.get(endpoint, headers={"Authorization": api_key}).json()
```

Non-negotiables:

- **`heso.init()` must run before the agent.** Import the generated
  `heso_bootstrap` at the top of your entrypoint, or call `heso.init()` first.
  Config resolves: explicit args → env (`HESO_*`) → `heso.toml` → defaults.
- **Blocking is the default.** A blocked action raises `BlockedError` *before*
  the body runs. Pass `blocking=False` for observe-only (shadow) mode: refused
  actions are still captured, signed, and audited, but don't raise.
- **`require_approval` raises `SuspendedError`.** The action pauses and an
  approval opens; the work resumes at L1 once a human co-signs. In Python the
  error is **actionable** — it carries `action_hash` + `rule_id` and its message
  prints the next step (the console approvals URL when one is configured, else
  the local `@heso.gated` + `heso.append_decision` dev path). See the
  suspend/resume API in [references/python.md](references/python.md).
- **Console approvals (how the co-sign actually happens).** A trusted, role-gated
  human approves the gated action in the web console and co-signs it **in the
  browser** with a per-device WebCrypto key. The thin cloud relays the detached
  co-signature and **holds no signing key**; the operator SDK re-mints the L1,
  locally re-verifies it (`Valid(L1)`), and pushes it. The **same** relay flow
  drives a k-of-n quorum — each approver co-signs their own leg in their own browser.
  When a suspension opens, the org can notify approvers out of band (Resend email +
  HMAC-signed org webhooks, configured manager-only on the **console session plane**
  at `GET/PUT /v1/org/notifications` — not the SDK's x-api-key plane).
- **Key rotation fails closed.** If the operator key rotates between suspend and
  finalize, the in-core assemble rejects the stale base (an `OperatorKeyMismatch`)
  and the SDK **re-suspends** the action under the new key — a fresh suspended L0
  with a new `action_hash` that the approval re-opens against. Never a silent mint
  under a stale key.
- **Gate a whole client with `heso.wrap()`** — gates `.create()` as `llm_call`,
  `.request()` as `http_request`, reaches nested attrs
  (`client.chat.completions.create(...)`), passes the rest through.
- **Adapters:** `heso.HesoCallbackHandler()` for LangChain/LangGraph; `heso.wrap()`
  for OpenAI/Anthropic; lazy namespaces `heso.crewai`, `heso.openai_agents`,
  `heso.claude_agent`, `heso.pydantic_ai`, `heso.langgraph`, `heso.mcp`.

## Gate an MCP server with zero code — `heso-mcp`

The fastest way to govern an agent you don't want to touch: point any MCP client
(Claude Desktop, Cursor, VS Code) at the `heso-mcp` proxy instead of the real
stdio server. It spawns the real server after `--`, forwards every message
verbatim, and intercepts only `tools/call` — running each through the same gate
as the decorators **before** it reaches the server.

```bash
heso-mcp --project-root ~/agent -- npx -y @some/mcp-server --its --own --flags
```

- **allowed** → the signed receipt is persisted under
  `heso-local-data/receipts/<action_hash>.json` and the request is forwarded
  untouched; the server's result is bound back as a follow-up receipt.
- **blocked / suspended** → the request is **never** forwarded; the client gets a
  proper MCP tool result with `isError: true` carrying the actionable reason (the
  responsible rule for a block; the `action_hash` to approve for a suspension).
- an engine fault **fails closed** — the call is refused, never forwarded ungated.
- `--observe` is mirror-only (capture + sign, never refuse). With `--api-key` /
  `--endpoint` a suspension also opens a hosted console approval. The dev
  passphrase file is picked up automatically (and refused under `HESO_ENV=production`).

Everything that isn't a `tools/call` (`initialize`, `tools/list`, notifications,
server stderr) passes through byte-for-byte, so the proxy is invisible to both sides.

## Verify a receipt (TypeScript / Node)

In Node you can both **gate** (see [references/typescript.md](references/typescript.md))
and **verify**. This section covers verify + the cloud client.

```ts
import { gate, assertGate, isDecisionAllowed } from "@hesohq/sdk"

const r = gate(receiptJson, "L0")     // { allowed, trustLevel, verdict }
if (r.allowed) proceed()

assertGate(receiptJson, "L1")          // throws unless valid AND human co-signed
applyTransfer()

if (isDecisionAllowed(receipt, ["allow", "redact"])) proceed()  // branch on policy
```

- **Verify before you trust.** Never read `trustLevel` off parsed JSON — get it
  from `gate()`.
- **`assertGate(json, "L1")`** before money movement or destructive ops.
- **Push re-verifies server-side.** `pushReceipt()` sends to the cloud outbox;
  the server re-runs the identical check and rejects a tampered body (HTTP 422).
  The result `status` is `appended` / `duplicate` / `quota_exceeded`.
- **`configure(apiKey, endpoint)` once** before any cloud call; local
  `gate`/`assertGate` need no config and no network.

## Verify in the browser (`@hesohq/verify-wasm`)

```ts
import init, { verifyActionReceipt } from "@hesohq/verify-wasm"
await init()                                   // fetch the .wasm once; cache the promise
const v = verifyActionReceipt(receiptBytes)    // sync after init: { verdict, trust_level }
```

ESM only, holds no private key, never signs; your app must serve the `.wasm`.
Await `init()` exactly once. Also exposes in-browser policy tooling — `parsePolicy`,
`policyRulesFromToml`, `ruleToSentence`, `validateNoFloorBypass` (parse / preview /
floor-check; there is **no** decision-against-action `evaluatePolicy`).

**Anyone can verify without HESO.** The public `/verify` page on heso.ca checks a
pasted/uploaded receipt in the browser (same wasm core) with **no login** — point
a relying party there. The wire format is openly specified (`ACTION-RECEIPT-1.0`,
`ACTION-RECEIPT-2.0`, `TRANSPARENCY-1.0`, `HESO-1.0`) and an MIT/Apache-dual-licensed
verifier crate + `heso-verify-cli` let third parties verify with zero HESO code.

## Evidence bundles — offline, self-verifying

Beyond a single receipt, the core assembles a **self-contained evidence bundle**: a
directory (and a deterministic POSIX tar) holding the `receipts.jsonl`, a `VERIFY.sh`,
and a `README.txt`. The relying party unpacks it and runs `./VERIFY.sh` — which
resolves the released standalone `heso-verify-cli` and re-checks every receipt
offline, with no HESO install and no network. The Rust entry point is
`heso._core.evidence_bundle_tar` (consumed by the SDKs); on the cloud, Team+ orgs
export a bundle via `POST /v1/evidence/export`. A bundle proves the same thing one
receipt does — authorization, re-derived — never downstream success.

## Policy is authored in the dashboard, not hand-written

This is the part people get wrong. **Policy is built in the HESO web console**
(`/policy`), not by hand-editing TOML. `heso.toml` is the *underlying* format the
engine reads; the dashboard is the authoring surface and renders the exact rule
sentences that land on receipts. Full detail (field catalog, operators, bands
math): [references/policy.md](references/policy.md).

**Importance bands.** Rules live in named bands that compile down to the engine's
`order` (it still sorts ascending and does first-match-wins):

| Band | Order range | Role |
| --- | --- | --- |
| **Always-on** | — (read-only) | The two pinned **floors**. Always applied, can't be turned off. Not a rule band. |
| **Exceptions** | 0–999 | Narrowing carve-outs. Checked **first**. |
| **Guardrails** | 1000–1999 | The core policy. |
| **Baseline** | 2000–2999 | Catch-all defaults. Checked **last**. |

You order rules by dragging within a band (the band, not raw numbers); "Add
exception" creates a carve-out scoped above a rule. The UI flags a rule that can
**never run** because an earlier broader rule shadows it.

**Authoring a rule** = pick a verb + subject + host scope, then build conditions
in a **field → operator → value** builder (conditions are a pure AND — all must
hold). Operators: `gt`, `lt`, `gte`, `lte`, `eq`, `neq`, `in`, `not_in`,
`exists`, `matches`, constrained to the field's type (`money`, `number`, `host`,
`enum`, `bool`, `string`). The decision is `allow` / `block` / `redact` /
`require_approval` (+ approver labels + SLA).

**Simulate, then deploy.** `/policy/simulate` runs a captured action against the
working policy and shows which rule matches and the decision — before anything
ships. Deploying goes through a **Review & sign** bar to the Rust engine
(`deployPolicy` → a `policy_id`); only Security Admin / Owner can deploy.

**Curated packs (a starting point, not a separate engine).** HESO ships curated
policy packs (`AI Agent Baseline`, `SOC 2`, `ISO 27001`, `HIPAA`, and — currently
**draft / unpublished** — `ISO/IEC 42001` and `NIST AI RMF`) that **merge into the
active policy via deploy** — they are tighten-only `require_approval` rules, so they
can never trip the floor validator. `min_plan` gates *enforcing* a pack (free orgs
get one starter pack: `AI Agent Baseline`; SOC 2 / packs beyond it are Pro+);
preview and simulate stay free for everyone. Don't describe ISO 42001 / NIST AI RMF
as live gallery packs yet.

Hard rules:

- **Default-deny.** Anything no rule matches is **blocked**.
- **Pinned floors can't be allowed away.** The dangerous lanes — `payment`,
  `delete`, `account_change`, `data_export` — carry a floor (plus a second floor:
  a `payment` with no valid mandate). A policy may *tighten* a floor but can never
  `allow` a dangerous lane without approval — try and the policy is rejected at
  load with a `[FLOOR_BYPASS]` error naming the rule id and verb.
- **`heso.toml`** is the file form (what `heso init` writes, what the local
  Python engine reads). You *can* hand-edit it, but author in the dashboard so
  the rule sentence you see is the one that lands on the receipt.

## Verification: the gates

The verifier walks gates top to bottom and stops at the **first** failure, naming
one verdict (the PascalCase engine tag). Passing the core gates yields `Valid`.
Full detail + the "never write your own canonicalizer" rule:
[references/verification.md](references/verification.md).

1. **Algorithm recognized** → else `WrongAlgorithm`
2. **Version recognized** → else `Unsupported`
3. **Hash recomputes** (BLAKE3 over RFC-8785 canonical bytes, `action_hash`
   stripped first) → else `HashMismatch`
4. **Operator signature verifies** → else `InvalidSignature` (or `Malformed`)
5. **Approver signature(s) verify** (if present) → else `InvalidSignature`; the
   approver key must differ from the operator → else `SelfApproval`. (There is no
   `invalid_approver` verdict.) For a quorum (`multi_approval`) receipt each leg
   verifies under the co-sign domain against a **distinct roster key**, and trust
   re-derives to L1 only when **≥ `threshold`** distinct legs verify — fewer than
   that fails `ThresholdNotMet` (carries `have`/`need`, e.g. `ThresholdNotMet:have=1,need=2`).
6. **Redaction markers well-formed** → else `MalformedRedaction`
7. **Trust re-derives** and matches the claim → else `TrustLevelMismatch`. A quorum
   re-derives to **L1** (with its `multi_approval` block), not a higher level.

A few more gates run only when the field they check is present: a trusted-time
`time_anchor` that does not verify → `TimeAnchorUnverifiable`; a receipt whose
signed `anchor_policy = Required` carries **no** anchor → `AnchorRequired` (the
offline verifier itself rejects it — not just the server); a payment mandate →
`MandateRejected`; and (re-deriving verify only) the signed classification →
`ClassificationMismatch` / `TaxonomyUnavailable`. A `Valid` verdict means exactly
two things: the bytes are the bytes the operator signed (unaltered), and the
re-derived trust level matches the claim. Nothing about downstream success.

## Honesty rules (do not violate)

1. A receipt proves **authorization** (and at L1, human approval), never an
   outcome.
2. Governance numbers are real or honestly empty — never hardcoded or faked.
3. Never trust a wire `trust_level` — re-derive it via verification.
4. Never log/transmit a redacted field's value — redaction keeps only a BLAKE3
   commitment (or nothing, in destructive mode).
5. Never hand-roll canonicalization/BLAKE3/Ed25519 — always call the core, or you
   get false `HashMismatch` on valid receipts.

## When NOT to use HESO

- You only need logging/metrics — HESO proves authorization, not observability.
- You need to capture from a runtime with no HESO SDK — capture is Python and Node
  today (the browser is verify-only); you can still verify those receipts anywhere.
- You want to assert an action's real-world effect — HESO cannot prove that.

## References

- [references/python.md](references/python.md) — full Python gating: decorators,
  `wrap`, `step`, blocking/observe, suspend/resume, redaction, adapters, init.
- [references/typescript.md](references/typescript.md) — Node gating (`init`,
  AI SDK / Mastra adapters, `engine.gate`), `gate`/`assertGate`/`isDecisionAllowed`/
  `wrap`, the cloud client, exported types.
- [references/policy.md](references/policy.md) — UI authoring, importance bands,
  the per-verb field catalog, operators, floors, simulate, deploy, `heso.toml`.
- [references/receipts.md](references/receipts.md) — the full Action Receipt
  schema, every nested type, canonicalization, a worked L1 example.
- [references/verification.md](references/verification.md) — the verify gates, the
  verdict tags, byte-for-byte canonicalization, where it runs.
- [references/cli-and-api.md](references/cli-and-api.md) — `heso` CLI, the cloud
  HTTP API, auth, and environment variables.
- Live docs: https://heso.ca/docs
