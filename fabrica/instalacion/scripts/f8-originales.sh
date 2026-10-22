#!/usr/bin/env bash
# Consultar originales públicos; la cabecera secreta vive en el escrow.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$HERE/../lib-fases.sh"
fases_ejecutar f8-originales "$@"
