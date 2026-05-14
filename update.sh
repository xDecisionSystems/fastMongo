#!/usr/bin/env bash
set -euo pipefail

VERSION_NAME="${VERSION_NAME:-unknown}"

APP_DIR="/opt/fastmongo"
APP_USER="fastmongo"
APP_GROUP="fastmongo"
BASE_URL="https://raw.githubusercontent.com/xDecisionSystems/fastMongo/main"
STAGING_DIR=""

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root."
  exit 1
fi

cleanup() {
  [[ -n "${STAGING_DIR}" && -d "${STAGING_DIR}" ]] && rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

# Fetch all files into a staging dir first so nothing is changed until confirmed.
STAGING_DIR="$(mktemp -d /tmp/fastmongo-update.XXXXXX)"

fetch_to_staging() {
  local name="$1"
  wget -qO "${STAGING_DIR}/${name}" "${BASE_URL}/${name}"
}

echo "Fetching latest files..."
fetch_to_staging "main.py"
fetch_to_staging "deploy_fastmongo_lxc.sh"
fetch_to_staging "update.sh"

# Extract the incoming version name from the new main.py.
NEW_VERSION="$(grep -m1 '^VERSION_NAME\s*=' "${STAGING_DIR}/main.py" | sed 's/.*=\s*["\x27]\(.*\)["\x27]/\1/')"

if [[ "${VERSION_NAME}" == "${NEW_VERSION}" ]]; then
  echo "Current version : ${VERSION_NAME}"
  echo "Incoming version: ${NEW_VERSION}"
  echo "Already up to date. No update needed."
  exit 0
fi

echo ""
echo "Current version : ${VERSION_NAME}"
echo "Incoming version: ${NEW_VERSION}"
echo ""
read -r -p "Apply update from '${VERSION_NAME}' to '${NEW_VERSION}'? [Y/n] " confirm </dev/tty
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
install_file "deploy_fastmongo_lxc.sh"  "root:root"                "0700"
install_file "update.sh"                "root:root"                "0700"

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
