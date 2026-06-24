# Quickstart / Validation: Dokploy S3 Destination Registration

Runnable scenarios that prove the feature works. Replace placeholders. See
[contracts/cli.md](./contracts/cli.md) and [contracts/dokploy-api.md](./contracts/dokploy-api.md) for details.

## Prerequisites

- AWS CLI v2 configured (existing requirement).
- For the registration path: `curl` and `jq` installed.
- A reachable Dokploy instance and an API token (Dokploy → Settings → `/settings/profile` → API/CLI).

## Scenario A — Store a profile once (US2)

```bash
./create-dokploy-s3-destination.sh configure --dokploy-profile prod
# prompts: Dokploy URL  -> https://dokploy.example.com
#          API key      -> (hidden input)
```
**Expect**: file `~/.config/dokploy-s3/profiles/prod.env` exists, mode `600`; the token was never echoed.
```bash
stat -f '%Sp' ~/.config/dokploy-s3/profiles/prod.env   # -> -rw-------  (Linux: stat -c '%A')
```

## Scenario B — Preview without acting (US4, dry-run)

```bash
./create-dokploy-s3-destination.sh create \
  --stage prod --prefix passbolt-backups --profile my-aws-profile \
  --register-dokploy --dokploy-profile prod --dry-run
```
**Expect**: intended `POST .../api/destination.create` printed with body; `secretAccessKey` shown as
`***REDACTED***`; **no** network call made; exit 0.

## Scenario C — Provision + register end-to-end (US1)

```bash
./create-dokploy-s3-destination.sh create \
  --stage prod --prefix passbolt-backups --profile my-aws-profile \
  --register-dokploy --dokploy-profile prod
```
**Expect**: bucket/IAM provisioned; credentials printed (as today); connection test passes; destination
created; success summary; exit 0. Verify in Dokploy UI that a destination named after the bucket exists
and tests green — **without any manual UI entry** (SC-001).

## Scenario D — Idempotent re-run (US3)

Run Scenario C again unchanged.
**Expect**: "destination '<bucket>' already exists, skipping"; exactly one destination in Dokploy; exit 0 (SC-003).

## Scenario E — Backward compatibility (SC-004)

```bash
./create-dokploy-s3-destination.sh --stage prod --prefix x --profile my-aws-profile --dry-run
```
**Expect**: identical output to the previous tool version (no subcommand, no Dokploy mention). Compare
against the prior release's dry-run output.

## Scenario F — Failure surfaces (FR-012)

Use a deliberately wrong region/endpoint or revoked key with `--register-dokploy` (no `--dry-run`).
**Expect**: credentials still printed first; connection test fails with the rclone error verbatim; exit non-zero.

## Offline test suite

```bash
make test        # bats: dispatch, profile precedence, endpoint build, dry-run redaction
make lint        # shellcheck (gate)
```
