#!/usr/bin/env bats
# Smoke test: the script still runs as a CLI after the sourcing guard.

load helpers

@test "--help exits 0 and prints usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  assert_contains "$output" "Usage:"
}

@test "--version exits 0" {
  run "$SCRIPT" --version
  [ "$status" -eq 0 ]
  assert_contains "$output" "create-dokploy-s3-destination"
}
