#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${PMCA_BUILD_PYTHON:-python3}"
cd "$ROOT"
"$PYTHON" -m PyInstaller --noconfirm --clean \
  --distpath "$ROOT/Engine/Runtime" --workpath "$ROOT/Engine/.build" \
  "$ROOT/Engine/engine.spec"
"$ROOT/Engine/Runtime/PMCAEngine.app/Contents/MacOS/pmca-engine" --self-test
