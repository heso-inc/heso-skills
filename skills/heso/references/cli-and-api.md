# CLI + cloud API

## CLI (`heso`)

```bash
heso init [dir]
```

`heso init` is the one CLI command. It mints your **operator identity** in-process
via the `heso._core` wheel (`init_identity` — no separate binary), writes a starter
`heso.toml`, and adds the local data directory to `.gitignore`. It is idempotent —
an existing key and policy are left as-is. It leaves:

```
heso_bootstrap.py   # import heso; heso.init()
heso.toml           # starter policy written by heso init (first-match-wins rules)
.heso/              # minted Ed25519 operator key + JSONL audit chain + outbox (gitignored)
```

There is no separate engine binary: gating, signing, and the audit chain all run
**in-process** via the bundled `heso._core` wheel (minting needs a wheel built with
the `process` feature). Never commit `.heso/`: the signing key, audit log, and
outbox live there and stay on the machine.

A standalone Rust verifier, `heso-verify-cli [--json] <receipts.jsonl>
<public_key_file>`, checks a receipt bundle offline with zero heso install (exit
0 valid, 1 invalid, 2 unsupported, 64 usage).

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
| GET | `/v1/approvals/{action_hash}` | — | `ApprovalView` |
| GET | `/v1/approvals/{action_hash}/l1-parts` | — | `L1Parts` |
| POST | `/v1/approvals/{action_hash}/submit-token` | `SubmitTokenRequest` | `ApprovalView` |

`status` on a receipt push is `appended` / `duplicate` / `quota_exceeded`. There
is no batch route — `pushReceipts` loops over `POST /v1/receipts`. An approval is
opened by mirror-pushing the suspended receipt (not a separate open call).

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
| `HESO_PROJECT_ROOT` | Where to discover `heso.toml` / `.heso/`. |
| `HESO_WORKFLOW` | Default workflow label for captured actions. |
| `HESO_ACCOUNT` | Default account. |
| `HESO_BLOCKING` | Default blocking mode (default `true`). |
| `HESO_CLOCK` | Clock override (testing). |
| `HESO_TIMEOUT` | Engine call timeout. |
| `HESO_BIN` | Legacy/compat — accepted but not needed (gating is in-process). |

**Needs the API key:** `pullPolicy`, `pushReceipt(s)`, `pollApproval`,
`waitForApproval`, `getL1Parts`, `submitApprovalToken`.
**Needs nothing (local, offline):** `gate`, `assertGate`, all signing, hashing,
redaction, and the browser WASM verify.
