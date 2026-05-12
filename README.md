# fastMongo

`fastMongo` runs two Dockerized apps in this repo:

1. MongoDB (`mongo/Dockerfile`)
2. FastAPI (`api/Dockerfile`)

The API accepts JSON payloads, validates JWTs through `fastJWT`, stores data in MongoDB, and can export the full database with a separate API key.

## Agent quickstart checklist

1. Copy `.env.example` to `.env` and set keys/passwords.
2. Start stack: `docker compose pull && docker compose up -d`.
3. Verify API health: `curl http://localhost:8000/health`.
4. Run smoke tests: `./tests/test_api.sh`.

## Services

### MongoDB service

- Built from `mongo/Dockerfile`
- Executes `mongo/init-mongo.js` on first startup
- Creates `writer` user with `readWrite` role on `MONGO_DB_NAME`
- Creates `reader` user with `read` role on `MONGO_DB_NAME`

### FastAPI service

- Built from `api/Dockerfile`
- Exposes `GET /health`
- Exposes `POST /post` (JWT required)
- Exposes `POST /keypost` (API key required)
- Exposes `POST /getrecs` (API key required)
- Exposes `GET /exportdb` (special API key required)

## Prerequisite

A `fastJWT` service must be running and reachable from the API container (configured by `FASTJWT_URL`).

## Run

`fastMongo` can run directly from Docker Hub images (no local image build required).

Example `docker-compose.yml`:

```yaml
services:
  mongo:
    image: adclab/fastmongo-mongo:latest
    container_name: fastmongo-mongo
    restart: unless-stopped
    environment:
      MONGO_INITDB_ROOT_USERNAME: ${MONGO_INITDB_ROOT_USERNAME:?MONGO_INITDB_ROOT_USERNAME is required}
      MONGO_INITDB_ROOT_PASSWORD: ${MONGO_INITDB_ROOT_PASSWORD:?MONGO_INITDB_ROOT_PASSWORD is required}
      MONGO_DB_NAME: ${MONGO_DB_NAME:?MONGO_DB_NAME is required}
      MONGO_WRITER_PASSWORD: ${MONGO_WRITER_PASSWORD:?MONGO_WRITER_PASSWORD is required}
      MONGO_READER_PASSWORD: ${MONGO_READER_PASSWORD:?MONGO_READER_PASSWORD is required}
    volumes:
      - mongo-data:/data/db

  api:
    image: adclab/fastmongo-api:latest
    container_name: fastmongo-api
    restart: unless-stopped
    depends_on:
      - mongo
    environment:
      MONGO_HOST: mongo
      MONGO_PORT: 27017
      MONGO_DB_NAME: ${MONGO_DB_NAME:?MONGO_DB_NAME is required}
      MONGO_COLLECTION: ${MONGO_COLLECTION:?MONGO_COLLECTION is required}
      MONGO_WRITER_USERNAME: writer
      MONGO_WRITER_PASSWORD: ${MONGO_WRITER_PASSWORD:?MONGO_WRITER_PASSWORD is required}
      FASTJWT_URL: ${FASTJWT_URL:?FASTJWT_URL is required}
      FASTJWT_VALIDATE_PATH: ${FASTJWT_VALIDATE_PATH:?FASTJWT_VALIDATE_PATH is required}
      WRITE_API_KEY: ${WRITE_API_KEY:?WRITE_API_KEY is required}
      EXPORT_API_KEY: ${EXPORT_API_KEY:?EXPORT_API_KEY is required}
      GETRECS_ALLOWED_FIELDS: ${GETRECS_ALLOWED_FIELDS:?GETRECS_ALLOWED_FIELDS is required}
    ports:
      - "8000:8000"

volumes:
  mongo-data:
```

1. Create env file:

```bash
cp .env.example .env
```

2. Update at least these values in `.env`:

- `FASTJWT_URL` (must point to your running `fastJWT` service)
- `WRITE_API_KEY` (API key for `/keypost`)
- `EXPORT_API_KEY` (API key for `/getrecs` and `/exportdb`)
- `GETRECS_ALLOWED_FIELDS` (comma-separated allowlist for `/getrecs`, e.g. `package.name,package.metadata.owner`)
- `MONGO_INITDB_ROOT_PASSWORD`, `MONGO_WRITER_PASSWORD`, `MONGO_READER_PASSWORD` (required — no defaults)

Minimum working `.env` example:

```env
MONGO_INITDB_ROOT_USERNAME=root
MONGO_INITDB_ROOT_PASSWORD=changeme
MONGO_DB_NAME=fastmongo
MONGO_WRITER_PASSWORD=changeme
MONGO_READER_PASSWORD=changeme
MONGO_COLLECTION=packages
FASTJWT_URL=http://fastjwt:8000
FASTJWT_VALIDATE_PATH=/validate-key
WRITE_API_KEY=replace-with-strong-write-key
EXPORT_API_KEY=replace-with-strong-export-key
GETRECS_ALLOWED_FIELDS=package.name,package.version
```

