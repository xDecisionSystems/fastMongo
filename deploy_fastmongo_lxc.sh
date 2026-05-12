#!/usr/bin/env bash
set -euo pipefail

# Native fastMongo deployment for Debian 13 Proxmox LXC
# Template target: debian-13-standard_13.1-2_amd64.tar.zst
#
# What this script does:
# 1. Downloads fastMongo source archive from GitHub
# 2. Installs MongoDB + runtime dependencies
# 3. Copies source to /opt/fastmongo
# 4. Creates Python virtualenv and installs API deps
# 5. Configures MongoDB with authentication enabled
# 6. Creates /etc/fastmongo/fastmongo.env
# 7. Creates and enables fastmongo-api systemd service
#
# Run as root inside the LXC:
#   wget -qO- https://raw.githubusercontent.com/xDecisionSystems/fastMongo/main/deploy_fastmongo_lxc.sh | bash

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root."
  exit 1
fi

APP_DIR="/opt/fastmongo"
APP_USER="fastmongo"
APP_GROUP="fastmongo"
SOURCE_STAGING_DIR=""
MONGOD_SERVICE=""
INSTALL_LOG="/tmp/fastmongo-install.log"
VERSION_KEY_NAME="wombat"

MONGO_DB_NAME="${MONGO_DB_NAME:-fastmongo}"
MONGO_COLLECTION="${MONGO_COLLECTION:-app}"
MONGO_WRITER_USERNAME="writer"
MONGO_READER_USERNAME="reader"
MONGO_WRITER_PASSWORD="${MONGO_WRITER_PASSWORD:-$(openssl rand -base64 24 | tr -d '\n')}"
MONGO_READER_PASSWORD="${MONGO_READER_PASSWORD:-$(openssl rand -base64 24 | tr -d '\n')}"
SECRET_KEY="${SECRET_KEY:-$(openssl rand -hex 32)}"
JWT_EXPIRATION_MINUTES="${JWT_EXPIRATION_MINUTES:-20}"
JWT_ISSUER="${JWT_ISSUER:-fastjwt-api}"
JWT_AUDIENCE="${JWT_AUDIENCE:-fastjwt-clients}"
RATE_LIMIT_REQUESTS="${RATE_LIMIT_REQUESTS:-60}"
RATE_LIMIT_WINDOW_SECONDS="${RATE_LIMIT_WINDOW_SECONDS:-60}"
API_WRITE_KEY="${API_WRITE_KEY:-$(openssl rand -hex 32)}"
API_READ_KEY="${API_READ_KEY:-$(openssl rand -hex 32)}"
API_MASTER_KEY="${API_MASTER_KEY:-$(openssl rand -hex 32)}"
CORS_ORIGINS="${CORS_ORIGINS:-}"
GETRECS_ALLOWED_FIELDS="${GETRECS_ALLOWED_FIELDS:-app.name,app.version}"
API_BIND_HOST="${API_BIND_HOST:-0.0.0.0}"
API_BIND_PORT="${API_BIND_PORT:-8000}"

# js_string safely escapes a value for use inside a JS double-quoted string.
js_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

step() {
  echo
  echo "==> $1"
}

run_quiet() {
  local description="$1"
  shift
  if ! "$@" >>"${INSTALL_LOG}" 2>&1; then
    echo "Failed during: ${description}"
    echo "Install log: ${INSTALL_LOG}"
    tail -n 40 "${INSTALL_LOG}" || true
    exit 1
  fi
}

download_source_archive() {
  local archive_url="https://codeload.github.com/xDecisionSystems/fastMongo/tar.gz/main"
  local staging_root
  staging_root="$(mktemp -d /tmp/fastmongo-src.XXXXXX)"

  echo "Downloading latest source from xDecisionSystems/fastMongo@main..."
  wget -qO- "${archive_url}" | tar -xzf - -C "${staging_root}"

  SOURCE_STAGING_DIR="$(find "${staging_root}" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  if [[ -z "${SOURCE_STAGING_DIR}" || ! -d "${SOURCE_STAGING_DIR}" ]]; then
    echo "Failed to extract fastMongo source archive."
    exit 1
  fi

  if [[ ! -f "${SOURCE_STAGING_DIR}/main.py" || ! -f "${SOURCE_STAGING_DIR}/requirements.txt" ]]; then
    echo "Downloaded archive is missing required files (main.py, requirements.txt)."
    exit 1
  fi
}

cleanup_source_archive() {
  if [[ -n "${SOURCE_STAGING_DIR}" && -d "${SOURCE_STAGING_DIR}" ]]; then
    rm -rf "$(dirname "${SOURCE_STAGING_DIR}")"
  fi
}

install_system_packages() {
  export DEBIAN_FRONTEND=noninteractive
  run_quiet "apt-get update (system packages)" apt-get -qq update
  run_quiet "apt-get install (system packages)" apt-get -qq install -y --no-install-recommends \
    ca-certificates \
    gpg \
    openssl \
    python3 \
    python3-pip \
    python3-venv \
    rsync \
    systemd \
    systemd-sysv
}

