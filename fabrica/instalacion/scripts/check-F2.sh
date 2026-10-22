#!/usr/bin/env bash
# Check F2: 0 verde, 1 rojo, 2 precondición. Nunca repara.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$HERE/../lib-fases.sh"
fases_ejecutar check F2 "$@"
