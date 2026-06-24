#!/usr/bin/env bash
# Shared bats helpers for the dokploy-s3 test suite.

# Absolute path to the script under test.
SCRIPT="${BATS_TEST_DIRNAME}/../create-dokploy-s3-destination.sh"

# Run a snippet with the script's functions sourced (main is guarded, so it
# does not execute on source). Output and status are captured by `run`.
#   in_script 'validate_profile_name foo'
in_script() {
  run bash -c "source '$SCRIPT'; $1"
}

# Create an isolated XDG_CONFIG_HOME for profile-storage tests.
setup_config_home() {
  TEST_XDG="$(mktemp -d)"
  export XDG_CONFIG_HOME="$TEST_XDG"
}

teardown_config_home() {
  [ -n "${TEST_XDG:-}" ] && rm -rf "$TEST_XDG"
}

# A PATH shim dir whose `curl` fails loudly if ever invoked (for dry-run tests).
setup_curl_trap() {
  TEST_BIN="$(mktemp -d)"
  cat >"$TEST_BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "FATAL: curl was invoked" >&2
exit 99
EOF
  chmod +x "$TEST_BIN/curl"
  export PATH="$TEST_BIN:$PATH"
}

teardown_curl_trap() {
  [ -n "${TEST_BIN:-}" ] && rm -rf "$TEST_BIN"
}
