#!/usr/bin/env bats
# Foundational: Dokploy connection config layer (profiles + precedence).

load helpers

setup() { setup_config_home; }
teardown() { teardown_config_home; }

write_profile() {  # name url key
  mkdir -p "$XDG_CONFIG_HOME/dokploy-s3/profiles"
  cat >"$XDG_CONFIG_HOME/dokploy-s3/profiles/$1.env" <<EOF
DOKPLOY_URL="$2"
DOKPLOY_API_KEY="$3"
EOF
}

@test "config_dir honors XDG_CONFIG_HOME" {
  in_script 'config_dir'
  [ "$status" -eq 0 ]
  [ "$output" = "$XDG_CONFIG_HOME/dokploy-s3" ]
}

@test "validate_profile_name accepts a normal name" {
  in_script 'validate_profile_name prod'
  [ "$status" -eq 0 ]
}

@test "validate_profile_name rejects path separators and traversal" {
  in_script 'validate_profile_name "a/b"'
  [ "$status" -ne 0 ]
  in_script 'validate_profile_name ".."'
  [ "$status" -ne 0 ]
  in_script 'validate_profile_name ""'
  [ "$status" -ne 0 ]
}

@test "dokploy_profile_path builds the expected path" {
  in_script 'dokploy_profile_path prod'
  [ "$status" -eq 0 ]
  [ "$output" = "$XDG_CONFIG_HOME/dokploy-s3/profiles/prod.env" ]
}

@test "read_profile returns url and key from the file" {
  write_profile prod "https://prod.example.com" "tok-prod"
  in_script 'read_profile prod'
  [ "$status" -eq 0 ]
  assert_contains "$output" "https://prod.example.com"
  assert_contains "$output" "tok-prod"
}

@test "resolve uses the selected profile when no flag/env" {
  write_profile prod "https://prod.example.com" "tok-prod"
  run bash -c "source '$SCRIPT'; unset DOKPLOY_URL DOKPLOY_API_KEY; DOKPLOY_PROFILE_NAME=prod; resolve_dokploy_config; printf '%s|%s' \"\$DOKPLOY_URL\" \"\$DOKPLOY_API_KEY\""
  [ "$status" -eq 0 ]
  [ "$output" = "https://prod.example.com|tok-prod" ]
}

@test "resolve: environment overrides the profile" {
  write_profile prod "https://prod.example.com" "tok-prod"
  run bash -c "source '$SCRIPT'; export DOKPLOY_URL='https://env.example.com' DOKPLOY_API_KEY='tok-env'; DOKPLOY_PROFILE_NAME=prod; resolve_dokploy_config; printf '%s|%s' \"\$DOKPLOY_URL\" \"\$DOKPLOY_API_KEY\""
  [ "$status" -eq 0 ]
  [ "$output" = "https://env.example.com|tok-env" ]
}

@test "resolve: CLI flag overrides environment" {
  run bash -c "source '$SCRIPT'; export DOKPLOY_URL='https://env.example.com'; OPT_DOKPLOY_URL='https://flag.example.com'; resolve_dokploy_config; printf '%s' \"\$DOKPLOY_URL\""
  [ "$status" -eq 0 ]
  [ "$output" = "https://flag.example.com" ]
}

@test "resolve: falls back to the default profile when the selected one is missing" {
  write_profile default "https://default.example.com" "tok-default"
  run bash -c "source '$SCRIPT'; unset DOKPLOY_URL DOKPLOY_API_KEY; DOKPLOY_PROFILE_NAME=ghost; resolve_dokploy_config; printf '%s|%s' \"\$DOKPLOY_URL\" \"\$DOKPLOY_API_KEY\""
  [ "$status" -eq 0 ]
  [ "$output" = "https://default.example.com|tok-default" ]
}

@test "resolve: a url-only selected profile takes its key from the default profile" {
  write_profile sel "https://sel.example.com" ""
  write_profile default "https://default.example.com" "def-key"
  run bash -c "source '$SCRIPT'; unset DOKPLOY_URL DOKPLOY_API_KEY; DOKPLOY_PROFILE_NAME=sel; resolve_dokploy_config; printf '%s|%s' \"\$DOKPLOY_URL\" \"\$DOKPLOY_API_KEY\""
  [ "$status" -eq 0 ]
  [ "$output" = "https://sel.example.com|def-key" ]
}

@test "DOKPLOY_PROFILE env sets the default selected profile name" {
  DOKPLOY_PROFILE=staging run bash -c "source '$SCRIPT'; printf '%s' \"\$DOKPLOY_PROFILE_NAME\""
  [ "$status" -eq 0 ]
  [ "$output" = "staging" ]
}

@test "DOKPLOY_PROFILE_NAME defaults to 'default' without the env var" {
  run bash -c "unset DOKPLOY_PROFILE; source '$SCRIPT'; printf '%s' \"\$DOKPLOY_PROFILE_NAME\""
  [ "$status" -eq 0 ]
  [ "$output" = "default" ]
}
