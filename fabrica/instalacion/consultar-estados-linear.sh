#!/usr/bin/env bash
# --equipo CLAVE [--fixture JSON] [--token-nombre VARIABLE] [--out JSON].
# El token se recibe solo desde el entorno, por nombre; nunca por argumento.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/lib-instalacion.sh"
instalacion_main linear "$@"
