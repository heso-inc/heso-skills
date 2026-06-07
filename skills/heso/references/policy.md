# Policy reference

**Policy is authored in the HESO dashboard (`/policy`), not by hand-editing
TOML.** `heso.toml` is the underlying file format the engine reads; the dashboard
is the authoring surface and renders the exact rule sentences that land on
receipts. The engine sorts rules by ascending `order` and does first-match-wins —
the first rule whose subject + verb + scope + conditions all match decides, and
its decision is stamped onto the receipt. No scoring.

## Importance bands (how the UI models order)

You never type raw `order` numbers. Rules live in named **bands** that compile
down to the engine's `order: i64` (a web-only abstraction; the engine is
untouched). Bands map to disjoint order ranges so a rule's band can be inferred
back from its order on pull:

| Band | Order range | Base | Role |
| --- | --- | --- | --- |
| **Always-on** | — | — | The two pinned **floors**. Read-only, always applied, can't be turned off. NOT part of the `[[rule]]` array. |
| **Exceptions** | 0–999 | 0 | Narrowing carve-outs. Checked **first**. |
| **Guardrails** | 1000–1999 | 1000 | The core policy. |
| **Baseline** | 2000–2999 | 2000 | Catch-all defaults. Checked **last**. |

Each band owns 1000 positions. Reordering is **within a band** (up/down), and
every add/duplicate/move/delete reindexes the band so orders stay
`band_base + position`. "Add exception" on a guardrail/baseline rule creates a
carve-out pre-scoped above it (lands in Exceptions). Any order ≥ 2000 (including
legacy / hand-edited TOML) reads as Baseline.

## Authoring a rule

A rule pins:

- **subject** — `{ kind: "any" | "workflow" | "account", value? }` — who the
  action belongs to (`value` names the workflow/account; omit for `any`).
- **verb** — `"any"` or one of the seven: `llm_call`, `tool_call`,
  `http_request`, `payment`, `data_export`, `account_change`, `delete`.
- **scope** — a host glob matched against the action's `target_host`, or `"*"`.
- **conditions** — zero or more field checks, a pure **AND** (all must hold).
- **decision** — `allow` | `block` | `redact` | `require_approval`.
- **approvers** + **sla_minutes** — for `require_approval`.

Each rule renders to a plain-English **sentence** (`rule_display`) via the
Rust-faithful `ruleToSentence`, shown live as you author and stamped onto the
receipt's `policy.rule_display`. The UI also flags a rule that can **never run**
because an earlier, broader rule shadows it (first-match-wins).

## The condition builder

Conditions are built **field → operator → value**. The operators offered are
constrained to the field's type, and the value widget is shaped by the operator
(a money field gets a `$` threshold editor; an enum gets a dropdown; `in`/`not_in`
get a multi-value input; `exists` takes no value).

**Operators** (`ConditionOp`): `gt`, `lt`, `gte`, `lte`, `eq`, `neq`, `in`,
`not_in`, `exists`, `matches`.

**Field types** (`FieldType`): `bool`, `enum`, `host`, `money`, `number`,
`string`. `OPS_BY_TYPE` maps each type to its legal operators (e.g. a money field
can't `matches` a string).

**Fields are per-verb.** The catalog (`POLICY_FIELDS[verb]`, plus shared
`ANY_VERB_FIELDS` and `DERIVED_FIELDS`) only offers fields the engine can
actually match — no phantom fields. Representative examples:

- `llm_call`: `provider` (`openai`|`anthropic`|`google`|`aws`|`cohere`|`local`|
  `other`), `host`, `modality` (`text`|`image`|`audio`|`video`|`multimodal`),
  `pii_status` (`not_scanned`|`clean`|`found`).
- `payment`: `budget` (money), `currency` (`USD`|`EUR`|…|`USDC`|`USDT`|`other`).
- `http_request`: `host`, `http_method` (`GET`|`POST`|…), `pii_status`,
  `origin`.
- `account_change`: `environment` (`dev`|`staging`|`prod`|`unknown`), `effect`
  (`read_only`|`mutating`|`destructive`).
- Derived/any-verb fields apply across verbs (e.g. a `mandate.verdict` of
  `valid`|`invalid`|`absent`).

Every edit recomputes the condition's `display` string via the Rust-faithful
composer (`composeConditionDisplay`) so the live sentence stays honest.

## Simulate, then deploy

- **Simulate** (`/policy/simulate`): run a captured action against the working
  (unsaved) policy and see which rule matches and what it decides — before
  shipping. Backed by the same evaluator the engine uses (`evaluatePolicy`).
- **Deploy**: edits are held client-side until you deploy. A persistent
  **Review & sign** bar (visible on every policy sub-route while there are
  unsaved changes) deploys to the Rust engine — `deployPolicy(rules, policyHash)`
  returns a `policy_id`. Only **Security Admin** and **Owner** roles hold the
  `deploy_policy` permission.

## Pinned floors (always-on)

`payment`, `delete`, `account_change`, and large `data_export` carry a built-in
floor enforced when the engine loads the policy. A policy may **tighten** a floor
but can never `allow` one of these lanes without approval. If it tries, the policy
is **rejected at load** with a `[FLOOR_BYPASS]` error naming the offending rule id
and verb. The two floors render in the read-only **Always-on** band; they are not
editable rules.

## Default-deny

Anything no rule matches is **blocked**. There is no implicit allow-all: an empty
policy blocks everything, and you open lanes by adding rules. Combined with the
floors, a policy gap fails safe rather than leaking a dangerous action through.

## `heso.toml` (the underlying format)

The dashboard compiles rules to TOML and pulls them back (`rulesToToml` /
`parseRulesFromToml`). `heso init` writes a starter `heso.toml`; the local Python
engine discovers it by walking **upward** from the project root and reads it
in-process. Commit the policy; the local data dir (`.heso/`) is gitignored. A
single `[[rule]]` block:

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

You *can* hand-edit TOML (the Python engine reads it directly), but the dashboard
is the source of truth for teams — it shows the rule sentence, runs floor
validation, catches shadowed rules, and round-trips the band structure. Hand-edits
beyond the band ranges still work (they degrade to Baseline) but lose those
checks until re-pulled.
