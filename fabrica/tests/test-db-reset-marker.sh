#!/usr/bin/env bash
# tests/test-db-reset-marker.sh — self-test de TAL-5352: los TRES estados del marcador
# del gate (null = NO MEDIDO / 0 = sin reintento / 1 = reintentado). Uso:
#   bash tests/test-db-reset-marker.sh scripts/run-local-gates.sh
# Lo EJECUTA tests/run-tests.sh: un test que nadie corre no es una prueba, es un fichero.
# Self-test de TAL-5352: los tres estados del marcador.
set -u
SCRIPT_UNDER_TEST="$1"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAIL=0
# extrae el bloque lector del script real y lo evalúa con RUN_DIR controlado
extract() { sed -n '/Marcador del gate (TAL-5352)/,/^fi$/p' "$SCRIPT_UNDER_TEST"; }
run_case() {
  local name="$1" content="$2" exp_ret="$3" exp_rc="$4"
  local dir="$TMP/$name"; mkdir -p "$dir"
  [ "$content" != "__NONE__" ] && printf '%s' "$content" > "$dir/db-reset-retry.json"
  local out
  out=$(RUN_DIR="$dir"; eval "$(extract)"; echo "$DB_RESET_RETRIED|$DB_RESET_RC|$DB_RESET_REASON" 2>/dev/null)
  local got_ret="${out%%|*}" resto="${out#*|}"; local got_rc="${resto%%|*}" got_reason="${resto##*|}"
  if [ -n "${5:-}" ] && [ "$got_reason" != "$5" ]; then
    echo "  ✗ $name → reason=$got_reason (esperado $5)"; FAIL=1; return
  fi
  if [ "$got_ret" = "$exp_ret" ] && [ "$got_rc" = "$exp_rc" ]; then
    echo "  ✓ $name → retried=$got_ret rc=$got_rc"
  else
    echo "  ✗ $name → retried=$got_ret rc=$got_rc (esperado $exp_ret / $exp_rc)"; FAIL=1
  fi
}
echo "== mutantes del marcador =="
run_case "sin-marcador"      "__NONE__"                          "null"  "null"
run_case "retried-1"         '{"retried":1,"rc":[1,0]}'          "1"     "[1,0]"
run_case "retried-0"         '{"retried":0,"rc":[0]}'            "0"     "[0]"
run_case "json-invalido"     '{esto no es json'                  "null"  "null"
run_case "campo-ausente"     '{"rc":[0]}'                        "null"  "null"
run_case "tipo-erroneo"      '{"retried":"si","rc":[0]}'         "null"  "null"
run_case "rc-no-array"       '{"retried":1,"rc":0}'              "null"  "null"
# el mutante que da nombre a la revisión — «reintento que NUNCA se ejecuta». El único intento
# falló y no hubo segundo. Debe leerse tal cual: 0 no es null, y un fallo sin reintento no es un
# reintento fallido.
run_case "reintento-que-nunca-se-ejecuta" '{"retried":0,"rc":[1]}'   "0"    "[1]"
# el contrato promete UN reintento como máximo ⇒ un 2 o un 7 no es un dato exótico, es un
# marcador fuera de contrato. Fail-closed: NO MEDIDO, no se publica tal cual.
run_case "retried-7-fuera-contrato"  '{"retried":7,"rc":[]}'         "null" "null"
run_case "retried-2-fuera-contrato"  '{"retried":2,"rc":[1,1]}'      "null" "null"
# `reason` es el ÚNICO campo que dice POR QUÉ se reintentó. Se lee APARTE a propósito: un
# marcador de un gate viejo, sin reason, NO debe invalidar el retried que sí es válido.
run_case "reason-se-publica"     '{"retried":1,"rc":[1,0],"stop_rc":0,"reason":"confirmed"}' "1" "[1,0]" '"confirmed"'
run_case "reason-ausente-no-tumba-retried" '{"retried":1,"rc":[1,0]}' "1"   "[1,0]" "null"
run_case "reason-vacio-es-null"  '{"retried":1,"rc":[1,0],"reason":""}'     "1"   "[1,0]" "null"
[ "$FAIL" -eq 0 ] && echo "TEST-A2: TODO OK" || { echo "TEST-A2: FALLOS" >&2; exit 1; }
