# The destructive-primitive taxonomy (the crown jewel)

This is the one rule that makes HESO a *standard* and not a logging library:
**classify by effect, not by name.** Every action an agent takes that touches the
world is classified, by its **structural effect**, into exactly one of five
**destructive primitives** — never by the name of the tool or the framework that
emitted it. A tool called `helper.run()` that issues a card charge is
**`move-value`**, not "execute", because of what it does to the world. A tool
named `delete_everything` that only reads rows is an `observe`, not a `destroy`.

`classify` is a **total function over a closed vocabulary** — same TOML + same
action ⇒ same primitive, in Rust, Python, TypeScript, and the open verifier. It
is content-addressed (`taxonomy_hash`) and versioned, so a verifier can prove
*which* version of the taxonomy produced a classification.

> **One canonical home.** This reference teaches the taxonomy at a working level.
> The normative spine (the gold-master `taxonomy.toml`, the exact predicate
> semantics, the priority order, the namespaced-extension registry) is owned by
> the open **heso-spec** repo and cited here — the kernel, every SDK, the gate,
> and the conformance vectors point at the spec, not at this page. Do not hardcode
> wire constants here; cite the spec.

## The five destructive primitives (the spine)

| Primitive | What it does to the world | Rail-boundary examples |
| --- | --- | --- |
| **`move-value`** | Transfers economic value out of the principal's control | a payment / charge / payout / transfer; Stripe `POST /v1/payment_intents` |
| **`destroy`** | Irreversibly removes or mutates state | a delete / drop / overwrite / terminate; AWS `DeleteObject`, `TerminateInstances` |
| **`change-authority`** | Alters who can do what — identity, grants, roles, keys | an IAM grant, role change, key rotation, account modification |
| **`disclose`** | Sends in-scope data across a trust boundary | a bulk data export, a secret read, a transfer-out of sensitive rows |
| **`execute`** | Runs an effectful action that is none of the above | a generic tool call, an HTTP request, a code/command run |

Two more lanes complete the function so it is **total** — every action lands
somewhere, there is no `null` branch:

- **`observe`** — the *non-destructive* sibling of `execute`: a read, a model/LLM
  call, a retrieval that does **not** cross a disclosure boundary. The split is
  structural: the *same* `tool_call` / `http_request` / `llm_call` surface is
  `execute` when it changes the world and `observe` when it is read-only. An
  `observe` is off-rail and never produces a reconciliation alert.
- **`residual`** — the explicit **unresolved** lane. When no predicate matches,
  the action does **not** silently become "safe" or "execute" — it lands in
  `residual` and is treated under **deny-unknown**: gated as if it were the most
  dangerous primitive until a human or policy says otherwise. The gate **fails
  closed** on `residual`. Unknown ⇒ unsafe. There is no third door.

## Classify by effect, not by name

This is the discipline the whole standard rests on. The classifier reasons about
*what the action does to the world*, not what the tool is called:

- A payment that arrives as a generic `http_request` to `api.stripe.com
  /v1/payment_intents` is **`move-value`** — the destination + path + method make
  it a value transfer regardless of the tool name.
- A bulk export of 10,000 rows is **`disclose`** regardless of which endpoint
  served it — a row threshold crossing is a disclosure.
- A read of a secret store is **`disclose`**, even though "read" sounds benign.
- An LLM call carrying no disclosing payload is **`observe`**; the same call
  exfiltrating sensitive context is **`disclose`**.

Because classification is structural, an agent (or a re-implementer) cannot game
it by renaming a tool, and a verifier can re-derive the same primitive from the
recorded facts.

## The predicate vocabulary (closed)

Classification is driven by a **closed set** of predicate kinds. A re-implementer
may never invent a new kind — the vocabulary is fixed by the spec, and growth is
a spec change (a new ADR + vectors), never an ad-hoc field. Closedness is what
makes `classify` deterministic across languages.

| Predicate kind | Matches on |
| --- | --- |
| `host_set` | the destination host (exact / suffix set) — `api.stripe.com`, `*.amazonaws.com` |
| `path_glob` | the request path (glob) — `/v1/payment_intents`, `/v1/*/refunds` |
| `method_set` | the HTTP/tool method — `{POST, DELETE}` |
| `argv_token` | a token in the action's argv/arguments — `--force`, `rm`, `DROP` |
| `row_threshold` | a row/record count crossing a bound — `rows >= 1000` (bulk-data → disclose) |
| `fact_flag` | a named boolean fact resolved upstream — `is_secret_store`, `crosses_org_boundary` |
| `always` | unconditional match (the catch/floor row) |

`row_threshold` and `fact_flag` are what make the taxonomy *structural* rather
than surface-string matching: "1,000+ rows leaving" is a disclosure regardless of
endpoint; "this host is a secret store" is a fact resolved once and reused.

