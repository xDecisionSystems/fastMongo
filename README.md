# fastMongo

`fastMongo` is a single FastAPI service backed by MongoDB, intended for native LXC deployment.

## What it provides

- `GET /health`: health check
- `POST /generate-token`: mint JWTs (`API_WRITE_KEY` or `API_MASTER_KEY` required, or allowed browser `Origin`)
- `POST /validate-token`: validate JWTs (`API_WRITE_KEY` or `API_MASTER_KEY` required)
- `POST /allowed`: define allowed payload types/fields/max size (`API_MASTER_KEY` required)
- `GET /allowed`: list all allowed types (`API_MASTER_KEY` required)
- `DELETE /allowed/{type_name}`: delete an allowed type definition (`API_MASTER_KEY` required)
- `POST /post`: store a payload (`API_WRITE_KEY`, `API_MASTER_KEY`, or JWT bearer)
- `POST /getrecs`: query records by type and optional field (`API_READ_KEY` or `API_MASTER_KEY`)
- `GET /lastrecs`: get last 10 records of a type (`API_READ_KEY` or `API_MASTER_KEY`)
- `DELETE /records/{type_name}`: delete all records of a type (`API_MASTER_KEY` required)
- `DELETE /hardreset`: delete all records and all allowed types (`API_MASTER_KEY` required)
- `GET /exportdb`: export full DB (`API_MASTER_KEY` required)

## Agent endpoint contract (Claude/Codex-safe)

Use this section as the strict interaction contract for automation agents.

### Base rules

- Base URL: `http://<host>:8000` (or your configured port)
- Always send `Content-Type: application/json` for `POST` endpoints.
- API key header name is exactly: `X-API-Key`.
- JWT auth header is exactly: `Authorization: Bearer <token>`.
- Payloads are stored flat at the document root — fields declared in `/allowed` are top-level keys alongside `type_name`.
- `GETRECS_ALLOWED_TYPES` controls which `type_name` values can be queried via `/getrecs` and `/lastrecs`.

### Required auth per endpoint

- `GET /health`: no key required.
- `POST /generate-token`: write or master key, or browser `Origin` in `CORS_ORIGINS`.
- `POST /validate-token`: write or master key.
- `POST /allowed`: master key only.
- `GET /allowed`: master key only.
- `DELETE /allowed/{type_name}`: master key only.
- `POST /post`: write/master key OR valid JWT bearer token.
- `POST /getrecs`: read or master key.
- `GET /lastrecs`: read or master key.
- `DELETE /records/{type_name}`: master key only.
- `DELETE /hardreset`: master key only.
- `GET /exportdb`: master key only.

### Endpoint details (request/response contract)

#### `GET /health`

- Auth: none required.
- Success `200`:

```json
{
  "status": "ok"
}
```

---

#### `POST /generate-token`

- Auth: write or master key, or allowed browser `Origin`.
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
  - `422` missing or invalid `sub`.

---

#### `POST /validate-token`

- Auth: write or master key.
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

---

#### `POST /allowed`

- Auth: master key only.
- Purpose: define or update the allowed schema for a `type_name`. Must be called before posting data of that type.
- Request body:

```json
{
  "type_name": "my_type",
  "fields": ["field1", "field2"],
  "max_size": "64KB"
}
```

- Validation rules:
  - `type_name` must be non-empty.
  - `fields` must include at least one non-empty field name. Duplicates are deduplicated.
  - `max_size` must match `<integer><KB|MB>` (e.g. `64KB`, `2MB`).
  - Upserts by `type_name`.

- Success `200`:

```json
{
  "status": "saved",
  "type_name": "my_type",
  "fields": ["field1", "field2"],
  "max_size": "64KB",
  "max_size_bytes": 65536
}
```

- Common failures:
  - `401` missing/invalid master key.
  - `400` invalid `type_name`, `fields`, or `max_size`.

---

#### `GET /allowed`

