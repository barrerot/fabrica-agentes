#!/usr/bin/env bash
# Conservar un artefacto real y calcular su recibo.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$HERE/../lib-fases.sh"
fases_ejecutar f8-recibo "$@"