**How rows combine.** A class is a list of **rows**. Within a row, predicates
**AND** (all must hold). Across rows they **OR** (any row matches). Classes are
evaluated in a fixed **priority order** (highest-impact first) and the **first
class that matches wins** — so `move-value` beats `execute` when an action is both
a payment *and* an HTTP request. Ties break by the spec's fixed order, not by
evaluation order in any one implementation. The exact priority lattice
(`payment_endpoint > destructive_op > identity_endpoint > secret_store >
bulk_data > model_endpoint > messaging_endpoint > generic_network > local_compute
> residual`) is normative in the spec.

## Totality and deny-unknown

Three properties, all enforced mechanically:

1. **Totality** — every action maps to exactly one outcome. Totality is enforced
   at *parse time* of the taxonomy: a taxonomy that cannot classify every action
   **fails to load** rather than silently leaking actions.
2. **Closed vocabulary** — only the predicate kinds above exist. An unknown kind
   is a load error, not a runtime guess.
3. **Deny-unknown** — no match ⇒ `residual` ⇒ gated as the *least*-trusted
   classification. The gate fails closed.

This is the safety property the assurance story rests on: you can never reach the
world through a HESO gate with an action that was *silently* deemed safe.

## `taxonomy_hash` — pinning the classifier

The taxonomy is **content-addressed**: `taxonomy_hash` is **BLAKE3 over the
RFC-8785 (JCS) canonical projection** of the normative classification data — the
same canonicalize-then-BLAKE3 discipline the kernel uses for receipts (see
[verification.md](verification.md)). The projection is *only* the classes / rows
/ predicates / priority, never comments or auditor labels, so descriptive churn
never moves the hash. The hash tracks **behavior**, not prose.

Every signed action **pins the `taxonomy_hash` it was classified under**, and
**verification always checks against that pinned version** — "law at the time of
signing." An old action verifies under its own era's rules forever; a bug-fix
never orphans history. Any change is a **new, published, immutable version** (old
versions stay published and verifiable). *Verification (pinned)* is separate from
*analysis (latest)*: alerting may re-run today's rulebook over old actions to flag
a would-be-different classification — a **new finding**, never a rewrite.

## FROZEN-7 verbs → the five primitives (the load-bearing mapping)

The shipped kernel froze a coarser, label-shaped **seven coarse verbs**; the
canonical spine is the **five primitives**. They are close but **not** 1:1. The
spec makes the five primitives canonical and maps the seven onto them — it does
not paper over the gap. Teach the five; reference the mapping.

| Frozen verb (implemented) | Canonical primitive | Note |
| --- | --- | --- |
| `payment` | **`move-value`** | direct |
| `delete` | **`destroy`** | direct |
| `account_change` | **`change-authority`** | identity / grant / role / key |
| `data_export` | **`disclose`** | bulk-data out across a boundary |
| `secret` read | **`disclose`** | a secret-store read is a disclosure |
| `tool_call` | **`execute`** / **`observe`** | by structural effect — effectful ⇒ execute, read-only ⇒ observe |
| `http_request` | **`execute`** / **`observe`** | same split — does the call change/leak the world? |
| `llm_call` | **`observe`** (default) | non-destructive unless it carries a disclosing payload |

The FROZEN-7-vs-5 resolution is recorded as the load-bearing taxonomy-spine ADR
in the spec's decision record (the single source of truth for the mapping).

## `ClassificationMismatch` — the verifier catching a lie

`ClassificationMismatch` is not an obscure verdict — it is the verifier **catching
a recorded effect that does not match the signed classification.** A re-deriving
verify (gate 11 in [verification.md](verification.md)) replays the structural
classification from the action's own facts and compares it to the primitive the
signer claimed. If a `move-value` was signed as an `observe` to slip past a floor,
the bytes still verify, but the *classification* does not re-derive —
`ClassificationMismatch`. (`TaxonomyUnavailable` is the sibling: the pinned
taxonomy version can't be loaded to re-derive against.)

This is why classify-by-effect is enforceable, not just aspirational: the claim is
checkable against the facts by anyone with the open verifier.

## Namespaced extension

The taxonomy is extensible without forking the spine. A vendor class, private
fact, or fine label is **namespaced** as `<ns>/<name>` (e.g. `acme/internal-ledger`).
A bare name is reserved for core HESO/1 (deny-unknown applies to names too — an
unrecognized core-namespace name is rejected). An extension class still maps onto
one of the **five** primitives — extensions add resolution detail, never a sixth
primitive. Extensions are registered in the open spec's registry (a spec-repo
contribution with vectors), not a private edit to a vendored copy. (This is
distinct from a customer naming a *local policy rule* `<ns>/<name>` in their
`heso.toml`, which is a local concern — see [policy.md](policy.md).)

## Where it's consumed

- The **gate** classifies-by-effect against this taxonomy before signing — see
  [recorder-and-gate.md](recorder-and-gate.md).
- The **commitment store** indexes by primitive (the crown-jewel query axis) —
  see [cloud.md](cloud.md).
- The **verifier** re-derives the classification (`ClassificationMismatch`) — see
  [verification.md](verification.md).
- Wire constants, the gold-master `taxonomy.toml`, the priority lattice, and the
  conformance vectors are owned by the open **heso-spec** repo.
