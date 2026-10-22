#!/usr/bin/env bash
# check-shellcheck.sh — shellcheck -S error sobre TODO el shell del repo (TAL-4954/r3, gate
# 'shellcheck' de draft-handoff.sh). Mismo inventario que check-bash-syntax.sh (lib/inventory.sh)
# — este manifiesto autoriza TODO push futuro del motor: sin exclusiones de árbol completo.
#
# ÚNICO carve-out: skills/talent-channel-operation/tests/run-tests.sh — 3 hallazgos SC2218
# PRE-EXISTENTES (líneas 1521/1554/1557; hallados al onboardear TAL-4954, 2026-08-30), ajenos a
# TAL-4946/4954, dueño y ciclo de vida propios (skill talent-channel-operation; seguimiento
# aparte). Es un carve-out ESTRECHO de UN fichero — NO de skills/** ni de tests/** — y el gate
# 'syntax' (bash -n) SÍ lo cubre igualmente. Sin baseline jq/JSON: shellcheck corre DIRECTO sobre
# el resto del inventario y su rc se propaga tal cual (0=verde sin hallazgos, 1=hallazgo real,
# cualquier otro rc=fallo operacional del propio shellcheck) — así cualquier error NUEVO en
# CUALQUIER OTRO fichero (incl. el resto de skills/**) bloquea el sentinel sin ambigüedad.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT" || exit 2
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib/inventory.sh
. "$SELF_DIR/lib/inventory.sh" || { echo "no pude cargar lib/inventory.sh" >&2; exit 2; }

command -v shellcheck >/dev/null 2>&1 || { echo "[check-shellcheck] shellcheck no disponible en este host" >&2; exit 2; }

motor_inventory_files || exit 2
[ ${#MOTOR_INVENTORY[@]} -gt 0 ] || { echo "[check-shellcheck] inventario VACÍO (0 ficheros bajo scripts/githooks/tests/skills) — fail-closed" >&2; exit 2; }

CARVEOUT_SC2218="skills/talent-channel-operation/tests/run-tests.sh"
files=()
for f in "${MOTOR_INVENTORY[@]}"; do
  [ "$f" = "$CARVEOUT_SC2218" ] && continue
  files+=("$f")
done
[ ${#files[@]} -gt 0 ] || { echo "[check-shellcheck] inventario VACÍO tras el carve-out — fail-closed" >&2; exit 2; }

echo "[check-shellcheck] revisando ${#files[@]}/${#MOTOR_INVENTORY[@]} ficheros (carve-out: $CARVEOUT_SC2218 — 3× SC2218 pre-existente, TAL-4954)"
shellcheck -S error "${files[@]}"
