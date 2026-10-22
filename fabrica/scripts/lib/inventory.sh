#!/usr/bin/env bash
# lib/inventory.sh — inventario RECURSIVO, DETERMINISTA y FAIL-CLOSED del shell del motor
# (TAL-4954/r3), compartido por check-bash-syntax.sh y check-shellcheck.sh (ambos autorizan
# TODO push futuro del motor vía draft-handoff.sh — deben coincidir EXACTAMENTE en qué cubren,
# de un solo sitio).
#
# Alcance: scripts/**/*.sh a CUALQUIER profundidad (incl. scripts/github/, scripts/lib/, y
# subdirs futuros), githooks/pre-push, tests/**/*.sh (SOLO estático — la ejecución funcional de
# tests/run-tests.sh queda fuera de draft-handoff por el FAIL=1 pre-existente TAL-3854, que no
# afecta a bash -n/shellcheck sobre el propio fichero), skills/**/*.sh (el paquete de 16 skills
# es TAMBIÉN código del motor que un push puede romper — sin carve-out de árbol completo).
#
# motor_inventory_files() — llena el array global MOTOR_INVENTORY. Seguro ante espacios/saltos
# de línea en nombres de fichero (find -print0 + sort -z + mapfile -d ''). Debe invocarse con
# CWD ya en la raíz del repo (git rev-parse --show-toplevel + cd, responsabilidad del llamador).
#
# FAIL-CLOSED (r3): el rc de `find | sort` se CAPTURA explícitamente (materializado a un
# temporal bajo `set -o pipefail` en subshell — el rc de una tubería sin pipefail es el del
# ÚLTIMO comando, `sort`, que puede salir 0 aunque `find` haya fallado a mitad con un árbol
# requerido ausente o un error de permisos, dejando un inventario PARCIAL no-vacío que ambos
# gates tratarían como éxito). stderr de `find` YA NO se descarta: un árbol ausente o un error
# de permisos debe ser visible, no silencioso. Devuelve 0 en éxito (MOTOR_INVENTORY puede seguir
# legítimamente vacío — eso lo decide el LLAMADOR) y ≠0 ante CUALQUIER fallo de find/sort/mktemp/
# mapfile. El llamador SIEMPRE debe hacer `motor_inventory_files || exit 2`.
motor_inventory_files() {
  MOTOR_INVENTORY=()
  local tmp rc dirs=(scripts githooks tests skills)
  [ ! -d instalacion ] || dirs+=(instalacion)
  tmp="$(mktemp)" || { echo "[inventory] mktemp falló — fail-closed" >&2; return 2; }
  (
    set -o pipefail
    find "${dirs[@]}" -type f \
      \( -name '*.sh' -o -path 'githooks/pre-push' \) \
      -print0 | sort -z > "$tmp"
  )
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    echo "[inventory] find/sort del inventario falló (rc=$rc) — árbol requerido ausente, permiso denegado, u otro fallo — fail-closed" >&2
    return 2
  fi
  mapfile -d '' MOTOR_INVENTORY < "$tmp" || { rm -f "$tmp"; echo "[inventory] mapfile falló al leer el inventario — fail-closed" >&2; return 2; }
  rm -f "$tmp"
  return 0
}
