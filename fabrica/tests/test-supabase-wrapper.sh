#!/usr/bin/env bash
# tests/test-supabase-wrapper.sh — arnés AUTÓNOMO del envoltorio (talent-factory#41).
# Autónomo a propósito: el extracto que llegó de M2 usaba $TMP sin definirlo y,
# corrido tal cual, escribía en la RAÍZ del sistema. Éste se ejecuta solo:
#   bash tests/test-supabase-wrapper.sh [ruta-al-envoltorio]
# Sin Docker, sin red: el binario real va doblado.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WRAP="${1:-$(dirname "$HERE")/scripts/lib/wrapper/supabase}"
[ -x "$WRAP" ] || { echo "NO MEDIDO: no encuentro el envoltorio en $WRAP" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
ko(){ FAIL=$((FAIL+1)); echo "  ✗ $1" >&2; }

# ── doble del binario real: guionizado por caso mediante ficheros de control en $D
mkdoble(){ # <dir> <script-de-comportamiento>
  cat > "$1/supabase" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$1/calls"
$2
EOF
  chmod +x "$1/supabase"
}
run(){ # <dir> <args...> -> imprime rc
  local d="$1"; shift
  ( cd "$d" && TA_SUPABASE_BIN="$d/supabase" LG_GATE_MARKER_DIR="$d" LG_RUN_GROUP=rgX LG_SHA=shaY \
      bash "$WRAP" "$@" >/dev/null 2>&1; echo $? )
}
# `jq -c`, no `-r`: con -r un array sale MULTILINEA y la comparacion con "[1,0]" falla aunque el
# valor sea correcto. Rompia mi instrumento, no el envoltorio.
campo(){ jq -c "$2 // \"AUSENTE\"" "$1/db-reset-retry.json" 2>/dev/null | tr -d '"' || echo AUSENTE; }
llamadas(){ [ -f "$1/calls" ] && wc -l < "$1/calls" | tr -d ' ' || echo 0; }

echo "== enrutado: par adyacente, no subcadena =="
for c in "functions invoke demo --body|db reset|PASO" ; do :; done
caso_ruta(){ # <etiqueta> <esperado RUTA|PASO> <args...>
  local et="$1" esp="$2"; shift 2
  local d="$TMP/r$RANDOM$RANDOM"; mkdir -p "$d"; mkdoble "$d" 'exit 0'
  run "$d" "$@" >/dev/null
  local got=PASO; [ -f "$d/db-reset-retry.json" ] && got=RUTA
  [ "$got" = "$esp" ] && ok "$et → $got" || ko "$et → $got (esperado $esp)"
}
caso_ruta "db reset --local"                       RUTA db reset --local
caso_ruta "--workdir /tmp db reset (flag c/valor)" RUTA --workdir /tmp db reset
caso_ruta "--flag-desconocido v db reset"          RUTA --flag-desconocido v db reset
caso_ruta "functions invoke demo --body 'db reset'" PASO functions invoke demo --body 'db reset'
caso_ruta "--profile db reset (db es el VALOR)"    PASO --profile db reset
caso_ruta "db status reset (no adyacente)"         PASO db status reset
caso_ruta "status"                                 PASO status

echo "== conducta del reintento =="
d="$TMP/exito"; mkdir -p "$d"; mkdoble "$d" 'exit 0'
rc=$(run "$d" db reset); [ "$rc" = 0 ] && [ "$(campo "$d" .retried)" = 0 ] && [ "$(llamadas "$d")" = 1 ] \
  && ok "éxito a la primera → rc=0 retried=0 llamadas=1" || ko "éxito a la primera → rc=$rc retried=$(campo "$d" .retried) llamadas=$(llamadas "$d")"

d="$TMP/reintento"; mkdir -p "$d"; mkdoble "$d" '
case "$*" in
  "db reset") n=$(grep -c "^db reset$" '"$d"'/calls); [ "$n" -le 1 ] && { echo "error running container"; exit 1; }; exit 0 ;;
  *) exit 0 ;;
