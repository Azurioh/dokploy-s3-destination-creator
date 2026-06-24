#!/usr/bin/env bash
#
# Create an S3 bucket and a dedicated IAM user scoped to that bucket only,
# then print everything needed to configure a Dokploy S3 destination
# (bucket, region, endpoint, access key, secret key).
#
# An IAM *user* is created, not a role: Dokploy needs long-lived access keys,
# which roles cannot provide.
#
# Secure by default: bucket encryption (SSE-S3) and full public-access block
# are applied unless explicitly disabled.
#
# Usage:
#   ./create-dokploy-s3-destination.sh \
#       --stage prod --prefix passbolt-backups --profile my-aws-profile
#
# Run with --help for the full list of options.

set -euo pipefail

# --- Defaults --------------------------------------------------------------

readonly VERSION="1.1.0"
readonly REPO="Azurioh/dokploy-s3-destination-creator"
readonly REMOTE_SCRIPT="create-dokploy-s3-destination.sh"
readonly UPDATE_REF="main"             # branch/tag the update check compares against
readonly UPDATE_TIMEOUT=3              # seconds before the update check gives up
readonly DEFAULT_REGION="eu-west-3"
readonly DEFAULT_NAMESPACE="account-regional"
readonly NAMESPACE_SUFFIX="an"     # required trailing label for account-regional names
readonly DEFAULT_ENCRYPTION="AES256"
readonly DEFAULT_OUTPUT="text"

# Dokploy registration (opt-in) constants.
readonly DOKPLOY_PROVIDER="AWS"        # rclone --s3-provider value Dokploy expects for AWS S3
readonly DOKPLOY_HTTP_TIMEOUT=15       # seconds per Dokploy API call
readonly DEFAULT_DOKPLOY_PROFILE="default"

STAGE=""
PREFIX=""
PROFILE=""
REGION="$DEFAULT_REGION"
NAMESPACE="$DEFAULT_NAMESPACE"     # account-regional | global
BUCKET_NAME=""                     # explicit override of the computed name
USER_NAME=""
POLICY_NAME=""
ENCRYPTION="$DEFAULT_ENCRYPTION"   # AES256 | aws:kms | none
KMS_KEY_ID=""
BLOCK_PUBLIC_ACCESS=true
VERSIONING=false
LIFECYCLE_DAYS=""
TAGS=""                            # k1=v1,k2=v2
ENDPOINT_OVERRIDE=""               # override the endpoint shown in the output only
OUTPUT="$DEFAULT_OUTPUT"           # text | env | json
OUTPUT_FILE=""
DRY_RUN=false
QUIET=false
NO_UPDATE_CHECK=false

# Dokploy connection. DOKPLOY_URL / DOKPLOY_API_KEY may come from the
# environment, so they are intentionally NOT initialized here (initializing
# would clobber exported values); resolve_dokploy_config sets them after
# applying precedence. OPT_* hold CLI-flag overrides (highest precedence).
OPT_DOKPLOY_URL=""
OPT_DOKPLOY_API_KEY=""
DOKPLOY_PROFILE_NAME="$DEFAULT_DOKPLOY_PROFILE"
REGISTER_DOKPLOY=false
DOKPLOY_SERVER_ID=""
DESTINATION_NAME=""

# --- Logging ---------------------------------------------------------------

log()  { if [[ "$QUIET" == true ]]; then return 0; fi; printf '\033[0;34m[*]\033[0m %s\n' "$*" >&2; }
ok()   { if [[ "$QUIET" == true ]]; then return 0; fi; printf '\033[0;32m[+]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[-]\033[0m %s\n' "$*" >&2; }

