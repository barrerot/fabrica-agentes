#!/usr/bin/env bash
# Solo el token de Claude pasa al CLI; las claves operacionales permanecen en su fichero privado.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$HERE/../lib-fases.sh"
fases_ejecutar iniciar-actor "$@"
