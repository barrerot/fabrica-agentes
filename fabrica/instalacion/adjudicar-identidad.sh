#!/usr/bin/env bash
# --salida RUTA --home RUTA --destino CLON [--approved FRAGMENTO] [--sustituir MIEMBRO] (repetible) [--sustituir-todos].
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/lib-instalacion.sh"
instalacion_main adjudicar "$@"
