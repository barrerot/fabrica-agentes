#!/usr/bin/env bash
# Conservar los registros del skill bajo la identidad del coordinador.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 "$HERE/conservar.py" "$@"
