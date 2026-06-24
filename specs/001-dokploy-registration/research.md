# Phase 0 Research: Dokploy S3 Destination Registration

**Date**: 2026-06-23
**Source of truth**: `github.com/Dokploy/dokploy` (`canary` branch), files:
- `packages/server/src/db/schema/destination.ts` (DB table + Zod `api*Destination` schemas)
- `apps/dokploy/server/api/routers/destination.ts` (tRPC router)
- `apps/dokploy/components/dashboard/settings/destination/constants.ts` (`S3_PROVIDERS`)
- `apps/dokploy/scripts/generate-openapi.ts` + committed `/openapi.json` (HTTP mapping, auth)

All decisions below are source-confirmed unless marked otherwise.

---

## D-001 — `provider` value for AWS S3

**Decision**: Send `provider: "AWS"`.

**Rationale**: `provider` is a free `text` column / `z.string()` (not a Zod enum), but the UI dropdown
`S3_PROVIDERS` lists `{ key: "AWS", name: "Amazon Web Services (AWS) S3" }`, and the value feeds
rclone's `--s3-provider` flag. `"AWS"` is the canonical value for Amazon S3.

**Alternatives considered**: `"Other"` (generic S3-compatible) — rejected; less correct for real AWS and
may change rclone behaviour. Free-string means a typo would silently pass schema validation but fail at
connection-test time — so the value is hardcoded as a constant, not user-supplied.

---

## D-002 — `destination.create` request body

**Decision**: POST JSON body = `{ name, provider, accessKey, secretAccessKey, bucket, region, endpoint }`,
plus `serverId` only when a `--server-id` is supplied. **Omit `additionalFlags`.**

**Rationale**: `apiCreateDestination` requires `name, provider, accessKey, secretAccessKey, bucket,
region, endpoint`. `additionalFlags` is `z.array(z.string()).default([])` and is **dropped from the
generated OpenAPI request body** (trpc-openapi drops the defaulted array); it is an **array**, so the
earlier assumption of sending `""` is wrong. Omitting it is valid and simplest. `serverId` is
`z.string().optional()`.

**Alternatives considered**: sending `additionalFlags: []` explicitly — harmless but unnecessary; omit.
Sending `additionalFlags: ""` — **invalid** (wrong type), would be rejected. Resolved the spec's "empty
additional-flags" assumption: the field is omitted entirely.

---

## D-003 — Connection verification: `destination.testConnection`, ordered BEFORE create

**Decision**: POST `destination.testConnection` with the **raw credential fields** (same shape as create,
no id). Run it **before** `destination.create`. 2xx ⇒ proceed to create; non-2xx ⇒ fail the run
(non-zero) and surface the response body (rclone error message).

**Rationale**: The route is a mutation taking `apiCreateDestination` (credentials, not a `destinationId`);
internally it runs `rclone ls :s3:<bucket>`. Because it validates the *credentials against the bucket*
(independent of any stored record), testing **before** create is strictly better than after: a bad
credential/bucket fails fast and leaves **no orphan destination** in Dokploy. This refines FR-012 — the
intent ("verify the credentials reach the bucket, fail loudly otherwise") is fully met; only the ordering
moves earlier. Success body is empty (HTTP 200); failure is HTTP 400 with the rclone error (fallback
`"Error connecting to bucket"`).

