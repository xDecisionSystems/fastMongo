import os
import secrets
import json
import re
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from typing import Any, Deque, Dict, Literal, Optional
from collections import defaultdict, deque
from threading import Lock

import jwt
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from fastapi.responses import Response
from bson import json_util
from pymongo import MongoClient

VERSION_NAME = "window"

@asynccontextmanager
async def lifespan(_: FastAPI):
    print(f"fastMongo starting — version: {VERSION_NAME}", flush=True)
    yield

app = FastAPI(title="fastMongo API", version="1.0.0", lifespan=lifespan)


MONGO_HOST = os.getenv("MONGO_HOST", "127.0.0.1")
MONGO_PORT = int(os.getenv("MONGO_PORT", "27017"))
MONGO_DB_NAME = os.getenv("MONGO_DB_NAME", "fastmongo")
MONGO_COLLECTION = os.getenv("MONGO_COLLECTION", "app")
MONGO_WRITER_USERNAME = "writer"
MONGO_READER_USERNAME = "reader"
MONGO_WRITER_PASSWORD = os.getenv("MONGO_WRITER_PASSWORD")
MONGO_READER_PASSWORD = os.getenv("MONGO_READER_PASSWORD")

SECRET_KEY = os.getenv("SECRET_KEY")
JWT_EXPIRATION_MINUTES = int(os.getenv("JWT_EXPIRATION_MINUTES", "30"))
JWT_ISSUER = os.getenv("JWT_ISSUER", "fastjwt-api")
JWT_AUDIENCE = os.getenv("JWT_AUDIENCE", "fastjwt-clients")
RATE_LIMIT_REQUESTS = int(os.getenv("RATE_LIMIT_REQUESTS", "60"))
RATE_LIMIT_WINDOW_SECONDS = int(os.getenv("RATE_LIMIT_WINDOW_SECONDS", "60"))
API_WRITE_KEY = os.getenv("API_WRITE_KEY")
API_READ_KEY = os.getenv("API_READ_KEY")
API_MASTER_KEY = os.getenv("API_MASTER_KEY")
GETRECS_ALLOWED_TYPES_RAW = os.getenv("GETRECS_ALLOWED_TYPES")
CORS_ORIGINS_RAW = os.getenv("CORS_ORIGINS", "")
ALLOW_CORS_RAW = os.getenv("ALLOW_CORS", "true")

if not MONGO_WRITER_PASSWORD:
    raise RuntimeError("Missing required env var: MONGO_WRITER_PASSWORD")
if not MONGO_READER_PASSWORD:
    raise RuntimeError("Missing required env var: MONGO_READER_PASSWORD")
if not SECRET_KEY:
    raise RuntimeError("Missing required env var: SECRET_KEY")
if len(SECRET_KEY) < 32:
    raise RuntimeError("SECRET_KEY must be at least 32 characters")
if not API_WRITE_KEY:
    raise RuntimeError("Missing required env var: API_WRITE_KEY")
if not API_READ_KEY:
    raise RuntimeError("Missing required env var: API_READ_KEY")
if not API_MASTER_KEY:
    raise RuntimeError("Missing required env var: API_MASTER_KEY")
if not GETRECS_ALLOWED_TYPES_RAW:
    raise RuntimeError("Missing required env var: GETRECS_ALLOWED_TYPES")

GETRECS_ALLOWED_TYPES = {
    t.strip()
    for t in GETRECS_ALLOWED_TYPES_RAW.split(",")
    if t.strip()
}
if not GETRECS_ALLOWED_TYPES:
    raise RuntimeError("GETRECS_ALLOWED_TYPES must include at least one type name")

CORS_ORIGINS = [o.strip() for o in CORS_ORIGINS_RAW.split(",") if o.strip()]
ALLOW_CORS = ALLOW_CORS_RAW.strip().lower() in {"1", "true", "yes", "on"}

