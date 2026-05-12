#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

API_URL="${API_URL:-http://localhost:8000}"
WRITE_KEY="${WRITE_API_KEY:-}"
EXPORT_KEY="${EXPORT_API_KEY:-}"
GENERATE_KEY="${GENERATE_API_KEY:-}"
TOKEN_ORIGIN="${TEST_TOKEN_ORIGIN:-${CORS_ORIGINS%%,*}}"
GET_FIELD="${TEST_GET_FIELD:-package.name}"
ALLOWED_TYPE="${TEST_ALLOWED_TYPE:-smoke_payload}"
GET_TAG="${TEST_GET_TAG:-${ALLOWED_TYPE}}"
TEST_TAG="smoke-$(date +%s)"

if [[ -z "${WRITE_KEY}" ]]; then
  echo "Missing WRITE_API_KEY (set in environment or .env)"
  exit 1
fi

if [[ -z "${EXPORT_KEY}" ]]; then
  echo "Missing EXPORT_API_KEY (set in environment or .env)"
  exit 1
fi

if [[ -z "${GENERATE_KEY}" && -z "${TOKEN_ORIGIN}" ]]; then
  echo "Missing GENERATE_API_KEY or TEST_TOKEN_ORIGIN/CORS_ORIGINS for /generate-token test"
  exit 1
fi

echo "1) Health check..."
health_code="$(curl -s -o /tmp/fastmongo_health.json -w "%{http_code}" "${API_URL}/health")"
if [[ "${health_code}" != "200" ]]; then
  echo "Health check failed (HTTP ${health_code})"
  cat /tmp/fastmongo_health.json
  exit 1
fi

echo "2) configure allowed payload type..."
allowed_payload="$(cat <<EOF
{"type_name":"${ALLOWED_TYPE}","fields":["version","metadata"],"max_size":"64KB"}
EOF
)"
allowed_code="$(curl -s -o /tmp/fastmongo_allowed.json -w "%{http_code}" \
  -X POST "${API_URL}/allowed" \
  -H "X-API-Key: ${WRITE_KEY}" \
  -H "Content-Type: application/json" \
  -d "${allowed_payload}")"

if [[ "${allowed_code}" != "200" ]]; then
  echo "allowed setup failed (HTTP ${allowed_code})"
  cat /tmp/fastmongo_allowed.json
  exit 1
fi

echo "3) generate-token + jwt /post test..."
gen_payload='{"sub":"smoke-user"}'
if [[ -n "${GENERATE_KEY}" ]]; then
  gen_code="$(curl -s -o /tmp/fastmongo_generate_key.json -w "%{http_code}" \
    -X POST "${API_URL}/generate-token" \
    -H "X-API-Key: ${GENERATE_KEY}" \
    -H "Content-Type: application/json" \
    -d "${gen_payload}")"
else
  gen_code="$(curl -s -o /tmp/fastmongo_generate_key.json -w "%{http_code}" \
    -X POST "${API_URL}/generate-token" \
    -H "Origin: ${TOKEN_ORIGIN}" \
    -H "Content-Type: application/json" \
    -d "${gen_payload}")"
fi

if [[ "${gen_code}" != "200" ]]; then
  echo "generate-token failed (HTTP ${gen_code})"
  cat /tmp/fastmongo_generate_key.json
  exit 1
fi

jwt_token="$(python3 - <<'PY'
import json
with open('/tmp/fastmongo_generate_key.json', 'r', encoding='utf-8') as f:
    data = json.load(f)
print(data.get("jwt", ""))
PY
)"

if [[ -z "${jwt_token}" ]]; then
  echo "generate-token response missing jwt."
  cat /tmp/fastmongo_generate_key.json
  exit 1
fi

post_payload="$(cat <<EOF
{"type_name":"${ALLOWED_TYPE}","version":1,"metadata":{"owner":"test-script-${TEST_TAG}"}}
EOF
)"
post_code="$(curl -s -o /tmp/fastmongo_post.json -w "%{http_code}" \
  -X POST "${API_URL}/post" \
  -H "Authorization: Bearer ${jwt_token}" \
  -H "Content-Type: application/json" \
  -d "${post_payload}")"

if [[ "${post_code}" != "200" ]]; then
  echo "post failed (HTTP ${post_code})"
  cat /tmp/fastmongo_post.json
  exit 1
fi

echo "4) /post with API key test..."
apikey_post_payload="$(cat <<EOF
{"type_name":"${ALLOWED_TYPE}","version":1,"metadata":{"owner":"test-script-${TEST_TAG}"}}
EOF
)"
apikey_post_code="$(curl -s -o /tmp/fastmongo_post_apikey.json -w "%{http_code}" \
  -X POST "${API_URL}/post" \
  -H "X-API-Key: ${WRITE_KEY}" \
  -H "Content-Type: application/json" \
  -d "${apikey_post_payload}")"

if [[ "${apikey_post_code}" != "200" ]]; then
  echo "/post with API key failed (HTTP ${apikey_post_code})"
  cat /tmp/fastmongo_post_apikey.json
  exit 1
fi

echo "5) getrecs read test..."
getrecs_payload="$(cat <<EOF
{"getField":"${GET_FIELD}","getTag":"${GET_TAG}"}
EOF
)"
getrecs_code="$(curl -s -o /tmp/fastmongo_getrecs.json -w "%{http_code}" \
  -X POST "${API_URL}/getrecs" \
  -H "X-API-Key: ${EXPORT_KEY}" \
  -H "Content-Type: application/json" \
  -d "${getrecs_payload}")"

if [[ "${getrecs_code}" != "200" ]]; then
  echo "getrecs failed (HTTP ${getrecs_code})"
  cat /tmp/fastmongo_getrecs.json
  exit 1
fi

record_count="$(python3 - <<'PY'
import json
with open('/tmp/fastmongo_getrecs.json', 'r', encoding='utf-8') as f:
    data = json.load(f)
print(int(data.get("count", 0)))
PY
)"

if [[ "${record_count}" -lt 1 ]]; then
  echo "getrecs returned zero records unexpectedly."
  cat /tmp/fastmongo_getrecs.json
  exit 1
fi

echo "API smoke tests passed."
