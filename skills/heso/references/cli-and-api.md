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
local data directory to `.gitignore`. It is idempotent — an existing key and policy
are left as-is. It leaves:

```
heso_bootstrap.py   # import heso; heso.init()
heso.toml           # starter policy written by heso init (first-match-wins rules)
heso-local-data/    # minted Ed25519 operator key + receipts.jsonl + audit chain + outbox (gitignored)
```

**Zero-setup key passphrase.** Every `heso._core` key loader resolves its passphrase
from `HESO_KEY_PASSPHRASE`. To avoid a hard-fail on a fresh machine, `heso init`
auto-generates a **dev-only** passphrase into `heso-local-data/DEV-ONLY.passphrase`
(0600) and `heso.init()` loads it back into the env for the whole in-process
lifecycle. This is labeled dev mode, not weakened custody — the file sits next to the
key it unlocks, so it adds no protection. An explicit `HESO_KEY_PASSPHRASE` always
wins. Strict mode — `--require-passphrase`, `HESO_REQUIRE_PASSPHRASE`, or
`HESO_ENV=production`/`prod` — refuses to generate **or** adopt a dev passphrase and
demands a real one.

`heso demo` mints one allowed + one redacted receipt through the real engine, verifies
both offline, and prints the `heso verify <hash>` line to re-check them yourself —
zero network, zero cloud. `verify` / `show` resolve their argument as a receipt
`.json` path or an `action_hash` (full or prefix) looked up in `receipts.jsonl`.

There is no separate engine binary: gating, signing, and the audit chain all run
**in-process** via the bundled `heso._core` wheel (minting needs a wheel built with
the `process` feature). Never commit `heso-local-data/`: the signing key, the dev
passphrase, the audit log, `receipts.jsonl`, and the outbox live there and stay on
the machine.

A standalone Rust verifier, `heso-verify-cli [--json] <receipts.jsonl>
<public_key_file>`, checks a receipt bundle offline with zero heso install (exit
0 valid, 1 invalid, 2 unsupported, 64 usage). It is the binary an evidence bundle's
`VERIFY.sh` resolves, and it ships from the MIT/Apache-dual-licensed open verifier
repo alongside the published wire specs (`ACTION-RECEIPT-1.0`/`2.0`,
`TRANSPARENCY-1.0`, `HESO-1.0`).

## Cloud API

Base URL is your endpoint; auth is the `x-api-key` header. The org (tenant) is
resolved from the key — there is **no team id** in any path, and approvals are
keyed by `action_hash`.

```
x-api-key: <API_KEY>
Content-Type: application/json
```

Get the API key from the dashboard (Settings / Billing).

| Method | Path | Body | Returns |
| --- | --- | --- | --- |
| GET | `/v1/policy/pull` | — | `{ status, policy_id, policy_hash, toml }` |
| POST | `/v1/receipts` | `{ receipt, supersedes_action_hash? }` | `{ status, entry_hash, seq }` |
| GET | `/v1/approvals/{action_hash}` | — | `ApprovalView` (carries `threshold` + `approved_count`) |
| GET | `/v1/approvals/{action_hash}/assembly` | — | the relayed co-sign legs |
| POST | `/v1/approvals/{action_hash}/submit-token` | `SubmitTokenRequest` | `ApprovalView` |
| POST | `/v1/evidence/export` | export request | a self-verifying evidence bundle (tar w/ `receipts.jsonl` + `VERIFY.sh`). **Team+ only.** |

`status` on a receipt push is `appended` / `duplicate` / `quota_exceeded`. There
is no batch route — `pushReceipts` loops over `POST /v1/receipts`. An approval is
opened by mirror-pushing the suspended receipt (not a separate open call).

**One unified assembly surface drives both single-approver and quorum.** `GET
/v1/approvals/{action_hash}/assembly` returns a `legs` list (there is **no** separate
`/l1-parts` route): `getL1Parts` reads `legs[0]`, `getQuorumParts` reads the whole
list. Each `submit-token` call records **one** approver's vote, so a k-of-n quorum is
`threshold` separate submit-token calls — each approver co-signs their own leg **in
their browser** with a per-device key; the cloud relays the detached co-signatures
(it holds no signing key). The operator SDK then re-mints the L1 (a quorum carries a
`multi_approval` block but is **still L1**, not a higher level) and re-verifies it
before push.

If a policy marks trusted time **Required** for the lane, the pushed receipt must
carry a verifiable RFC-3161 `time_anchor` — an unanchored one fails re-verification
(`AnchorRequired`, a 422), exactly as the offline verifier would reject it.

The server **re-verifies** every receipt through the same Rust core before
accepting it — a tampered or under-signed receipt is rejected at the control plane,
not just locally.

### Status codes

| Code | Meaning |
| --- | --- |
| 400 | Malformed JSON or schema validation failure |
| 401 | Invalid API key |
| 404 | Not found |
| 422 | Receipt failed server re-verification |
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
| `HESO_ENV` | `production`/`prod` hard-blocks the dev passphrase (forces real custody). |
| `HESO_WORKFLOW` | Default workflow label for captured actions. |
| `HESO_ACCOUNT` | Default account. |
| `HESO_BLOCKING` | Default blocking mode (default `true`). |
| `HESO_CLOCK` | Clock override (testing). |
| `HESO_TIMEOUT` | Engine call timeout. |
| `HESO_BIN` | Legacy/compat — accepted but not needed (gating is in-process). |

**Needs the API key:** `pullPolicy`, `pushReceipt(s)`, `pollApproval`,
`waitForApproval`, `getL1Parts`, `getQuorumParts`, `submitApprovalToken`.
**Needs nothing (local, offline):** `gate`, `assertGate`, all signing, hashing,
redaction, and the browser WASM verify.