_cors_app = CORSMiddleware(
    app=app,
    allow_origins=CORS_ORIGINS if ALLOW_CORS else [],
    allow_methods=["GET", "POST", "DELETE"],
    allow_headers=["Content-Type", "Authorization", "X-API-Key"],
)

mongo_reader_client = MongoClient(
    host=MONGO_HOST,
    port=MONGO_PORT,
    username=MONGO_READER_USERNAME,
    password=MONGO_READER_PASSWORD,
    authSource=MONGO_DB_NAME,
)
mongo_writer_client = MongoClient(
    host=MONGO_HOST,
    port=MONGO_PORT,
    username=MONGO_WRITER_USERNAME,
    password=MONGO_WRITER_PASSWORD,
    authSource=MONGO_DB_NAME,
)

mongo_reader_collection = mongo_reader_client[MONGO_DB_NAME][MONGO_COLLECTION]
mongo_writer_collection = mongo_writer_client[MONGO_DB_NAME][MONGO_COLLECTION]
allowed_payloads_reader_collection = mongo_reader_client[MONGO_DB_NAME]["allowed_payloads"]
allowed_payloads_writer_collection = mongo_writer_client[MONGO_DB_NAME]["allowed_payloads"]
allowed_payloads_writer_collection.create_index("type_name", unique=True)

rate_limit_lock = Lock()
request_windows: Dict[str, Deque[float]] = defaultdict(deque)

class TokenRequest(BaseModel):
    jwt: str = Field(..., min_length=20, max_length=4096)


class TokenCreateRequest(BaseModel):
    sub: str = Field(..., min_length=1, max_length=128)


class TokenResponse(BaseModel):
    jwt: str
    expires_at: datetime


class ValidationResponse(BaseModel):
    status: Literal["valid", "expired", "invalid"]
    expires_at: Optional[int]
    subject: Optional[str]


class AllowedPayloadRequest(BaseModel):
    type_name: str = Field(..., min_length=1, max_length=128)
    fields: list[str] = Field(..., min_length=1, max_length=64)
    max_size: str = Field(..., min_length=3, max_length=32)


class AllowedPayloadResponse(BaseModel):
    status: Literal["saved"]
    type_name: str
    fields: list[str]
    max_size: str
    max_size_bytes: int


def _normalize_allowed_fields(fields: list[str]) -> list[str]:
    normalized: list[str] = []
    seen: set[str] = set()
    for field in fields:
        field_name = field.strip()
        if not field_name:
            raise HTTPException(status_code=400, detail="fields cannot contain empty or whitespace-only names")
        if field_name not in seen:
            seen.add(field_name)
            normalized.append(field_name)
    if not normalized:
        raise HTTPException(status_code=400, detail="fields must include at least one field name")
    return normalized


def _parse_max_size_to_bytes(max_size: str) -> int:
    match = re.match(r"^\s*(\d+)\s*(KB|MB)\s*$", max_size, flags=re.IGNORECASE)
    if not match:
        raise HTTPException(status_code=400, detail="max_size must be like '64KB' or '2MB'")

    size_value = int(match.group(1))
    if size_value <= 0:
        raise HTTPException(status_code=400, detail="max_size must be greater than 0")

    unit = match.group(2).upper()
    multiplier = 1024 if unit == "KB" else 1024 * 1024
    return size_value * multiplier