install_mongodb() {
  if command -v mongod >/dev/null 2>&1; then
    echo "MongoDB already installed."
    return
  fi

  # Debian trixie does not ship a mongodb-server package.
  # Use the official MongoDB 8.0 repo targeting bookworm (binary-compatible with trixie).
  install -d -m 0755 /usr/share/keyrings
  wget -qO- https://pgp.mongodb.com/server-8.0.asc \
    | gpg --dearmor -o /usr/share/keyrings/mongodb-server-8.0.gpg
  echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/8.0 main" \
    >/etc/apt/sources.list.d/mongodb-org-8.0.list

  run_quiet "apt-get update (mongodb repo)" apt-get -qq update
  run_quiet "apt-get install (mongodb-org)" apt-get -qq install -y mongodb-org
}

prepare_app_user_and_code() {
  if ! id -u "${APP_USER}" >/dev/null 2>&1; then
    useradd --system --create-home --shell /usr/sbin/nologin "${APP_USER}"
  fi

  install -d -o "${APP_USER}" -g "${APP_GROUP}" -m 0755 "${APP_DIR}"
  rsync -a --delete --exclude ".git" "${SOURCE_STAGING_DIR}/" "${APP_DIR}/"
  chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}"
}

install_python_deps() {
  python3 -m venv "${APP_DIR}/.venv"
  "${APP_DIR}/.venv/bin/pip" install --upgrade pip
  "${APP_DIR}/.venv/bin/pip" install -r "${APP_DIR}/requirements.txt"
}

configure_mongodb() {
  # Detect the MongoDB service unit name (distro packages may use 'mongodb').
  if systemctl list-unit-files mongod.service &>/dev/null && \
     systemctl list-unit-files mongod.service | grep -q mongod.service; then
    MONGOD_SERVICE="mongod"
  elif systemctl list-unit-files mongodb.service &>/dev/null && \
       systemctl list-unit-files mongodb.service | grep -q mongodb.service; then
    MONGOD_SERVICE="mongodb"
  else
    echo "Could not find a mongod or mongodb systemd service unit."
    exit 1
  fi

  systemctl enable "${MONGOD_SERVICE}" || true
  systemctl start "${MONGOD_SERVICE}"

  # Detect available mongo shell (mongosh or legacy mongo).
  local mongo_shell
  if command -v mongosh >/dev/null 2>&1; then
    mongo_shell="mongosh"
  elif command -v mongo >/dev/null 2>&1; then
    mongo_shell="mongo"
  else
    echo "No MongoDB shell (mongosh or mongo) found after install."
    exit 1
  fi

  # Wait for mongod to accept connections.
  local attempts=0
  until ${mongo_shell} --quiet --eval "db.adminCommand({ ping: 1 }).ok" >/dev/null 2>&1; do
    attempts=$(( attempts + 1 ))
    if [[ "${attempts}" -ge 30 ]]; then
      echo "MongoDB did not become ready in time."
      exit 1
    fi
    sleep 1
  done

  ${mongo_shell} --quiet <<EOF_MONGO
const dbName = "$(js_string "${MONGO_DB_NAME}")";
const writerUser = "$(js_string "${MONGO_WRITER_USERNAME}")";
const writerPass = "$(js_string "${MONGO_WRITER_PASSWORD}")";
const readerUser = "$(js_string "${MONGO_READER_USERNAME}")";
const readerPass = "$(js_string "${MONGO_READER_PASSWORD}")";

const targetDb = db.getSiblingDB(dbName);

if (!targetDb.getUser(writerUser)) {
  targetDb.createUser({
    user: writerUser,
    pwd: writerPass,
    roles: [{ role: "readWrite", db: dbName }]
  });
}

if (!targetDb.getUser(readerUser)) {
  targetDb.createUser({
    user: readerUser,
    pwd: readerPass,
    roles: [{ role: "read", db: dbName }]
  });
}
EOF_MONGO

  # Enable authentication so the users created above are enforced.
  local mongod_conf
  if [[ -f /etc/mongod.conf ]]; then
    mongod_conf=/etc/mongod.conf
  elif [[ -f /etc/mongodb.conf ]]; then
    mongod_conf=/etc/mongodb.conf
  else
    echo "Could not locate mongod.conf; skipping auth enable. Set security.authorization: enabled manually."
    return
  fi

  python3 - "${mongod_conf}" <<'EOF_PY'
import sys, re

path = sys.argv[1]
text = open(path).read()

# If authorization is already enabled, nothing to do.
if re.search(r'^\s*authorization\s*:\s*enabled', text, re.MULTILINE):
    sys.exit(0)

# If a security: block exists, insert authorization: enabled after it,
# preserving whatever else may already be under that key.
if re.search(r'^security\s*:', text, re.MULTILINE):
    text = re.sub(
        r'(^security\s*:[ \t]*\n)',
        r'\1  authorization: enabled\n',
        text,
        count=1,
        flags=re.MULTILINE,
    )
else:
    text = text.rstrip('\n') + '\n\nsecurity:\n  authorization: enabled\n'

open(path, 'w').write(text)
EOF_PY

  systemctl restart "${MONGOD_SERVICE}"
}

