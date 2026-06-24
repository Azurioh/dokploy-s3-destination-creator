# Contract: Dokploy HTTP API (as consumed by this tool)

**Source-confirmed** against `Dokploy/dokploy@canary` — see [../research.md](../research.md) (D-001..D-005).

- **Base**: `${DOKPLOY_URL%/}/api`
- **Auth**: header `x-api-key: <DOKPLOY_API_KEY>` on every request.
- **Content type**: `application/json` for POST bodies.
- **JSON**: bodies are built with `jq -n` (correct escaping of keys/secrets), never string interpolation.
- **Timeouts**: `curl --max-time <HTTP_TIMEOUT>`; treat curl exit ≠ 0 as a connection error with a clear message.

## 1. Idempotency lookup — `GET /destination.all`

```
GET {base}/destination.all
Headers: x-api-key: <token>
Body: none
```
- 2xx ⇒ response is a JSON **array** of destination rows. Detect existing by:
  `jq -e --arg n "$name" 'any(.[]?; .name == $n)'`
- If found ⇒ log "destination '<name>' already exists, skipping" and **succeed** (exit 0), no create (FR-011).
- Non-2xx (e.g. 401 bad key, connection refused) ⇒ error with status + body, exit non-zero.

## 2. Connection test — `POST /destination.testConnection` (fail-fast, before create)

```
POST {base}/destination.testConnection
Headers: x-api-key: <token>; Content-Type: application/json
Body: { name, provider:"AWS", accessKey, secretAccessKey, bucket, region, endpoint
        [, serverId if --server-id set] }
```
- **200** (empty body) ⇒ credentials reach the bucket; proceed to create.
- **400** ⇒ failure; body carries the rclone error (fallback `"Error connecting to bucket"`). Surface it
  verbatim and exit non-zero (FR-012).
- **404 "Server not found"** ⇒ Dokploy Cloud without `serverId`; surface a hint to pass `--server-id`.

## 3. Create — `POST /destination.create`

```
POST {base}/destination.create
Headers: x-api-key: <token>; Content-Type: application/json
Body: { name, provider:"AWS", accessKey, secretAccessKey, bucket, region, endpoint
        [, serverId if --server-id set] }
```
- **`additionalFlags` is omitted** (array type, server default `[]`; sending `""` is invalid — D-002).
- 2xx ⇒ success; print a summary (destination name + Dokploy URL), no secret.
- Non-2xx ⇒ error with status + body, exit non-zero.

## Request body builder (reference)

```bash
build_body() {  # args: name accessKey secretKey bucket region endpoint [serverId]
  local args=(--arg name "$1" --arg provider "AWS" --arg accessKey "$2" \
              --arg secretAccessKey "$3" --arg bucket "$4" --arg region "$5" --arg endpoint "$6")
  local filter='{name:$name,provider:$provider,accessKey:$accessKey,
                 secretAccessKey:$secretAccessKey,bucket:$bucket,region:$region,endpoint:$endpoint}'
  if [[ -n "${7:-}" ]]; then args+=(--arg serverId "$7"); filter='. + {serverId:$serverId}'; fi  # merged
  jq -n "${args[@]}" "$filter"
}
```

## Redaction (dry-run + logs)

`--dry-run` prints the method, URL, and a body where `secretAccessKey` (and the `x-api-key` header) are
replaced with `***REDACTED***`; no `curl` is invoked (FR-014/FR-015).
