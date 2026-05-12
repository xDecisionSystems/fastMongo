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
- Creates MongoDB writer user and reader user (reader is used by the API runtime)
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
