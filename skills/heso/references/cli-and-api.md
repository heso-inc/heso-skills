# CLI + cloud API

## CLI (`heso`)

Four commands. `init` scaffolds, `demo` proves the loop end-to-end, `verify` /
`show` read receipts back from the local store.

```bash
heso init [dir] [--require-passphrase]   # scaffold + mint operator identity
heso demo [dir]                          # init-if-needed, mint + verify your first receipts
heso verify <path|hash>                  # verify offline; print verdict + trust level
heso show <hash>                         # pretty-print a stored receipt by action_hash
```

`heso init` mints your **operator identity** in-process via the `heso._core` wheel
(`init_identity` — no separate binary), writes a starter `heso.toml`, and adds the
local data dir to `.gitignore`. It is idempotent. It leaves:

```
heso_bootstrap.py   # import heso; heso.init()
heso.toml           # starter policy (first-match-wins rules) — commit this
heso-local-data/    # minted Ed25519 operator key + receipts.jsonl + audit chain + outbox (gitignored)
```

**Zero-setup key passphrase.** Every key loader resolves its passphrase from
`HESO_KEY_PASSPHRASE`. To avoid a hard-fail on a fresh machine, `heso init`
auto-generates a **dev-only** passphrase into `heso-local-data/DEV-ONLY.passphrase`
(0600) and `heso.init()` loads it back into the env for the in-process lifecycle.
This is labeled dev mode, **not weakened custody** — the file sits next to the key
it unlocks, so it adds no protection. An explicit `HESO_KEY_PASSPHRASE` always
wins. Strict mode (`--require-passphrase`, `HESO_REQUIRE_PASSPHRASE`, or
`HESO_ENV=production`/`prod`) refuses to generate **or** adopt a dev passphrase and
demands a real one.

`heso demo` mints one allowed + one redacted receipt through the real engine,
verifies both offline, and prints the `heso verify <hash>` line — zero network,
zero cloud. There is no separate engine binary: gating, signing, and the audit
chain all run **in-process** via the bundled `heso._core` wheel. **Never commit
`heso-local-data/`** — the signing key, the dev passphrase, the audit log,
`receipts.jsonl`, and the outbox live there.

A standalone Rust verifier, `heso-verify-cli [--json] <receipts.jsonl>
<public_key_file>`, checks a receipt bundle offline with zero heso install (exit 0
valid, 1 invalid, 2 unsupported, 64 usage). It is the binary an evidence bundle's
`VERIFY.sh` resolves, and ships from the MIT/Apache-dual-licensed open verifier
repo alongside the published wire specs.

## Cloud API

The cloud is a **commitment store + reconciliation + proof surface** — not a
receipt mirror. The SDK pushes a **commitment** (fingerprint + index), never the
full receipt; raw content stays in the customer VPC. Full model:
[cloud.md](cloud.md).

Base URL is your endpoint; auth is the `x-api-key` header. The org (tenant) is
resolved from the key — there is **no team id** in any path, and approvals are
keyed by `action_hash`.

```
x-api-key: <API_KEY>
Content-Type: application/json
```

| Method | Path | Body | Returns |
| --- | --- | --- | --- |
| GET | `/v1/policy/pull` | — | `{ status, policy_id, policy_hash, toml }` |
| POST | `/v1/commitments` | a commitment (fingerprint + index — see below) | `{ status, entry_hash, seq }` |
| GET | `/v1/approvals/{action_hash}` | — | `ApprovalView` (carries `threshold` + `approved_count`) |
| GET | `/v1/approvals/{action_hash}/assembly` | — | the relayed co-sign legs |
| POST | `/v1/approvals/{action_hash}/submit-token` | `SubmitTokenRequest` | `ApprovalView` |
| GET | `/v1/reconciliation` | — | reconciliation state (matched / unwitnessed / cant_verify) |
| POST | `/v1/evidence/export` | export request | a self-verifying evidence bundle (tar w/ `receipts.jsonl` + `VERIFY.sh`) |

