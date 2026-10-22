#!/usr/bin/env bash
# Instalación del mismo artefacto verificado que la plantilla.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$HERE/../lib-fases.sh"
fases_ejecutar f3-coderabbit "$@"
