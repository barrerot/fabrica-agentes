#!/usr/bin/env bash
# Plan, aplicación aprobada y relectura de protección y ajustes.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 "$HERE/proteccion.py" "$@"
