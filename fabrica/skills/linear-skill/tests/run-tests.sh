#!/usr/bin/env bash
# Paridad completa y rechazo de entradas no documentales en los tres ficheros.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL '; printf '%q ' "$@"; echo; fi; }
cp -a "$ROOT" "$T/skill"
check bash "$T/skill/scripts/check-taxonomy-parity.sh"
for nombre in label-taxonomy.json talent-engine-config.json label-taxonomy.receipt.json; do
  f="$T/skill/examples/$nombre"
  cp "$f" "$T/original"
  for kind in varios lista vacio texto; do
    case "$kind" in
      varios) cat "$T/original" "$T/original" ;;
      lista) printf '[]' ;;
      vacio) : ;;
      texto) printf 'texto' ;;
    esac > "$f"
    rc=0; bash "$T/skill/scripts/check-taxonomy-parity.sh" > "$T/out" 2>&1 || rc=$?
    check test "$rc" = 2
  done
  cp "$T/original" "$f"
done
echo "RESULTADO: PASS=$pass FAIL=$fail SKIP=0 TOTAL=13"
[ "$fail" = 0 ] && [ "$pass" = 13 ]
