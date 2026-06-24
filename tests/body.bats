#!/usr/bin/env bats
# US1: JSON body builder for destination.create / testConnection.

load helpers

@test "build_dokploy_body sets provider AWS and the seven required fields" {
  run bash -c "source '$SCRIPT'; DOKPLOY_SERVER_ID=''; build_dokploy_body dest-name AKIA sec my-bucket eu-west-3 https://s3.eu-west-3.amazonaws.com"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.provider == "AWS"'
  echo "$output" | jq -e '.name == "dest-name"'
  echo "$output" | jq -e '.accessKey == "AKIA"'
  echo "$output" | jq -e '.secretAccessKey == "sec"'
  echo "$output" | jq -e '.bucket == "my-bucket"'
  echo "$output" | jq -e '.region == "eu-west-3"'
  echo "$output" | jq -e '.endpoint == "https://s3.eu-west-3.amazonaws.com"'
}

@test "build_dokploy_body omits additionalFlags" {
  run bash -c "source '$SCRIPT'; DOKPLOY_SERVER_ID=''; build_dokploy_body n k s b r e"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("additionalFlags") | not'
}

@test "build_dokploy_body escapes special characters in the secret" {
  run bash -c "source '$SCRIPT'; DOKPLOY_SERVER_ID=''; build_dokploy_body n k 'a\"b\\c' b r e"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.secretAccessKey')" = 'a"b\c' ]
}

@test "build_dokploy_body includes serverId only when set" {
  run bash -c "source '$SCRIPT'; DOKPLOY_SERVER_ID=''; build_dokploy_body n k s b r e"
  echo "$output" | jq -e 'has("serverId") | not'
  run bash -c "source '$SCRIPT'; DOKPLOY_SERVER_ID=srv-1; build_dokploy_body n k s b r e"
  echo "$output" | jq -e '.serverId == "srv-1"'
}
