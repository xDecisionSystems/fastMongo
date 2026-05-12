#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Running Python syntax checks..."
python3 -m py_compile "${ROOT_DIR}/main.py"
echo "Syntax checks passed."
