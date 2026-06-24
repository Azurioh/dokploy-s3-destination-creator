# Feature Specification: Dokploy S3 Destination Registration

**Feature Branch**: `001-dokploy-registration`

**Created**: 2026-06-23

**Status**: Draft

**Input**: User description: "Push the automation further so the tool can register the provisioned S3 bucket as a backup destination in Dokploy automatically, with stored per-account connection settings, instead of the current manual copy-paste into the Dokploy UI."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Provision and register in one command (Priority: P1)

An operator runs the tool to provision an S3 bucket and, in the same command, asks it to register that bucket as a backup destination in Dokploy. When the command finishes, the destination already exists in Dokploy and has been confirmed to work — the operator never opens the Dokploy UI.

**Why this priority**: This is the core value. It removes the error-prone manual copy-paste of five credential fields that exists today and is the reason the feature exists.

**Independent Test**: With a reachable Dokploy instance and valid credentials supplied, run the provisioning command with registration enabled, then confirm in Dokploy that a destination with the expected name, bucket, region, and endpoint exists and reports a successful connection — with no manual UI interaction.

**Acceptance Scenarios**:

1. **Given** valid AWS credentials and reachable Dokploy connection settings, **When** the operator runs the provisioning command with registration enabled, **Then** the S3 bucket is provisioned, a Dokploy destination is created with the matching values, the connection is verified, and a success summary is shown.
2. **Given** registration is not enabled, **When** the operator runs the provisioning command, **Then** the tool behaves exactly as it does today (provisions and prints the credentials) and makes no network call to Dokploy.
3. **Given** the Dokploy connection verification fails (the supplied credentials cannot reach the bucket), **When** the command runs, **Then** no destination is created, the operator is told the registration could not be verified, sees the underlying error, and the command exits with a non-zero status.

---

### User Story 2 - Store connection settings once per account (Priority: P1)

An operator who manages one or more Dokploy instances saves the connection settings (instance address and access token) once, under a named profile. Later provisioning runs reuse that profile so the operator never re-enters the address or token.

**Why this priority**: Re-entering the instance address and access token on every run is the redundancy the operator explicitly wants removed; without persistence the one-command flow is not actually convenient for repeated use.

**Independent Test**: Run the configuration command for a named profile, supply an address and token, then run a provisioning-with-registration command referencing that profile without re-supplying the address or token, and confirm it connects using the stored settings.

**Acceptance Scenarios**:

1. **Given** the operator runs the configuration command for a profile, **When** they enter the instance address and access token, **Then** the settings are saved for that profile so future runs can use them, and the token is never echoed back on screen.
2. **Given** a stored profile exists, **When** the operator runs a registration without supplying address or token, **Then** the tool uses the stored profile's settings.
3. **Given** settings are provided in more than one place, **When** the tool resolves which to use, **Then** it applies a documented precedence (explicit command input over environment over selected profile over the default profile).
4. **Given** no connection settings can be resolved from any source, **When** registration is requested, **Then** the tool stops with a clear message explaining how to configure them.

---

### User Story 3 - Re-runs do not create duplicates (Priority: P2)

An operator re-runs a provisioning-with-registration command for a destination that already exists in Dokploy (for example, after a partial earlier run or to refresh the bucket setup). The tool recognises the existing destination and does not create a duplicate.

**Why this priority**: The rest of the tool is idempotent (bucket and IAM steps are skipped when already present); registration must match that behaviour so re-runs are safe and do not litter Dokploy with duplicate destinations.

**Independent Test**: Register a destination, then run the same registration again and confirm that exactly one destination with that name exists in Dokploy and the second run reports it was skipped.

**Acceptance Scenarios**:

1. **Given** a Dokploy destination with the target name already exists, **When** the operator re-runs registration, **Then** the tool reports the destination already exists, skips creation, and exits successfully.
2. **Given** no destination with the target name exists, **When** the operator runs registration, **Then** the destination is created.

---

### User Story 4 - Preview before acting (Priority: P3)

An operator runs the command in preview mode to see exactly what would be sent to Dokploy before any real change is made, without exposing the secret credential.

**Why this priority**: The tool already supports a dry-run for the AWS side; extending it to the Dokploy side lets cautious operators verify the intended action, but it is a safety convenience rather than core functionality.

**Independent Test**: Run the registration command in preview mode and confirm it prints the intended request target and field values with the secret credential masked, and that no destination is created in Dokploy.

**Acceptance Scenarios**:

1. **Given** preview mode is active, **When** the operator runs registration, **Then** the tool prints the intended Dokploy action and field values with the secret credential masked, and performs no network call.

---

### Edge Cases

- **Insecure connection address**: When the Dokploy address is not local and is not secured in transit, the tool warns that the access token and secret credential would travel unprotected.
- **Missing optional tooling**: When the helpers required only for the registration path are absent, the tool fails the registration path with a clear, actionable message while leaving the provisioning-only path unaffected.
- **Unreachable instance / authentication rejected**: When the instance cannot be reached or the token is rejected, the tool surfaces the underlying error and exits non-zero rather than silently continuing.
- **Endpoint format**: The endpoint value supplied to Dokploy must be the regional service host without the bucket name embedded, to avoid a known Dokploy endpoint-handling defect.
- **Profile name with no stored file**: When a referenced profile has never been configured, the tool explains that the profile is unknown and how to create it.
- **Partial failure after key creation**: When provisioning succeeds but registration fails, the operator still receives the provisioned credentials so the work is not lost and can be completed manually.