3. Start:

```bash
docker compose pull
docker compose up -d
```

## Testing scripts

Run quick syntax checks:

```bash
./tests/test_syntax.sh
```

Run API smoke tests (expects the stack to be running and keys set in `.env`):

```bash
./tests/test_api.sh
```

Optional override for `getrecs` query field:

```bash
TEST_GET_FIELD=package.version ./tests/test_api.sh
```

## API usage

### Health check

```bash
curl http://localhost:8000/health
```

### Upload JSON payload

```bash
curl -X POST http://localhost:8000/post \
  -H "Authorization: Bearer <jwt-from-fastJWT>" \
  -H "Content-Type: application/json" \
  -d '{"name": "example", "version": 1, "metadata": {"owner": "team-a"}}'
```

Success response example:

```json
{
  "status": "stored",
  "id": "...",
  "stored_at": "2026-01-01T00:00:00+00:00"
}
```

### Upload JSON payload with API key

```bash
curl -X POST http://localhost:8000/keypost \
  -H "X-API-Key: <WRITE_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"name": "example", "version": 1, "metadata": {"owner": "team-a"}}'
```

`/keypost` success response schema:

```json
{
  "status": "stored",
  "id": "string",
  "stored_at": "ISO-8601 timestamp"
}
```

### Fetch records by field/tag

```bash
curl -X POST http://localhost:8000/getrecs \
  -H "X-API-Key: <EXPORT_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"getField": "package.name", "getTag": "example"}'
```

`/getrecs` success response schema:

```json
{
  "count": 1,
  "records": [
    {
      "_id": {"$oid": "..."},
      "package": {},
      "stored_at": {"$date": "..."}
    }
  ]
}
```

### Download full database as JSON

```bash
curl -X GET http://localhost:8000/exportdb \
  -H "X-API-Key: <EXPORT_API_KEY>" \
  -o fastmongo-export.json
```

## Claude Code / Codex Integration Notes

Use this section when building another app that depends on `fastmongo`.

### Endpoint contracts to follow

- `POST /keypost`
  - Auth header: `X-API-Key: <WRITE_API_KEY>`
  - Body: any JSON payload to store
  - Stored document shape: `{ package, stored_at, auth_method }`
- `POST /getrecs`
  - Auth header: `X-API-Key: <EXPORT_API_KEY>`
  - Body: `{"getField":"<allowed-field>","getTag":"<value>"}`
  - `getField` must be in `GETRECS_ALLOWED_FIELDS`
  - Response: `{"count": <int>, "records": [...]}` (Mongo/BSON-safe JSON)
- `GET /exportdb`
  - Auth header: `X-API-Key: <EXPORT_API_KEY>`
  - Returns full DB export JSON attachment

### Environment required by client apps

- `FASTMONGO_URL` (example: `http://localhost:8000`)
- `WRITE_API_KEY` (for writes to `/keypost`)
- `EXPORT_API_KEY` (for reads from `/getrecs` and exports from `/exportdb`)
- Align `GETRECS_ALLOWED_FIELDS` with the fields your app needs to query.

### Recommended dev workflow for agents

1. Start fastmongo with `docker compose pull && docker compose up -d`.
2. Verify health with `GET /health`.
3. Insert a fixture record via `POST /keypost`.
4. Query it back via `POST /getrecs` using an allowed field.
5. Run `./tests/test_api.sh` before opening PRs in dependent apps.

### Common pitfalls

- Using `WRITE_API_KEY` against `/getrecs` will fail (needs `EXPORT_API_KEY`).
- Querying a field not listed in `GETRECS_ALLOWED_FIELDS` returns `400`.
- `/post` requires JWT via `fastJWT`; use `/keypost` for API-key-based integrations.

### Common status codes

- `200`: Success.
- `400`: Bad request (e.g., invalid/missing `getField` or `getTag`).
- `401`: Missing/invalid API key or JWT.
- `502`: JWT validation upstream (`fastJWT`) unavailable/error during `/post`.

## Notes

- `/post` calls `fastJWT` `POST /validate-key`; if token status is not `valid`, request is rejected. The `fastJWT` service must return a JSON body with at least `{"status": "valid"}`. An optional `"subject"` field is stored alongside the record.
- `/keypost` writes packages using `WRITE_API_KEY` instead of JWT validation.
- `/getrecs` returns all records where `getField == getTag` in `MONGO_COLLECTION`. `getField` must be explicitly listed in `GETRECS_ALLOWED_FIELDS` (comma-separated dotted paths, e.g. `package.name,package.version`).
- `/exportdb` returns all collections/documents from `MONGO_DB_NAME` as a downloadable JSON file. All documents are loaded into memory before the response is sent — avoid using this endpoint on very large databases.
- `WRITE_API_KEY` is required to access `/keypost`. `EXPORT_API_KEY` is required to access `/getrecs` and `/exportdb`. These are separate secrets with different blast radii.
