#!/usr/bin/env bash
# Entrada de verificar-nucleo; propaga códigos y diagnósticos.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$HERE/../lib-fases.sh"
fases_ejecutar verificar-nucleo "$@"
