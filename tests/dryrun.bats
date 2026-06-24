#!/usr/bin/env bats
# US4: --dry-run previews the Dokploy calls with secrets redacted, no network.

load helpers

setup() { setup_curl_trap; }
teardown() { teardown_curl_trap; }

@test "dry-run prints a redacted body and makes no network call" {
  run bash -c "source '$SCRIPT'; DRY_RUN=true; DOKPLOY_URL=http://localhost:3000; DOKPLOY_API_KEY=topsecretkey; register_dokploy_destination my-bucket eu-west-3 https://s3.eu-west-3.amazonaws.com AKIA super-secret-value"
  [ "$status" -eq 0 ]
  assert_contains "$output" "***REDACTED***"
  assert_not_contains "$output" "super-secret-value"
  assert_not_contains "$output" "topsecretkey"
  assert_not_contains "$output" "FATAL: curl was invoked"
}

@test "dry-run shows the intended create endpoint" {
  run bash -c "source '$SCRIPT'; DRY_RUN=true; DOKPLOY_URL=http://localhost:3000; DOKPLOY_API_KEY=K; register_dokploy_destination my-bucket eu-west-3 https://s3.eu-west-3.amazonaws.com AKIA s"
  [ "$status" -eq 0 ]
  assert_contains "$output" "destination.create"
}