**The commitment payload** carries a fingerprint, a structural classification, a
verdict, and signatures — and **nothing of the action's body**:

```json
{ "action_hash": "...", "chain_prev": "...", "chain_head": "...",
  "session_id": "...", "seq": 12,
  "primitive": "move_value", "coarse_verb": "payment", "taxonomy_hash": "...",
  "resource_class": "payment_endpoint", "rail": "stripe",
  "trust_level": "L1", "decision": "allow",
  "winning_rule_id": "pay-cap", "winning_severity": "deny",
  "occurred_at": "2026-06-06T14:22:09Z",
  "signer_fpr": "...", "signature": "...", "envelope_kind": "dsse" }
```

This is a **versioned protocol change** from the retired `POST /v1/receipts`
firehose, gated by **new conformance vectors** in the open spec (a golden
commitment + a golden DSSE envelope), so the Rust signer, both SDKs, and the open
verifier stay byte-identical.

`status` on a commitment push is `appended` / `duplicate` / `quota_exceeded`. The
store is append-only — a re-pushed commitment is a `409 duplicate`, never an
overwrite. The cloud **verifies the detached signatures** on the commitment; it
holds no minting key and there is **no body to re-run a check over** (that was the
receipt-mirror model). Inclusion is proven (`verifyInclusionJs`), not re-graded.

**Approvals — one unified assembly surface.** `GET
/v1/approvals/{action_hash}/assembly` returns a `legs` list (no separate
`/l1-parts` route): single-approver reads `legs[0]`, quorum reads the whole list.
Each `submit-token` call records **one** approver's vote, so a k-of-n quorum is
`threshold` separate submit-token calls. The co-sign / relay mechanics (how the
human approves and the cloud relays without holding a key) are one canonical
statement in [SKILL.md](../SKILL.md); the language APIs are in
[python.md](python.md) / [typescript.md](typescript.md).

If a policy marks trusted time **Required**, the commitment's receipt must carry a
verifiable RFC-3161 `time_anchor` — an unanchored one fails (`AnchorRequired`,
422), exactly as the offline verifier rejects it.

### Status codes

| Code | Meaning |
| --- | --- |
| 400 | Malformed JSON or schema validation failure |
| 401 | Invalid API key |
| 404 | Not found |
| 409 | Duplicate commitment (already recorded) |
| 422 | Signature / envelope failed server verification |
| 429 | Rate limited (honor `Retry-After`) |
| 503 | Server at capacity (honor `Retry-After`) |

## Environment variables

Used by the Python SDK (`heso.init()` resolves explicit args → env → `heso.toml`
→ defaults) and the TS SDK (`configure`):

| Var | Used for |
| --- | --- |
| `HESO_API_KEY` | Cloud api-key (TS `configure`). |
| `HESO_ENDPOINT` | Cloud base URL (TS `configure`). |
| `HESO_PROJECT_ROOT` | Where to discover `heso.toml` / `heso-local-data/`. |
| `HESO_KEY_PASSPHRASE` | Decrypts the encrypted operator key (every key loader). |
| `HESO_KEY_PASSPHRASE_FILE` | A file holding that passphrase (read on startup). |
| `HESO_REQUIRE_PASSPHRASE` | Strict custody: refuse to auto-generate a dev passphrase. |
| `HESO_ENV` | `production`/`prod` hard-blocks the dev passphrase. |
| `HESO_WORKFLOW` | Default workflow label for captured actions. |
| `HESO_ACCOUNT` | Default account. |
| `HESO_BLOCKING` | Default blocking mode (default `true`). |
| `HESO_CLOCK` | Clock override (testing). |
| `HESO_TIMEOUT` | Engine call timeout. |

**Needs the API key:** the cloud calls above. **Needs nothing (local, offline):**
`gate`, `assertGate`, all signing, hashing, redaction, and the browser WASM verify.
