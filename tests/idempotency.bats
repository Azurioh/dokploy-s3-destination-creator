#!/usr/bin/env bats
# US3: skip creation when a destination of the same name already exists.

load helpers

# Stub curl: destination.all returns whatever ALL_BODY holds; create/test 200.
make_stub() {  # all_body
  STUBDIR="$(mktemp -d)"
  export CURL_LOG="$STUBDIR/curl.log"; : >"$CURL_LOG"
  export ALL_BODY="$1"
  cat >"$STUBDIR/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"
printf '%s\n' "$args" >>"$CURL_LOG"
case "$args" in
  *destination.all*)            printf '%s\n200' "$ALL_BODY" ;;
  *destination.testConnection*) printf '\n200' ;;
  *destination.create*)         printf '{"destinationId":"d1"}\n200' ;;
  *)                            printf '\n404' ;;
esac
EOF
  chmod +x "$STUBDIR/curl"
  export PATH="$STUBDIR:$PATH"
}
teardown() { [ -n "${STUBDIR:-}" ] && rm -rf "$STUBDIR"; }

@test "dokploy_destination_exists is true when the name is present" {
  make_stub '[{"name":"my-bucket"},{"name":"other"}]'
  run bash -c "source '$SCRIPT'; DOKPLOY_URL=http://localhost:3000; DOKPLOY_API_KEY=K; dokploy_destination_exists my-bucket"
  [ "$status" -eq 0 ]
}

@test "dokploy_destination_exists is false when the name is absent" {
  make_stub '[{"name":"other"}]'
  run bash -c "source '$SCRIPT'; DOKPLOY_URL=http://localhost:3000; DOKPLOY_API_KEY=K; dokploy_destination_exists my-bucket"
  [ "$status" -ne 0 ]
}

@test "register skips create when the destination already exists" {
  make_stub '[{"name":"my-bucket"}]'
  run bash -c "source '$SCRIPT'; DOKPLOY_URL=http://localhost:3000; DOKPLOY_API_KEY=K; register_dokploy_destination my-bucket eu-west-3 https://s3.eu-west-3.amazonaws.com AKIA secret"
  [ "$status" -eq 0 ]
  assert_contains "$output" "already exists"
  assert_not_contains "$(cat "$CURL_LOG")" "destination.create"
  assert_not_contains "$(cat "$CURL_LOG")" "destination.testConnection"
}