- Auth: master key only.
- Success `200`:

```json
{
  "count": 1,
  "types": [
    {
      "type_name": "my_type",
      "fields": ["field1", "field2"],
      "max_size": "64KB",
      "max_size_bytes": 65536,
      "updated_at": "2026-05-14T12:00:00+00:00"
    }
  ]
}
```

---

#### `DELETE /allowed/{type_name}`

- Auth: master key only.
- Deletes the allowed type definition. Does not delete stored records of that type.
- Success `200`:

```json
{
  "status": "deleted",
  "type_name": "my_type"
}
```

- Common failures:
  - `401` missing/invalid master key.
  - `404` type not found.

---

#### `POST /post`

- Auth: write/master key OR JWT bearer token.
- Required workflow: call `POST /allowed` for the `type_name` before posting.
- Payload fields are stored flat at the document root alongside `type_name`.
- Request body must include `type_name` and only fields declared in `/allowed`:

```json
{
  "type_name": "my_type",
  "field1": "value",
  "field2": "value"
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
  - `400` missing/invalid `type_name`, undeclared type, or unexpected fields.
  - `401` invalid API key or JWT.
  - `413` payload exceeds configured max size.
  - `429` rate limit exceeded.

- Stored MongoDB document shape:

```json
{
  "_id": "<object_id>",
  "type_name": "my_type",
  "field1": "value",
  "field2": "value",
  "stored_at": "<utc_timestamp>",
  "jwt_subject": "<subject_or_null>",
  "auth_method": "jwt | api_key"
}
```

---

#### `POST /getrecs`

- Auth: read or master key.
- `type_name` must be in `GETRECS_ALLOWED_TYPES` env var.
- Query all records of a type:

```json
{
  "type_name": "my_type"
}
```

- Query records of a type filtered by a field value:

```json
{
  "type_name": "my_type",
  "getField": "field1",
  "getTag": "value"
}
```

- Success `200`:

```json
{
  "count": 2,
  "records": [{}]
}
```

- Common failures:
  - `401` invalid read/master key.
  - `400` `type_name` not in `GETRECS_ALLOWED_TYPES`, or invalid `getField`/`getTag`.

---

#### `GET /lastrecs`

- Auth: read or master key.
- `type_name` must be in `GETRECS_ALLOWED_TYPES` env var.
- Query parameter: `type_name`
- Returns the 10 most recent records sorted by `stored_at` descending.

```
GET /lastrecs?type_name=my_type
```

- Success `200`:

```json
{
  "count": 10,
  "records": [{}]
}
```

- Common failures:
  - `401` invalid read/master key.
  - `400` `type_name` not in `GETRECS_ALLOWED_TYPES`.

---

#### `DELETE /records/{type_name}`

- Auth: master key only.
- Deletes all stored records of the specified type.
- Success `200`:

```json
{
  "status": "deleted",
  "type_name": "my_type",
  "deleted_count": 42
}
```

- Common failures:
  - `401` missing/invalid master key.

---

#### `DELETE /hardreset`

- Auth: master key only.
- Deletes all stored records AND all allowed type definitions.
- Success `200`:

```json
{
  "status": "reset",
  "records_deleted": 42,
  "types_deleted": 3
}
```

- Common failures:
  - `401` missing/invalid master key.

---

#### `GET /exportdb`

- Auth: master key only.
- Success `200`: JSON file attachment containing:
  - `database`
  - `exported_at`
  - `collections` object with all collection data.

- Common failures:
  - `401` missing/invalid master key.

---

### Minimal machine flow for agents

1. Call `POST /allowed` with master key to declare a `type_name` and its fields.
2. Call `POST /post` with write/master key or JWT to store records.
3. Call `POST /getrecs` or `GET /lastrecs` with read/master key to retrieve records.
4. Call `DELETE /records/{type_name}` or `DELETE /hardreset` to clean up.

## Updating

Run inside the LXC as root:

```bash
wget -qO- https://raw.githubusercontent.com/xDecisionSystems/fastMongo/main/update.sh | bash
```

## LXC deployment

Run inside your Debian 13 Proxmox LXC as root:

```bash
wget -qO- https://raw.githubusercontent.com/xDecisionSystems/fastMongo/main/deploy_fastmongo_lxc.sh | bash
```

What the script does:
- Downloads fastMongo source files from GitHub
- Installs MongoDB and runtime dependencies
- Copies source into `/opt/fastmongo`
- Creates a Python virtualenv and installs API dependencies
- Creates MongoDB writer and reader users
- Writes runtime env to `/etc/fastmongo/fastmongo.env`
- Creates and starts `fastmongo-api` systemd service

Verify:

```bash
systemctl status mongod
systemctl status fastmongo-api
curl http://127.0.0.1:8000/health
```

## Runtime configuration

File: `/etc/fastmongo/fastmongo.env`

Required values:
- `MONGO_WRITER_PASSWORD`
- `MONGO_READER_PASSWORD`
- `SECRET_KEY` (32+ chars)
- `API_WRITE_KEY`
- `API_READ_KEY`
- `API_MASTER_KEY`
- `GETRECS_ALLOWED_TYPES` — comma-separated list of `type_name` values that can be queried (e.g. `my_type,other_type`)

Common optional values:
- `MONGO_HOST` (default: `127.0.0.1`)
- `MONGO_PORT` (default: `27017`)
- `MONGO_DB_NAME` (default: `fastmongo`)
- `MONGO_COLLECTION` (default: `app`)
- `JWT_EXPIRATION_MINUTES` (default: `20`)
- `JWT_ISSUER` (default: `fastjwt-api`)
- `JWT_AUDIENCE` (default: `fastjwt-clients`)
- `RATE_LIMIT_REQUESTS` (default: `60`, `0` disables)
- `RATE_LIMIT_WINDOW_SECONDS` (default: `60`)
- `CORS_ORIGINS` (optional browser allowlist for `/generate-token`)

## API examples

Store a record:

```bash
# 1. Define the allowed type:
curl -X POST http://localhost:8000/allowed \
  -H "X-API-Key: <API_MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"type_name":"my_type","fields":["field1","field2"],"max_size":"64KB"}'

