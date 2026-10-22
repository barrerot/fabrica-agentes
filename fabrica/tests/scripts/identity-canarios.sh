#!/usr/bin/env bash
# identity-canarios.sh — fixture de scripts/lib/compose-identity.sh (TAL-5383 · A2).
#
# Cubre, con comprobacion ejecutable (no solo prosa), el contrato de identidad del
# plan-gate: cero-cierres bajo `set -uo pipefail` (rc=0, no rc=1 del pipeline), extraccion
# case-insensitive normalizada y deduplicada, propagacion de un fallo REAL del extractor
# (via shim de `grep` por PATH que solo intercepta la invocacion exacta de la funcion — no
# una inyeccion de patron que la funcion no admite), `jq -er` sin comillas en el dominio, y
# `identity_mismo_dominio` sin fail-open cuando ambos operandos estan vacios.
#
# Uso: identity-canarios.sh   ·   RC=0 todo caza · 1 algun canario se escapa
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${1:-$HERE/../../scripts/lib/compose-identity.sh}"
W=$(mktemp -d); trap 'rm -rf -- "$W"' EXIT
ok=0; ko=0

[ -f "$LIB" ] || { echo "FAIL-CLOSED: no existe la libreria: $LIB"; exit 2; }
# shellcheck source=/dev/null
source "$LIB"
# [TAL-8037/C2] clave del team NEUTRA del arnés (ABC ≠ TAL): la clave es de la instancia, jamás un default de casa.
export TF_LINEAR_TEAM_KEY=ABC

check() { # check <etiqueta> <rc_esperado> <rc_real>
  if [ "$3" -eq "$2" ]; then ok=$((ok+1)); printf 'OK    %-58s RC=%s\n' "$1" "$3"
  else ko=$((ko+1)); printf 'FALLO %-58s RC=%s (esperado %s)\n' "$1" "$3" "$2"; fi
}
check_nonzero() { # check_nonzero <etiqueta> <rc_real> — exige rc!=0 sin fijar un valor concreto
  if [ "$2" -ne 0 ]; then ok=$((ok+1)); printf 'OK    %-58s RC=%s (!=0)\n' "$1" "$2"
  else ko=$((ko+1)); printf 'FALLO %-58s RC=0 (se esperaba !=0)\n' "$1"; fi
}
check_out() { # check_out <etiqueta> <esperado> <real>
  if [ "$3" = "$2" ]; then ok=$((ok+1)); printf 'OK    %-58s out=[%s]\n' "$1" "$3"
  else ko=$((ko+1)); printf 'FALLO %-58s out=[%s] (esperado [%s])\n' "$1" "$3" "$2"; fi
}

echo "=== identity_issues_de_body: cero cierres bajo pipefail -> rc=0, salida vacia ==="
out=$(identity_issues_de_body "PR sin ningun cierre"); rc=$?
check "cero cierres: rc" 0 "$rc"
check_out "cero cierres: salida" "" "$out"

echo
echo "=== identity_issues_de_body: extraccion case-insensitive normalizada + dedupe ==="
out=$(identity_issues_de_body "closes abc-123. Fixes ABC-1 resolves abc-1" | tr '\n' ' ' | sed 's/ $//')
check_out "minusculas + cruce de casos + dedupe" "ABC-1 ABC-123" "$out"

out=$(identity_issues_de_body "Closes #ABC-9" | tr '\n' ' ' | sed 's/ $//')
check_out "cierre con # literal" "ABC-9" "$out"

echo
echo "=== identity_issues_de_body: fallo REAL del extractor se propaga (shim de grep por PATH) ==="
# El shim SOLO intercepta la invocacion exacta que usa la funcion (busca el patron
# closes|fixes|resolves entre los argumentos); cualquier otra invocacion de grep en el
# sistema sigue intacta via el grep real localizado por ruta absoluta ANTES de tocar PATH.
REAL_GREP="$(command -v grep)"
cat > "$W/grep" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    *'(closes|fixes|resolves)'*) echo "grep-shim: fallo operacional simulado" >&2; exit 2 ;;
  esac
done
exec "$REAL_GREP" "\$@"
EOF
chmod +x "$W/grep"
out=$(PATH="$W:$PATH" identity_issues_de_body "closes ABC-1" 2>/dev/null)
rc=$?
check "fallo real: rc propagado (no 0, no engullido por pipefail)" 2 "$rc"
check_out "fallo real: salida vacia (no exito silencioso)" "" "$out"

