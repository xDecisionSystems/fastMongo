import os
import secrets
import json
from datetime import datetime, timezone
from typing import Any, Dict

import httpx
from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import Response
from bson import json_util
from pymongo import MongoClient

app = FastAPI(title="fastMongo API", version="1.0.0")


MONGO_HOST = os.getenv("MONGO_HOST", "mongo")
MONGO_PORT = int(os.getenv("MONGO_PORT", "27017"))
MONGO_DB_NAME = os.getenv("MONGO_DB_NAME", "app")
MONGO_COLLECTION = os.getenv("MONGO_COLLECTION", "packages")
MONGO_WRITER_USERNAME = os.getenv("MONGO_WRITER_USERNAME", "writer")
MONGO_WRITER_PASSWORD = os.getenv("MONGO_WRITER_PASSWORD")

FASTJWT_URL = os.getenv("FASTJWT_URL", "http://fastjwt:8000")
FASTJWT_VALIDATE_PATH = os.getenv("FASTJWT_VALIDATE_PATH", "/validate-key")
WRITE_API_KEY = os.getenv("WRITE_API_KEY")
EXPORT_API_KEY = os.getenv("EXPORT_API_KEY")
GETRECS_ALLOWED_FIELDS_RAW = os.getenv("GETRECS_ALLOWED_FIELDS")

if not MONGO_WRITER_PASSWORD:
    raise RuntimeError("Missing required env var: MONGO_WRITER_PASSWORD")
if not WRITE_API_KEY:
    raise RuntimeError("Missing required env var: WRITE_API_KEY")
if not EXPORT_API_KEY:
    raise RuntimeError("Missing required env var: EXPORT_API_KEY")
if not GETRECS_ALLOWED_FIELDS_RAW:
    raise RuntimeError("Missing required env var: GETRECS_ALLOWED_FIELDS")

GETRECS_ALLOWED_FIELDS = {
    field.strip()
    for field in GETRECS_ALLOWED_FIELDS_RAW.split(",")
    if field.strip()
}
if not GETRECS_ALLOWED_FIELDS:
    raise RuntimeError("GETRECS_ALLOWED_FIELDS must include at least one field name")

mongo_client = MongoClient(
    host=MONGO_HOST,
    port=MONGO_PORT,
    username=MONGO_WRITER_USERNAME,
    password=MONGO_WRITER_PASSWORD,
    authSource=MONGO_DB_NAME,
)
mongo_collection = mongo_client[MONGO_DB_NAME][MONGO_COLLECTION]


async def validate_jwt(jwt_token: str) -> Dict[str, Any]:
    validate_url = f"{FASTJWT_URL.rstrip('/')}{FASTJWT_VALIDATE_PATH}"

    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.post(validate_url, json={"jwt": jwt_token})
            response.raise_for_status()
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Failed to validate token: {exc}") from exc

    payload = response.json()
    token_status = payload.get("status")

    if token_status != "valid":
        raise HTTPException(status_code=401, detail=f"JWT is {token_status or 'invalid'}")

    return payload


def extract_bearer_token(authorization: str | None) -> str:
    if not authorization:
        raise HTTPException(status_code=401, detail="Missing Authorization header")

    prefix = "Bearer "
    if not authorization.startswith(prefix):
        raise HTTPException(status_code=401, detail="Authorization header must use Bearer token")

    token = authorization[len(prefix) :].strip()
    if not token:
        raise HTTPException(status_code=401, detail="Missing JWT token")

    return token


def validate_write_api_key(x_api_key: str | None) -> None:
    if not x_api_key or not secrets.compare_digest(x_api_key, WRITE_API_KEY):
        raise HTTPException(status_code=401, detail="Invalid API key")


def validate_export_api_key(x_api_key: str | None) -> None:
    if not x_api_key or not secrets.compare_digest(x_api_key, EXPORT_API_KEY):
        raise HTTPException(status_code=401, detail="Invalid API key")


@app.get("/health")
def health() -> Dict[str, str]:
    return {"status": "ok"}


@app.post("/post")
async def store_package(payload: Dict[str, Any], authorization: str | None = Header(default=None)) -> Dict[str, str]:
    token = extract_bearer_token(authorization)
    validated = await validate_jwt(token)

    subject = validated.get("subject")
    now = datetime.now(timezone.utc)

    result = mongo_collection.insert_one({
        "package": payload,
        "stored_at": now,
        "jwt_subject": subject,
    })

    return {
        "status": "stored",
        "id": str(result.inserted_id),
        "stored_at": now.isoformat(),
    }


@app.post("/keypost")
def store_package_with_api_key(
    payload: Dict[str, Any],
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
) -> Dict[str, str]:
    validate_write_api_key(x_api_key)

    now = datetime.now(timezone.utc)

    document = {
        "package": payload,
        "stored_at": now,
        "auth_method": "api_key",
    }

    result = mongo_collection.insert_one(document)

    return {
        "status": "stored",
        "id": str(result.inserted_id),
        "stored_at": now.isoformat(),
    }


@app.post("/getrecs")
def get_records_by_field(
    payload: Dict[str, Any],
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
) -> Dict[str, Any]:
    validate_export_api_key(x_api_key)

    get_field = payload.get("getField")
    get_tag = payload.get("getTag")

    if not isinstance(get_field, str) or not get_field.strip():
        raise HTTPException(status_code=400, detail="getField must be a non-empty string")
    get_field = get_field.strip()
    if get_field not in GETRECS_ALLOWED_FIELDS:
        raise HTTPException(status_code=400, detail="getField is not in the allowed list")
    if get_tag is None:
        raise HTTPException(status_code=400, detail="getTag is required")

    records = list(mongo_collection.find({get_field: get_tag}))
    normalized_records = json.loads(json_util.dumps(records))

    return {
        "count": len(normalized_records),
        "records": normalized_records,
    }


@app.get("/exportdb")
def export_database(x_api_key: str | None = Header(default=None, alias="X-API-Key")) -> Response:
    validate_export_api_key(x_api_key)

    db = mongo_client[MONGO_DB_NAME]
    now = datetime.now(timezone.utc)
    export_payload: Dict[str, Any] = {
        "database": MONGO_DB_NAME,
        "exported_at": now,
        "collections": {},
    }

    for collection_name in db.list_collection_names():
        documents = list(db[collection_name].find({}))
        export_payload["collections"][collection_name] = documents

    body = json_util.dumps(export_payload, indent=2)
    filename = f"{MONGO_DB_NAME}-export-{now.strftime('%Y%m%dT%H%M%SZ')}.json"

    return Response(
        content=body,
        media_type="application/json",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )
