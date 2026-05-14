# fastMongo

`fastMongo` is a single FastAPI service backed by MongoDB, intended for native LXC deployment.

## What it provides

- `POST /generate-token`: mint JWTs (requires `API_WRITE_KEY` or `API_MASTER_KEY`, or allowed browser `Origin`)
- `POST /validate-token`: validate JWTs (`API_WRITE_KEY` or `API_MASTER_KEY` required)
- `POST /allowed`: define allowed payload types/fields/max size for `/post` (`API_MASTER_KEY` required)
- `POST /post`: store a payload (JWT via `Authorization: Bearer` or API key via `X-API-Key: API_WRITE_KEY` or `API_MASTER_KEY`)
- `POST /getrecs`: query records by allowed field using `API_READ_KEY` or `API_MASTER_KEY`
- `GET /exportdb`: export full DB using `API_MASTER_KEY`
- `GET /health`: health check

## Agent endpoint contract (Claude/Codex-safe)

Use this section as the strict interaction contract for automation agents.

### Base rules

- Base URL: `http://<host>:8000` (or your configured port)
- Always send `Content-Type: application/json` for `POST` endpoints.
- API key header name is exactly: `X-API-Key`.
- JWT auth header is exactly: `Authorization: Bearer <token>`.
- If `ALLOW_CORS=false`, `/health`, `/generate-token`, and `/post` require a valid API key even when they might otherwise allow browser-origin access.

### Required auth per endpoint

- `GET /health`: no key required unless `ALLOW_CORS=false`.
- `POST /generate-token`: `X-API-Key` with write/master key, or browser `Origin` in `CORS_ORIGINS`.
- `POST /validate-token`: write key or master key.
- `POST /allowed`: master key only.
- `POST /post`: write key/master key OR valid JWT bearer token.
- `POST /getrecs`: read key or master key.
- `GET /exportdb`: master key only.

### Endpoint details (request/response contract)

#### `GET /health`

- Auth: no key required unless `ALLOW_CORS=false`; then any valid API key is required.
- Success `200`:

```json
{
  "status": "ok"
}
```

#### `POST /generate-token`

- Auth: `X-API-Key` with write/master key, or allowed browser `Origin`.
- Request body:

```json
{
  "sub": "user-123"
}
```

- Success `200`:

```json
{
  "jwt": "<token>",
  "expires_at": "2026-05-14T12:00:00+00:00"
}
```

- Common failures:
- `401` missing/invalid credentials.
- `422` invalid request body (missing or invalid `sub`).

#### `POST /validate-token`

- Auth: write key or master key.
- Request body:

```json
{
  "jwt": "<token>"
}
```

- Success `200`:

```json
{
  "status": "valid",
  "expires_at": 1770000000,
  "subject": "user-123"
}
```

- Notes:
- `status` is one of `valid`, `expired`, `invalid`.
- `expires_at` and `subject` are `null` when token is not valid.

#### `POST /allowed` (authoritative schema gate for `/post`)

- Auth: master key only.
- Purpose: define or update allowed schema per `type_name`.
- Request body:

```json
{
  "type_name": "example",
  "fields": ["version", "metadata"],
  "max_size": "64KB"
}
```

- Validation rules:
- `type_name` must be non-empty after trimming.
- `fields` must include at least one non-empty field name.
- Duplicate `fields` are deduplicated in order.
- `max_size` must match `<integer><KB|MB>` (example: `64KB`, `2MB`).
- Upsert behavior by `type_name`.

- Success `200`:

```json
{
  "status": "saved",
  "type_name": "example",
  "fields": ["version", "metadata"],
  "max_size": "64KB",
  "max_size_bytes": 65536
}
```

- Common failures:
- `401` missing/invalid master key.
- `400` invalid `type_name`, `fields`, or `max_size`.

#### `POST /post`

- Auth: write/master API key OR JWT bearer token.
- Request body: any JSON object that passes `/allowed` rule for its `type_name`.
- Required `/allowed -> /post` workflow:
1. Call `POST /allowed` for each `type_name` before storing payloads of that type.
2. `POST /post` payload must include `type_name`.
3. Payload keys may only include `type_name` and fields declared in `/allowed`.
4. Raw request size must be `<= max_size_bytes` for that `type_name`.

- Example accepted body:

```json
{
  "type_name": "example",
  "version": 1,
  "metadata": {
    "owner": "team-a"
  }
}
```

- Success `200`:

```json
{
  "status": "stored",
  "id": "<mongo_object_id>",
  "stored_at": "2026-05-14T12:00:00+00:00"
}
```

- Common failures:
- `400` missing/invalid `type_name`, disallowed payload type, or unexpected fields.
- `401` invalid API key or JWT.
- `413` payload exceeds configured max size.
- `429` rate limit exceeded.

- Stored Mongo document shape:
- All payload fields stored at the document root.
- `stored_at`: UTC timestamp.
- `jwt_subject`: JWT subject when JWT auth used, otherwise `null`.
- `auth_method`: `jwt` or `api_key`.

#### `POST /getrecs`

- Auth: read key or master key.
- Request body:

```json
{
  "getField": "package.type_name",
  "getTag": "example"
}
```

