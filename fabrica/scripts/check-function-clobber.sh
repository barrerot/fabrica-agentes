#!/usr/bin/env bash
# scripts/check-function-clobber.sh — Guard de PISADA SILENCIOSA de funciones SQL entre piezas.
#
# EL DEFECTO QUE CIERRA (medido en producción, 2026-09-06, PR #2264 vs #2253 de academia-ejemplo):
# dos piezas redefinen la MISMA función con `create or replace function`, cada una en SU PROPIO
# fichero de migración. Como son ficheros distintos, `git` NO ve conflicto: el rebase sale limpio,
# el diff parece disjunto y la revisión humana no tiene a qué agarrarse. Pero al aplicarse, la
# migración con el slot MAYOR gana, y si su cuerpo se derivó de una versión ANTERIOR a la otra
# pieza, revierte su trabajo EN SILENCIO.
#
# El caso real: TAL-5429 (#2264) redefinía `app_internal.create_extra_canjes_order_impl` partiendo
# de una base anterior a TAL-5339 (#2253), que ya estaba en `main` y había arreglado un fallo de
# DINERO en esa misma función. El rebase fue limpio; nada avisó. Lo cazó, 50 minutos después, el
# pgTAP de la pieza anterior (`H11 FAIL (retorno): unit_price_cents devuelto = 73290, esperado
# 51303`). Este script lo caza ANTES de gastar la suite, en segundos, y sin depender de que la
# pieza pisada tenga test.
#
# QUÉ COMPARA (conjuntos, no cardinales):
#   A = funciones que la PIEZA redefine     -> `create or replace function` en las líneas AÑADIDAS
#                                              de `diff(base..head)` sobre ficheros `*.sql`
#   B = funciones que MAIN redefinió DESPUÉS de la base de la pieza -> ídem sobre `diff(base..main)`
#   A ∩ B ≠ ∅  ⇒  ALARMA (exit 1), con la lista de funciones y los commits de `main` que las tocaron.
#
# Por qué "después de la base" y no "en main": una función que `main` ya tenía redefinida ANTES de
# la base de la pieza no es una pisada — la pieza partió de ese trabajo y lo lleva dentro. Sólo es
# pisada lo que entró a `main` MIENTRAS la pieza estaba fuera.
#
# IDENTIDAD: `esquema.nombre` en minúsculas, sin lista de argumentos. Dos sobrecargas del mismo
# nombre se tratan como la MISMA entidad — a propósito: prefiere una alarma de más (que se
# descarta leyendo el diff en segundos) a una pisada de menos.
#
# FAIL-CLOSED-ON-UNKNOWN: una línea que declara `create or replace function` pero de la que este
# script NO sabe extraer identidad (nombre en la línea siguiente, comentario raro, etc.) NO se
# ignora: para el script con exit 2 y la línea literal. Un guard que se salta lo que no entiende
# es un guard que miente.
#
# Uso:
#   scripts/check-function-clobber.sh --base <ref> --head <ref> [--main <ref>]
#
#   --base  base de la pieza (dónde arrancó: normalmente `git merge-base <head> <main>`).
#   --head  punta de la pieza (el head del PR ya rebasado).
#   --main  punta del tronco. Por defecto `origin/main` si existe; si no, `main`.
#           Si ninguna resuelve, exit 2 — NUNCA se adivina.
#
# Exit: 0 sin pisada · 1 pisada detectada (lista impresa) · 2 uso/refs irresolubles/parse desconocido.

set -uo pipefail

morir() { echo "check-function-clobber: $*" >&2; exit 2; }

BASE_REF=""; HEAD_REF=""; MAIN_REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base) [ $# -ge 2 ] || morir "--base requiere un valor"; BASE_REF="$2"; shift 2 ;;
    --head) [ $# -ge 2 ] || morir "--head requiere un valor"; HEAD_REF="$2"; shift 2 ;;
    --main) [ $# -ge 2 ] || morir "--main requiere un valor"; MAIN_REF="$2"; shift 2 ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; exit 2 ;;
    *) morir "argumento desconocido: $1" ;;
  esac
done

[ -n "$BASE_REF" ] || morir "falta --base (la base de la pieza; normalmente git merge-base <head> <main>)"
[ -n "$HEAD_REF" ] || morir "falta --head (la punta de la pieza)"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || morir "no estoy dentro de un repositorio git"

resolver() { # <ref> <etiqueta> -> imprime el sha; muere si no resuelve
  local sha
  sha="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "$1^{commit}")" \
    || morir "$2 '$1' no resuelve a un commit — fail-closed, no se adivina"
  printf '%s' "$sha"
}

BASE="$(resolver "$BASE_REF" "--base")" || exit 2
HEAD="$(resolver "$HEAD_REF" "--head")" || exit 2

