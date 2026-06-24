# Phase 1 Data Model: Dokploy S3 Destination Registration

This tool has no database; "entities" are the in-memory/on-disk shapes the script manipulates.

## Connection Profile

A named, reusable set of Dokploy connection settings, persisted per user.

| Field | Source / Var | Required | Validation |
|---|---|---|---|
| profile name | `--dokploy-profile` / `DOKPLOY_PROFILE`, default `default` | yes | `^[A-Za-z0-9._-]+$` (used as a filename; reject path separators) |
| `DOKPLOY_URL` | prompt / flag / env | yes | non-empty; must start `http://` or `https://`; trailing `/` stripped |
| `DOKPLOY_API_KEY` | prompt (`read -rs`) / flag / env | yes | non-empty; never echoed or printed |

**Storage**: `${XDG_CONFIG_HOME:-$HOME/.config}/dokploy-s3/profiles/<name>.env`
- Directory mode `700`, file mode `600` (created via `umask 077`, mirroring the existing `--output-file` pattern at line 724-729).
- Format: two `KEY=VALUE` lines, safe to `source` in a subshell. Values are written quoted.
- Reading a profile that does not exist ⇒ actionable error naming the profile and the `configure` command (FR-007).

## Dokploy Backup Destination

The record created in Dokploy. Built entirely from provisioned credentials + resolved config.

| Field | Value | Notes |
|---|---|---|
| `name` | `--destination-name`, default = bucket name | predictable for idempotency (D-006, FR-013) |
| `provider` | constant `"AWS"` | D-001; not user-supplied |
| `accessKey` | provisioned IAM access key id | from existing `create_access_key` |
| `secretAccessKey` | provisioned IAM secret | never printed except existing render path |
| `bucket` | provisioned bucket name | — |
| `region` | `$REGION` | — |
| `endpoint` | `https://s3.<region>.amazonaws.com` | reuses existing var (line 695); **no bucket in host** (D-007) |
| `serverId` | `--server-id` if set | optional; required by Dokploy Cloud for `testConnection` (D-003) |
| ~~`additionalFlags`~~ | **omitted** | array type, defaulted server-side; never send `""` (D-002) |

**State / lifecycle**: skip-only idempotency — if a destination with the same `name` exists, no
create/update/delete is performed (FR-011; Non-Goals: no update/delete this iteration).

## Provisioned Credentials (input to registration)

Produced by the unchanged provisioning steps; the bridge between the AWS side and Dokploy.

| Field | Origin in script |
|---|---|
| bucket | `compute_bucket_name` (line 691) |
| region | `$REGION` |
| endpoint | line 695 |
| access key id | `create_access_key` (line 716-717) |
| secret access key | `create_access_key` (line 716-718) |

## Configuration Resolution (precedence)

For `DOKPLOY_URL` and `DOKPLOY_API_KEY`, highest wins (FR-006):

1. Explicit CLI flag (`--dokploy-url`; `--dokploy-api-key` — discouraged, leaks in process list, documented)
2. Process environment (`DOKPLOY_URL` / `DOKPLOY_API_KEY`)
3. Selected profile file (`--dokploy-profile` / `DOKPLOY_PROFILE`)
4. `default` profile file

If, after resolution, either value is empty when registration is requested ⇒ stop before any network
call with guidance to run `configure` or set env/flags (FR-007).