esac'
rc=$(run "$d" db reset)
[ "$rc" = 0 ] && [ "$(campo "$d" .retried)" = 1 ] && [ "$(campo "$d" .rc)" = "[1,0]" ] \
  && ok "carrera → UN reintento, rc=[1,0], retried=1" || ko "carrera → rc=$rc retried=$(campo "$d" .retried) rc[]=$(campo "$d" .rc)"

d="$TMP/otrofallo"; mkdir -p "$d"; mkdoble "$d" 'echo "algo distinto"; exit 3'
rc=$(run "$d" db reset)
[ "$rc" = 3 ] && [ "$(campo "$d" .retried)" = 0 ] \
  && ok "fallo ajeno → se propaga tal cual (rc=3), sin reintento" || ko "fallo ajeno → rc=$rc retried=$(campo "$d" .retried)"

d="$TMP/bucle"; mkdir -p "$d"; mkdoble "$d" 'case "$*" in "db reset") echo "error running container"; exit 1;; *) exit 0;; esac'
rc=$(run "$d" db reset)
n=$(grep -c "^db reset$" "$d/calls" 2>/dev/null || echo 0)
[ "$n" = 2 ] && ok "jamás un bucle → exactamente 2 resets" || ko "bucle → $n resets (esperado 2)"

echo "== el stop del reintento DEBE llevar --no-backup =="
d="$TMP/nobackup"; mkdir -p "$d"; mkdoble "$d" '
case "$*" in
  "db reset") n=$(grep -c "^db reset$" '"$d"'/calls); [ "$n" -le 1 ] && { echo "error running container"; exit 1; }; exit 0 ;;
  *) exit 0 ;;
esac'
run "$d" db reset >/dev/null
# Sin el flag, `stop` vuelca backup y el `start` lo restaura: el 2.o intento no parte de un stack
# limpio. Este caso enrojece si alguien lo quita — que es exactamente como se perdió la primera vez.
if grep -qx 'stop --no-backup' "$d/calls"; then ok "el stop lleva --no-backup"
else ko "el stop NO lleva --no-backup (llamadas: $(tr '\n' '|' < "$d/calls"))"; fi
grep -qx 'stop' "$d/calls" && ko "hay un stop DESNUDO, sin --no-backup" || ok "no hay ningún stop desnudo"

echo "== contrato del marcador (arreglos 1 y 2 de M1) =="
d="$TMP/contrato"; mkdir -p "$d"; mkdoble "$d" 'exit 0'; run "$d" db reset >/dev/null
todos=1
for k in .retried .rc .stop_rc .reason .run_group .sha .wrapper_version; do
  jq -e "has(\"${k#.}\")" "$d/db-reset-retry.json" >/dev/null 2>&1 || { ko "falta el campo $k"; todos=0; }
done
[ "$todos" = 1 ] && ok "los SIETE campos del contrato están presentes"
[ "$(campo "$d" .run_group)" = rgX ] && ok "run_group atado a la corrida" || ko "run_group=$(campo "$d" .run_group)"
[ "$(campo "$d" .sha)" = shaY ] && ok "sha atado a la corrida" || ko "sha=$(campo "$d" .sha)"
[ "$(campo "$d" .wrapper_version)" = 2 ] && ok "wrapper_version publicada" || ko "wrapper_version=$(campo "$d" .wrapper_version)"
ls "$d"/db-reset-retry.json.* >/dev/null 2>&1 && ko "quedó un temporal sin renombrar (escritura no atómica)" || ok "escritura atómica: sin temporales residuales"

echo
[ "$FAIL" -eq 0 ] && { echo "TEST-SUPABASE-WRAPPER: TODO OK ($PASS)"; exit 0; } || { echo "TEST-SUPABASE-WRAPPER: $FAIL FALLOS de $((PASS+FAIL))" >&2; exit 1; }
