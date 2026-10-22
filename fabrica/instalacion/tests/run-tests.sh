#!/usr/bin/env bash
# Suite aislada con datos sintéticos, sin servicios externos.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$DIR/pruebas.py"
python3 "$DIR/linear_api.py"
python3 "$DIR/f8-secuencia.py"
