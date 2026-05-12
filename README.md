# fastMongo

`fastMongo` is a single FastAPI service backed by MongoDB, intended for native LXC deployment.

## What it provides

- `POST /generate-token`: mint JWTs (requires `API_KEY` or allowed browser `Origin`)
- `POST /validate-token`: validate JWTs
- `POST /allowed`: define allowed payload types/fields/max size for `/post` (`MASTER_KEY` required)
- `POST /post`: store a payload (JWT via `Authorization: Bearer` or API key via `X-API-Key: API_KEY` or `MASTER_KEY`)
- `POST /getrecs`: query records by allowed field using `API_KEY` or `MASTER_KEY`
- `GET /exportdb`: export full DB using `MASTER_KEY`
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
- Creates MongoDB writer/reader users
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
- `SECRET_KEY` (32+ chars)
- `API_KEY`
- `MASTER_KEY`
- `GETRECS_ALLOWED_FIELDS`

Common optional values:
- `MONGO_HOST` (default: `127.0.0.1`)
- `MONGO_PORT` (default: `27017`)
- `MONGO_DB_NAME` (default: `fastmongo`)
- `MONGO_COLLECTION` (default: `app`)
- `MONGO_WRITER_USERNAME` (default: `writer`)
- `JWT_EXPIRATION_MINUTES` (default: `20`)
- `JWT_ISSUER` (default: `fastjwt-api`)
- `JWT_AUDIENCE` (default: `fastjwt-clients`)
- `RATE_LIMIT_REQUESTS` (default: `60`, `0` disables)
- `RATE_LIMIT_WINDOW_SECONDS` (default: `60`)
- `CORS_ORIGINS` (optional browser allowlist for `/generate-token`)
- `API_URL` (test script only — not read by the service; default: `http://localhost:8000`)

## API examples

Generate a token:

```bash
curl -X POST http://localhost:8000/generate-token \
  -H "X-API-Key: <API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"sub":"user-123"}'
```

Store with JWT (`/post`):

```bash
# First define allowed payload type/fields/max size:
curl -X POST http://localhost:8000/allowed \
  -H "X-API-Key: <MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"type_name":"example","fields":["version","metadata"],"max_size":"64KB"}'

# Then upload payload using only allowed fields (fields are optional; extra fields are rejected):
curl -X POST http://localhost:8000/post \
  -H "Authorization: Bearer <jwt-from-generate-token>" \
  -H "Content-Type: application/json" \
  -d '{"type_name":"example","version":1,"metadata":{"owner":"team-a"}}'
```

Store with API key (`/post`):

```bash
curl -X POST http://localhost:8000/post \
  -H "X-API-Key: <API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"type_name":"example","version":1,"metadata":{"owner":"team-a"}}'
```

Validate a token:

```bash
curl -X POST http://localhost:8000/validate-token \
  -H "Content-Type: application/json" \
  -d '{"jwt":"<token>"}'
```

Query records:

```bash
curl -X POST http://localhost:8000/getrecs \
  -H "X-API-Key: <API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"getField":"package.name","getTag":"example"}'
```

Export DB:

```bash
curl -X GET http://localhost:8000/exportdb \
  -H "X-API-Key: <MASTER_KEY>" \
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
- `MASTER_KEY`
- `API_KEY` (recommended), or `TEST_TOKEN_ORIGIN` / `CORS_ORIGINS`
