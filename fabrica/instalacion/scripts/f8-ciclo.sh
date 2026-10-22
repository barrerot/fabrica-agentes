#!/usr/bin/env bash
# Armar el índice de siete etapas presentes con sus hashes definitivos.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$HERE/../lib-fases.sh"
fases_ejecutar f8-ciclo "$@"
