---
name: heso
description: >-
  Add HESO governance to an AI agent: gate every action against policy, sign it
  into a tamper-evident Action Receipt, route risky actions to a human approver,
  and verify receipts offline anywhere. Use when wiring HESO into a codebase,
  choosing between the heso / @heso/sdk / @heso/core / @heso/verify-wasm
  packages, authoring policy (importance bands, conditions, floors, simulate,
  deploy) or a heso.toml, gating tools/LLM clients, enforcing a trust level
  (L0/L1), redacting fields, handling approvals/suspend-resume, or verifying an
  Action Receipt and reading its verdict. Triggers on "gate the agent", "sign
  this action", "require approval", "verify a receipt", "trust level", "policy
  rule", "heso.toml", "Action Receipt", "redact".
metadata:
  version: 0.1.0
  homepage: https://heso.dev/docs
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
(`heso._core`), a native Node addon (`@heso/core`), and a browser WASM module
(`@heso/verify-wasm`) — so a verdict is byte-identical whether it runs on your
server or in a reviewer's browser. Nobody re-implements canonicalization, BLAKE3,
or Ed25519 in JS or Python.

**The one rule that governs every design choice:** a receipt proves an action was
_authorized_ under a known policy — and at L1 that a human _approved_ it with a
device-held key. It does **not** prove the action _succeeded_ in the world. Never
write code, copy, or comments that claim more. Never synthesize governance
numbers (receipt/approval/block counts must be real or honestly empty).

All packages are at `0.1.0`. Wire format: `alg = "heso-action/v2+ed25519"`,
`action_version = "heso-action/2.0"`.

## Pick the package first

One core, four surfaces. Choose by the job, not the language.

| Package | Runtime | Use it to |
| --- | --- | --- |
| `heso` | Python ≥ 3.10 | **Gate** an agent — capture, policy-check, sign, audit. The only surface that captures and signs. |
| `@heso/sdk` | Node ≥ 18 | **Verify** receipts and call the cloud control plane (push receipts, open approvals, pull policy). |
| `@heso/core` | Node ≥ 18 (native) | Raw primitives `@heso/sdk` wraps: verify, BLAKE3 hashing, chain/transparency verify, redaction, Ed25519 keys. |
| `@heso/verify-wasm` | Browser | **Verify only**, client-side. No private key, no network. Also exposes in-browser policy eval. |

- "Gate my agent's actions" → **`heso`** (Python). There is **no Node capture/
  decorator surface** — gating is Python today. (Auto-instrumentation was removed;
  supported gating is decorators, `wrap()`, and the framework adapters.)
- "Trust a receipt from a Node service" → **`@heso/sdk`**.
- "Show a user their receipt verifies, in the browser" → **`@heso/verify-wasm`**.
- Gate in Python, verify anywhere — the verdict matches across all three.

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
- **Trust level** — `L0` = operator-signed. `L1` = operator **plus** a human
  approver's co-signature from a device-held key. There is no L2/L3. Trust is
  **re-derived on every verify** from the signatures that pass; a receipt
  claiming L1 with only an operator signature fails `trust_mismatch`. **Never
  read `trust_level` off the wire — gate on a verified one.**
- **Audit chain** — receipts BLAKE3 hash-linked; altering an earlier receipt
  breaks every link after it.

## Gate an agent (Python)

Scaffold once, decorate the actions, init before the agent runs. Full surface
(suspend/resume, adapters, every kwarg): [references/python.md](references/python.md).

```bash
pip install heso        # or: uv add heso
heso init               # mints operator key, writes starter heso.toml, gitignores .heso/
```

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
  approval opens; the work resumes at L1 once a human co-signs. See the
  suspend/resume API in [references/python.md](references/python.md).
- **Gate a whole client with `heso.wrap()`** — gates `.create()` as `llm_call`,
  `.request()` as `http_request`, reaches nested attrs
  (`client.chat.completions.create(...)`), passes the rest through.
- **Adapters:** `heso.HesoCallbackHandler()` for LangChain; `heso.wrap()` for
  OpenAI/Anthropic clients.

## Verify a receipt (TypeScript / Node)

