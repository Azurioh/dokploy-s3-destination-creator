# Contract: CLI Surface

## Subcommands

| Invocation | Meaning |
|---|---|
| `script create [opts]` | Provision S3 (+ optional Dokploy registration). |
| `script [opts]` | **Same as `create`** — bare invocation, backward compatible (FR-001). |
| `script configure [--dokploy-profile NAME]` | Interactively store a Dokploy connection profile. |

Dispatch: peek `$1`; if it equals `configure` or `create`, consume it; otherwise treat the whole
argv as `create` arguments. `-h/--help` and `-v/--version` continue to work at top level.

## New flags on `create`

| Flag | Default | Notes |
|---|---|---|
| `--register-dokploy` | off | Opt-in; when off, no Dokploy code runs and output is unchanged (FR-002). |
| `--dokploy-url URL` | — | Overrides resolved URL (precedence rank 1). |
| `--dokploy-profile NAME` | `default` | Selects the stored profile. **Distinct from `--profile` (AWS).** |
| `--dokploy-api-key KEY` | — | Discouraged (process-list leak); documented. Prefer env/profile. |
| `--server-id ID` | — | Optional; required by Dokploy Cloud for the connection test. |
| `--destination-name NAME` | bucket name | Name of the Dokploy destination (idempotency key). |

`--dry-run` (existing) extends to Dokploy: prints intended method + URL + JSON body with the secret
and any token **redacted**; performs no network call (FR-014).

## `configure` behaviour

1. Resolve profile name (`--dokploy-profile`, default `default`); validate charset.
2. Prompt for `DOKPLOY_URL` (visible) and `DOKPLOY_API_KEY` (`read -rs`, no echo).
3. `mkdir -p` config dir (mode 700); write `<name>.env` (mode 600, `umask 077`).
4. Confirm with the profile path; **never** print the token back (FR-004).

## Environment variables

`DOKPLOY_URL`, `DOKPLOY_API_KEY`, `DOKPLOY_PROFILE` — consumed per the precedence in data-model.md.

## Preflight (registration path only)

- `curl` and `jq` must be present ⇒ else error with install hint and exit non-zero (FR-017).
- Resolved URL not `https://` and host not `localhost`/`127.0.0.1` ⇒ **warn** about cleartext transit (FR-016).
- URL or API key unresolved ⇒ error pointing to `configure` (FR-007).

## Exit codes

| Code | Condition |
|---|---|
| 0 | Success (incl. idempotent skip; incl. dry-run). |
| 1 | Usage/validation error, unresolved config, missing deps. |
| non-zero (propagated) | Provisioning failure (existing), or Dokploy test/create failure (FR-012). |

## Ordering within `create --register-dokploy`

Provision (unchanged) → write `--output-file` if requested → `require_dokploy_tools` → resolve
config → idempotency check (`GET destination.all`, skip if name exists) → `testConnection`
(retried while the new IAM key is still propagating, then fail-fast) → `create` → success summary.

The S3 destination block (including the secret key) is **not** printed to the terminal when
registration succeeds: Dokploy now holds the credentials. To guarantee the once-only secret is
never lost on a partial failure, any Dokploy-side failure prints the credentials before exiting
non-zero. Without `--register-dokploy`, the block is always printed as before.
