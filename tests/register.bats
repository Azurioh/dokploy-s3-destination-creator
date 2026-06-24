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

@test "register aborts when url/key cannot be resolved" {
  setup_config_home
  run bash -c "source '$SCRIPT'; unset DOKPLOY_URL DOKPLOY_API_KEY; register_dokploy_destination b eu-west-3 https://s3.eu-west-3.amazonaws.com k s"
  [ "$status" -ne 0 ]
  assert_contains "$output" "not configured"
  teardown_config_home
}
