#!/usr/bin/env bash
# --respuestas RUTA --salida RUTA --home RUTA [--solo-env] [--forzar].
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/lib-instalacion.sh"
instalacion_main generar "$@"
