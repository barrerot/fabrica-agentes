#!/usr/bin/env bash
# Entrada de cron-tablas; no interpreta configuración como código.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$HERE/../lib-fases.sh"
fases_ejecutar cron-tablas "$@"
