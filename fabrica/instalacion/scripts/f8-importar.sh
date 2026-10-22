#!/usr/bin/env bash
# Recibir únicamente evidencia regular bajo el estado privado del instalador.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 "$HERE/importar-evidencias.py" "$@"
