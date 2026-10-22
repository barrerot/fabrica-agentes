#!/usr/bin/env bash
# check-bash-syntax.sh — bash -n sobre TODO el shell del repo (TAL-4954/r3, gate 'syntax' de
# draft-handoff.sh vía manifiestos/talent-factory.conf). Este manifiesto autoriza TODO push
# futuro del motor: el inventario debe ser recursivo y sin puntos ciegos (ver lib/inventory.sh).
# Fail-closed: fallo de inventario (find/sort/mktemp/mapfile) ⇒ exit 2; inventario
# LEGÍTIMAMENTE vacío (0 ficheros) ⇒ exit 2 también. Nunca "0 ficheros, todo verde" en silencio.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT" || exit 2
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib/inventory.sh
. "$SELF_DIR/lib/inventory.sh" || { echo "no pude cargar lib/inventory.sh" >&2; exit 2; }

motor_inventory_files || exit 2
[ ${#MOTOR_INVENTORY[@]} -gt 0 ] || { echo "[check-bash-syntax] inventario VACÍO (0 ficheros bajo scripts/githooks/tests/skills) — fail-closed" >&2; exit 2; }

rc=0
for f in "${MOTOR_INVENTORY[@]}"; do
  if bash -n "$f" 2>&1; then
    echo "  ✓ bash -n $f"
  else
    echo "  ✗ bash -n $f" >&2
    rc=1
  fi
done
echo "[check-bash-syntax] ${#MOTOR_INVENTORY[@]} ficheros revisados"
exit "$rc"
