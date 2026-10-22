#!/usr/bin/env bash
# Clasifica capturas usando el parser real instalado; no registra versiones automáticamente.
set -uo pipefail
[ "$#" -eq 2 ] || { [ "$#" -eq 3 ] && [ "$3" = --registrar ]; } || { echo 'precondición calibrar-pane CLON DIRECTORIO [--registrar]' >&2; exit 2; }
lib="$1/.claude/skills/talent-channel-operation/scripts/lib.sh"
[ -f "$lib" ] && [ ! -L "$lib" ] || { echo "falla parser ausente: $lib" >&2; exit 1; }
# shellcheck source=/dev/null
. "$lib" || { echo "falla carga del parser: $lib" >&2; exit 1; }
for estado in idle busy 'done' modal redraw; do
  fichero="$2/$estado.txt"
  [ -s "$fichero" ] && [ ! -L "$fichero" ] || { echo "falla captura ausente: $estado" >&2; exit 1; }
  tco_fixture_secret_scan < "$fichero" >/dev/null 2>&1 || { echo "falla captura rechazada: $estado" >&2; exit 1; }
  rc=0
  tco_pane_busy_from < "$fichero" >/dev/null 2>&1 || rc=$?
  case "$estado" in idle|done) esperado=1 ;; busy) esperado=0 ;; *) esperado=2 ;; esac
  [ "$rc" -eq "$esperado" ] || { echo "falla clasificación: $estado rc=$rc esperado=$esperado" >&2; exit 1; }
done
echo 'capturas clasificadas'
if [ "${3:-}" = --registrar ]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  python3 "$HERE/calibracion.py" "$2"
fi
