# dokploy-s3-destination-creator

> One command to provision a hardened, least-privilege S3 bucket and the credentials needed to wire it up as a [Dokploy](https://dokploy.com) S3 destination.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/shell-bash-4EAA25.svg?logo=gnubash&logoColor=white)](#requirements)
[![ShellCheck](https://img.shields.io/badge/lint-shellcheck-brightgreen.svg)](https://www.shellcheck.net/)

`create-dokploy-s3-destination.sh` automates the boring, error-prone setup behind a Dokploy backup destination:

1. Creates an S3 bucket (using the new [account-regional namespace](https://aws.amazon.com/blogs/aws/introducing-account-regional-namespaces-for-amazon-s3-general-purpose-buckets/), or the classic global namespace).
2. Creates a dedicated IAM user whose inline policy grants access to **that bucket only**.
3. Issues an access key and prints everything Dokploy needs: bucket, region, endpoint, access key, secret key.

It is **secure by default** (server-side encryption + full public-access block), **idempotent** (safe to re-run), and **scriptable** (`text`, `env`, or `json` output, plus a `--dry-run` mode).

---

## Table of contents

- [Why](#why)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Options](#options)
- [Output formats](#output-formats)
- [What it creates](#what-it-creates)
- [Using it with Dokploy](#using-it-with-dokploy)
- [IAM permissions for the operator](#iam-permissions-for-the-operator)
- [Safety & idempotency](#safety--idempotency)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

---

## Why

Setting up an S3 destination by hand means juggling bucket naming rules, a least-privilege IAM policy, encryption settings, and access-key handling — every time, for every stage. A copy-pasted policy that's too broad, a bucket left publicly accessible, or a key pasted into the wrong place are easy mistakes. This script encodes the safe path once so each destination is provisioned the same correct way.

## Requirements

| Tool | Notes |
| --- | --- |
| [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | Configured with a profile that has the [permissions below](#iam-permissions-for-the-operator). |
| `bash` ≥ 4 | The script uses arrays and modern Bash features. |

No other dependencies — output parsing uses the AWS CLI's own `--query`/`--output`, so `jq` is **not** required.

> **Account-regional namespace** is an AWS feature released in March 2026. If your account or region does not support it yet, pass `--namespace global` to fall back to the classic global namespace.

## Installation

Pick whichever fits your workflow.

### One-line installer (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/Azurioh/dokploy-s3-destination-creator/main/install.sh | bash
```

Pin a version or choose the install directory:

```bash
curl -fsSL https://raw.githubusercontent.com/Azurioh/dokploy-s3-destination-creator/main/install.sh | VERSION=v1.0.0 bash
curl -fsSL https://raw.githubusercontent.com/Azurioh/dokploy-s3-destination-creator/main/install.sh | INSTALL_DIR="$HOME/.local/bin" bash
```

The installer resolves the target directory automatically (`INSTALL_DIR` → a writable `/usr/local/bin` → `~/.local/bin`), warns if the AWS CLI is missing, and tells you if the install directory isn't on your `PATH`. Prefer to audit it first? Download, read, then run it.

### From a clone (Makefile)

```bash
git clone https://github.com/Azurioh/dokploy-s3-destination-creator.git
cd dokploy-s3-destination-creator

sudo make install                  # system-wide, into /usr/local/bin
make install PREFIX="$HOME/.local" # user-only, no sudo
make uninstall                     # remove it
```

### Manual / no install

```bash
git clone https://github.com/Azurioh/dokploy-s3-destination-creator.git
cd dokploy-s3-destination-creator
chmod +x create-dokploy-s3-destination.sh
./create-dokploy-s3-destination.sh --help
```

### Updating

On startup the tool checks whether a newer version exists and, when run
interactively, offers to install it for you:

```
[!] A new version is available: 1.0.0 -> 1.1.0
Install the update now? [y/N]
```

Answering `y` runs the installer and exits so you can re-run with the new
version. The check is best-effort — it never blocks the tool when you are
offline — and is **skipped automatically** with `--quiet`, `--dry-run`, in
non-interactive shells (it just prints a hint instead of prompting), or when
`DOKPLOY_S3_NO_UPDATE_CHECK` is set. Disable it per-run with `--no-update-check`.

You can also update manually at any time — re-installing overwrites the old
binary in place.

```bash
# If you installed via the one-liner, run it again (reports old -> new version):
curl -fsSL https://raw.githubusercontent.com/Azurioh/dokploy-s3-destination-creator/main/install.sh | bash

# If you installed from a clone:
git pull && sudo make install
```

Check your installed version at any time:

```bash
create-dokploy-s3-destination --version
```

## Quick start

```bash
./create-dokploy-s3-destination.sh \
  --stage prod \
  --prefix passbolt-backups \
  --profile my-aws-profile
```

Output:

```
============================================================
 Dokploy S3 destination
============================================================
 Bucket name        : passbolt-backups-prod-123456789012-eu-west-3-an
 Region             : eu-west-3
 Endpoint           : https://s3.eu-west-3.amazonaws.com
 Access Key ID      : AKIAIOSFODNN7EXAMPLE
 Secret Access Key  : wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
============================================================
```

> 💡 Always preview with `--dry-run` first if you're unsure what will be created.

## Options

| Flag | Default | Description |
| --- | --- | --- |
| `--stage <name>` | *(required)* | Deployment stage (e.g. `prod`, `staging`, `dev`). |
| `--prefix <name>` | *(required)* | Bucket name prefix (e.g. `passbolt-backups`). |
| `--profile <name>` | *(required)* | AWS CLI profile to use. |
| `--region <region>` | `eu-west-3` | Target AWS region. |
| `--namespace <ns>` | `account-regional` | `account-regional` or `global`. See [naming](#bucket-naming). |
| `--bucket-name <name>` | *computed* | Use an exact bucket name (skips name computation). |
| `--user-name <name>` | `dokploy-<prefix>-<stage>` | IAM user name. |
| `--policy-name <name>` | `<prefix>-<stage>-s3-access` | Inline policy name. |
| `--encryption <mode>` | `AES256` | `AES256`, `aws:kms`, or `none`. |
| `--kms-key-id <id>` | — | KMS key id/ARN/alias (required when `--encryption aws:kms`). |
| `--no-public-access-block` | *(block on)* | Skip the S3 Block Public Access configuration. |
| `--versioning` | *(off)* | Enable bucket versioning. |
| `--lifecycle-days <n>` | — | Expire objects (and noncurrent versions) after `n` days. |
| `--tags <k=v,k=v>` | — | Tags applied to both the bucket and the IAM user. |
| `--endpoint <url>` | *computed* | Override the endpoint shown in the output (display only). |
| `--output <format>` | `text` | `text`, `env`, or `json`. |
| `--output-file <path>` | — | Also write the result to a file (`chmod 600`). |
| `--dry-run` | — | Print intended actions without making any change. |
| `--quiet` | — | Suppress progress logs (errors are still shown). |
| `--no-update-check` | — | Skip the startup check for a newer version. |
| `-v`, `--version` | — | Print the version and exit. |
| `-h`, `--help` | — | Show usage. |

### Examples

Backup-grade bucket with versioning, retention, and tags:

```bash
./create-dokploy-s3-destination.sh \
  --stage prod --prefix passbolt-backups --profile my-aws-profile \
  --versioning --lifecycle-days 30 --tags 'app=passbolt,env=prod'
```

KMS encryption with a specific key:

```bash
./create-dokploy-s3-destination.sh \
  --stage prod --prefix vault --profile my-aws-profile \
  --encryption aws:kms --kms-key-id alias/backups
```

Capture credentials for automation:

```bash
# As a sourceable env file
./create-dokploy-s3-destination.sh --stage ci --prefix artifacts --profile ci --output env --quiet > s3.env

# As JSON, piped into another tool
./create-dokploy-s3-destination.sh --stage ci --prefix artifacts --profile ci --output json --quiet | jq .
```

Preview before committing to anything:

```bash
./create-dokploy-s3-destination.sh --stage dev --prefix myapp --profile dev --dry-run
```

## Output formats

**`text`** (default) — the human-readable summary box shown above.

**`env`** — ready to source into a shell or `.env` file:

```bash
DOKPLOY_S3_BUCKET=passbolt-backups-prod-123456789012-eu-west-3-an
DOKPLOY_S3_REGION=eu-west-3
DOKPLOY_S3_ENDPOINT=https://s3.eu-west-3.amazonaws.com
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
```

**`json`** — for piping into other tooling:

```json
{
  "bucket": "passbolt-backups-prod-123456789012-eu-west-3-an",
  "region": "eu-west-3",
  "endpoint": "https://s3.eu-west-3.amazonaws.com",
  "accessKeyId": "AKIAIOSFODNN7EXAMPLE",
  "secretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
}
```

## What it creates

### Bucket naming

| Namespace | Computed name |
| --- | --- |
| `account-regional` (default) | `<prefix>-<stage>-<account-id>-<region>-an` |
| `global` | `<prefix>-<stage>-<account-id>-<region>` |

The `-an` suffix and account/region segments are required by the account-regional namespace. Use `--bucket-name` to bypass this entirely.

### IAM policy (least privilege)

The IAM user receives an inline policy scoped to the new bucket and nothing else:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "ListBucket",    "Effect": "Allow", "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::<bucket>" },
    { "Sid": "ObjectActions", "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::<bucket>/*" }
  ]
}
```

### Security defaults

| Setting | Default | Disable with |
| --- | --- | --- |
| Server-side encryption (SSE-S3) | **On** | `--encryption none` |
| Block Public Access (all four toggles) | **On** | `--no-public-access-block` |
| Versioning | Off | — (enable with `--versioning`) |

> An **IAM user** is created rather than a role, because Dokploy needs long-lived access keys, which roles cannot provide.

## Using it with Dokploy

1. Run the script and keep the output handy.
2. In Dokploy, go to **Settings → S3 Destinations → Add Destination**.
3. Fill in the fields from the output:
   - **Bucket** → `Bucket name`
   - **Region** → `Region`
   - **Endpoint** → `Endpoint`
   - **Access Key** → `Access Key ID`
   - **Secret Key** → `Secret Access Key`
4. Save and run a test backup.

## IAM permissions for the operator

The profile passed via `--profile` must be allowed to perform the actions the script calls. A minimal policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "sts:GetCallerIdentity", "Resource": "*" },
    { "Effect": "Allow", "Action": [
        "s3:CreateBucket",
        "s3:PutBucketPublicAccessBlock",
        "s3:PutEncryptionConfiguration",
        "s3:PutBucketVersioning",
        "s3:PutLifecycleConfiguration",
        "s3:PutBucketTagging"
      ], "Resource": "*" },
    { "Effect": "Allow", "Action": [
        "iam:CreateUser",
        "iam:TagUser",
        "iam:PutUserPolicy",
        "iam:CreateAccessKey",
        "iam:ListAccessKeys"
      ], "Resource": "*" }
  ]
}
```

Trim the statements you don't need (e.g. drop `s3:PutBucketVersioning` if you never use `--versioning`).

## Safety & idempotency

- **Re-running is safe.** An existing bucket you own (`BucketAlreadyOwnedByYou`) or user (`EntityAlreadyExists`) is detected and the script continues; the inline policy is simply overwritten.
- **Access keys are not duplicated blindly.** IAM caps a user at two access keys; if that limit is hit, the script stops and tells you how to list and rotate keys instead of failing cryptically.
- **`--dry-run`** performs only the read-only account lookup and prints every action it *would* take.
- **Secrets** are printed once. Use `--output-file` to write them to a `chmod 600` file, and never commit them.

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| `Failed to resolve AWS account` | Bad/expired profile credentials. Check `aws sts get-caller-identity --profile <profile>`. |
| `create-bucket failed ... InvalidBucketName` | Name too long (> 63 chars) or namespace unsupported. Shorten `--prefix`/`--stage` or try `--namespace global`. |
| `already has the maximum of 2 access keys` | Delete an unused key (`aws iam list-access-keys --user-name <user>`), then re-run. |
| `AccessDenied` on a `Put*` call | Operator profile is missing a permission — see the [policy above](#iam-permissions-for-the-operator). |

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, coding standards, and the pull-request process.

## License

[MIT](LICENSE) © Azurioh
