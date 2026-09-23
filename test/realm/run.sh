#!/usr/bin/env bash
# Runs the realm content tests. Requires helm and python3 with PyYAML.
set -euo pipefail
cd "$(dirname "$0")"
exec python3 -m unittest discover -s . -p 'test_*.py' "$@"
