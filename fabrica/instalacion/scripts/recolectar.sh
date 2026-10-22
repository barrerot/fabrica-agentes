#!/usr/bin/env bash
# Recolección mecánica de solo lectura; únicamente escribe el informe privado.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$HERE/../lib-fases.sh"
# shellcheck source=/dev/null
. "$FASES_RAIZ/scripts/lib/redact.sh"
case "${1:-}" in F[0-8]) ;; *) echo 'precondición uso recolectar.sh F0..F8' >&2; exit 2 ;; esac
[ "$#" -eq 1 ] || exit 2
umask 077
dest="$FASES_RAIZ/instalacion/estado/recoleccion-$1.txt"
[ -d "$(dirname "$dest")" ] && [ ! -L "$dest" ] || exit 2
{
  printf 'fase=%s\n' "$1"
  fases_ejecutar estado verificar || printf 'estado_rc=%s\n' "$?"
  fases_ejecutar inventario || printf 'inventario_rc=%s\n' "$?"
  git -C "$FASES_RAIZ" status --short 2>/dev/null || printf 'git=ausente\n'
  for pieza in NUCLEO.sha256 estado/fases.tsv estado/contexto.conf; do
    if [ -f "$FASES_RAIZ/instalacion/$pieza" ]; then
      printf 'pieza=%s present\n' "$pieza"
    else
      printf 'pieza=%s missing\n' "$pieza"
    fi
  done
} | lg_redact > "$dest"
chmod 600 "$dest"
printf '%s\n' "$dest"