def _validate_payload_against_allowed_schema(payload: Dict[str, Any], payload_size: int) -> None:
    type_name = payload.get("type_name")
    if not isinstance(type_name, str) or not type_name.strip():
        raise HTTPException(status_code=400, detail="payload must include a non-empty string field: type_name")
    type_name = type_name.strip()

    rule = allowed_payloads_reader_collection.find_one(
        {"type_name": type_name},
        {"_id": 0, "fields": 1, "max_size_bytes": 1},
    )
    if not rule:
        raise HTTPException(status_code=400, detail=f"payload type '{type_name}' is not allowed")

    configured_fields = rule.get("fields", [])
    if not isinstance(configured_fields, list):
        raise HTTPException(status_code=500, detail="Stored allowed payload fields are invalid")
    configured_max_size_bytes = rule.get("max_size_bytes")
    if not isinstance(configured_max_size_bytes, int) or configured_max_size_bytes <= 0:
        raise HTTPException(status_code=500, detail="Stored allowed payload size is invalid")

    allowed_keys = set(configured_fields)
    allowed_keys.add("type_name")

    payload_keys = set(payload.keys())
    unexpected_keys = sorted(payload_keys - allowed_keys)
    if unexpected_keys:
        raise HTTPException(
            status_code=400,
            detail=f"payload contains unexpected fields: {', '.join(unexpected_keys)}",
        )

    if payload_size > configured_max_size_bytes:
        raise HTTPException(
            status_code=413,
            detail=f"payload exceeds allowed max size for '{type_name}' ({configured_max_size_bytes} bytes)",
        )


def _create_token(subject: str) -> tuple[str, datetime]:
    now = datetime.now(timezone.utc)
    expires_at = now + timedelta(minutes=JWT_EXPIRATION_MINUTES)
    payload = {
        "iss": JWT_ISSUER,
        "aud": JWT_AUDIENCE,
        "sub": subject,
        "exp": expires_at,
        "iat": now,
    }
    token = jwt.encode(payload, SECRET_KEY, algorithm="HS256")
    return token, expires_at


def _validate_token(token: str) -> tuple[str, Optional[dict]]:
    try:
        payload = jwt.decode(
            token,
            SECRET_KEY,
            algorithms=["HS256"],
            audience=JWT_AUDIENCE,
            issuer=JWT_ISSUER,
            options={"require": ["exp", "iat", "iss", "aud", "sub"]},
        )
        return "valid", payload
    except jwt.ExpiredSignatureError:
        return "expired", None
    except jwt.InvalidTokenError:
        return "invalid", None


def validate_jwt_or_401(jwt_token: str) -> Dict[str, Any]:
    token_status, payload = _validate_token(jwt_token)
    if token_status != "valid" or payload is None:
        raise HTTPException(status_code=401, detail=f"JWT is {token_status}")
    return payload


def _enforce_rate_limit(client_key: str) -> None:
    if RATE_LIMIT_REQUESTS <= 0:
        return

    now = datetime.now(tz=timezone.utc).timestamp()
    cutoff = now - RATE_LIMIT_WINDOW_SECONDS

    with rate_limit_lock:
        timestamps = request_windows[client_key]
        while timestamps and timestamps[0] < cutoff:
            timestamps.popleft()
        if len(timestamps) >= RATE_LIMIT_REQUESTS:
            raise HTTPException(status_code=429, detail="Rate limit exceeded")
        timestamps.append(now)


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


def _is_master_key(x_api_key: str | None) -> bool:
    return bool(x_api_key and secrets.compare_digest(x_api_key, API_MASTER_KEY))


def validate_master_api_key(x_api_key: str | None) -> None:
    if not _is_master_key(x_api_key):
        raise HTTPException(status_code=401, detail="Invalid API key")


def validate_write_or_master_api_key(x_api_key: str | None) -> None:
    if not x_api_key:
        raise HTTPException(status_code=401, detail="Invalid API key")
    if (
        secrets.compare_digest(x_api_key, API_WRITE_KEY)
        or secrets.compare_digest(x_api_key, API_MASTER_KEY)
    ):
        return
    raise HTTPException(status_code=401, detail="Invalid API key")


def validate_read_or_master_api_key(x_api_key: str | None) -> None:
    if not x_api_key:
        raise HTTPException(status_code=401, detail="Invalid API key")
    if (
        secrets.compare_digest(x_api_key, API_READ_KEY)
        or secrets.compare_digest(x_api_key, API_MASTER_KEY)
    ):
        return
    raise HTTPException(status_code=401, detail="Invalid API key")


