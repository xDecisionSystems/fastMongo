#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/fastmongo"
APP_USER="fastmongo"
APP_GROUP="fastmongo"
BASE_URL="https://raw.githubusercontent.com/xDecisionSystems/fastMongo/main"
STAGING_DIR=""

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root."
  exit 1
fi

if ! systemctl cat fastmongo-api &>/dev/null; then
  echo "fastmongo-api service does not exist. Run deploy_fastmongo_lxc.sh first."
  exit 1
fi

cleanup() {
  [[ -n "${STAGING_DIR}" && -d "${STAGING_DIR}" ]] && rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

# Detect the currently installed version from the live file.
CURRENT_VERSION="unknown"
if [[ -f "${APP_DIR}/main.py" ]]; then
  CURRENT_VERSION="$(grep -m1 '^VERSION_NAME\s*=' "${APP_DIR}/main.py" | sed 's/.*=\s*["\x27]\(.*\)["\x27]/\1/')"
fi

# Fetch all files into a staging dir first so nothing is changed until confirmed.
STAGING_DIR="$(mktemp -d /tmp/fastmongo-update.XXXXXX)"

fetch_to_staging() {
  local name="$1"
  wget -qO "${STAGING_DIR}/${name}" "${BASE_URL}/${name}"
}

echo "Fetching latest files..."
fetch_to_staging "main.py"
fetch_to_staging "requirements.txt"
fetch_to_staging "deploy_fastmongo_lxc.sh"
fetch_to_staging "update.sh"

# Extract the incoming version name from the new main.py.
NEW_VERSION="$(grep -m1 '^VERSION_NAME\s*=' "${STAGING_DIR}/main.py" | sed 's/.*=\s*["\x27]\(.*\)["\x27]/\1/')"

if [[ "${CURRENT_VERSION}" == "${NEW_VERSION}" ]]; then
  echo "Current version : ${CURRENT_VERSION}"
  echo "Incoming version: ${NEW_VERSION}"
  echo "Already up to date. No update needed."
  exit 0
fi

echo ""
echo "Current version : ${CURRENT_VERSION}"
echo "Incoming version: ${NEW_VERSION}"
echo ""
read -r -p "Apply update from '${CURRENT_VERSION}' to '${NEW_VERSION}'? [Y/n] " confirm </dev/tty
if [[ "${confirm}" =~ ^[Nn]$ ]]; then
  echo "Update cancelled."
  exit 0
fi

install_file() {
  local name="$1" owner="$2" mode="$3"
  chown "${owner}" "${STAGING_DIR}/${name}"
  chmod "${mode}" "${STAGING_DIR}/${name}"
  mv "${STAGING_DIR}/${name}" "${APP_DIR}/${name}"
}

install_file "main.py"                  "${APP_USER}:${APP_GROUP}" "0644"
install_file "requirements.txt"         "${APP_USER}:${APP_GROUP}" "0644"
install_file "deploy_fastmongo_lxc.sh"  "root:root"                "0700"
install_file "update.sh"                "root:root"                "0700"

echo "Installing dependencies..."
"${APP_DIR}/.venv/bin/pip" install -q -r "${APP_DIR}/requirements.txt"

# Ensure the service unit points at the correct ASGI entrypoint.
if grep -q 'main:app\b' /etc/systemd/system/fastmongo-api.service; then
  sed -i 's|main:app\b|main:cors_app|g' /etc/systemd/system/fastmongo-api.service
  systemctl daemon-reload
  echo "Updated service unit to main:cors_app."
fi

echo "Updated to version: ${NEW_VERSION}"
echo "Restarting fastmongo-api..."
systemctl restart fastmongo-api

sleep 2
if systemctl is-active --quiet fastmongo-api; then
  echo "fastmongo-api restarted successfully."
else
  echo "fastmongo-api failed to start after update:"
  systemctl status fastmongo-api --no-pager || true
  exit 1
fi