## Requirements *(mandatory)*

### Functional Requirements

#### Command structure & compatibility

- **FR-001**: The tool MUST expose a `configure` action (to store connection settings) and a `create` action (to provision and optionally register), while preserving today's invocation as the default action so existing usage continues to work unchanged.
- **FR-002**: The registration behaviour MUST be opt-in and OFF by default; when not enabled, the tool's observable output for the provisioning path MUST be identical to the current behaviour and MUST make no network call to Dokploy.

#### Connection settings & profiles

- **FR-003**: The tool MUST let an operator save Dokploy connection settings (instance address and access token) under a named profile, defaulting to a profile named `default` when none is given.
- **FR-004**: The configuration action MUST collect the access token without displaying it on screen and MUST never echo a stored token back in any output.
- **FR-005**: Stored settings MUST be persisted so they are readable only by the owning user, and they MUST be stored under the user's standard per-user configuration location.
- **FR-006**: The tool MUST resolve connection settings using a documented precedence: explicit command input, then environment-provided values, then the selected profile, then the `default` profile.
- **FR-007**: When registration is requested but no connection settings can be resolved, the tool MUST stop before contacting Dokploy and explain how to provide or configure them.
- **FR-008**: The tool MUST allow selecting which profile to use for a given run.

#### Registration behaviour

- **FR-009**: When registration is enabled, the tool MUST create a Dokploy backup destination using the provisioned values: destination name, storage provider, access credential, secret credential, bucket, region, and endpoint.
- **FR-010**: The endpoint value supplied to Dokploy MUST be the regional service host without the bucket name embedded in it.
- **FR-011**: Before creating a destination, the tool MUST check whether a destination with the target name already exists and, if so, skip creation, report the skip, and exit successfully (idempotent re-runs, no duplicates).
- **FR-012**: Before creating a destination, the tool MUST verify that the supplied credentials successfully reach the target bucket, and MUST NOT create the destination — failing the run with the underlying error and a non-zero exit — if verification does not succeed. (Verifying first avoids leaving an orphaned, non-working destination in Dokploy; see research decision D-003.)
- **FR-013**: The tool MUST derive the destination name in a predictable, documented way so that idempotency checks and re-runs refer to the same destination.

#### Safety, preview & dependencies

- **FR-014**: In preview mode, the tool MUST print the intended Dokploy action and field values, MUST mask the secret credential, and MUST NOT perform any network call.
- **FR-015**: The tool MUST never print the secret credential or the access token in cleartext in normal output, preview output, or logs.
- **FR-016**: When the Dokploy address is not local and not secured in transit, the tool MUST warn the operator that credentials would be transmitted unprotected.
- **FR-017**: Additional tooling required only for the registration path MUST be required only when that path is used; its absence MUST produce a clear, actionable error and MUST NOT affect the provisioning-only path.

### Key Entities *(include if feature involves data)*

- **Connection Profile**: A named set of Dokploy connection settings — instance address and access token — stored per user and reusable across runs. The `default` profile is used when none is selected.
- **Dokploy Backup Destination**: The S3 destination as represented inside Dokploy — identified by name and carrying bucket, region, endpoint, and the access/secret credentials needed to reach the bucket.
- **Provisioned Credentials**: The bucket name, region, endpoint, access credential, and secret credential produced by the existing provisioning steps; these are the inputs to registration.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can take a freshly provisioned bucket all the way to a working, verified Dokploy destination in a single command, with zero manual steps in the Dokploy interface.
- **SC-002**: After configuring a profile once, an operator can register subsequent destinations for that account without re-entering the instance address or access token.
- **SC-003**: Running the same registration twice results in exactly one destination in Dokploy (no duplicates).
- **SC-004**: With registration disabled, the provisioning output is unchanged from the previous version of the tool (verifiable by comparison).
- **SC-005**: The secret credential and access token never appear in cleartext in command output, preview output, or logs, in 100% of runs.
- **SC-006**: When registration cannot be completed, the operator still retains the provisioned credentials needed to finish manually, and the command's exit status reflects the failure.

## Assumptions

- The exact storage-provider identifier expected by Dokploy for AWS S3, the precise name/shape of the connection-verification action, and whether the "additional flags" field accepts an empty value are technical details to be confirmed against the target Dokploy instance's live API description during implementation; reasonable defaults (AWS S3 provider, a dedicated test-connection action, and an empty additional-flags value) are assumed until confirmed.
- The operator runs the tool against a single AWS account and region per invocation; multi-account or multi-region batch registration is out of scope.
- The Dokploy instance is reachable from the machine running the tool and the operator holds a valid access token with permission to manage destinations.
- The existing provisioning steps (bucket, least-privilege user, access key) and their current output remain the source of the values handed to registration.
- Per-user secret storage as an owner-readable file under the standard configuration location is an acceptable security posture for this tool; OS keychain integration is explicitly out of scope for this iteration.

### Non-Goals

- No automation for non-AWS object storage providers (e.g. MinIO, Scaleway, Cloudflare R2).
- No access-key rotation automation.
- No update or deletion of existing Dokploy destinations; idempotency is skip-only with no force/overwrite option in this iteration.
- No multi-account or multi-region batch provisioning/registration in a single invocation.