In Node you **verify**; you don't capture. Full surface (cloud client, types,
status codes): [references/typescript.md](references/typescript.md).

```ts
import { gate, assertGate, isDecisionAllowed } from "@heso/sdk"

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
  the server re-runs the identical check and can reject (`accepted: false`).
- **`configure(apiKey, endpoint)` once** before any cloud call; local
  `gate`/`assertGate` need no config and no network.

## Verify in the browser (`@heso/verify-wasm`)

```ts
import init, { verifyActionReceipt } from "@heso/verify-wasm"
await init()                                   // fetch the .wasm once; cache the promise
const v = verifyActionReceipt(receiptBytes)    // sync after init: { verdict, trust_level }
```

ESM only, holds no private key, never signs; your app must serve the `.wasm`.
Await `init()` exactly once. Also exposes in-browser policy eval
(`parsePolicy`, `evaluatePolicy`, `ruleToSentence`).

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

Hard rules:

- **Default-deny.** Anything no rule matches is **blocked**.
- **Pinned floors can't be allowed away.** `payment`, `delete`,
  `account_change`, and large `data_export` carry a floor. A policy may *tighten*
  it but can never `allow` one without approval — try and the policy is rejected
  at load with a `[FLOOR_BYPASS]` error naming the rule id and verb.
- **`heso.toml`** is the file form (what `heso init` writes, what the local
  Python engine reads). You *can* hand-edit it, but author in the dashboard so
  the rule sentence you see is the one that lands on the receipt.

## Verification: the seven gates

The verifier walks gates top to bottom and stops at the **first** failure, naming
one verdict. Passing all seven yields `valid`. Full detail + the
"never write your own canonicalizer" rule: [references/verification.md](references/verification.md).

1. **Algorithm recognized** → else `wrong_algorithm`
2. **Version recognized** → else `unsupported_version`
3. **Hash recomputes** (BLAKE3 over RFC-8785 canonical bytes, `action_hash`
   stripped first) → else `hash_mismatch`
4. **Operator signature verifies** → else `invalid_signature`
5. **Approver signature verifies** (if present) → else `invalid_approver`
6. **Redaction markers well-formed** → else `redaction_malformed`
7. **Trust re-derives** and matches the claim → else `trust_mismatch`

A `valid` verdict means exactly two things: the bytes are the bytes the operator
signed (unaltered), and the re-derived trust level matches the claim. Nothing
about downstream success.

## Honesty rules (do not violate)

1. A receipt proves **authorization** (and at L1, human approval), never an
   outcome.
2. Governance numbers are real or honestly empty — never hardcoded or faked.
3. Never trust a wire `trust_level` — re-derive it via verification.
4. Never log/transmit a redacted field's value — redaction keeps only a BLAKE3
   commitment (or nothing, in destructive mode).
5. Never hand-roll canonicalization/BLAKE3/Ed25519 — always call the core, or you
   get false `hash_mismatch` on valid receipts.

## When NOT to use HESO

- You only need logging/metrics — HESO proves authorization, not observability.
- You need to gate a non-Python agent today — capture is Python-only (you can
  still verify its receipts from Node or the browser).
- You want to assert an action's real-world effect — HESO cannot prove that.

## References

- [references/python.md](references/python.md) — full Python gating: decorators,
  `wrap`, `step`, blocking/observe, suspend/resume, redaction, adapters, init.
- [references/typescript.md](references/typescript.md) — `gate`/`assertGate`/
  `isDecisionAllowed`/`wrap`, the cloud client, exported types, status codes.
- [references/policy.md](references/policy.md) — UI authoring, importance bands,
  the per-verb field catalog, operators, floors, simulate, deploy, `heso.toml`.
- [references/receipts.md](references/receipts.md) — the full Action Receipt
  schema, every nested type, canonicalization, a worked L1 example.
- [references/verification.md](references/verification.md) — the seven gates, the
  verdict table, byte-for-byte canonicalization, where it runs.
- [references/cli-and-api.md](references/cli-and-api.md) — `heso` CLI, the cloud
  HTTP API, auth, and environment variables.
- Live docs: https://heso.dev/docs