def _is_any_valid_api_key(x_api_key: str | None) -> bool:
    if not x_api_key:
        return False
    return (
        secrets.compare_digest(x_api_key, API_WRITE_KEY)
        or secrets.compare_digest(x_api_key, API_READ_KEY)
        or secrets.compare_digest(x_api_key, API_MASTER_KEY)
    )


def _require_api_key_when_cors_disabled(x_api_key: str | None) -> None:
    if ALLOW_CORS:
        return
    if not _is_any_valid_api_key(x_api_key):
        raise HTTPException(status_code=401, detail="API key required when ALLOW_CORS is false")


def _check_generate_token_auth(request: Request, x_api_key: str | None) -> None:
    """Allow if caller supplies write/master key or allowed Origin."""
    _require_api_key_when_cors_disabled(x_api_key)
    if x_api_key:
        validate_write_or_master_api_key(x_api_key)
        return
    origin = request.headers.get("origin", "")
    if ALLOW_CORS and CORS_ORIGINS and origin in CORS_ORIGINS:
        return
    raise HTTPException(status_code=401, detail="Missing or invalid credentials for /generate-token")


@app.get("/health")
def health(x_api_key: str | None = Header(default=None, alias="X-API-Key")) -> Dict[str, str]:
    _require_api_key_when_cors_disabled(x_api_key)
    return {"status": "ok"}


@app.post("/generate-token", response_model=TokenResponse)
async def generate_token(
    payload: TokenCreateRequest,
    request: Request,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
) -> TokenResponse:
    _check_generate_token_auth(request, x_api_key)
    token, expires_at = _create_token(payload.sub)
    return TokenResponse(jwt=token, expires_at=expires_at)


@app.post("/validate-token", response_model=ValidationResponse)
async def validate_token(
    payload: TokenRequest,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
) -> ValidationResponse:
    validate_write_or_master_api_key(x_api_key)
    token_status, decoded = _validate_token(payload.jwt)
    expires_at = decoded.get("exp") if decoded else None
    subject = decoded.get("sub") if decoded else None
    return ValidationResponse(status=token_status, expires_at=expires_at, subject=subject)


@app.post("/allowed", response_model=AllowedPayloadResponse)
def save_allowed_payload(
    payload: AllowedPayloadRequest,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
) -> AllowedPayloadResponse:
    validate_master_api_key(x_api_key)

    type_name = payload.type_name.strip()
    if not type_name:
        raise HTTPException(status_code=400, detail="type_name cannot be blank or whitespace-only")

    normalized_fields = _normalize_allowed_fields(payload.fields)
    normalized_max_size = payload.max_size.strip().upper()
    max_size_bytes = _parse_max_size_to_bytes(normalized_max_size)

    allowed_payloads_writer_collection.update_one(
        {"type_name": type_name},
        {
            "$set": {
                "type_name": type_name,
                "fields": normalized_fields,
                "max_size": normalized_max_size,
                "max_size_bytes": max_size_bytes,
                "updated_at": datetime.now(timezone.utc),
            }
        },
        upsert=True,
    )

    return AllowedPayloadResponse(
        status="saved",
        type_name=type_name,
        fields=normalized_fields,
        max_size=normalized_max_size,
        max_size_bytes=max_size_bytes,
    )


@app.get("/allowed")
def list_allowed_types(
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
) -> Dict[str, Any]:
    validate_master_api_key(x_api_key)

    types = list(allowed_payloads_reader_collection.find({}, {"_id": 0}))
    normalized = json.loads(json_util.dumps(types))

    return {
        "count": len(normalized),
        "types": normalized,
    }


@app.delete("/allowed/{type_name}")
def delete_allowed_type(
    type_name: str,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
) -> Dict[str, Any]:
    validate_master_api_key(x_api_key)

    result = allowed_payloads_writer_collection.delete_one({"type_name": type_name})
    if result.deleted_count == 0:
        raise HTTPException(status_code=404, detail=f"type '{type_name}' not found")

    return {"status": "deleted", "type_name": type_name}


