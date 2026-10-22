#!/usr/bin/env bash
# Compatibilidad del montaje: captura un turno terminado con el capturador real.
set -euo pipefail
[ $# -ge 3 ] && [ $# -le 4 ] || { echo 'uso capturar-done CLON CARRIL PANE [--repetir]' >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec bash "$HERE/f8-capturas.sh" "$1" "$2" "$3" 'done' "${4:-}"
