#!/usr/bin/env bash
# insumos-por-gate.sh — CARGADOR del mapa de insumos por gate (dato en insumos-por-gate.conf).
#
# El mapa lo derivó M2 leyendo lo que cada `TF_GATE_CMD_*` EJECUTA y lo que ese comando LEE
# (sha256 del fichero original: ca71472d9b470f4f…, 38 líneas). Se conserva como DATO aparte para
# que se pueda revisar y versionar sin tocar código.
#
# POR QUÉ NO VA EN EL MANIFIESTO: el `manifest_digest` está sellado en cada receipt; añadir claves
# a `academy.conf` invalidaría TODAS las suites en vuelo — justo el daño que este mecanismo evita.
# Esto lo lee SOLO la estación; no viaja al runner y no cambia `motor_sha256`.
#
# SEMÁNTICAS RATIFICADAS (CEO 19:26):
#   · TF_INPUTS_UNIVERSAL — si el avance lo toca, CADUCAN TODOS los receipts.
#   · fail-closed — un gate SIN entrada NO se conserva jamás. Un mapa incompleto cuesta tiempo,
#     nunca falsos verdes.

INSUMOS_CONF="${LG_INSUMOS_CONF:-${BASH_SOURCE[0]%/*}/insumos-por-gate.conf}"
[ -r "$INSUMOS_CONF" ] || { echo "sin mapa de insumos ($INSUMOS_CONF)" >&2; return 1 2>/dev/null || exit 1; }
# Gramática cerrada: solo asignaciones TF_INPUTS_* entrecomilladas y comentarios. La estación NO
# ejecuta un fichero de datos sin comprobar que es datos.
if grep -vqE '^\s*(#.*)?$|^TF_((NOT_)?INPUTS_[A-Za-z0-9_]+|ALWAYS_RERUN)="[^"`$;|&<>()]*"\s*$' "$INSUMOS_CONF"; then
  echo "mapa de insumos FUERA de la gramática cerrada: $INSUMOS_CONF" >&2; return 1 2>/dev/null || exit 1
fi
# shellcheck disable=SC1090
. "$INSUMOS_CONF"

# noglob acotado: se restaura el estado que tenía el llamante, no se le impone el nuestro.
_TA_NOGLOB_PREV=""
_ta_noglob_on() { case $- in *f*) _TA_NOGLOB_PREV=1;; *) _TA_NOGLOB_PREV=0;; esac; set -f; }
_ta_noglob_off() { [ "$_TA_NOGLOB_PREV" = 1 ] || set +f; }

# glob → ERE anclada. `**` cruza directorios; `*` no. Se escapan los metacaracteres del regex.
_glob_a_ere() {
  printf '%s' "$1" | sed -e 's/[.[\()+^$|]/\\&/g' -e 's/}/\\}/g' -e 's/{/\\{/g' \
    -e 's/\*\*/\x01/g' -e 's/\*/[^\/]*/g' -e 's/\x01/.*/g' -e 's/?/./g' \
    | sed -e 's/^/^/' -e 's/$/$/'
}

# insumos_de_gate <gate-id> → una ERE por línea; rc=1 si el gate NO está en el mapa (fail-closed).
insumos_de_gate() {
  local g="$1" var val p
  case "$g" in e2e-*:*|e2e-*) g="e2e";; esac      # todos los shards comparten insumos
  var="TF_INPUTS_${g//-/_}"; var="${var//:/_}"
  val="${!var-}"
  [ -n "${val+x}" ] && [ -n "$val" ] || return 1
  # `set -f` OBLIGATORIO: se quiere word-splitting pero NO pathname expansion. Sin él, desde un
  # árbol que contenga `src/` o `supabase/` bash expande el glob a rutas REALES —`supabase/**` pasa
  # a `supabase/migrations`— y la ERE resultante (`^supabase/migrations$`) NO casa con
  # `supabase/migrations/x.sql`: ningún insumo casaría y TODOS los receipts rancios se darían por
  # buenos. Fail-OPEN silencioso, justo en el control que decide si una evidencia caducada vale.
  # Cazado por M2 (M2-FAILOPEN-LATENTE-EN-50); hoy no mordía solo porque el agregador corre con el
  # clon del motor como CWD, que no tiene esos directorios. Depender de eso es depender del azar.
  _ta_noglob_on
  for p in $val; do _glob_a_ere "$p"; echo; done
  _ta_noglob_off
  return 0
}

# no_insumos_de_gate <gate-id> → una ERE por línea con las EXCLUSIONES declaradas del gate
# (TAL-5462). Vacío si el gate no declara ninguna — ese es el caso por defecto y el seguro: sin
# exclusiones, el gate se comporta exactamente como antes. Las exclusiones se aplican DESPUÉS de
# las inclusiones y sólo descuentan rutas que casan positivamente con un patrón declarado, así que
# una carpeta nueva jamás se descuenta sola.
no_insumos_de_gate() {
  local g="$1" var val p
  case "$g" in e2e-*:*|e2e-*) g="e2e";; esac      # todos los shards comparten exclusiones
  var="TF_NOT_INPUTS_${g//-/_}"; var="${var//:/_}"
  val="${!var-}"
  [ -n "${val:-}" ] || return 0
  # `for p in $val` hace word-splitting Y EXPANSION DE RUTAS. Un patron declarado como
  # `supabase/tests/**` se sustituiria por lo que EXISTA en el directorio actual, asi que la misma
  # configuracion daria exclusiones distintas segun donde se ejecute. Y `**` sin `globstar` casa un
  # solo nivel, con lo que los anidados se pierden. Aqui hacen falta las PALABRAS, no las rutas:
  # se desactiva el globbing para la expansion y se restaura el estado previo.
  local _glob_estaba_on=0
  case "$-" in *f*) : ;; *) _glob_estaba_on=1 ;; esac
  set -f
  for p in $val; do _glob_a_ere "$p"; echo; done
  [ "$_glob_estaba_on" = "1" ] && set +f
  return 0
}

# siempre_recorre <gate-id> → rc 0 si el gate está DECLARADO como «siempre re-corre» (TAL-5462).
# No cambia el comportamiento (sin entrada ya se re-corría): sirve para que el arnés distinga
# «declarado a conciencia» de «se nos olvidó mapearlo».
siempre_recorre() {
  local g="$1" x
  case "$g" in e2e-*:*|e2e-*) g="e2e";; esac
  g="${g//-/_}"; g="${g//:/_}"
  for x in ${TF_ALWAYS_RERUN-}; do [ "${x//-/_}" = "$g" ] && return 0; done
  return 1
}

# insumos_universales → una ERE por línea (vacío si no hay declaración)
insumos_universales() {
  local p
  _ta_noglob_on
  for p in ${TF_INPUTS_UNIVERSAL-}; do _glob_a_ere "$p"; echo; done
  _ta_noglob_off
}
