# Contributing to dokploy-s3-destination-creator

Thanks for taking the time to contribute! This project is a single, focused Bash script, so the bar for contributing is low — but we keep quality high. This guide covers how to set up, what we expect from changes, and how to get them merged.

By participating, you agree to keep interactions respectful and constructive. Be kind; assume good intent.

## Table of contents

- [Ways to contribute](#ways-to-contribute)
- [Development setup](#development-setup)
- [Coding standards](#coding-standards)
- [Testing your changes](#testing-your-changes)
- [Commit messages](#commit-messages)
- [Pull request process](#pull-request-process)
- [Reporting bugs](#reporting-bugs)
- [Reporting security issues](#reporting-security-issues)

## Ways to contribute

- 🐛 **Report a bug** — open an [issue](https://github.com/Azurioh/dokploy-s3-destination-creator/issues) with steps to reproduce.
- 💡 **Suggest a feature** — open an issue describing the use case before sending a PR for anything non-trivial.
- 📖 **Improve the docs** — typos, clarifications, and better examples are always welcome.
- 🔧 **Submit a fix or feature** — see the process below.

## Development setup

You only need a few tools:

| Tool | Purpose |
| --- | --- |
| [`bash`](https://www.gnu.org/software/bash/) ≥ 4 | Runtime. |
| [`shellcheck`](https://www.shellcheck.net/) | Static analysis — **required** to pass before merge. |
| [`bats-core`](https://github.com/bats-core/bats-core) | Test runner for the `tests/` suite — **required** to pass before merge. |
| [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | Only needed for live (non-dry-run) testing. |
| [`curl`](https://curl.se/) + [`jq`](https://jqlang.github.io/jq/) | Only needed for the Dokploy registration path (`--register-dokploy` / `configure`). |

```bash
git clone https://github.com/Azurioh/dokploy-s3-destination-creator.git
cd dokploy-s3-destination-creator
chmod +x create-dokploy-s3-destination.sh
```

Install ShellCheck:

```bash
# macOS
brew install shellcheck
# Debian/Ubuntu
sudo apt-get install shellcheck
```

## Coding standards

The script follows a consistent style — please match it.

- **Strict mode.** The script runs under `set -euo pipefail`. Don't weaken it. Write code that's correct under these flags (e.g. guard against unset variables, handle expected non-zero exits with `if cmd; then`).
- **ShellCheck-clean.** No warnings. If you must suppress one, add a scoped `# shellcheck disable=SCxxxx` with a comment explaining why.
- **One responsibility per function.** Each AWS operation lives in its own small function. Keep them pure and testable where possible.
- **Always use braces.** Every `if`/`else`/`for`/`while` body uses `{ }`-style blocks on their own lines — no one-line `if x; then y; fi` shortcuts, no `[[ ... ]] && cmd` for control flow.
- **No magic values.** Extract defaults into the `readonly` constants block at the top of the file.
- **Naming.** Functions and local variables are `snake_case`; module-level configuration variables are `UPPER_SNAKE_CASE`.
- **Logging.** Use the existing `log` / `ok` / `warn` / `err` helpers (they respect `--quiet` and write to stderr). Never `echo` progress to stdout — stdout is reserved for the final machine-readable result.
- **Fail loudly, clearly.** On AWS errors, surface the captured output and exit non-zero. Where a failure is recoverable (e.g. resource already exists), warn and continue.
- **Comments explain *why*, not *what*.** Only comment non-obvious intent.
- **Keep the default path dependency-free.** The AWS-only provisioning path must rely on the AWS CLI alone — parse AWS output with `--query`/`--output`, no `jq`. Extra dependencies (`curl`, `jq`) are allowed **only** on the opt-in Dokploy registration path and must be guarded by a preflight check so the default path keeps working without them.

## Testing your changes

Every change must pass ShellCheck and, where it touches behavior, be exercised in dry-run.

**1. Lint:**

```bash
make lint        # shellcheck create-dokploy-s3-destination.sh
```

**1b. Run the test suite** (bats — offline, no AWS or Dokploy needed):

```bash
make test        # runs bats tests/
```

New behavior should come with a bats test under `tests/`. Tests source the script (its
`main` is guarded so sourcing does not execute it) and call functions directly, or run the
script as a subprocess. See `tests/helpers.bash` for shared helpers.

**2. Validate argument handling (no AWS needed):**

```bash
./create-dokploy-s3-destination.sh --help
./create-dokploy-s3-destination.sh --stage prod --prefix p --profile x --namespace bogus  # should reject
```

**3. Exercise the full flow without touching AWS** by stubbing the `aws` binary on `PATH`:

```bash
TMPD=$(mktemp -d)
cat > "$TMPD/aws" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  if [[ "$a" == "get-caller-identity" ]]; then echo "123456789012"; exit 0; fi
done
echo "stub: unexpected mutation call" >&2; exit 1
STUB
chmod +x "$TMPD/aws"
PATH="$TMPD:$PATH" ./create-dokploy-s3-destination.sh \
  --stage prod --prefix demo --profile demo --output json --dry-run --quiet
```

**4. (Optional) Live test** against a throwaway AWS account/region before submitting changes to real AWS calls. Clean up any test buckets/users afterwards.

## Commit messages

- Write commits in **English**.
- Follow [Conventional Commits](https://www.conventionalcommits.org/): `type(scope): summary`.
  - Common types: `feat`, `fix`, `docs`, `refactor`, `chore`, `test`.
  - Keep the subject line ≤ 72 characters, imperative mood.
- Add a body when the *why* isn't obvious from the subject.

Examples:

```
feat: add --lifecycle-days option for object expiration
fix: skip LocationConstraint in us-east-1
docs: clarify operator IAM permissions
```

## Pull request process

1. **Fork** the repository and create a branch from `main`:
   ```bash
   git checkout -b feat/my-change
   ```
2. Make your change, keeping commits focused.
3. Ensure ShellCheck passes and the relevant tests above succeed.
4. Update the [README](README.md) if you add, rename, or change an option's behavior — the options table must stay accurate.
5. Open a PR against `main` with a clear description of **what** changed and **why**. Link any related issue.
6. Be responsive to review feedback. A maintainer will merge once checks pass and the change is approved.

All PR titles, descriptions, and review comments should be written in **English**.

## Reporting bugs

Open an [issue](https://github.com/Azurioh/dokploy-s3-destination-creator/issues) and include:

- The exact command you ran (**redact account IDs, keys, and secrets**).
- What you expected vs. what happened.
- Relevant error output (again, redacted).
- Your `aws --version` and `bash --version`.

## Reporting security issues

If you discover a vulnerability — for example a way the script could leak credentials or create an over-permissive policy — **do not open a public issue**. Instead, contact the maintainer privately so it can be addressed before disclosure.

---

Thanks again for contributing! 🎉
