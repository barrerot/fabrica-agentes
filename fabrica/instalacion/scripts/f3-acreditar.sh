#!/usr/bin/env bash
# Lectura oculta y distribución de tokens antes de iniciar sesiones.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$HERE/../lib-fases.sh"
fases_ejecutar f3-acreditar "$@"