if [ -z "$MAIN_REF" ]; then
  if git -C "$REPO_ROOT" rev-parse --verify --quiet 'origin/main^{commit}' >/dev/null; then
    MAIN_REF="origin/main"
  elif git -C "$REPO_ROOT" rev-parse --verify --quiet 'main^{commit}' >/dev/null; then
    MAIN_REF="main"
  else
    morir "no se pasó --main y no existen ni 'origin/main' ni 'main' — fail-closed, no se adivina el tronco"
  fi
fi
MAIN="$(resolver "$MAIN_REF" "--main")" || exit 2

# funciones_redefinidas <desde> <hasta> — imprime una identidad `esquema.nombre` por línea (únicas,
# ordenadas) de cada `create or replace function` AÑADIDO en ficheros *.sql entre los dos commits.
funciones_redefinidas() {
  local desde="$1" hasta="$2" diff_rc=0 linea ident cuerpo
  local -a salida=()
  local diff_out
  diff_out="$(git -C "$REPO_ROOT" diff --no-color --no-ext-diff -U0 "$desde" "$hasta" -- '*.sql' 2>&1)" || diff_rc=$?
  # Un `git diff` que falla NO se interpreta como "no hay funciones": eso sería fail-open.
  [ "$diff_rc" -eq 0 ] || morir "git diff $desde..$hasta falló (rc=$diff_rc): $diff_out"

  while IFS= read -r linea; do
    # sólo líneas AÑADIDAS (no la cabecera +++), sin el '+' inicial
    case "$linea" in
      '+++'*) continue ;;
      '+'*) cuerpo="${linea#+}" ;;
      *) continue ;;
    esac
    # Un comentario de línea NO declara nada: se recorta `-- …` antes de decidir. Sin esto, una
    # línea de prosa que MENCIONA la frase (las hay: los propios ficheros de migración se
    # documentan a sí mismos) dispararía el fail-closed y volvería el guard inservible.
    cuerpo="${cuerpo%%--*}"
    # ¿declara una redefinición de función? (case-insensitive, espacios flexibles)
    printf '%s' "$cuerpo" | grep -qiE 'create[[:space:]]+or[[:space:]]+replace[[:space:]]+function' || continue
    # extraer la identidad que sigue a `function`
    ident="$(printf '%s' "$cuerpo" \
      | sed -nE 's/.*[Cc][Rr][Ee][Aa][Tt][Ee][[:space:]]+[Oo][Rr][[:space:]]+[Rr][Ee][Pp][Ll][Aa][Cc][Ee][[:space:]]+[Ff][Uu][Nn][Cc][Tt][Ii][Oo][Nn][[:space:]]+([A-Za-z0-9_."]+).*/\1/p' \
      | head -1)"
    ident="${ident//\"/}"
    # FAIL-CLOSED-ON-UNKNOWN: declara redefinición pero no sé de qué -> paro, no lo ignoro.
    [ -n "$ident" ] || morir "línea con 'create or replace function' sin identidad extraíble (¿el nombre está en otra línea?) en $desde..$hasta — fail-closed, no se ignora: >>>${cuerpo}<<<"
    salida+=("$(printf '%s' "$ident" | tr '[:upper:]' '[:lower:]')")
  done <<< "$diff_out"

  [ ${#salida[@]} -eq 0 ] || printf '%s\n' "${salida[@]}" | sort -u
}

PIEZA="$(funciones_redefinidas "$BASE" "$HEAD")" || exit 2
TRONCO="$(funciones_redefinidas "$BASE" "$MAIN")" || exit 2

if [ -z "$PIEZA" ]; then
  echo "check-function-clobber: la pieza no redefine ninguna función SQL — nada que comparar (verde)"
  exit 0
fi

COLISION="$(comm -12 <(printf '%s\n' "$PIEZA") <(printf '%s\n' "${TRONCO:-}" | sed '/^$/d'))"

if [ -z "$COLISION" ]; then
  n_pieza="$(printf '%s\n' "$PIEZA" | grep -c . || true)"
  echo "check-function-clobber: VERDE — la pieza redefine $n_pieza función(es) y main no ha tocado ninguna desde ${BASE:0:12}"
  exit 0
fi

echo "check-function-clobber: PISADA SILENCIOSA — main redefinió estas funciones DESPUÉS de la base de la pieza (${BASE:0:12}):" >&2
while IFS= read -r fn; do
  [ -n "$fn" ] || continue
  echo "  · $fn" >&2
  # commits de main que la tocaron, para que quien lea sepa contra qué re-derivar
  git -C "$REPO_ROOT" log --no-color --oneline "$BASE..$MAIN" -S"$fn" --pickaxe-regex -i -- '*.sql' 2>/dev/null \
    | sed 's/^/      main: /' >&2 || true
done <<< "$COLISION"
cat >&2 <<'FIN'

  El rebase salió limpio porque cada pieza redefine la función en SU PROPIO fichero de migración:
  git no ve conflicto. Al aplicarse gana la migración de slot MAYOR, así que si el cuerpo de esta
  pieza se derivó de una versión anterior, revierte en silencio el trabajo que ya está en main.
  Re-derivar el cuerpo sobre la versión de main ANTES de seguir (y re-auditar).
FIN
exit 1
