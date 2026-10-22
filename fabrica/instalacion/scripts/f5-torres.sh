#!/usr/bin/env bash
# Entrada de f5-torres; propaga códigos y diagnósticos.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$HERE/../lib-fases.sh"
fases_ejecutar f5-torres "$@"
