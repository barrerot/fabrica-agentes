#!/usr/bin/env bash
# tests/test-insumos-por-area.sh — TAL-5462. Self-test del mapa de insumos por ÁREA:
# exclusiones (`TF_NOT_INPUTS_*`), gates declarados como «siempre re-corre» (`TF_ALWAYS_RERUN`)
# y el cruce manifiesto↔mapa que impide que un gate se quede sin clasificar EN SILENCIO.
# Lo EJECUTA tests/run-tests.sh: un test que nadie corre no es una prueba, es un fichero.
#
# Los dos fixtures de churn son DIFFS REALES, no inventados (PRs #2241 y #2255 de academia-ejemplo).
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/insumos-por-gate.sh"
CONF="$REPO_ROOT/scripts/lib/insumos-por-gate.conf"
MANIFIESTO="$REPO_ROOT/manifiestos/ejemplo.conf"
[ -r "$LIB" ]  || { echo "FAIL: no encuentro $LIB"; exit 2; }
[ -r "$CONF" ] || { echo "FAIL: no encuentro $CONF"; exit 2; }

FAIL=0
ok()  { echo "  PASS  $1"; }
bad() { echo "  FAIL  $1" >&2; FAIL=1; }

# shellcheck source=scripts/lib/insumos-por-gate.sh
. "$LIB" || { echo "FAIL: el mapa no carga"; exit 2; }

# afectado <gate> <churn> → rc 0 si el churn CADUCA el gate; rc 1 si lo conserva.
# Réplica exacta del orden del agregador: inclusiones primero, exclusiones después.
afectado() {
  local g="$1" churn="$2" pats excl
  pats="$(insumos_de_gate "$g")" || return 0        # sin mapa ⇒ caduca (fail-closed)
  excl="$(no_insumos_de_gate "$g" || true)"
  [ -n "$excl" ] && churn="$(printf '%s\n' "$churn" | grep -E -v -f <(printf '%s\n' "$excl") || true)"
  printf '%s\n' "$churn" | grep -v '^$' | grep -qE -f <(printf '%s\n' "$pats")
}

# cuenta_caducados <churn> → «caducados conservados» contando los 25 shards e2e como 25.
cuenta_caducados() {
  local churn="$1" g cad=0 con=0
  for g in typecheck lint build i18n flags tenant markdownlint skills-package tests-manifest unit integration db-guards; do
    if afectado "$g" "$churn"; then cad=$((cad+1)); else con=$((con+1)); fi
  done
  if afectado e2e "$churn"; then cad=$((cad+25)); else con=$((con+25)); fi
  echo "$cad $con"
}

# ── FIXTURES: diffs REALES ────────────────────────────────────────────────────────────────────
# #2255 (TAL-5416): toca SÓLO instrumentación de pgTAP. Es el caso que motivó TAL-5462.
CHURN_2255='scripts/ci/run-money-pgtap.sh
supabase/tests/tal4814_extra_canjes_core.sql'
# #2241 (TAL-4506): 28 ficheros, con src/** de por medio. CONTROL NEGATIVO: aquí e2e DEBE caducar.
CHURN_2241='.env.example
docs/runbooks/email-templates.md
scripts/backfill-dosier-delivery.ts
scripts/ci/run-db-guards-local.sh
scripts/data-ops/tal-4849/management-api.ts
src/app/api/commerce/leads/route.ts
src/lib/commerce/dosier-delivery.ts
src/lib/commerce/messaging-templates.ts
src/lib/email/errors.ts
src/lib/supabase/types.ts
supabase/migrations/20271459000000_tal4506_dosier_sender.sql
supabase/tests/tal4506_dosier_sender.sql
tests/integration/commerce/dosier-delivery.test.ts
tests/unit/commerce/dosier-delivery.test.ts'

echo "== TAL-5462: mapa de insumos por área — exclusiones, always-rerun y cruce manifiesto↔mapa =="

# (1) El caso que motiva la issue: sólo pgTAP tocado ⇒ e2e e integration se CONSERVAN.
if ! afectado e2e "$CHURN_2255" && ! afectado integration "$CHURN_2255"; then
  ok "(1) churn sólo-pgTAP (#2255) -> e2e e integration CONSERVADOS"
