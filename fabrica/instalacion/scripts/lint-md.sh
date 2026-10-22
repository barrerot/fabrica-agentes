#!/usr/bin/env bash
# Entrada de lint-md; propaga códigos y diagnósticos.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$HERE/../lib-fases.sh"
if [ "$#" = 0 ]; then
  set -- "$HERE/../../CLAUDE.md" "$HERE/../../EMPIEZA-AQUI.md" "$HERE"/../fases/*.md
fi
fases_ejecutar lint-md "$@"
