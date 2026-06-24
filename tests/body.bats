#!/usr/bin/env bats
# US1: JSON body builder for destination.create / testConnection.

load helpers

jqval() { printf '%s' "$1" | jq -r "$2"; }

@test "build_dokploy_body sets provider AWS and the seven required fields" {
  run bash -c "source '$SCRIPT'; DOKPLOY_SERVER_ID=''; build_dokploy_body dest-name AKIA sec my-bucket eu-west-3 https://s3.eu-west-3.amazonaws.com"
  [ "$status" -eq 0 ]
  [ "$(jqval "$output" '.provider')" = "AWS" ]
  [ "$(jqval "$output" '.name')" = "dest-name" ]
  [ "$(jqval "$output" '.accessKey')" = "AKIA" ]
  [ "$(jqval "$output" '.secretAccessKey')" = "sec" ]
  [ "$(jqval "$output" '.bucket')" = "my-bucket" ]
  [ "$(jqval "$output" '.region')" = "eu-west-3" ]
  [ "$(jqval "$output" '.endpoint')" = "https://s3.eu-west-3.amazonaws.com" ]
}

@test "build_dokploy_body omits additionalFlags" {
  run bash -c "source '$SCRIPT'; DOKPLOY_SERVER_ID=''; build_dokploy_body n k s b r e"
  [ "$status" -eq 0 ]
  [ "$(jqval "$output" 'has("additionalFlags")')" = "false" ]
}

@test "build_dokploy_body escapes special characters in the secret" {
  run bash -c "source '$SCRIPT'; DOKPLOY_SERVER_ID=''; build_dokploy_body n k 'a\"b\\c' b r e"
  [ "$status" -eq 0 ]
  [ "$(jqval "$output" '.secretAccessKey')" = 'a"b\c' ]
}

@test "build_dokploy_body includes serverId only when set" {
  run bash -c "source '$SCRIPT'; DOKPLOY_SERVER_ID=''; build_dokploy_body n k s b r e"
  [ "$(jqval "$output" 'has("serverId")')" = "false" ]
  run bash -c "source '$SCRIPT'; DOKPLOY_SERVER_ID=srv-1; build_dokploy_body n k s b r e"
  [ "$(jqval "$output" '.serverId')" = "srv-1" ]
}
