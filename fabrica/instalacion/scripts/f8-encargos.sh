#!/usr/bin/env bash
# Imprimir el encargo con la identidad pública del montaje.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$HERE/../lib-fases.sh"
fases_ejecutar f8-encargos "$@"
