# Policy reference

**Policy is code.** It lives in the repo as `heso.toml`, is reviewed in a PR, and
is enforced by a GitHub status check that lints it and **proves** invariants
before merge — see the GitHub policy-as-code embed in [embeds.md](embeds.md). The
web dashboard (`/policy`) is **one** authoring surface (a visual editor whose
edits flow to a PR against the same policy-as-code source), **not** the home of
policy. Both compile to the same `heso.toml` the engine reads.

The engine sorts rules by ascending `order` and does **first-match-wins** — the
first rule whose subject + verb + scope + conditions all match decides, and its
decision is stamped onto the receipt. No scoring.

## `heso.toml` (the source of truth)

`heso init` writes a starter `heso.toml`; the local Python engine discovers it by
walking **upward** from the project root and reads it in-process. **Commit the
policy**; the local data dir (`heso-local-data/`) is gitignored. A single rule:

```toml
[[rule]]
id = "approve-large-payments"
order = 1020              # Guardrails band (1000–1999), position 20
enabled = true
subject = { kind = "any" }
verb = "payment"
scope = "*"
conditions = [
  { field = "amount_usd", op = "gt", value = 5000, display = "amount over $5,000" },
]
decision = "require_approval"
approvers = ["finance-lead", "cfo"]
sla_minutes = 120
```

Hand-edit it freely (the Python engine reads it directly) — but route real changes
through a PR so the GitHub embed can lint, floor-validate, prove invariants, and
catch shadowed rules. The visual dashboard editor renders the same plain-English
sentence (`rule_display`) that lands on the receipt.

## Authoring a rule

A rule pins:

- **subject** — `{ kind: "any" | "workflow" | "account", value? }`.
- **verb** — `"any"` or one of the seven coarse verbs (`llm_call`, `tool_call`,
  `http_request`, `payment`, `data_export`, `account_change`, `delete`). Policy
  keys on the verb; the verb maps to a destructive primitive — see
  [taxonomy.md](taxonomy.md).
- **scope** — a host glob matched against the action's `target_host`, or `"*"`.
- **conditions** — zero or more field checks, a pure **AND** (all must hold).
- **decision** — `allow` | `block` | `redact` | `require_approval`.
- **approvers** + **sla_minutes** — for `require_approval`. A rule can require a
  **quorum** (k distinct approvals). Quorum semantics, what each signer vouches
  for, and the `multi_approval` block live in [receipts.md](receipts.md) — a
  quorum re-derives to **L1**, not a higher level.

Each rule renders to a `rule_display` sentence via the Rust-faithful
`ruleToSentence`. The UI flags a rule that can **never run** because an earlier,
broader rule shadows it (first-match-wins).

## The condition builder

Conditions are **field → operator → value**, with operators constrained to the
field's type.

- **Operators** (`ConditionOp`): `gt`, `lt`, `gte`, `lte`, `eq`, `neq`, `in`,
  `not_in`, `exists`, `matches`.
- **Field types** (`FieldType`): `bool`, `enum`, `host`, `money`, `number`,
  `string`. `OPS_BY_TYPE` maps each type to its legal operators (a money field
  can't `matches` a string).
- **Fields are per-verb** (`POLICY_FIELDS[verb]` + shared `ANY_VERB_FIELDS` /
  `DERIVED_FIELDS`) — only fields the engine can actually match. Representative:
  `llm_call` → `provider` / `host` / `modality` / `pii_status`; `payment` →
  `budget` (money) / `currency`; `http_request` → `host` / `http_method` /
  `pii_status` / `origin`; `account_change` → `environment` / `effect`. A
  derived `mandate.verdict` is `valid` | `invalid` | `absent`.

Every edit recomputes the condition's `display` via the Rust-faithful composer so
the live sentence stays honest.

## Importance bands (how the UI models order)

You never type raw `order` numbers. Rules live in named **bands** that compile
down to the engine's `order: i64` (a web-only abstraction; the engine is
untouched):