- Validation rules:
- `getField` must be a non-empty string and must exist in env var `GETRECS_ALLOWED_FIELDS`.
- `getTag` must be a non-empty string.

- Success `200`:

```json
{
  "count": 1,
  "records": [
    {}
  ]
}
```

- Common failures:
- `401` invalid read/master key.
- `400` invalid `getField`/`getTag`, or `getField` not allowlisted.

#### `GET /exportdb`

- Auth: master key only.
- Success `200`: JSON file attachment containing:
- `database`
- `exported_at`
- `collections` object with all collection data.

- Common failures:
- `401` missing/invalid master key.

### Minimal machine flow for agents

1. Call `POST /allowed` with master key.
2. Call `POST /generate-token` with write key (optional if using API key auth for `/post`).
3. Call `POST /post` with JWT bearer or write/master key.
4. Call `POST /getrecs` with read/master key and an allowed `getField`.

## Updating

Run inside the LXC as root:

```bash
wget -qO- https://raw.githubusercontent.com/xDecisionSystems/fastMongo/main/update.sh | bash
```

## LXC deployment

Deployment script:
- `deploy_fastmongo_lxc.sh`

Run inside your Debian 13 Proxmox LXC (single command):

```bash
wget -qO- https://raw.githubusercontent.com/xDecisionSystems/fastMongo/main/deploy_fastmongo_lxc.sh | bash
```

What the script does:
- Downloads fastMongo source files from GitHub
- Installs MongoDB and runtime dependencies
- Copies downloaded source into `/opt/fastmongo`
- Creates a Python virtualenv and installs API dependencies
- Creates MongoDB writer user and reader user (API runtime uses reader for reads and writer for writes)
- Writes runtime env file to `/etc/fastmongo/fastmongo.env`
- Creates and starts `fastmongo-api` systemd service

Verify:

```bash
systemctl status mongod
systemctl status fastmongo-api
curl http://127.0.0.1:8000/health
```

## Runtime configuration

Use `.env.example` as your base for secrets and config values.

Required values:
- `MONGO_WRITER_PASSWORD`
- `MONGO_READER_PASSWORD`
- `SECRET_KEY` (32+ chars)
- `API_WRITE_KEY`
- `API_READ_KEY`
- `API_MASTER_KEY`
- `GETRECS_ALLOWED_FIELDS`

Common optional values:
- `MONGO_HOST` (default: `127.0.0.1`)
- `MONGO_PORT` (default: `27017`)
- `MONGO_DB_NAME` (default: `fastmongo`)
- `MONGO_COLLECTION` (default: `app`)
- `JWT_EXPIRATION_MINUTES` (default: `30`)
- `JWT_ISSUER` (default: `fastjwt-api`)
- `JWT_AUDIENCE` (default: `fastjwt-clients`)
- `RATE_LIMIT_REQUESTS` (default: `60`, `0` disables)
- `RATE_LIMIT_WINDOW_SECONDS` (default: `60`)
- `CORS_ORIGINS` (optional browser allowlist for `/generate-token`)
- `API_URL` (test script only — not read by the service; default: `http://localhost:8000`)

`GETRECS_ALLOWED_FIELDS` must contain Mongo dotted field paths that exist in stored documents.
`/post` stores payloads under the `package` key (for example `package.type_name`).

## API examples

Generate a token:

```bash
curl -X POST http://localhost:8000/generate-token \
  -H "X-API-Key: <API_WRITE_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"sub":"user-123"}'
```

Store with JWT (`/post`):

```bash
# First define allowed payload type/fields/max size:
curl -X POST http://localhost:8000/allowed \
  -H "X-API-Key: <API_MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"type_name":"example","fields":["version","metadata"],"max_size":"64KB"}'

# Then upload payload using only allowed fields (fields are optional; extra fields are rejected):
curl -X POST http://localhost:8000/post \
  -H "Authorization: Bearer <jwt-from-generate-token>" \
  -H "Content-Type: application/json" \
  -d '{"type_name":"example","version":1,"metadata":{"owner":"team-a"}}'
```

Store with API key or MASTER API key (`/post`):

```bash
curl -X POST http://localhost:8000/post \
  -H "X-API-Key: <API_WRITE_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"type_name":"example","version":1,"metadata":{"owner":"team-a"}}'
```

Validate a token:

```bash
curl -X POST http://localhost:8000/validate-token \
  -H "X-API-Key: <API_WRITE_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"jwt":"<token>"}'
```

Query records:

```bash
curl -X POST http://localhost:8000/getrecs \
  -H "X-API-Key: <API_READ_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"getField":"package.type_name","getTag":"example"}'
```

Export DB, requires MASTER API key:

```bash
curl -X GET http://localhost:8000/exportdb \
  -H "X-API-Key: <API_MASTER_KEY>" \
  -o fastmongo-export.json
```

## Testing

Syntax check:

```bash
./tests/test_syntax.sh
```

API smoke test (reads `.env` if present):

```bash
./tests/test_api.sh
```

Smoke test requirements:
- `API_MASTER_KEY`
- `API_WRITE_KEY`
- `API_READ_KEY`
