#!/usr/bin/env bats
# Foundational: subcommand dispatch with a backward-compatible default of `create`.

load helpers

@test "explicit 'create' subcommand is accepted (not treated as unknown arg)" {
  run "$SCRIPT" create --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "bare invocation still routes to create (backward compatible)" {
  # No subcommand: --help must still work exactly as before.
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "bare invocation with missing required args errors via create's validation" {
  run "$SCRIPT" --stage prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"--prefix is required"* ]]
}

@test "unknown leading flag falls through to create and is rejected" {
  run "$SCRIPT" --definitely-not-a-flag
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown argument"* ]]
}