else
  bad "(1) churn sólo-pgTAP invalida e2e/integration: la exclusión no está surtiendo efecto"
fi

# (2) …pero los gates que SÍ leen pgTAP siguen caducando. La exclusión es por gate, no global.
if afectado db-guards "$CHURN_2255" && afectado tests-manifest "$CHURN_2255" && afectado tenant "$CHURN_2255"; then
  ok "(2) el MISMO churn SÍ caduca db-guards, tests-manifest y tenant (leen supabase/tests)"
else
  bad "(2) db-guards/tests-manifest/tenant deberían caducar con un cambio en supabase/tests"
fi

# (3) Recorte medido del fixture real.
read -r cad con <<<"$(cuenta_caducados "$CHURN_2255")"
if [ "$cad" -eq 3 ] && [ "$con" -eq 34 ]; then
  ok "(3) #2255: caducan 3/37, conservan 34/37 (antes de TAL-5462: 29 y 8)"
else
  bad "(3) #2255: esperaba 3 caducados / 34 conservados, obtuve $cad / $con"
fi

# (4) CONTROL NEGATIVO con diff real: si el churn toca src/**, e2e caduca. No sobre-conservamos.
if afectado e2e "$CHURN_2241"; then
  ok "(4) #2241 (toca src/**) -> e2e CADUCA: la exclusión no tapa un cambio de aplicación"
else
  bad "(4) #2241 toca src/** y e2e se conservó — eso es un FALSO VERDE"
fi

# (5) FAIL-CLOSED ante área NUEVA: algo bajo supabase/ que nadie ha clasificado sigue caducando.
if afectado e2e 'supabase/area-inventada-manana/x.sql'; then
  ok "(5) área NUEVA bajo supabase/ -> sigue caducando e2e (fail-closed, no se descuenta sola)"
else
  bad "(5) un área nueva bajo supabase/ se descontó sola — eso es fail-OPEN"
fi

# (6) Las exclusiones las heredan los shards, igual que las inclusiones.
if [ "$(no_insumos_de_gate 'e2e-pagos:pagos-stripe')" = "$(no_insumos_de_gate e2e)" ] \
   && [ -n "$(no_insumos_de_gate e2e)" ]; then
  ok "(6) los shards e2e heredan las exclusiones de la familia"
else
  bad "(6) un shard e2e no hereda las exclusiones de la familia"
fi

# (7) Gate sin exclusiones declaradas ⇒ comportamiento idéntico al previo.
if [ -z "$(no_insumos_de_gate unit)" ] && [ -z "$(no_insumos_de_gate db-guards)" ]; then
  ok "(7) un gate sin TF_NOT_INPUTS_* no declara exclusiones (comportamiento previo intacto)"
else
  bad "(7) un gate sin exclusiones declaradas devolvió exclusiones"
fi

# (8) EL CRUCE (la lección de M2): ningún gate del manifiesto puede quedar sin clasificar.
#     O tiene entrada en el mapa, o está DECLARADO en TF_ALWAYS_RERUN. La ausencia deja de valer.
if [ -r "$MANIFIESTO" ]; then
  huerfanos=""
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    insumos_de_gate "$g" >/dev/null 2>&1 && continue
    siempre_recorre "$g" && continue
    huerfanos="$huerfanos $g"
  done < <(grep -oE '^TF_GATE_CMD_[A-Za-z0-9_]+' "$MANIFIESTO" | sed 's/TF_GATE_CMD_//' | sort -u)
  if [ -z "$huerfanos" ]; then
    ok "(8) cruce manifiesto↔mapa: ningún gate sin clasificar (ni mapeado ni declarado)"
  else
    bad "(8) gates del manifiesto SIN clasificar (dales entrada en el mapa o decláralos en TF_ALWAYS_RERUN):$huerfanos"
  fi
else
  bad "(8) no encuentro $MANIFIESTO para cruzar los gates"
fi

# (9) El gate apagado está declarado a conciencia, no ausente por olvido.
if siempre_recorre carveout_check && ! insumos_de_gate carveout_check >/dev/null 2>&1; then
  ok "(9) carveout_check: sin insumos inventados, DECLARADO como siempre-re-corre"
