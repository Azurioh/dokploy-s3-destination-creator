---
description: "Task list for Dokploy S3 Destination Registration"
---

# Tasks: Dokploy S3 Destination Registration

**Input**: Design documents from `/specs/001-dokploy-registration/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/cli.md, contracts/dokploy-api.md, quickstart.md

**Tests**: INCLUDED — user requested bats-core tests for offline logic + shellcheck gate (TDD: write/verify failing before implementing the matching function).

**Organization**: Grouped by user story. ⚠️ **Single-file constraint**: nearly all implementation tasks edit the
one script `create-dokploy-s3-destination.sh`, so they are **sequential within that file** — `[P]` is used only
for tasks in genuinely different files (bats specs, README, install.sh, Makefile, CONTRIBUTING). Stories remain
independently *testable*, but not independently *editable* in parallel (shared file). See Dependencies.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: different file, no dependency on an incomplete task
- **[Story]**: US1–US4 (foundational/setup/polish carry no story label)

## Path notes

- Tool (edited in place): `create-dokploy-s3-destination.sh` (anchors from plan.md: globals after L53,
  `parse_args` 107–135, `require_aws` 190, `awsx` 198, `main` 678, render at 635, credential render at L716–722).
- Tests: `tests/*.bats`. Docs: `README.md`, `install.sh`, `Makefile`, `CONTRIBUTING.md`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Make the offline test harness runnable before writing logic.

- [ ] T001 Create `tests/` directory and `tests/helpers.bash` with a stub-curl/stub-aws helper and a temp
  `XDG_CONFIG_HOME` fixture, plus `tests/dokploy_registration.bats` containing one smoke test asserting
  `./create-dokploy-s3-destination.sh --help` exits 0 and prints usage.
- [ ] T002 [P] Add a `test` target to `Makefile` that runs `bats tests/` (guard: skip with a clear message if
  `bats` is not installed) — do not modify the existing `lint` target yet.
- [ ] T003 [P] Document bats-core install + `make test` in `CONTRIBUTING.md` (new "Tests" section).

**Checkpoint**: `make test` runs and the smoke test passes against the unmodified script.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Shared plumbing every story needs. All tasks edit `create-dokploy-s3-destination.sh` (sequential).

**⚠️ CRITICAL**: No user story work begins until this phase is complete.

- [ ] T004 Add new globals + constants after L53 in `create-dokploy-s3-destination.sh`: `SUBCOMMAND=""`,
  `REGISTER_DOKPLOY=false`, `DOKPLOY_URL=""`, `DOKPLOY_API_KEY=""`, `DOKPLOY_PROFILE_NAME="default"`,
  `DOKPLOY_SERVER_ID=""`, `DESTINATION_NAME=""`; `readonly DOKPLOY_PROVIDER="AWS"`,
  `readonly DOKPLOY_HTTP_TIMEOUT=15`, and a `config_dir()` helper returning `${XDG_CONFIG_HOME:-$HOME/.config}/dokploy-s3`.
- [ ] T005 [P] Bats: write FAILING tests in `tests/dispatch.bats` for subcommand dispatch — bare invocation routes to
  create (existing flags still parse), explicit `create`/`configure` recognized, unknown subcommand falls through to
  create's arg parser, `--help`/`--version` still work at top level.
- [ ] T006 Refactor `main` (L678) into subcommand dispatch in `create-dokploy-s3-destination.sh`: rename the current
  `main` body to `cmd_create`; new `main` peeks `$1` — if `configure`/`create`, shift into `SUBCOMMAND` and dispatch;
  otherwise default to `cmd_create` with full argv (backward compatible, FR-001/FR-002). Make T005 pass.
- [ ] T007 [P] Bats: write FAILING tests in `tests/config.bats` for the config layer — profile-name charset
  validation (reject `/`, `..`), profile path build under a temp `XDG_CONFIG_HOME`, `read_profile` sources only
  `DOKPLOY_URL`/`DOKPLOY_API_KEY`, and `resolve_dokploy_config` precedence (flag > env > selected profile > default).
- [ ] T008 Implement the config layer functions in `create-dokploy-s3-destination.sh`: `dokploy_profile_path`,
  `validate_profile_name`, `read_profile` (source in a subshell, export only the two vars), and
  `resolve_dokploy_config` applying the data-model.md precedence; missing-profile and unresolved-config errors are
  actionable (FR-006/FR-007). Make T007 pass.
- [ ] T009 Implement the HTTP layer in `create-dokploy-s3-destination.sh`: `require_dokploy_tools` (curl+jq preflight
  with install hint, FR-017), `dokploy_api` wrapper (mirrors `awsx` at L198 — prepends `${DOKPLOY_URL%/}/api`, sets
  `x-api-key`, `--max-time "$DOKPLOY_HTTP_TIMEOUT"`, returns status+body), and `warn_if_insecure_url` (non-https &&
  non-localhost ⇒ warn, FR-016).
- [ ] T010 [P] Bats: write FAILING test in `tests/security.bats` asserting `warn_if_insecure_url` warns for an
  `http://` non-localhost URL and stays silent for `https://` and `http://localhost`. Make it pass via T009.

**Checkpoint**: dispatch + config + http plumbing exist and their offline tests are green; no behavior change to the
default AWS-only path.

---

## Phase 3: User Story 1 - Provision and register in one command (Priority: P1) 🎯 MVP

**Goal**: `create --register-dokploy` provisions S3 then creates a verified Dokploy destination, zero UI steps.

**Independent Test**: With a reachable Dokploy + valid creds, run create with `--register-dokploy`; destination
exists in Dokploy with matching name/bucket/region/endpoint and tests green (quickstart Scenario C).

- [ ] T011 [US1] Add registration flags to `parse_args` (107–135) in `create-dokploy-s3-destination.sh`:
  `--register-dokploy`, `--dokploy-url`, `--dokploy-profile`, `--dokploy-api-key`, `--server-id`,
  `--destination-name`; update `usage()` (62–103). **Do NOT touch `--profile`** (AWS profile). Add validation
  (e.g. `--dokploy-api-key` prints a process-list-leak warning; URL scheme check).
- [ ] T012 [P] [US1] Bats: write FAILING tests in `tests/body.bats` for `build_dokploy_body` — asserts JSON has
  `provider:"AWS"`, the seven required fields, **no** `additionalFlags` key, and `serverId` present only when
  `--server-id` set; verify a secret containing quotes/backslashes is correctly escaped (jq-built, D-002).
- [ ] T013 [US1] Implement `build_dokploy_body` (jq `-n`, per contracts/dokploy-api.md) and `dokploy_create`
  (POST `/destination.create`, 2xx ⇒ ok, non-2xx ⇒ surface status+body, exit non-zero) in
  `create-dokploy-s3-destination.sh`. Make T012 pass.
- [ ] T014 [US1] Implement `dokploy_test_connection` (POST `/destination.testConnection` with the same body; 200 ⇒
  pass; 400 ⇒ surface rclone error verbatim + exit non-zero; 404 "Server not found" ⇒ hint `--server-id`) in
  `create-dokploy-s3-destination.sh` (D-003, FR-012).
- [ ] T015 [US1] Implement `register_dokploy_destination` orchestration in `create-dokploy-s3-destination.sh`:
  `require_dokploy_tools` → `resolve_dokploy_config` → `warn_if_insecure_url` → (idempotency check placeholder; real
  check lands in US3) → `dokploy_test_connection` → `dokploy_create` → success summary (destination name + URL, **no
  secret**). Derive destination name = `${DESTINATION_NAME:-$bucket}` (D-006).
- [ ] T016 [US1] Wire registration into `cmd_create` after the credential render (after L722, before the "shown only
  once" warning at L734): `if [[ "$REGISTER_DOKPLOY" == true ]]; then register_dokploy_destination ...; fi`. Ensure
  credentials are always printed first so a registration failure never loses them (Edge: partial failure).

**Checkpoint**: end-to-end provision+register works against a live instance (Scenario C); failure path surfaces and
exits non-zero (Scenario F).

---

## Phase 4: User Story 2 - Store connection settings once per account (Priority: P1)

**Goal**: `configure` saves a named profile (URL + token) so later runs reuse it without re-entry.

**Independent Test**: `configure --dokploy-profile prod`, then a registration referencing `prod` without URL/token
uses the stored settings (quickstart Scenario A + reuse).

- [ ] T017 [P] [US2] Bats: write FAILING tests in `tests/configure.bats` — feeding URL + token via a stubbed
  `read`, `cmd_configure` creates `<XDG>/dokploy-s3/profiles/prod.env` with file mode `600` and dir mode `700`, and
  the token never appears in stdout/stderr (FR-004/FR-005).
- [ ] T018 [US2] Implement `cmd_configure` in `create-dokploy-s3-destination.sh`: resolve+validate profile name,
  prompt `DOKPLOY_URL` (visible) and `DOKPLOY_API_KEY` (`read -rs`, no echo), `mkdir -p` config dir (umask 077),
  write `<name>.env` (quoted values, mode 600), confirm with the path — never echo the token. Make T017 pass.
- [ ] T019 [US2] Add a `configure` usage/help branch (so `configure --help` works) in
  `create-dokploy-s3-destination.sh`.

**Checkpoint**: Scenario A passes; a stored profile drives Scenario C without `--dokploy-url`/token.

---

## Phase 5: User Story 3 - Re-runs do not create duplicates (Priority: P2)

**Goal**: skip-only idempotency — existing destination name ⇒ no duplicate, exit 0.

**Independent Test**: run registration twice; exactly one destination in Dokploy; second run reports skip (Scenario D).

- [ ] T020 [P] [US3] Bats: write FAILING test in `tests/idempotency.bats` — `dokploy_destination_exists` given a
  sample `destination.all` JSON array returns success when `.name` matches and failure otherwise (jq `any`).
- [ ] T021 [US3] Implement `dokploy_destination_exists` (GET `/destination.all`, `jq -e 'any(.[]?; .name==$n)'`,
  per contracts/dokploy-api.md) in `create-dokploy-s3-destination.sh`. Make T020 pass.
- [ ] T022 [US3] Replace the idempotency placeholder in `register_dokploy_destination` (T015): before
  test/create, if `dokploy_destination_exists` ⇒ log "destination '<name>' already exists, skipping" and return 0
  (FR-011); non-2xx from the lookup ⇒ surface + exit non-zero.

**Checkpoint**: Scenario D yields exactly one destination; re-run exits 0 with skip message.

---

## Phase 6: User Story 4 - Preview before acting (Priority: P3)

**Goal**: `--dry-run` prints intended Dokploy calls with secret + token redacted and makes no network call.

**Independent Test**: registration with `--dry-run` prints redacted `POST .../destination.create`; no curl runs;
exit 0 (Scenario B).

- [ ] T023 [P] [US4] Bats: write FAILING test in `tests/dryrun.bats` — registration with `--dry-run` prints the
  intended method/URL/body with `secretAccessKey` and the API key shown as `***REDACTED***`, and a PATH-stubbed
  `curl` that fails if invoked is **never** called (FR-014/FR-015).
- [ ] T024 [US4] Add dry-run guards in `dokploy_api`/`register_dokploy_destination` (reuse existing `DRY_RUN`,
  L51/699): when `DRY_RUN==true`, print the redacted intended call(s) and skip all network I/O. Make T023 pass.

**Checkpoint**: Scenario B passes; no Dokploy call occurs under `--dry-run`.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [ ] T025 [P] Update `README.md`: document `configure`/`create` subcommands, profiles + precedence,
  `--register-dokploy` and new flags, the curl/jq registration-only deps, and replace the "manual Dokploy UI" steps
  (current README L274–284) with the automated flow.
- [ ] T026 [P] Update `install.sh`: note curl + jq as optional dependencies needed only for `--register-dokploy`.
- [ ] T027 Extend the `Makefile` `lint` target so shellcheck covers the new code; ensure `make lint` is clean
  (zero warnings) for the whole script.
- [ ] T028 Bump `VERSION` (L23) `1.0.0` → `1.1.0` in `create-dokploy-s3-destination.sh` (additive feature).
- [ ] T029 Run the full gate: `make lint` + `make test` green, then manually execute quickstart Scenarios B
  (dry-run) and E (backward-compat: bare invocation output unchanged vs prior release) and record results.

---

## Dependencies & Execution Order

### Phase order

- Setup (P1) → Foundational (P2, BLOCKS all stories) → US1 → US2 → US3 → US4 → Polish.
- US3 (T022) and US1 (T015) share `register_dokploy_destination`: US1 lands a placeholder, US3 fills it — so US3
  depends on T015. US4 (T024) modifies the same orchestration/`dokploy_api` ⇒ depends on US1.

### Single-file reality (important)

Because US1–US4 all edit `create-dokploy-s3-destination.sh`, they **cannot** be developed in parallel by different
people without merge conflicts. Recommended: one implementer, sequential by phase. The `[P]` tasks are the
*separate-file* ones (bats specs, README, install.sh, CONTRIBUTING) which can be written alongside.

### Within each story

- Write the bats test ([P], different file) first and confirm it FAILS, then implement the function in the script to
  make it pass.

### Parallel opportunities

- T002 + T003 (Makefile target + CONTRIBUTING) — different files.
- All `*.bats` authoring tasks (T005, T007, T010, T012, T017, T020, T023) are [P] vs script edits (different files),
  but each must precede its paired implementation task.
- T025 + T026 (README + install.sh) in Polish — different files.

---

## Implementation Strategy

### MVP (User Story 1)

1. Phase 1 Setup → 2. Phase 2 Foundational (CRITICAL) → 3. Phase 3 US1 → **STOP & VALIDATE** Scenario C/F.
US1 alone delivers the core value (one-command verified registration) using `--dokploy-url`/env, even before
`configure` exists.

### Incremental delivery

US1 (MVP, one-command register) → US2 (stored profiles, removes re-entry) → US3 (idempotent re-runs) →
US4 (dry-run preview) → Polish (docs, lint, version, quickstart validation). Each increment keeps the AWS-only
default path byte-for-byte unchanged (SC-004).

---

## Notes

- [P] = different file, no incomplete dependency. Same-file tasks are never [P].
- TDD: every implementation task has a preceding [P] bats task; verify red before green.
- Never print the secret or API token (incl. dry-run/logs); profile files are mode 600.
- Commit after each task or logical group; keep commit messages in English.
