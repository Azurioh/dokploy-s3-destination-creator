#!/usr/bin/env bats
# Foundational: warn when the Dokploy URL is not encrypted in transit.

load helpers

@test "warn_if_insecure_url warns for http on a non-local host" {
  in_script 'warn_if_insecure_url http://dokploy.example.com:3000'
  [ "$status" -eq 0 ]
  [[ "$output" == *"not https"* ]]
}

@test "warn_if_insecure_url is silent for https" {
  in_script 'warn_if_insecure_url https://dokploy.example.com'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "warn_if_insecure_url is silent for http localhost" {
  in_script 'warn_if_insecure_url http://localhost:3000'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