else
  bad "(9) carveout_check no está declarado en TF_ALWAYS_RERUN (o se le inventaron insumos)"
fi

# (10) La gramática del fichero de datos sigue CERRADA: una inyección no se carga.
TMPC="$(mktemp)"; cp "$CONF" "$TMPC"
CAN="${TMPDIR:-/tmp}/tal5462-inyectado"
# shellcheck disable=SC2016
printf 'TF_INPUTS_x="$(touch %s)"\n' "$CAN" >> "$TMPC"
out="$(LG_INSUMOS_CONF="$TMPC" bash -c ". '$LIB'" 2>&1)"; rc=$?
rm -f "$TMPC" "$CAN"
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'gramática cerrada'; then
  ok "(10) gramática cerrada: una asignación con sustitución de comandos NO se carga"
else
  bad "(10) la gramática aceptó una inyección (rc=$rc): $out"
fi

# (MUTANTE) Ensanchar la exclusión de e2e a todo `supabase/**` haría que un cambio de MIGRACIÓN
# —que sí es insumo de e2e— se conservara: falso verde. El arnés debe morderlo.
MUTC="$(mktemp)"
sed 's#^TF_NOT_INPUTS_e2e=.*#TF_NOT_INPUTS_e2e="supabase/**"#' "$CONF" > "$MUTC"
if ! diff -q "$CONF" "$MUTC" >/dev/null 2>&1; then
  ok "(mutante, pre-check) exclusión ensanchada a supabase/** (diff confirmado)"
else
  bad "(mutante, pre-check) el sed no cambió nada — el mutante no prueba nada"
fi
mut_out="$(LG_INSUMOS_CONF="$MUTC" bash -c '
  . '"$LIB"'
  churn="supabase/migrations/20271459000000_tal4506_dosier_sender.sql"
  pats="$(insumos_de_gate e2e)"; excl="$(no_insumos_de_gate e2e || true)"
  [ -n "$excl" ] && churn="$(printf "%s\n" "$churn" | grep -E -v -f <(printf "%s\n" "$excl") || true)"
  printf "%s\n" "$churn" | grep -v "^$" | grep -qE -f <(printf "%s\n" "$pats") && echo CADUCA || echo CONSERVA')"
rm -f "$MUTC"
if [ "$mut_out" = "CONSERVA" ]; then
  ok "(mutante) MUERDE: con la exclusión ensanchada, un cambio de MIGRACIÓN se conservaría (falso verde)"
else
  bad "(mutante) esperaba CONSERVA (falso verde) con la exclusión ensanchada, obtuve: $mut_out"
fi

echo "== TAL-5446: los patrones de exclusión NO se expanden contra el disco =="
# `for p in $val` hace word-splitting Y pathname expansion: un patrón declarado se sustituiría por lo
# que EXISTA en el cwd, así que la misma configuración daría exclusiones distintas según dónde se
# ejecute. Se mide DESDE un directorio que contiene rutas que casarían.
_t="$(mktemp -d)"; mkdir -p "$_t/supabase/tests/anidado"
: > "$_t/supabase/tests/directo.sql"; : > "$_t/supabase/tests/anidado/caso.sql"
_salida="$( cd "$_t" && TF_NOT_INPUTS_e2e='supabase/tests/**' no_insumos_de_gate e2e )"
_n="$(printf '%s\n' "$_salida" | grep -c . )"
if [ "$_n" = "1" ]; then ok "el patrón sobrevive entero (1 salida, no una por fichero del disco)"
else bad "el patrón se expandió contra el disco: $_n salidas"; fi
_salida2="$( cd "$_t" && TF_NOT_INPUTS_e2e='supabase/tests/** docs/**' no_insumos_de_gate e2e )"
_n2="$(printf '%s\n' "$_salida2" | grep -c . )"
if [ "$_n2" = "2" ]; then ok "CONTROL: dos patrones declarados → dos salidas"
else bad "CONTROL falló: esperaba 2, obtuvo $_n2"; fi
rm -rf "$_t"

echo
if [ "$FAIL" -eq 0 ]; then echo "[test-insumos-por-area] TODOS los casos OK"; exit 0; fi
echo "[test-insumos-por-area] hubo fallos" >&2; exit 1