echo
echo "=== [TAL-8037] clave del team de la INSTANCIA: env -> manifiesto TF_MANIFEST -> fail-closed (jamas TAL) ==="
out=$(identity_issues_de_body "closes TAL-7" | tr '\n' ' '); check_out "clave ABC: 'closes TAL-7' NO cierra nada (mutacion de clave)" "" "$out"
out=$( (unset TF_LINEAR_TEAM_KEY TF_MANIFEST; identity_issues_de_body "closes ABC-7" 2>/dev/null); echo "rc=$?" ); check_out "sin clave (ni env ni manifiesto): rc 2 fail-closed" "rc=2" "$out"
msg=$( (unset TF_LINEAR_TEAM_KEY TF_MANIFEST; identity_issues_de_body "closes ABC-7" 2>&1 >/dev/null) ); case "$msg" in *TF_LINEAR_TEAM_KEY*) m=nombra;; *) m=mudo;; esac; check_out "sin clave: el mensaje NOMBRA TF_LINEAR_TEAM_KEY" "nombra" "$m"
printf 'TF_LINEAR_TEAM_KEY="XYZ"\n' > "$W/m.conf"
out=$( (unset TF_LINEAR_TEAM_KEY; TF_MANIFEST="$W/m.conf" identity_issues_de_body "closes xyz-5" | tr '\n' ' ' | sed 's/ $//') ); check_out "clave desde el manifiesto TF_MANIFEST" "XYZ-5" "$out"
out=$( (TF_LINEAR_TEAM_KEY=abc identity_issues_de_body "closes abc-7" 2>/dev/null); echo "rc=$?" ); check_out "clave invalida (minusculas): rc 2" "rc=2" "$out"
out=$( (TF_LINEAR_TEAM_KEY=$'X2Y\n.*' identity_issues_de_body "closes zzz-1" 2>/dev/null); echo "rc=$?" ); check_out "clave MULTILINEA (acta m1): rc 2, no extrae nada" "rc=2" "$out"

echo
echo "=== identity_dominio_de_issue_json: jq -er sin comillas + rc!=0 en cada caso invalido ==="
out=$(identity_dominio_de_issue_json '{"project":{"name":"Fabrica"}}'); rc=$?
check "dominio valido: rc" 0 "$rc"
check_out "dominio valido: salida SIN comillas" "Fabrica" "$out"

identity_dominio_de_issue_json '{}' >/dev/null 2>&1; check_nonzero "project ausente: rc!=0" "$?"
identity_dominio_de_issue_json '{"project":null}' >/dev/null 2>&1; check_nonzero "project null: rc!=0" "$?"
identity_dominio_de_issue_json '{"project":{"name":null}}' >/dev/null 2>&1; check_nonzero "project.name null: rc!=0" "$?"
identity_dominio_de_issue_json '{"project":{"name":""}}' >/dev/null 2>&1; check_nonzero "project.name vacio: rc!=0" "$?"
identity_dominio_de_issue_json '{"project":{"name":123}}' >/dev/null 2>&1; check_nonzero "project.name no-string: rc!=0" "$?"
identity_dominio_de_issue_json 'esto no es json' >/dev/null 2>&1; check_nonzero "JSON roto: rc!=0" "$?"

echo
echo "=== identity_mismo_dominio: sin fail-open cuando algun operando esta vacio ==="
identity_mismo_dominio "Fabrica" "Fabrica"; check "dos strings iguales no vacios: rc=0 (verdadero)" 0 "$?"
identity_mismo_dominio "Fabrica" "Vibe"; check_nonzero "dos strings distintos: rc!=0 (falso)" "$?"
identity_mismo_dominio "" ""; check_nonzero "AMBOS vacios: rc!=0 (falso, NUNCA mismo dominio)" "$?"
identity_mismo_dominio "Fabrica" ""; check_nonzero "uno vacio: rc!=0 (falso)" "$?"
identity_mismo_dominio "" "Fabrica"; check_nonzero "el otro vacio: rc!=0 (falso)" "$?"

echo
echo "=== fixture realista: tests/fixtures/handoff-canonico.md ==="
FIXTURE="$HERE/../fixtures/handoff-canonico.md"
if [ -f "$FIXTURE" ]; then
  body="$(cat "$FIXTURE")"
  out="$(identity_issues_de_body "$body" | tr '\n' ' ' | sed 's/ $//')"
  check_out "extraccion sobre HANDOFF real (closes/Fixes/resolves mixto)" "ABC-5391 ABC-5392 ABC-5393" "$out"
else
  ko=$((ko+1)); printf 'FALLO %-58s\n' "no existe el fixture: $FIXTURE"
fi

echo
echo "== resumen =="
echo "OK=$ok FALLOS=$ko"
[ "$ko" -eq 0 ] && exit 0 || exit 1
