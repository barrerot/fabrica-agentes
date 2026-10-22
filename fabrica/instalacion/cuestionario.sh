#!/usr/bin/env bash
# siguiente | registrar ID VALOR | revisar; --respuestas RUTA en cualquier posición.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/lib-instalacion.sh"
instalacion_main cuestionario "$@"