| Band | Order range | Role |
| --- | --- | --- |
| **Always-on** | — (read-only) | The pinned **floors**. Always applied, can't be turned off. NOT part of the `[[rule]]` array. |
| **Exceptions** | 0–999 | Narrowing carve-outs. Checked **first**. |
| **Guardrails** | 1000–1999 | The core policy. |
| **Baseline** | 2000–2999 | Catch-all defaults. Checked **last**. |

Each band owns 1000 positions; reordering is **within a band**, and every edit
reindexes so orders stay `band_base + position`. "Add exception" creates a
carve-out pre-scoped above a rule (lands in Exceptions). Any order ≥ 2000
(including legacy / hand-edited TOML) reads as Baseline.

## Pinned floors (always-on)

`payment`, `delete`, `account_change`, and large `data_export` carry a built-in
**floor** enforced when the engine loads the policy (plus a second floor: a
`payment` with no valid mandate). A policy may **tighten** a floor but can never
`allow` one of these lanes without approval — try, and the policy is **rejected at
load** with a `[FLOOR_BYPASS]` error naming the offending rule id and verb. The
floors render in the read-only **Always-on** band.

The human-approval floor is enforced in the **untrusted external-delegation** lane
(the iframe / external-client path). An authenticated, role-gated, device-pinned
console approver satisfies it **by identity** — a documented exemption, not a
bypass.

## Default-deny

Anything no rule matches is **routed to a human, not hard-blocked.** When no rule
fires, the engine applies a synthetic `policy.default.deny_unknown` rule whose
decision is **`require_approval`** — the action **suspends** (the Python SDK raises
`SuspendedError`, never `BlockedError`, so `except BlockedError` will **not** catch
it) and waits for an approver. There is no implicit allow-all: an empty policy
**suspends** everything; open lanes by adding `allow` rules. Combined with the
floors and the taxonomy's deny-unknown (`residual` fails closed — see
[taxonomy.md](taxonomy.md)), a policy gap fails safe rather than leaking.

## Simulate, then deploy

- **Simulate** — run a captured action against the working policy and see which
  rule matches and what it decides, before shipping (the GitHub embed runs this in
  CI on the PR; the dashboard runs it interactively). Client-side you have only
  `parsePolicy` / `policyRulesFromToml` / `ruleToSentence` /
  `validateNoFloorBypass` — there is **no** decision-against-action
  `evaluatePolicy` in the verify-wasm surface.
- **Deploy** — `deployPolicy(rules, policyHash)` returns a `policy_id`; only
  **Security Admin** / **Owner** hold the `deploy_policy` permission.

## Curated policy packs

HESO ships curated **policy packs** — bundles of **tighten-only**
`require_approval` rules mapped to a framework's controls. A pack is a starting
point, not a separate engine: it **merges into the active policy via deploy** and
runs through the same first-match-wins floors-and-all engine, so it can never trip
the `[FLOOR_BYPASS]` validator. Each pack carries a content hash (`pack_hash =
blake3(rules_toml)`) that drives "update available" and a `min_plan` that gates
**enforcing** a pack (preview / simulate stay free for everyone).

> **Pack readiness is data, not prose.** Which packs are published vs. draft, and
> each pack's `min_plan`, live in the open spec's machine-readable
> `heso-spec/packs/manifest.toml`. Read the manifest for the live set rather than
> trusting a list written here — a hardcoded "draft / unpublished" note rots
> silently. Do not present a draft pack as a live, installable gallery pack.

## Trusted time (optional, Required-gated)

Trusted time is **off by default** — most receipts carry no anchor. A policy can
mark trusted time **Required** for a lane; the engine then stamps `anchor_policy =
Required` into the **signed receipt body on-wire** — verifier-enforceable at the
offline verifier, not only the server. A receipt from that lane that carries no
verifiable RFC-3161 `time_anchor` fails `AnchorRequired`. The anchor bounds when the
post-approval body existed — **not** when a human decided. The `heso._core` wheel
ships `mint_time_anchor` so the SDK can obtain the TSA token without an external
binary — the policy stamp, the wheel mint, and the offline verifier enforcement are
wired end-to-end. See [verification.md](verification.md).
