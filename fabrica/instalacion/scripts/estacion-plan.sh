#!/usr/bin/env bash
# Sonda de solo lectura autorizable por sudoers, sin argumentos libres.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$HERE/../lib-fases.sh"
fases_ejecutar estacion-plan "$@"