**Alternatives considered**: test after create (spec's literal wording) — rejected: leaves an orphan
destination on failure and offers no safety benefit since the test is credential-based. No test at all —
rejected by the locked decision.

**Cloud caveat**: on Dokploy Cloud (`IS_CLOUD`), `testConnection` throws `404 "Server not found"` without
`serverId`. Mitigation: support an optional `--server-id` flag; if the test returns that specific error,
surface a hint that Cloud requires `--server-id`.

---

## D-004 — Idempotency lookup: `GET destination.all`

**Decision**: `GET {base}/destination.all` (header `x-api-key`, no input), parse the returned JSON array
with `jq`, and skip create if any element's `.name` equals the target destination name.

**Rationale**: `all` is a tRPC `.query()` ⇒ GET, no input; returns the full array of destination rows; the
display field is `name` (identifier is `destinationId`). Matching on `name` is sufficient for skip-only
idempotency (FR-011).

**Caveat (confirmed)**: the committed `openapi.json` renders the `all` 200 response as an empty object
(trpc-openapi didn't infer the output type), but at runtime it returns the array. We rely on the runtime
shape; `jq` tolerates extra/unknown fields.

---

## D-005 — OpenAPI HTTP mapping & auth

**Decision**: Base path `{DOKPLOY_URL}/api`; dot-notation routes. Queries → **GET** (query-string input),
mutations → **POST** (JSON body). Auth header **`x-api-key: <token>`** on every call.

| Procedure | HTTP | Path | Input |
|---|---|---|---|
| `destination.all` | GET | `{base}/destination.all` | none |
| `destination.testConnection` | POST | `{base}/destination.testConnection` | JSON body (raw creds) |
| `destination.create` | POST | `{base}/destination.create` | JSON body |

**Rationale**: confirmed from generated `openapi.json` and `generate-openapi.ts`
(`securitySchemes.apiKey.in = "header", name = "x-api-key"`).

---

## D-006 — Destination name derivation

**Decision**: Destination name defaults to the **provisioned bucket name**, overridable via
`--destination-name NAME`.

**Rationale**: The bucket name is already deterministic in the existing tool
(`{prefix}-{stage}-{account}-{region}[-an]`), so using it makes the idempotency check (D-004) and re-runs
refer to the same destination predictably (FR-013). An override covers the case where the operator wants a
friendlier label in the Dokploy UI.

---

## D-007 — endpoint construction (Dokploy bug #1717)

**Decision**: `endpoint = https://s3.<region>.amazonaws.com` (regional host, **no bucket** in host, no
path). Always `https`.

**Rationale**: Dokploy issue #1717 — embedding the bucket in the endpoint host breaks Dokploy's endpoint
handling. The existing tool already knows the region; build the endpoint from it. (A `--endpoint`
override remains available for non-AWS hosts, but that is out of scope per Non-Goals; for AWS we construct
it.)

---

## D-008 — New runtime dependencies (registration path only)

**Decision**: `curl` (HTTP) and `jq` (parse `destination.all` + build JSON bodies safely) are required
**only** when `--register-dokploy` is used or `configure` writes/needs JSON. A preflight check fails with a
clear, actionable message if either is missing. The AWS-only path keeps today's dependency set (AWS CLI).

**Rationale**: Honors the locked decision and keeps the default path's footprint unchanged (FR-017). `jq`
is used to **construct** the JSON body too (not string interpolation) so secret/key values are correctly
escaped.

---

## D-009 — Testing approach (no suite exists today)

**Decision**: Add `bats-core` tests covering pure/offline logic — argument/subcommand dispatch, profile
resolution precedence, endpoint construction, and `--dry-run` output (asserting the secret is redacted and
no network call is made). Keep `shellcheck` as the lint gate (extend the Makefile `lint` target to the new
code). Network calls to Dokploy are **not** hit in CI; they are exercised via `--dry-run` assertions and a
manual `quickstart.md` scenario against a real instance.

**Rationale**: Matches a single-script bash tool; `bats` + `shellcheck` are the standard, dependency-light
choices and need no live Dokploy. Mocking HTTP is possible (stub `curl` on PATH) for one happy-path
integration test, documented as optional.

---

## Resolved unknowns (from spec Assumptions)

| Unknown (spec) | Resolution |
|---|---|
| Exact `provider` enum string for AWS S3 | `"AWS"` (free string; D-001) |
| Exact test-connection endpoint name/shape | `POST destination.testConnection`, raw creds, 200/400 (D-003) |
| Whether `additionalFlags` accepts `""` | No — it's an array; **omit it** (D-002) |
| `destination.all` response shape / name field | Array of rows; field `name` (D-004) |
| OpenAPI GET/POST mapping + auth | queries GET / mutations POST; `x-api-key` (D-005) |
