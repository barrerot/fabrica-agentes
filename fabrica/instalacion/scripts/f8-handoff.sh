#!/usr/bin/env bash
# Conservar la verificación del PR en borrador antes de que M1 lo fusione.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$HERE/../lib-fases.sh"
fases_ejecutar f8-handoff "$@"
