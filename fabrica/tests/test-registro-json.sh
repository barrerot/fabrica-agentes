#!/usr/bin/env bash
# Función real del agregador: documento único y predicado de cobertura conservado.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG_FORM_MISS=''
eval "$(sed -n '/^reg_form_ok() {/,/^}/p' "$ROOT/scripts/post-local-gates.sh")"
pass=0; fail=0
check_rc() {
  local esperado=$1 contenido=$2 familias=$3 rc=0
  reg_form_ok "$contenido" "$familias" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "$esperado" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL registro rc=%s esperado=%s\n' "$rc" "$esperado"; fi
}
valido='{"families":{"unit":{"shards":[{"id":"abc","specs":["test"]}]}}}'
check_rc 0 "$valido" unit
for contenido in "$valido $valido" '[]' '' 'texto'; do check_rc 1 "$contenido" unit; done
check_rc 2 "$valido" ausente
[ "$REG_FORM_MISS" = ausente ] || fail=$((fail+1))
check_rc 1 '{"families":{}}' unit
check_rc 1 '{"families":{"unit":{"shards":[]}}}' unit
check_rc 1 '{"families":{"unit":{"shards":[{"id":"abc","specs":[]}]}}}' unit
check_rc 1 '{"families":{"unit":{"shards":[{"id":"abc","specs":["a"]},{"id":"abc","specs":["b"]}]}}}' unit
printf 'RESULTADO registro JSON: PASS=%s FAIL=%s TOTAL=10\n' "$pass" "$fail"
[ "$fail" = 0 ] && [ "$pass" = 10 ]
