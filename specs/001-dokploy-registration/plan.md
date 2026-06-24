# Implementation Plan: Dokploy S3 Destination Registration

**Branch**: `001-dokploy-registration` | **Date**: 2026-06-23 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-dokploy-registration/spec.md`

## Summary

Extend the existing single-file Bash tool so that, in addition to provisioning a hardened S3
bucket + scoped IAM user, it can **register that bucket as a backup destination in Dokploy** via
Dokploy's OpenAPI (`x-api-key` auth), and **store the Dokploy connection once per named profile**
so it is not re-entered on every run. Behaviour is additive and opt-in: with no new flags the tool
is byte-for-byte identical to today. Approach: add a subcommand layer (`configure` / `create`,
default `create`), a profile config layer (`~/.config/dokploy-s3/profiles/<name>.env`, chmod 600),
and a Dokploy HTTP layer (`testConnection` → idempotency check → `create`) gated behind
`--register-dokploy`. See [research.md](./research.md) for source-confirmed API decisions.

## Technical Context

**Language/Version**: Bash (`set -euo pipefail`; bash 4+ for arrays/regex already used). Single
distributable script `create-dokploy-s3-destination.sh`.

**Primary Dependencies**: AWS CLI v2 (existing, unchanged). **New, registration-path only**: `curl`
(HTTP) and `jq` (build JSON bodies with correct escaping + parse `destination.all`). Guarded by a
preflight check; absent ⇒ clear error; AWS-only path keeps today's dependency set.

**Storage**: Per-profile env files at `${XDG_CONFIG_HOME:-$HOME/.config}/dokploy-s3/profiles/<name>.env`
holding `DOKPLOY_URL` and `DOKPLOY_API_KEY`. Dir mode `700`, file mode `600`. Sourced in a subshell.

**Testing**: `bats-core` for offline logic (subcommand dispatch, profile precedence, endpoint build,
`--dry-run` redaction). `shellcheck` as the lint gate (existing `make lint` extended). No live Dokploy
in CI; network paths exercised via `--dry-run` assertions + a manual `quickstart.md` scenario.

**Target Platform**: macOS + Linux developer/operator workstations (local CLI).

**Project Type**: Single-file CLI tool (no app/service split).

**Performance Goals**: N/A — interactive CLI; at most 3 short Dokploy HTTP calls per registration.

**Constraints**: Must remain one distributable script (installer + Makefile fetch a single file);
default path unchanged (backward compatible); secret + API token never printed in cleartext (incl.
`--dry-run` and logs); new deps only on the opt-in path.

**Scale/Scope**: One AWS account + region per invocation; estimated +~250–350 lines of Bash plus
docs and a small bats suite.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

The project constitution (`.specify/memory/constitution.md`) is the **unratified template** (placeholder
principles), so there are no project-specific ratified gates. The applicable invariants are the user's
global engineering rules; this design is checked against them:

- **Backward compatibility / smallest change**: additive subcommand + opt-in flag; default behaviour
  preserved (FR-001/FR-002, SC-004). PASS.
- **Single Responsibility per function**: new code split into a config layer, an HTTP layer, and a
  registration orchestration step — each function one reason to change. PASS.
- **No secret leakage**: token via `read -rs`, never echoed; `jq`-built bodies; redaction in dry-run;
  files chmod 600 (FR-004/FR-005/FR-014/FR-015). PASS.
- **Reuse before add**: reuses existing `endpoint` construction (line 695), `awsx`-style wrapper pattern,
  `DRY_RUN`, logging helpers, and naming. PASS.
- **No new architecture**: stays a single Bash script per the existing distribution model. PASS.

**Result**: PASS — no violations; Complexity Tracking left empty.

## Project Structure

### Documentation (this feature)

```text
specs/001-dokploy-registration/
├── plan.md              # This file
├── spec.md              # Feature spec
├── research.md          # Phase 0 — Dokploy API decisions (D-001..D-009)
├── data-model.md        # Phase 1 — entities (Profile, Destination, Provisioned Credentials)
├── quickstart.md        # Phase 1 — runnable validation scenarios
├── contracts/
│   ├── cli.md           # CLI contract: subcommands, flags, env, precedence, exit codes
│   └── dokploy-api.md   # Dokploy HTTP contract used by the tool (all/testConnection/create)
└── checklists/
    └── requirements.md  # Spec quality checklist (from /speckit-specify)
```

### Source Code (repository root)

```text
create-dokploy-s3-destination.sh   # the tool — edited in place, additive sections:
                                    #   • globals block (new vars)
                                    #   • subcommand dispatch in main()
                                    #   • configure_* functions (config layer)
                                    #   • dokploy_* functions (HTTP layer)
                                    #   • register_dokploy_destination (orchestration)
install.sh                         # mention curl/jq as optional (registration) deps
Makefile                           # extend `lint` (shellcheck) to new code; add `test` (bats)
README.md                          # document configure/create, profiles, --register-dokploy
CONTRIBUTING.md                    # note bats tests + how to run them
tests/                             # NEW — bats suite (offline)
└── dokploy_registration.bats
```

**Structure Decision**: Single-file CLI is retained (constitution-aligned, matches install/Makefile
which fetch one file). All runtime logic lives in `create-dokploy-s3-destination.sh`, organised into
clearly separated function groups; tests live under a new `tests/` dir and are not shipped by the
installer.

### Integration points in the existing script (file:line)

- **Globals** (after line 53): add `SUBCOMMAND`, `REGISTER_DOKPLOY=false`, `DOKPLOY_URL`,
  `DOKPLOY_API_KEY`, `DOKPLOY_PROFILE_NAME="default"`, `DOKPLOY_SERVER_ID`, `DESTINATION_NAME`.
  Constants: `DOKPLOY_PROVIDER="AWS"` (D-001), `CONFIG_DIR`, `HTTP_TIMEOUT`.
- **`parse_args`** (107–135): add `--register-dokploy`, `--dokploy-url`, `--dokploy-profile`,
  `--server-id`, `--destination-name`. **Do NOT touch `--profile`** (it is the AWS profile; the Dokploy
  profile is `--dokploy-profile`, env `DOKPLOY_PROFILE`).
- **`require_aws`** (190): add a sibling `require_dokploy_tools` (curl + jq) called only on the
  registration path.
- **`awsx`** (198): mirror with `dokploy_api()` wrapper carrying base URL + `x-api-key`.
- **`main`** (678): wrap into subcommand dispatch — peek `$1`; if `configure`/`create`, shift into
  `SUBCOMMAND`; else default to `create` (bare invocation = today's behaviour). Current `main` body
  becomes `cmd_create`; new `cmd_configure`.
- **End of `cmd_create`** (after line 731, before the "shown only once" warning): if
  `REGISTER_DOKPLOY` ⇒ `register_dokploy_destination "$bucket" "$REGION" "$endpoint" "$access_key" "$secret_key"`.

## Complexity Tracking

> No constitution violations — section intentionally empty.
