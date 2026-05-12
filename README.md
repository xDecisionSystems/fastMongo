# fastMongo

`fastMongo` runs two Dockerized apps in this repo:

1. MongoDB (`mongo/Dockerfile`)
2. FastAPI (`api/Dockerfile`)

The API accepts JSON payloads, validates JWTs through `fastJWT`, stores data in MongoDB, and can export the full database with a separate API key.

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

3. Start:

```bash
docker compose up --build
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

### Fetch records by field/tag

```bash
curl -X POST http://localhost:8000/getrecs \
  -H "X-API-Key: <EXPORT_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"getField": "package.name", "getTag": "example"}'
```

### Download full database as JSON

```bash
curl -X GET http://localhost:8000/exportdb \
  -H "X-API-Key: <EXPORT_API_KEY>" \
  -o fastmongo-export.json
```

## Notes

- `/post` calls `fastJWT` `POST /validate-key`; if token status is not `valid`, request is rejected. The `fastJWT` service must return a JSON body with at least `{"status": "valid"}`. An optional `"subject"` field is stored alongside the record.
- `/keypost` writes packages using `WRITE_API_KEY` instead of JWT validation.
- `/getrecs` returns all records where `getField == getTag` in `MONGO_COLLECTION`. `getField` must be explicitly listed in `GETRECS_ALLOWED_FIELDS` (comma-separated dotted paths, e.g. `package.name,package.version`).
- `/exportdb` returns all collections/documents from `MONGO_DB_NAME` as a downloadable JSON file. All documents are loaded into memory before the response is sent — avoid using this endpoint on very large databases.
- `WRITE_API_KEY` is required to access `/keypost`. `EXPORT_API_KEY` is required to access `/getrecs` and `/exportdb`. These are separate secrets with different blast radii.
