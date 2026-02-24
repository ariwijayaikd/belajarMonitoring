#!/usr/bin/env bash
set -euo pipefail
python3 ./generate-targets.py
curl -s -X POST http://localhost:9090/-/reload >/dev/null || true