write_fastmongo_env() {
  install -d -o root -g "${APP_GROUP}" -m 0750 /etc/fastmongo
  cat >/etc/fastmongo/fastmongo.env <<EOF_ENV
# fastMongo runtime environment
#
# Easy to change later (takes effect after: systemctl restart fastmongo-api):
# - SECRET_KEY
# - JWT_EXPIRATION_MINUTES
# - JWT_ISSUER
# - JWT_AUDIENCE
# - RATE_LIMIT_REQUESTS
# - RATE_LIMIT_WINDOW_SECONDS
# - API_WRITE_KEY
# - API_READ_KEY
# - API_MASTER_KEY
# - CORS_ORIGINS
# - GETRECS_ALLOWED_FIELDS
# - MONGO_COLLECTION
#
# Not automatically safe to change (requires extra/manual work):
# - MONGO_WRITER_PASSWORD:
#   Must match the MongoDB 'writer' user password, or update that Mongo user too.
# - MONGO_READER_PASSWORD:
#   Must match the MongoDB 'reader' user password, or update that Mongo user too.
# - MONGO_DB_NAME:
#   Existing data/users may still exist only in the previous DB name.
# - MONGO_HOST / MONGO_PORT:
#   Must point to a reachable MongoDB server.
#
# Note:
# - API bind host/port are set in /etc/systemd/system/fastmongo-api.service
#   (ExecStart), not in this env file.

MONGO_HOST=127.0.0.1
MONGO_PORT=27017
MONGO_DB_NAME=${MONGO_DB_NAME}
MONGO_COLLECTION=${MONGO_COLLECTION}
MONGO_WRITER_PASSWORD=${MONGO_WRITER_PASSWORD}
MONGO_READER_PASSWORD=${MONGO_READER_PASSWORD}
SECRET_KEY=${SECRET_KEY}
JWT_EXPIRATION_MINUTES=${JWT_EXPIRATION_MINUTES}
JWT_ISSUER=${JWT_ISSUER}
JWT_AUDIENCE=${JWT_AUDIENCE}
RATE_LIMIT_REQUESTS=${RATE_LIMIT_REQUESTS}
RATE_LIMIT_WINDOW_SECONDS=${RATE_LIMIT_WINDOW_SECONDS}
API_WRITE_KEY=${API_WRITE_KEY}
API_READ_KEY=${API_READ_KEY}
API_MASTER_KEY=${API_MASTER_KEY}
CORS_ORIGINS=${CORS_ORIGINS}
GETRECS_ALLOWED_FIELDS=${GETRECS_ALLOWED_FIELDS}
EOF_ENV
  chown root:"${APP_GROUP}" /etc/fastmongo/fastmongo.env
  chmod 0640 /etc/fastmongo/fastmongo.env
}

write_systemd_service() {
  cat >/etc/systemd/system/fastmongo-api.service <<EOF_SERVICE
[Unit]
Description=fastMongo FastAPI service
After=network-online.target ${MONGOD_SERVICE}.service
Wants=network-online.target
Requires=${MONGOD_SERVICE}.service

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${APP_DIR}
EnvironmentFile=/etc/fastmongo/fastmongo.env
ExecStart=${APP_DIR}/.venv/bin/uvicorn main:app --host ${API_BIND_HOST} --port ${API_BIND_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  systemctl daemon-reload
  systemctl enable fastmongo-api
  systemctl restart fastmongo-api

  # Confirm the service actually came up.
  sleep 2
  if ! systemctl is-active --quiet fastmongo-api; then
    echo "fastmongo-api failed to start:"
    systemctl status fastmongo-api --no-pager || true
    exit 1
  fi
}

print_summary() {
  echo
  echo "Deployment complete."
  echo "Version key: ${VERSION_KEY_NAME}"
  echo "fastMongo API service: systemctl status fastmongo-api"
  echo "MongoDB service:       systemctl status ${MONGOD_SERVICE}"
  echo
  echo "Runtime configuration: /etc/fastmongo/fastmongo.env"
  echo "  (contains API keys, JWT secret, and DB credentials — readable by root and the fastmongo group)"
  echo
  echo "Installed source: xDecisionSystems/fastMongo@main (latest)"
  echo "API expected on: http://${API_BIND_HOST}:${API_BIND_PORT}"
}

echo "Version key: ${VERSION_KEY_NAME}"
step "Downloading source files"
download_source_archive
step "Installing required packages"
install_system_packages
step "Installing MongoDB"
install_mongodb
step "Preparing application files"
prepare_app_user_and_code
cleanup_source_archive
step "Installing Python dependencies"
install_python_deps
step "Configuring MongoDB"
configure_mongodb
step "Writing runtime environment"
write_fastmongo_env
step "Creating and starting service"
write_systemd_service
print_summary
