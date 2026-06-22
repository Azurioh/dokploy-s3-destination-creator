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

readonly DEFAULT_REGION="eu-west-3"
readonly DEFAULT_NAMESPACE="account-regional"
readonly NAMESPACE_SUFFIX="an"     # required trailing label for account-regional names
readonly DEFAULT_ENCRYPTION="AES256"
readonly DEFAULT_OUTPUT="text"

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

# --- Logging ---------------------------------------------------------------

log()  { if [[ "$QUIET" == true ]]; then return 0; fi; printf '\033[0;34m[*]\033[0m %s\n' "$*" >&2; }
ok()   { if [[ "$QUIET" == true ]]; then return 0; fi; printf '\033[0;32m[+]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[-]\033[0m %s\n' "$*" >&2; }

usage() {
  cat >&2 <<EOF
Create an S3 bucket + scoped IAM user and emit Dokploy S3 destination settings.

Usage: $0 --stage <stage> --prefix <prefix> --profile <aws-profile> [options]

Required:
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
  -h, --help                Show this help
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

# --- Main ------------------------------------------------------------------

main() {
  parse_args "$@"
  validate_args
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

  if [[ "$DRY_RUN" != true ]]; then
    warn "The secret access key is shown only once. Store it securely now."
  fi
}

main "$@"