usage() {
  cat >&2 <<EOF
Create an S3 bucket + scoped IAM user and emit (or register) Dokploy S3 destination settings.

Usage:
  $0 [create] --stage <stage> --prefix <prefix> --profile <aws-profile> [options]
  $0 configure [--dokploy-profile <name>]    # store a Dokploy connection profile

('create' is the default when no subcommand is given.)

Required (create):
  --stage <name>            Deployment stage (e.g. prod, staging, dev)
  --prefix <name>           Bucket name prefix (e.g. passbolt-backups)
  --profile <name>          AWS CLI profile to use

Naming:
  --region <region>         AWS region (default: ${DEFAULT_REGION})
  --namespace <ns>          account-regional | global (default: ${DEFAULT_NAMESPACE})
                            account-regional uses the per-account namespace and
                            appends -<account>-<region>-${NAMESPACE_SUFFIX} to the name.
  --bucket-name <name>      Use this exact bucket name (skips name computation)
  --user-name <name>        IAM user name (default: dokploy-<prefix>-<stage>)
  --policy-name <name>      Inline policy name (default: <prefix>-<stage>-s3-access)

Bucket hardening:
  --encryption <mode>       AES256 | aws:kms | none (default: ${DEFAULT_ENCRYPTION})
  --kms-key-id <id>         KMS key id/ARN/alias (required when --encryption aws:kms)
  --no-public-access-block  Do not apply the S3 Block Public Access settings
  --versioning              Enable bucket versioning
  --lifecycle-days <n>      Expire objects (and noncurrent versions) after n days
  --tags <k=v,k=v>          Tags applied to both the bucket and the IAM user

Output:
  --endpoint <url>          Override the endpoint shown in the output
  --output <format>         text | env | json (default: ${DEFAULT_OUTPUT})
  --output-file <path>      Also write the result to a file (chmod 600)
  --dry-run                 Print intended actions without making any change
  --quiet                   Suppress progress logs (errors still shown)
  --no-update-check         Do not check for a newer version on startup
  -v, --version             Print the version and exit
  -h, --help                Show this help

Dokploy registration (opt-in; needs curl + jq):
  --register-dokploy        After provisioning, register the bucket as a Dokploy
                            S3 destination (verifies the connection first).
  --dokploy-url <url>       Dokploy base URL (e.g. https://dokploy.example.com).
  --dokploy-profile <name>  Stored connection profile to use (default: ${DEFAULT_DOKPLOY_PROFILE}).
  --dokploy-api-key <key>   API key (discouraged: visible in the process list;
                            prefer 'configure' or the DOKPLOY_API_KEY env var).
  --server-id <id>          Dokploy server id (required by Dokploy Cloud).
  --destination-name <name> Destination name in Dokploy (default: the bucket name).

Connection settings resolve as: flag > env (DOKPLOY_URL / DOKPLOY_API_KEY) >
selected profile > '${DEFAULT_DOKPLOY_PROFILE}' profile. Store a profile with '$0 configure'.

The startup update check is skipped automatically with --quiet, --dry-run, or
when DOKPLOY_S3_NO_UPDATE_CHECK is set. It never blocks on errors or offline use.
EOF
}

# --- Argument parsing ------------------------------------------------------

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stage)                  STAGE="${2:-}"; shift 2 ;;
      --prefix)                 PREFIX="${2:-}"; shift 2 ;;
      --profile)                PROFILE="${2:-}"; shift 2 ;;
      --region)                 REGION="${2:-}"; shift 2 ;;
      --namespace)              NAMESPACE="${2:-}"; shift 2 ;;
      --bucket-name)            BUCKET_NAME="${2:-}"; shift 2 ;;
      --user-name)              USER_NAME="${2:-}"; shift 2 ;;
      --policy-name)            POLICY_NAME="${2:-}"; shift 2 ;;
      --encryption)             ENCRYPTION="${2:-}"; shift 2 ;;
      --kms-key-id)             KMS_KEY_ID="${2:-}"; shift 2 ;;
      --no-public-access-block) BLOCK_PUBLIC_ACCESS=false; shift ;;
      --versioning)             VERSIONING=true; shift ;;
      --lifecycle-days)         LIFECYCLE_DAYS="${2:-}"; shift 2 ;;
      --tags)                   TAGS="${2:-}"; shift 2 ;;
      --endpoint)               ENDPOINT_OVERRIDE="${2:-}"; shift 2 ;;
      --output)                 OUTPUT="${2:-}"; shift 2 ;;
      --output-file)            OUTPUT_FILE="${2:-}"; shift 2 ;;
      --dry-run)                DRY_RUN=true; shift ;;
      --quiet)                  QUIET=true; shift ;;
      --no-update-check)        NO_UPDATE_CHECK=true; shift ;;
      --register-dokploy)       REGISTER_DOKPLOY=true; shift ;;
      --dokploy-url)            OPT_DOKPLOY_URL="${2:-}"; shift 2 ;;
      --dokploy-profile)        DOKPLOY_PROFILE_NAME="${2:-}"; shift 2 ;;
      --server-id)              DOKPLOY_SERVER_ID="${2:-}"; shift 2 ;;
      --destination-name)       DESTINATION_NAME="${2:-}"; shift 2 ;;
      --dokploy-api-key)
        OPT_DOKPLOY_API_KEY="${2:-}"
        warn "--dokploy-api-key is visible in the process list; prefer 'configure' or the DOKPLOY_API_KEY env var."
        shift 2
        ;;
      -v|--version)             printf 'create-dokploy-s3-destination %s\n' "$VERSION"; exit 0 ;;
      -h|--help)                usage; exit 0 ;;
      *)                        err "Unknown argument: $1"; usage; exit 1 ;;
    esac
  done
}

validate_args() {
  local missing=0
  if [[ -z "$STAGE" ]];   then err "--stage is required";   missing=1; fi
  if [[ -z "$PREFIX" ]];  then err "--prefix is required";  missing=1; fi
  if [[ -z "$PROFILE" ]]; then err "--profile is required"; missing=1; fi
  if [[ "$missing" -eq 1 ]]; then usage; exit 1; fi

  if ! [[ "$PREFIX" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
    err "Invalid --prefix '$PREFIX': lowercase letters, digits, dots and hyphens only"
    exit 1
  fi
  if ! [[ "$STAGE" =~ ^[a-z0-9-]+$ ]]; then
    err "Invalid --stage '$STAGE': lowercase letters, digits and hyphens only"
    exit 1
  fi
  case "$NAMESPACE" in
    account-regional|global) ;;
    *) err "Invalid --namespace '$NAMESPACE': expected 'account-regional' or 'global'"; exit 1 ;;
  esac
  case "$ENCRYPTION" in
    AES256|none) ;;
    aws:kms)
      if [[ -z "$KMS_KEY_ID" ]]; then
        err "--encryption aws:kms requires --kms-key-id"
        exit 1
      fi ;;
    *) err "Invalid --encryption '$ENCRYPTION': expected AES256, aws:kms or none"; exit 1 ;;
  esac
  case "$OUTPUT" in
    text|env|json) ;;
    *) err "Invalid --output '$OUTPUT': expected text, env or json"; exit 1 ;;
  esac
  if [[ -n "$LIFECYCLE_DAYS" ]] && ! [[ "$LIFECYCLE_DAYS" =~ ^[1-9][0-9]*$ ]]; then
    err "Invalid --lifecycle-days '$LIFECYCLE_DAYS': expected a positive integer"
    exit 1
  fi
}

