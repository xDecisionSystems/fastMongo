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
GET_FIELD="${TEST_GET_FIELD:-package.name}"
TEST_TAG="smoke-$(date +%s)"

if [[ -z "${WRITE_KEY}" ]]; then
  echo "Missing WRITE_API_KEY (set in environment or .env)"
  exit 1
fi

if [[ -z "${EXPORT_KEY}" ]]; then
  echo "Missing EXPORT_API_KEY (set in environment or .env)"
  exit 1
fi

echo "1) Health check..."
health_code="$(curl -s -o /tmp/fastmongo_health.json -w "%{http_code}" "${API_URL}/health")"
if [[ "${health_code}" != "200" ]]; then
  echo "Health check failed (HTTP ${health_code})"
  cat /tmp/fastmongo_health.json
  exit 1
fi

echo "2) keypost write test..."
keypost_payload="$(cat <<EOF
{"name":"${TEST_TAG}","version":1,"metadata":{"owner":"test-script"}}
EOF
)"
keypost_code="$(curl -s -o /tmp/fastmongo_keypost.json -w "%{http_code}" \
  -X POST "${API_URL}/keypost" \
  -H "X-API-Key: ${WRITE_KEY}" \
  -H "Content-Type: application/json" \
  -d "${keypost_payload}")"

if [[ "${keypost_code}" != "200" ]]; then
  echo "keypost failed (HTTP ${keypost_code})"
  cat /tmp/fastmongo_keypost.json
  exit 1
fi

echo "3) getrecs read test..."
getrecs_payload="$(cat <<EOF
{"getField":"${GET_FIELD}","getTag":"${TEST_TAG}"}
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

