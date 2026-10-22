#!/usr/bin/env bash
# Ejecuta la batería de distribución y conserva su recibo privado.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$HERE/../lib-fases.sh"
fases_ejecutar f0-bateria "$@"
