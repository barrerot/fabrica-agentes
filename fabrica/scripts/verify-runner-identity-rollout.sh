#!/usr/bin/env bash
# verify-runner-identity-rollout.sh — preflight de rollout del mapa de identidad (TAL-5196 E1).
#
# Corre esto con la lista VIGENTE de runners de flota ANTES de activar en producción el
# parser fail-closed de scripts/lib/runner-identity.sh: resuelve CADA spec contra el mapa
# (manifiestos/runner-identity.map o TF_RUNNER_IDENTITY_MAP) sin tocar red/incus/ssh — solo
# identidad. Si alguno no resuelve, dice cuál y sale 1 ANTES de que un despacho real muera a
# mitad de operación. Uso:
#   bash scripts/verify-runner-identity-rollout.sh <TF_STATION_HOST> <spec...>
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/runner-identity.sh
. "$SELF_DIR/lib/runner-identity.sh"

[ $# -ge 2 ] || { echo "uso: $0 <TF_STATION_HOST> <spec...>" >&2; exit 2; }
STATION="$1"; shift
# [TAL-8037] Sin manifiesto por defecto de casa: el de la instancia (junto a él vive el mapa de identidad de runners).
MAN="${TF_MANIFEST:?verify-runner-identity-rollout.sh: TF_MANIFEST sin definir (manifiesto de la fábrica de la instancia; sin default de casa)}"

ri_load_map "$MAN"
[ -n "${RI_ALIAS_TO_HOST[$STATION]:-}" ] || {
  echo "✗ TF_STATION_HOST '$STATION' no resuelve en el mapa de identidad" >&2
  exit 1
}
if ! sentinel_err="$(ri_require_real_host "$STATION" "${RI_ALIAS_TO_HOST[$STATION]}" 2>&1)"; then
  echo "✗ $sentinel_err" >&2
  exit 1
fi

fail=0
for spec in "$@"; do
  if pair="$(ri_resolve_spec "$spec" "$STATION" 2>&1)"; then
    tuple="${pair%%$'\t'*}"
    echo "✓ $spec -> $tuple"
  else
    echo "✗ $spec: $pair" >&2
    fail=1
  fi
done

[ "$fail" -eq 0 ] && echo "=== ROLLOUT OK: todas las entradas resuelven ===" \
  || { echo "=== ROLLOUT FALLIDO: añade los alias que faltan en runner-identity.map antes de activar fail-closed ===" >&2; exit 1; }
