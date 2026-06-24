#!/usr/bin/env bats
# Foundational: the script must be sourceable so functions can be unit-tested
# without executing main().

load helpers

@test "sourcing the script does not execute main (functions available)" {
  in_script 'declare -f usage >/dev/null && echo SOURCED_OK'
  [ "$status" -eq 0 ]
  [ "$output" = "SOURCED_OK" ]
}
