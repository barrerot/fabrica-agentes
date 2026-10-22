#!/usr/bin/env bash
# Entrada de f2-provision; propaga códigos y diagnósticos.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$HERE/../lib-fases.sh"
fases_ejecutar f2-provision "$@"
