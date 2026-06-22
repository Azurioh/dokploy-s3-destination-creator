#!/usr/bin/env bash
#
# Installer for create-dokploy-s3-destination.
#
# Quick install (latest from main):
#   curl -fsSL https://raw.githubusercontent.com/Azurioh/dokploy-s3-destination-creator/main/install.sh | bash
#
# Pin a version, or choose the install dir:
#   curl -fsSL .../install.sh | VERSION=v1.0.0 bash
#   curl -fsSL .../install.sh | INSTALL_DIR="$HOME/.local/bin" bash
#
# Prefer to read before you run? Download it first, inspect, then execute.

set -euo pipefail

readonly REPO="Azurioh/dokploy-s3-destination-creator"
readonly SCRIPT_NAME="create-dokploy-s3-destination.sh"
readonly BIN_NAME="create-dokploy-s3-destination"

REF="${VERSION:-main}"
RAW_URL="${DOKPLOY_S3_SRC_URL:-https://raw.githubusercontent.com/${REPO}/${REF}/${SCRIPT_NAME}}"

log()  { printf '\033[0;34m[*]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[0;32m[+]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[-]\033[0m %s\n' "$*" >&2; }

# Resolve the install directory: explicit override > writable /usr/local/bin > ~/.local/bin.
resolve_install_dir() {
  if [[ -n "${INSTALL_DIR:-}" ]]; then
    printf '%s' "$INSTALL_DIR"
  elif [[ -w /usr/local/bin ]]; then
    printf '%s' "/usr/local/bin"
  else
    printf '%s' "${HOME}/.local/bin"
  fi
}

download() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsSL "$url" -o "$out"; then
      err "Download failed: $url"
      exit 1
    fi
  elif command -v wget >/dev/null 2>&1; then
    if ! wget -qO "$out" "$url"; then
      err "Download failed: $url"
      exit 1
    fi
  else
    err "Neither curl nor wget is available. Install one and retry."
    exit 1
  fi
}

main() {
  case "$(uname -s)" in
    Linux|Darwin) ;;
    *) err "Unsupported OS '$(uname -s)'. This tool targets Linux and macOS."; exit 1 ;;
  esac

  local install_dir dest tmp
  install_dir="$(resolve_install_dir)"
  dest="${install_dir}/${BIN_NAME}"

  log "Installing ${BIN_NAME} (${REF}) to ${install_dir}"

  tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT

  download "$RAW_URL" "$tmp"

  if [[ ! -s "$tmp" ]]; then
    err "Downloaded file is empty — check the version/ref '${REF}'."
    exit 1
  fi

  mkdir -p "$install_dir"
  install -m 0755 "$tmp" "$dest"
  ok "Installed: $dest"

  if ! command -v aws >/dev/null 2>&1; then
    warn "AWS CLI not found on PATH. Install it before using the tool:"
    warn "  https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  fi

  if ! command -v "$BIN_NAME" >/dev/null 2>&1; then
    warn "$install_dir is not on your PATH. Add it to your shell config:"
    warn "  export PATH=\"$install_dir:\$PATH\""
  else
    ok "Run '${BIN_NAME} --help' to get started."
  fi
}

main "$@"