@app.delete("/records/{type_name}")
def delete_records_by_type(
    type_name: str,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
) -> Dict[str, Any]:
    validate_master_api_key(x_api_key)

    result = mongo_writer_collection.delete_many({"type_name": type_name})

    return {"status": "deleted", "type_name": type_name, "deleted_count": result.deleted_count}


@app.delete("/hardreset")
def hard_reset(
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
) -> Dict[str, Any]:
    validate_master_api_key(x_api_key)

    records_result = mongo_writer_collection.delete_many({})
    types_result = allowed_payloads_writer_collection.delete_many({})

    return {
        "status": "reset",
        "records_deleted": records_result.deleted_count,
        "types_deleted": types_result.deleted_count,
    }


@app.post("/post")
async def store_package(
    payload: Dict[str, Any],
    request: Request,
    authorization: str | None = Header(default=None),
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
) -> Dict[str, str]:
    _require_api_key_when_cors_disabled(x_api_key)
    # Auth before any DB work.
    subject: str | None = None
    auth_method = "jwt"
    if x_api_key:
        validate_write_or_master_api_key(x_api_key)
        auth_method = "api_key"
    else:
        token = extract_bearer_token(authorization)
        validated = validate_jwt_or_401(token)
        subject = validated.get("sub")

    client_host = request.client.host if request.client else "unknown"
    _enforce_rate_limit(client_host)

    raw_body = await request.body()
    payload_size = len(raw_body)
    _validate_payload_against_allowed_schema(payload, payload_size)

    now = datetime.now(timezone.utc)

    result = mongo_writer_collection.insert_one({
        **payload,
        "stored_at": now,
        "jwt_subject": subject,
        "auth_method": auth_method,
    })

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
    validate_read_or_master_api_key(x_api_key)

    type_name = payload.get("type_name")
    get_field = payload.get("getField")
    get_tag = payload.get("getTag")

    if not isinstance(type_name, str) or not type_name.strip():
        raise HTTPException(status_code=400, detail="type_name must be a non-empty string")
    type_name = type_name.strip()

    if type_name not in GETRECS_ALLOWED_TYPES:
        raise HTTPException(status_code=400, detail="type_name is not in the allowed list")

    query: Dict[str, Any] = {"type_name": type_name}

    if get_field is not None or get_tag is not None:
        if not isinstance(get_field, str) or not get_field.strip():
            raise HTTPException(status_code=400, detail="getField must be a non-empty string")
        get_field = get_field.strip()
        if not isinstance(get_tag, str) or not get_tag.strip():
            raise HTTPException(status_code=400, detail="getTag must be a non-empty string")
        query[get_field] = get_tag.strip()

    records = list(mongo_reader_collection.find(query))
    normalized_records = json.loads(json_util.dumps(records))

    return {
        "count": len(normalized_records),
        "records": normalized_records,
    }


@app.get("/lastrecs")
def get_last_records(
    type_name: str,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
) -> Dict[str, Any]:
    validate_read_or_master_api_key(x_api_key)

    if not type_name.strip():
        raise HTTPException(status_code=400, detail="type_name must be a non-empty string")
    type_name = type_name.strip()

    if type_name not in GETRECS_ALLOWED_TYPES:
        raise HTTPException(status_code=400, detail="type_name is not in the allowed list")

    records = list(mongo_reader_collection.find({"type_name": type_name}).sort("stored_at", -1).limit(10))
    normalized_records = json.loads(json_util.dumps(records))

    return {
        "count": len(normalized_records),
        "records": normalized_records,
    }


@app.get("/exportdb")
def export_database(x_api_key: str | None = Header(default=None, alias="X-API-Key")) -> Response:
    validate_master_api_key(x_api_key)

    db = mongo_reader_client[MONGO_DB_NAME]
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


async def asgi_app(scope, receive, send):
    api_key = ""
    for name, value in scope.get("headers", []):
        if name == b"x-api-key":
            api_key = value.decode()
            break
    if _is_any_valid_api_key(api_key):
        await app(scope, receive, send)
    else:
        await _cors_app(scope, receive, send)