validate_bucket_name() {
  local b="$1"
  if (( ${#b} < 3 || ${#b} > 63 )); then
    err "Bucket name length ${#b} is out of the allowed range [3, 63]: $b"
    exit 1
  fi
  if ! [[ "$b" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]]; then
    err "Invalid bucket name '$b': must be a valid DNS-style S3 name"
    exit 1
  fi
  if [[ "$NAMESPACE" == "account-regional" && "$b" != *-"$NAMESPACE_SUFFIX" ]]; then
    warn "Namespace is account-regional but bucket name does not end with -${NAMESPACE_SUFFIX}; AWS may reject it"
  fi
}

require_aws() {
  if ! command -v aws >/dev/null 2>&1; then
    err "AWS CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
  fi
}

# Wrapper so every call carries the chosen profile.
awsx() { aws --profile "$PROFILE" "$@"; }

# --- Update check ----------------------------------------------------------

# Return 0 if dotted-numeric version $1 is strictly greater than $2.
version_gt() {
  local a="$1" b="$2"
  if [[ "$a" == "$b" ]]; then
    return 1
  fi
  local IFS=.
  local -a ra rb
  read -ra ra <<<"$a"
  read -ra rb <<<"$b"
  local i max="${#ra[@]}"
  if (( ${#rb[@]} > max )); then
    max="${#rb[@]}"
  fi
  for (( i = 0; i < max; i++ )); do
    local x="${ra[i]:-0}" y="${rb[i]:-0}"
    x="${x%%[^0-9]*}"; x="${x:-0}"
    y="${y%%[^0-9]*}"; y="${y:-0}"
    if (( 10#$x > 10#$y )); then
      return 0
    fi
    if (( 10#$x < 10#$y )); then
      return 1
    fi
  done
  return 1
}

# Fetch the VERSION constant from the remote script. Best-effort: prints the
# version on success, nothing on any failure (offline, no downloader, timeout).
fetch_remote_version() {
  local url="https://raw.githubusercontent.com/${REPO}/${UPDATE_REF}/${REMOTE_SCRIPT}"
  local body=""
  if command -v curl >/dev/null 2>&1; then
    body=$(curl -fsSL --max-time "$UPDATE_TIMEOUT" "$url" 2>/dev/null) || return 0
  elif command -v wget >/dev/null 2>&1; then
    body=$(wget -qO- --timeout="$UPDATE_TIMEOUT" "$url" 2>/dev/null) || return 0
  else
    return 0
  fi
  grep -m1 '^readonly VERSION=' <<<"$body" | cut -d'"' -f2
}

run_self_update() {
  local target="$1"
  local url="https://raw.githubusercontent.com/${REPO}/${UPDATE_REF}/install.sh"
  log "Updating to ${target}..."
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL "$url" | bash; then
      ok "Updated to ${target}. Re-run the command to use the new version."
      exit 0
    fi
  elif command -v wget >/dev/null 2>&1; then
    if wget -qO- "$url" | bash; then
      ok "Updated to ${target}. Re-run the command to use the new version."
      exit 0
    fi
  fi
  err "Update failed. Continuing with the current version ${VERSION}."
}

maybe_check_update() {
  if [[ "$NO_UPDATE_CHECK" == true || "$QUIET" == true || "$DRY_RUN" == true ]]; then
    return 0
  fi
  if [[ -n "${DOKPLOY_S3_NO_UPDATE_CHECK:-}" ]]; then
    return 0
  fi

  local remote
  remote=$(fetch_remote_version)
  if [[ -z "$remote" ]] || ! version_gt "$remote" "$VERSION"; then
    return 0
  fi

  warn "A new version is available: ${VERSION} -> ${remote}"

  # Only prompt when attached to a terminal; otherwise just hint and move on.
  if [[ ! -t 0 || ! -t 1 ]]; then
    warn "Update with: curl -fsSL https://raw.githubusercontent.com/${REPO}/${UPDATE_REF}/install.sh | bash"
    return 0
  fi

  local reply=""
  printf 'Install the update now? [y/N] ' >&2
  read -r reply || return 0
  case "$reply" in
    y|Y|yes|YES) run_self_update "$remote" ;;
    *)           log "Skipping update." ;;
  esac
}

# --- Tag parsing -----------------------------------------------------------
# Fills IAM_TAG_ARGS (array, "Key=k,Value=v") and BUCKET_TAGGING ("TagSet=[...]").
# Limitation: tag keys and values cannot contain ',' or '='.

IAM_TAG_ARGS=()
BUCKET_TAGGING=""

build_tags() {
  IAM_TAG_ARGS=()
  BUCKET_TAGGING=""
  if [[ -z "$TAGS" ]]; then
    return 0
  fi

  local tagset_items=()
  local pair k v
  IFS=',' read -ra pairs <<<"$TAGS"
  for pair in "${pairs[@]}"; do
    if [[ -z "$pair" ]]; then
      continue
    fi
    if [[ "$pair" != *=* ]]; then
      err "Invalid tag '$pair': expected key=value"
      exit 1
    fi
    k="${pair%%=*}"
    v="${pair#*=}"
    if [[ -z "$k" ]]; then
      err "Invalid tag '$pair': empty key"
      exit 1
    fi
    IAM_TAG_ARGS+=("Key=${k},Value=${v}")
    tagset_items+=("{Key=${k},Value=${v}}")
  done
  local joined
  joined=$(IFS=','; printf '%s' "${tagset_items[*]}")
  BUCKET_TAGGING="TagSet=[${joined}]"
}

# --- AWS operations --------------------------------------------------------

get_account_id() {
  local account_id
  if ! account_id=$(awsx sts get-caller-identity --query Account --output text 2>&1); then
    err "Failed to resolve AWS account (check profile '$PROFILE' and credentials):"
    err "$account_id"
    exit 1
  fi
  printf '%s' "$account_id"
}

compute_bucket_name() {
  local account_id="$1"
  if [[ -n "$BUCKET_NAME" ]]; then
    printf '%s' "$BUCKET_NAME"
  elif [[ "$NAMESPACE" == "account-regional" ]]; then
    printf '%s' "${PREFIX}-${STAGE}-${account_id}-${REGION}-${NAMESPACE_SUFFIX}"
  else
    printf '%s' "${PREFIX}-${STAGE}-${account_id}-${REGION}"
  fi
}

create_bucket() {
  local bucket="$1"
  local -a args=(--bucket "$bucket" --region "$REGION")

  if [[ "$NAMESPACE" == "account-regional" ]]; then
    args+=(--bucket-namespace account-regional)
  fi
  # us-east-1 rejects an explicit LocationConstraint; every other region needs it.
  if [[ "$REGION" != "us-east-1" ]]; then
    args+=(--create-bucket-configuration "LocationConstraint=$REGION")
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN create-bucket ${args[*]}"
    return 0
  fi

  local output
  if output=$(awsx s3api create-bucket "${args[@]}" 2>&1); then
    ok "Bucket created: $bucket"
  elif grep -q "BucketAlreadyOwnedByYou" <<<"$output"; then
    warn "Bucket already exists and is owned by you, continuing: $bucket"
  else
    err "create-bucket failed:"
    err "$output"
    exit 1
  fi
}

apply_public_access_block() {
  local bucket="$1"
  if [[ "$BLOCK_PUBLIC_ACCESS" != true ]]; then
    warn "Skipping public-access block (--no-public-access-block)"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN put-public-access-block on $bucket (block all)"
    return 0
  fi

  local output
  if output=$(awsx s3api put-public-access-block \
      --bucket "$bucket" \
      --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" 2>&1); then
    ok "Public access fully blocked"
  else
    err "put-public-access-block failed:"
    err "$output"
    exit 1
  fi
}

apply_encryption() {
  local bucket="$1"
  if [[ "$ENCRYPTION" == "none" ]]; then
    warn "Skipping bucket encryption configuration (--encryption none)"
    return 0
  fi

  local rule
  if [[ "$ENCRYPTION" == "aws:kms" ]]; then
    rule="{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"${KMS_KEY_ID}\"},\"BucketKeyEnabled\":true}]}"
  else
    rule="{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"AES256\"}}]}"
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN put-bucket-encryption ($ENCRYPTION) on $bucket"
    return 0
  fi

  local output
  if output=$(awsx s3api put-bucket-encryption \
      --bucket "$bucket" \
      --server-side-encryption-configuration "$rule" 2>&1); then
    ok "Encryption enabled: $ENCRYPTION"
  else
    err "put-bucket-encryption failed:"
    err "$output"
    exit 1
  fi
}

apply_versioning() {
  local bucket="$1"
  if [[ "$VERSIONING" != true ]]; then
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN enable versioning on $bucket"
    return 0
  fi

  local output
  if output=$(awsx s3api put-bucket-versioning \
      --bucket "$bucket" \
      --versioning-configuration Status=Enabled 2>&1); then
    ok "Versioning enabled"
  else
    err "put-bucket-versioning failed:"
    err "$output"
    exit 1
  fi
}

apply_lifecycle() {
  local bucket="$1"
  if [[ -z "$LIFECYCLE_DAYS" ]]; then
    return 0
  fi

  local noncurrent=""
  if [[ "$VERSIONING" == true ]]; then
    noncurrent=",\"NoncurrentVersionExpiration\":{\"NoncurrentDays\":${LIFECYCLE_DAYS}}"
  fi
  local config="{\"Rules\":[{\"ID\":\"expire-after-${LIFECYCLE_DAYS}-days\",\"Status\":\"Enabled\",\"Filter\":{\"Prefix\":\"\"},\"Expiration\":{\"Days\":${LIFECYCLE_DAYS}}${noncurrent}}]}"

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN put-bucket-lifecycle-configuration (${LIFECYCLE_DAYS}d) on $bucket"
    return 0
  fi

  local output
  if output=$(awsx s3api put-bucket-lifecycle-configuration \
      --bucket "$bucket" \
      --lifecycle-configuration "$config" 2>&1); then
    ok "Lifecycle rule applied: expire after ${LIFECYCLE_DAYS} days"
  else
    err "put-bucket-lifecycle-configuration failed:"
    err "$output"
    exit 1
  fi
}

apply_bucket_tags() {
  local bucket="$1"
  if [[ -z "$BUCKET_TAGGING" ]]; then
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN put-bucket-tagging on $bucket: $BUCKET_TAGGING"
    return 0
  fi

  local output
  if output=$(awsx s3api put-bucket-tagging \
      --bucket "$bucket" \
      --tagging "$BUCKET_TAGGING" 2>&1); then
    ok "Bucket tags applied"
  else
    err "put-bucket-tagging failed:"
    err "$output"
    exit 1
  fi
}

create_user() {
  local user="$1"
  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN create-user $user"
    return 0
  fi

  local output
  if output=$(awsx iam create-user --user-name "$user" 2>&1); then
    ok "IAM user created: $user"
  elif grep -q "EntityAlreadyExists" <<<"$output"; then
    warn "IAM user already exists, continuing: $user"
  else
    err "create-user failed:"
    err "$output"
    exit 1
  fi
}

apply_user_tags() {
  local user="$1"
  if [[ ${#IAM_TAG_ARGS[@]} -eq 0 ]]; then
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN tag-user $user: ${IAM_TAG_ARGS[*]}"
    return 0
  fi

  local output
  if output=$(awsx iam tag-user --user-name "$user" --tags "${IAM_TAG_ARGS[@]}" 2>&1); then
    ok "IAM user tags applied"
  else
    err "tag-user failed:"
    err "$output"
    exit 1
  fi
}

put_policy() {
  local user="$1" bucket="$2" policy_name="$3"

  local policy_doc
  policy_doc=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBucket",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${bucket}"
    },
    {
      "Sid": "ObjectActions",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::${bucket}/*"
    }
  ]
}
EOF
)

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN put-user-policy '$policy_name' on $user (scoped to $bucket)"
    return 0
  fi

  local policy_file
  policy_file=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$policy_file'" RETURN
  printf '%s' "$policy_doc" > "$policy_file"

  local output
  if output=$(awsx iam put-user-policy \
      --user-name "$user" \
      --policy-name "$policy_name" \
      --policy-document "file://$policy_file" 2>&1); then
    ok "Inline policy '$policy_name' attached to $user (scoped to $bucket)"
  else
    err "put-user-policy failed:"
    err "$output"
    exit 1
  fi
}

create_access_key() {
  local user="$1"
  if [[ "$DRY_RUN" == true ]]; then
    printf '%s\t%s' "<dry-run-access-key-id>" "<dry-run-secret-access-key>"
    return 0
  fi

  local output
  if ! output=$(awsx iam create-access-key \
      --user-name "$user" \
      --query 'AccessKey.[AccessKeyId,SecretAccessKey]' \
      --output text 2>&1); then
    if grep -q "LimitExceeded" <<<"$output"; then
      err "IAM user '$user' already has the maximum of 2 access keys."
      err "Delete an unused key, then re-run. List keys with:"
      err "  aws --profile $PROFILE iam list-access-keys --user-name $user"
    else
      err "create-access-key failed:"
      err "$output"
    fi
    exit 1
  fi
  printf '%s' "$output"
}

# --- Output ----------------------------------------------------------------

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

render_output() {
  local bucket="$1" region="$2" endpoint="$3" access_key="$4" secret_key="$5"

  case "$OUTPUT" in
    env)
      cat <<EOF
DOKPLOY_S3_BUCKET=${bucket}
DOKPLOY_S3_REGION=${region}
DOKPLOY_S3_ENDPOINT=${endpoint}
AWS_ACCESS_KEY_ID=${access_key}
AWS_SECRET_ACCESS_KEY=${secret_key}
EOF
      ;;
    json)
      cat <<EOF
{
  "bucket": "$(json_escape "$bucket")",
  "region": "$(json_escape "$region")",
  "endpoint": "$(json_escape "$endpoint")",
  "accessKeyId": "$(json_escape "$access_key")",
  "secretAccessKey": "$(json_escape "$secret_key")"
}
EOF
      ;;
    *)
      cat <<EOF

============================================================
 Dokploy S3 destination
============================================================
 Bucket name        : ${bucket}
 Region             : ${region}
 Endpoint           : ${endpoint}
 Access Key ID      : ${access_key}
 Secret Access Key  : ${secret_key}
============================================================
EOF
      ;;
  esac
}

# --- Dokploy: connection config --------------------------------------------

# Base directory for stored profiles (XDG-aware).
config_dir() {
  printf '%s/dokploy-s3' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# Path to a profile's env file. The name is used as a filename, so it must be
# validated first.
dokploy_profile_path() {
  printf '%s/profiles/%s.env' "$(config_dir)" "$1"
}

# Reject names that are empty, contain path separators, or could traverse.
validate_profile_name() {
  local name="$1"
  if [[ -z "$name" ]]; then
    err "Profile name must not be empty"
    return 1
  fi
  if [[ "$name" == *"/"* || "$name" == *".."* ]]; then
    err "Invalid profile name '$name': must not contain '/' or '..'"
    return 1
  fi
  if ! [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    err "Invalid profile name '$name': allowed characters are letters, digits, '.', '_' and '-'"
    return 1
  fi
}

# Extract a KEY=value from a profile file (last occurrence wins), stripping
# optional surrounding double quotes. The file is parsed, never sourced, so a
# profile cannot execute code.
_profile_value() {
  local file="$1" key="$2" line value
  line="$(grep -E "^${key}=" "$file" | tail -n1)"
  value="${line#*=}"
  value="${value%\"}"
  value="${value#\"}"
  printf '%s' "$value"
}

# Print "<url>\n<key>" for a stored profile (both possibly empty); prints
# nothing if the profile file does not exist.
read_profile() {
  local name="$1" path
  path="$(dokploy_profile_path "$name")"
  if [[ ! -f "$path" ]]; then
    return 0
  fi
  printf '%s\n%s\n' \
    "$(_profile_value "$path" DOKPLOY_URL)" \
    "$(_profile_value "$path" DOKPLOY_API_KEY)"
}

# Given a profile and the current url/key, fill any empty value from the
# profile. Echoes "<url>\n<key>". (No namerefs: must run on bash 3.2.)
_merge_profile_into() {
  local profile="$1" url="$2" key="$3"
  local data
  data="$(read_profile "$profile")"
  local purl pkey
  purl="${data%%$'\n'*}"
  pkey="${data#*$'\n'}"
  pkey="${pkey%%$'\n'*}"
  if [[ "$pkey" == "$data" ]]; then
    pkey=""
  fi
  if [[ -z "$url" ]]; then
    url="$purl"
  fi
  if [[ -z "$key" ]]; then
    key="$pkey"
  fi
  printf '%s\n%s' "$url" "$key"
}

# Resolve DOKPLOY_URL and DOKPLOY_API_KEY using precedence:
#   CLI flag > environment > selected profile > default profile.
resolve_dokploy_config() {
  local url="$OPT_DOKPLOY_URL" key="$OPT_DOKPLOY_API_KEY"

  if [[ -z "$url" ]]; then
    url="${DOKPLOY_URL:-}"
  fi
  if [[ -z "$key" ]]; then
    key="${DOKPLOY_API_KEY:-}"
  fi

  if [[ -z "$url" || -z "$key" ]]; then
    local merged
    merged="$(_merge_profile_into "$DOKPLOY_PROFILE_NAME" "$url" "$key")"
    url="${merged%%$'\n'*}"
    key="${merged#*$'\n'}"
  fi
  if [[ ( -z "$url" || -z "$key" ) && "$DOKPLOY_PROFILE_NAME" != "$DEFAULT_DOKPLOY_PROFILE" ]]; then
    local merged
    merged="$(_merge_profile_into "$DEFAULT_DOKPLOY_PROFILE" "$url" "$key")"
    url="${merged%%$'\n'*}"
    key="${merged#*$'\n'}"
  fi

  DOKPLOY_URL="$url"
  DOKPLOY_API_KEY="$key"
}

# --- Dokploy: HTTP ---------------------------------------------------------

# curl + jq are only needed on the registration path; fail early and clearly.
require_dokploy_tools() {
  local missing=()
  if ! command -v curl >/dev/null 2>&1; then
    missing+=("curl")
  fi
  if ! command -v jq >/dev/null 2>&1; then
    missing+=("jq")
  fi
  if (( ${#missing[@]} > 0 )); then
    err "Dokploy registration needs: ${missing[*]}. Install them and retry (only required with --register-dokploy)."
    exit 1
  fi
}

# Warn when the API key + secret would travel unencrypted.
warn_if_insecure_url() {
  local url="$1"
  case "$url" in
    https://*) return 0 ;;
    http://localhost|http://localhost:*|http://localhost/*) return 0 ;;
    http://127.0.0.1|http://127.0.0.1:*|http://127.0.0.1/*) return 0 ;;
    http://*)
      warn "Dokploy URL '$url' is not https; the API key and secret will be sent unencrypted."
      return 0
      ;;
    *) return 0 ;;
  esac
}

# Perform a Dokploy API call. Echoes "<http_status>\n<body>"; a transport
# failure (e.g. host unreachable) yields status 000. Reads the resolved
# DOKPLOY_URL / DOKPLOY_API_KEY.
dokploy_api() {
  local method="$1" route="$2" body="${3:-}"
  local url="${DOKPLOY_URL%/}/api/${route}"
  local curl_args=(
    --silent --show-error --max-time "$DOKPLOY_HTTP_TIMEOUT"
    -H "x-api-key: ${DOKPLOY_API_KEY}"
    -X "$method"
    -o - -w $'\n%{http_code}'
  )
  if [[ -n "$body" ]]; then
    curl_args+=(-H "Content-Type: application/json" --data "$body")
  fi
  local response
  if ! response="$(curl "${curl_args[@]}" "$url" 2>/dev/null)"; then
    printf '000\n'
    return 0
  fi
  local status_code="${response##*$'\n'}"
  local response_body="${response%$'\n'*}"
  printf '%s\n%s' "$status_code" "$response_body"
}

# --- Dokploy: registration -------------------------------------------------

# Build the JSON body for destination.create / destination.testConnection.
# Args: name accessKey secretKey bucket region endpoint
# jq does the escaping. additionalFlags is omitted (server default []);
# serverId is included only when set.
build_dokploy_body() {
  local name="$1" access_key="$2" secret_key="$3" bucket="$4" region="$5" endpoint="$6"
  # shellcheck disable=SC2016  # $name etc. are jq variables, not shell expansions
  local filter='{name:$name, provider:$provider, accessKey:$accessKey, secretAccessKey:$secretAccessKey, bucket:$bucket, region:$region, endpoint:$endpoint}'
  local jq_args=(
    --arg name "$name"
    --arg provider "$DOKPLOY_PROVIDER"
    --arg accessKey "$access_key"
    --arg secretAccessKey "$secret_key"
    --arg bucket "$bucket"
    --arg region "$region"
    --arg endpoint "$endpoint"
  )
  if [[ -n "$DOKPLOY_SERVER_ID" ]]; then
    jq_args+=(--arg serverId "$DOKPLOY_SERVER_ID")
    filter="${filter} + {serverId:\$serverId}"
  fi
  jq -n "${jq_args[@]}" "$filter"
}

# Best-effort human message from a Dokploy/tRPC error body.
dokploy_error_message() {
  local body="$1" msg
  msg="$(printf '%s' "$body" | jq -r '[.. | .message? // empty] | first // empty' 2>/dev/null)"
  if [[ -n "$msg" ]]; then
    printf '%s' "$msg"
  else
    printf '%s' "$body"
  fi
}

# Abort with a helpful message for a failed Dokploy call.
dokploy_fail() {
  local action="$1" status="$2" body="$3"
  if [[ "$status" == "000" ]]; then
    err "Could not reach Dokploy at ${DOKPLOY_URL%/} ($action: connection failed or timed out)."
  else
    err "Dokploy $action failed (HTTP $status): $(dokploy_error_message "$body")"
  fi
  exit 1
}

# Verify the credentials reach the bucket (rclone ls under the hood). Aborts on
# failure so we never create a destination that does not work.
dokploy_test_connection() {
  local body="$1" resp status rbody
  resp="$(dokploy_api POST destination.testConnection "$body")"
  status="${resp%%$'\n'*}"
  rbody="${resp#*$'\n'}"
  if [[ "$status" == "200" || "$status" == "201" ]]; then
    return 0
  fi
  if [[ "$status" == "404" && "$rbody" == *"Server not found"* ]]; then
    err "Dokploy connection test failed: server not found. On Dokploy Cloud you must pass --server-id <id>."
    exit 1
  fi
  dokploy_fail "connection test" "$status" "$rbody"
}

# Create the destination in Dokploy.
dokploy_create() {
  local body="$1" resp status rbody
  resp="$(dokploy_api POST destination.create "$body")"
  status="${resp%%$'\n'*}"
  rbody="${resp#*$'\n'}"
  if [[ "$status" == "200" || "$status" == "201" ]]; then
    return 0
  fi
  dokploy_fail "destination create" "$status" "$rbody"
}

# Return 0 if a destination with the given name already exists in Dokploy.
dokploy_destination_exists() {
  local name="$1" resp status body
  resp="$(dokploy_api GET destination.all)"
  status="${resp%%$'\n'*}"
  body="${resp#*$'\n'}"
  if [[ "$status" != "200" && "$status" != "201" ]]; then
    dokploy_fail "destination list" "$status" "$body"
  fi
  printf '%s' "$body" | jq -e --arg n "$name" 'any(.[]?; .name == $n)' >/dev/null 2>&1
}

# Orchestrate registration: preflight, resolve config, verify, then create.
# Args: bucket region endpoint accessKey secretKey
register_dokploy_destination() {
  local bucket="$1" region="$2" endpoint="$3" access_key="$4" secret_key="$5"

  require_dokploy_tools
  if ! validate_profile_name "$DOKPLOY_PROFILE_NAME"; then
    exit 1
  fi
  resolve_dokploy_config
  if [[ -z "$DOKPLOY_URL" || -z "$DOKPLOY_API_KEY" ]]; then
    err "Dokploy URL and API key are not configured. Run '$0 configure', pass --dokploy-url, or set DOKPLOY_URL / DOKPLOY_API_KEY."
    exit 1
  fi
  warn_if_insecure_url "$DOKPLOY_URL"

  local name="${DESTINATION_NAME:-$bucket}"
  local body
  body="$(build_dokploy_body "$name" "$access_key" "$secret_key" "$bucket" "$region" "$endpoint")"

  if [[ "$DRY_RUN" == true ]]; then
    local base redacted
    base="${DOKPLOY_URL%/}/api"
    redacted="$(printf '%s' "$body" | jq '.secretAccessKey = "***REDACTED***"')"
    log "Dry-run: no requests will be sent. Intended Dokploy calls (header 'x-api-key: ***REDACTED***'):"
    printf 'GET  %s/destination.all\n' "$base" >&2
    printf 'POST %s/destination.testConnection\n' "$base" >&2
    printf 'POST %s/destination.create\n' "$base" >&2
    printf '%s\n' "$redacted" >&2
    return 0
  fi

  if dokploy_destination_exists "$name"; then
    ok "Dokploy destination '$name' already exists; skipping."
    return 0
  fi

  log "Verifying Dokploy can reach the bucket..."
  dokploy_test_connection "$body"
  log "Registering Dokploy destination '$name'..."
  dokploy_create "$body"
  ok "Dokploy destination '$name' registered."
}

# --- Subcommands -----------------------------------------------------------

cmd_create() {
  parse_args "$@"
  validate_args
  maybe_check_update
  require_aws
  build_tags

  log "Resolving AWS account for profile '$PROFILE'..."
  local account_id
  account_id=$(get_account_id)
  ok "Account: $account_id"

  local bucket user policy_name endpoint
  bucket=$(compute_bucket_name "$account_id")
  validate_bucket_name "$bucket"
  user="${USER_NAME:-dokploy-${PREFIX}-${STAGE}}"
  policy_name="${POLICY_NAME:-${PREFIX}-${STAGE}-s3-access}"
  endpoint="${ENDPOINT_OVERRIDE:-https://s3.${REGION}.amazonaws.com}"

  log "Bucket name: $bucket"
  log "IAM user:    $user"
  if [[ "$DRY_RUN" == true ]]; then
    warn "Dry-run mode: no changes will be made"
  fi

  create_bucket "$bucket"
  apply_public_access_block "$bucket"
  apply_encryption "$bucket"
  apply_versioning "$bucket"
  apply_lifecycle "$bucket"
  apply_bucket_tags "$bucket"

  create_user "$user"
  apply_user_tags "$user"
  put_policy "$user" "$bucket" "$policy_name"

  log "Creating access key..."
  local key_pair access_key secret_key
  key_pair=$(create_access_key "$user")
  access_key=$(cut -f1 <<<"$key_pair")
  secret_key=$(cut -f2 <<<"$key_pair")

  local rendered
  rendered=$(render_output "$bucket" "$REGION" "$endpoint" "$access_key" "$secret_key")
  printf '%s\n' "$rendered"

  if [[ -n "$OUTPUT_FILE" ]]; then
    local prev_umask
    prev_umask=$(umask)
    umask 077
    printf '%s\n' "$rendered" > "$OUTPUT_FILE"
    umask "$prev_umask"
    ok "Result written to $OUTPUT_FILE (mode 600)"
  fi

  # Register in Dokploy after the credentials are shown, so a registration
  # failure never loses the provisioned credentials.
  if [[ "$REGISTER_DOKPLOY" == true ]]; then
    register_dokploy_destination "$bucket" "$REGION" "$endpoint" "$access_key" "$secret_key"
  fi

  if [[ "$DRY_RUN" != true ]]; then
    warn "The secret access key is shown only once. Store it securely now."
  fi
}

configure_usage() {
  cat >&2 <<EOF
Store a Dokploy connection profile (URL + API key) for reuse with --register-dokploy.

Usage: $0 configure [--dokploy-profile <name>]

Options:
  --dokploy-profile <name>  Profile name to write (default: ${DEFAULT_DOKPLOY_PROFILE})
  -h, --help                Show this help

You will be prompted for the Dokploy URL and API key. The key is read without
echo and stored in ${XDG_CONFIG_HOME:-\$HOME/.config}/dokploy-s3/profiles/<name>.env
(file mode 600). Create a token in Dokploy under Settings -> /settings/profile.
EOF
}

cmd_configure() {
  local profile="$DEFAULT_DOKPLOY_PROFILE"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dokploy-profile) profile="${2:-}"; shift 2 ;;
      -h|--help)         configure_usage; exit 0 ;;
      *)                 err "Unknown argument: $1"; configure_usage; exit 1 ;;
    esac
  done

  if ! validate_profile_name "$profile"; then
    exit 1
  fi

  local url key
  printf 'Dokploy URL: ' >&2
  read -r url
  printf 'Dokploy API key (input hidden): ' >&2
  read -rs key
  printf '\n' >&2

  if [[ -z "$url" || -z "$key" ]]; then
    err "Both the Dokploy URL and API key are required."
    exit 1
  fi

  local dir path
  dir="$(config_dir)/profiles"
  path="$(dokploy_profile_path "$profile")"

  local prev_umask
  prev_umask=$(umask)
  umask 077
  mkdir -p "$dir"
  cat > "$path" <<EOF
DOKPLOY_URL="$url"
DOKPLOY_API_KEY="$key"
EOF
  umask "$prev_umask"

  if ! chmod 700 "$(config_dir)" "$dir"; then
    warn "Could not tighten permissions on $dir"
  fi
  if ! chmod 600 "$path"; then
    warn "Could not tighten permissions on $path"
  fi

  ok "Saved Dokploy profile '$profile' to $path"
}

# --- Main ------------------------------------------------------------------

# Dispatch on the optional leading subcommand. A bare invocation (no
# subcommand) defaults to `create`, preserving the original CLI.
main() {
  case "${1:-}" in
    configure)
      shift
      cmd_configure "$@"
      ;;
    create)
      shift
      cmd_create "$@"
      ;;
    *)
      cmd_create "$@"
      ;;
  esac
}

# Only run when executed directly, not when sourced (e.g. by the test suite).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
