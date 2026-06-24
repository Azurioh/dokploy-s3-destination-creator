#!/usr/bin/env bats
# US2: the `configure` subcommand stores a connection profile.

load helpers

setup() { setup_config_home; }
teardown() { teardown_config_home; }

@test "configure writes a 600 profile file under a 700 directory" {
  run bash -c "printf '%s\n%s\n' 'https://dok.example.com' 'tok-secret' | '$SCRIPT' configure --dokploy-profile prod"
  [ "$status" -eq 0 ]
  file="$XDG_CONFIG_HOME/dokploy-s3/profiles/prod.env"
  [ -f "$file" ]
  [ "$(file_mode "$file")" = "600" ]
  [ "$(file_mode "$XDG_CONFIG_HOME/dokploy-s3")" = "700" ]
  run bash -c "source '$SCRIPT'; read_profile prod"
  assert_contains "$output" "https://dok.example.com"
  assert_contains "$output" "tok-secret"
}

@test "configure never echoes the API key" {
  run bash -c "printf '%s\n%s\n' 'https://dok.example.com' 'super-secret-key' | '$SCRIPT' configure --dokploy-profile prod"
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "super-secret-key"
}

@test "configure defaults to the 'default' profile" {
  run bash -c "printf '%s\n%s\n' 'https://d' 'k' | '$SCRIPT' configure"
  [ "$status" -eq 0 ]
  [ -f "$XDG_CONFIG_HOME/dokploy-s3/profiles/default.env" ]
}

@test "configure rejects an empty URL or key" {
  run bash -c "printf '%s\n%s\n' '' '' | '$SCRIPT' configure"
  [ "$status" -ne 0 ]
}

@test "configure rejects an invalid profile name" {
  run bash -c "printf '%s\n%s\n' 'https://d' 'k' | '$SCRIPT' configure --dokploy-profile 'a/b'"
  [ "$status" -ne 0 ]
}

@test "configure --help exits 0" {
  run "$SCRIPT" configure --help
  [ "$status" -eq 0 ]
  assert_contains "$output" "configure"
}
