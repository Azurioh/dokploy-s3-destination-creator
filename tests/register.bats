#!/usr/bin/env bats
# US1: register_dokploy_destination orchestration (verify -> create).

load helpers

setup() {
  STUBDIR="$(mktemp -d)"
  export CURL_LOG="$STUBDIR/curl.log"
  : >"$CURL_LOG"
  cat >"$STUBDIR/curl" <<'EOF'
#!/usr/bin/env bash
# Record args, then emulate dokploy_api's expected "<body>\n<status>".
args="$*"
printf '%s\n' "$args" >>"$CURL_LOG"
case "$args" in
  *destination.testConnection*) printf '\n200' ;;
  *destination.create*)         printf '{"destinationId":"d1"}\n200' ;;
  *destination.all*)            printf '[]\n200' ;;
  *)                            printf '\n404' ;;
esac
EOF
  chmod +x "$STUBDIR/curl"
  export PATH="$STUBDIR:$PATH"
}

teardown() { rm -rf "$STUBDIR"; }

@test "register verifies the connection then creates the destination" {
  run bash -c "source '$SCRIPT'; DOKPLOY_URL=http://localhost:3000; DOKPLOY_API_KEY=K; register_dokploy_destination my-bucket eu-west-3 https://s3.eu-west-3.amazonaws.com AKIA secret"
  [ "$status" -eq 0 ]
  assert_contains "$output" "registered"
  assert_contains "$(cat "$CURL_LOG")" "destination.testConnection"
  assert_contains "$(cat "$CURL_LOG")" "destination.create"
}

@test "register aborts and does NOT create when the connection test fails" {
  cat >"$STUBDIR/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"
printf '%s\n' "$args" >>"$CURL_LOG"
case "$args" in
  *destination.all*)            printf '[]\n200' ;;
  *destination.testConnection*) printf '{"message":"Error connecting to bucket"}\n400' ;;
  *)                            printf '{}\n200' ;;
esac
EOF
  chmod +x "$STUBDIR/curl"
  run bash -c "source '$SCRIPT'; DOKPLOY_URL=http://localhost:3000; DOKPLOY_API_KEY=K; register_dokploy_destination my-bucket eu-west-3 https://s3.eu-west-3.amazonaws.com AKIA secret"
  [ "$status" -ne 0 ]
  assert_contains "$output" "Error connecting to bucket"
  assert_not_contains "$(cat "$CURL_LOG")" "destination.create"
}

@test "register retries a transient InvalidAccessKeyId then creates the destination" {
  # First two testConnection calls fail as InvalidAccessKeyId (key not yet
  # propagated across AWS); the third succeeds. A counter file tracks attempts.
  export ATTEMPT_FILE="$STUBDIR/attempts"
  : >"$ATTEMPT_FILE"
  cat >"$STUBDIR/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"
printf '%s\n' "$args" >>"$CURL_LOG"
case "$args" in
  *destination.all*) printf '[]\n200' ;;
  *destination.testConnection*)
    printf 'x' >>"$ATTEMPT_FILE"
    if [ "$(wc -c <"$ATTEMPT_FILE")" -lt 3 ]; then
      printf '{"message":"api error InvalidAccessKeyId: The AWS Access Key Id you provided does not exist in our records."}\n400'
    else
      printf '\n200'
    fi
    ;;
  *destination.create*) printf '{"destinationId":"d1"}\n200' ;;
  *) printf '\n404' ;;
esac
EOF
  chmod +x "$STUBDIR/curl"
  # Neutralize sleep so the backoff does not slow the test suite.
  run bash -c "source '$SCRIPT'; sleep() { :; }; DOKPLOY_URL=http://localhost:3000; DOKPLOY_API_KEY=K; register_dokploy_destination my-bucket eu-west-3 https://s3.eu-west-3.amazonaws.com AKIA secret"
  [ "$status" -eq 0 ]
  assert_contains "$output" "retrying"
  assert_contains "$output" "registered"
  assert_contains "$(cat "$CURL_LOG")" "destination.create"
  # Three testConnection attempts were made (two failures + one success).
  [ "$(wc -c <"$ATTEMPT_FILE")" -eq 3 ]
}

@test "register aborts when InvalidAccessKeyId persists past all retries" {
  cat >"$STUBDIR/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"
printf '%s\n' "$args" >>"$CURL_LOG"
case "$args" in
  *destination.all*) printf '[]\n200' ;;
  *destination.testConnection*) printf '{"message":"api error InvalidAccessKeyId: nope"}\n400' ;;
  *) printf '{}\n200' ;;
esac
EOF
  chmod +x "$STUBDIR/curl"
  run bash -c "source '$SCRIPT'; sleep() { :; }; DOKPLOY_URL=http://localhost:3000; DOKPLOY_API_KEY=K; register_dokploy_destination my-bucket eu-west-3 https://s3.eu-west-3.amazonaws.com AKIA secret"
  [ "$status" -ne 0 ]
  assert_contains "$output" "InvalidAccessKeyId"
  assert_not_contains "$(cat "$CURL_LOG")" "destination.create"
}

@test "register aborts when url/key cannot be resolved" {
  setup_config_home
  run bash -c "source '$SCRIPT'; unset DOKPLOY_URL DOKPLOY_API_KEY; register_dokploy_destination b eu-west-3 https://s3.eu-west-3.amazonaws.com k s"
  [ "$status" -ne 0 ]
  assert_contains "$output" "not configured"
  teardown_config_home
}

@test "register never puts the secret or API key on the curl command line" {
  run bash -c "source '$SCRIPT'; DOKPLOY_URL=http://localhost:3000; DOKPLOY_API_KEY=apikey-distinct-zzz; register_dokploy_destination my-bucket eu-west-3 https://s3.eu-west-3.amazonaws.com AKIA secret-distinct-yyy"
  [ "$status" -eq 0 ]
  assert_not_contains "$(cat "$CURL_LOG")" "secret-distinct-yyy"
  assert_not_contains "$(cat "$CURL_LOG")" "apikey-distinct-zzz"
}

@test "register redacts a secret echoed back in a Dokploy error message" {
  cat >"$STUBDIR/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *destination.all*)            printf '[]\n200' ;;
  *destination.testConnection*) printf '{"message":"failed: rclone ls --s3-secret-access-key=\"leaked-secret-xyz\" :s3:b"}\n400' ;;
  *)                            printf '{}\n200' ;;
esac
EOF
  chmod +x "$STUBDIR/curl"
  run bash -c "source '$SCRIPT'; DOKPLOY_URL=http://localhost:3000; DOKPLOY_API_KEY=K; register_dokploy_destination my-bucket eu-west-3 https://s3.eu-west-3.amazonaws.com AKIA leaked-secret-xyz"
  [ "$status" -ne 0 ]
  assert_not_contains "$output" "leaked-secret-xyz"
  assert_contains "$output" "REDACTED"
}