# 2. Post a record:
curl -X POST http://localhost:8000/post \
  -H "X-API-Key: <API_WRITE_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"type_name":"my_type","field1":"hello","field2":"world"}'
```

Query records:

```bash
# All records of a type:
curl -X POST http://localhost:8000/getrecs \
  -H "X-API-Key: <API_READ_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"type_name":"my_type"}'

# Filtered by field value:
curl -X POST http://localhost:8000/getrecs \
  -H "X-API-Key: <API_READ_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"type_name":"my_type","getField":"field1","getTag":"hello"}'

# Last 10 records:
curl "http://localhost:8000/lastrecs?type_name=my_type" \
  -H "X-API-Key: <API_READ_KEY>"
```

Generate and use a JWT:

```bash
TOKEN=$(curl -s -X POST http://localhost:8000/generate-token \
  -H "X-API-Key: <API_WRITE_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"sub":"user-123"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['jwt'])")

curl -X POST http://localhost:8000/post \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type_name":"my_type","field1":"hello","field2":"world"}'
```

Reset all data:

```bash
curl -X DELETE http://localhost:8000/hardreset \
  -H "X-API-Key: <API_MASTER_KEY>"
```

Export DB:

```bash
curl http://localhost:8000/exportdb \
  -H "X-API-Key: <API_MASTER_KEY>" \
  -o fastmongo-export.json
```

## Testing

API smoke test (reads `.env.test` if present, falls back to `.env`):

```bash
./tests/test_api.sh
```

Smoke test requirements in `.env.test`:
- `API_URL`
- `API_MASTER_KEY`
- `API_WRITE_KEY`
- `API_READ_KEY`
