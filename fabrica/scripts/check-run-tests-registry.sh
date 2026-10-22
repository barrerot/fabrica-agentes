#!/usr/bin/env bash
# scripts/check-run-tests-registry.sh — TAL-5435. Guard de integridad del registro de
# `tests/run-tests.sh` frente a una integración (merge o rebase) que se coma entradas.
#
# Reemplaza la convención anterior — tres `grep -c` corridos A MANO por M1 contra un número
# fijo escrito en prosa ("contrato: 91") — por una comparación de CONJUNTO. El defecto medido
# de la convención vieja (TAL-5435): un cardinal no acredita identidad. Perder una entrada real
# del lado de `main` y ganar cualquier otra deja el cardinal INTACTO y el gate en verde con una
# entrada real perdida; y, en sentido contrario, cualquier ampliación legítima del registro
# rompe el número fijo hasta que alguien lo actualiza a mano (medido: 16 cambios de conteo en
# los últimos 22 commits que tocan el fichero).
#
# MECANISMO: el registro del HEAD de la integración debe contener, como CONJUNTO, la UNIÓN
# EXACTA de las entradas `check "<descripción>" ...` de los dos lados que se integran — el lado
# de `main` y el lado de la pieza. Cero valores fijos: no hay ningún número escrito en este
# script ni en ningún fichero que este script lea.
#
#   - Entidad de identidad: el texto de la descripción entre comillas de cada línea
#     `check "..."`. Es exacto (no substring) — dos entradas distintas no pueden compartir
#     descripción; ver contrato (a) abajo.
#   - En una integración por MERGE, los dos lados son los propios PADRES del commit de
#     integración — autocontenidos, sin ningún identificador escrito a mano. Se derivan solos.
#   - En una integración por REBASE no hay segundo padre. El padre inmediato del head SOLO es
#     la base nueva cuando la pieza rebasa UNA sola confirmación — con dos o más, el padre
#     inmediato es una confirmación intermedia de la propia pieza YA reproducida sobre la base,
#     y derivar "main-side" de ahí puede ocultar una pérdida real de main (hallazgo BLOQUEANTE
#     de code-gate r1: no hay forma general de distinguir ambos casos solo con el conteo de
#     padres). Por eso, ante 1 solo padre, NINGÚN lado se deriva: `--main-side` (la base nueva
#     real) Y `--piece-side` (el head pre-rebase) son AMBOS obligatorios. Sin cualquiera de los
#     dos, el script se PARA fail-closed — nunca asume ni fabrica una referencia, precisamente
#     para no cablear a medias lo que no se puede derivar con seguridad.
#
# Contratos (falla con exit 1/2 y motivo si cualquiera no se cumple):
#   (a) ninguna de las tres referencias (main-side, piece-side, head) tiene descripciones
#       `check "..."` DUPLICADAS dentro de sí misma — una descripción repetida podría enmascarar
#       la pérdida de una de las dos copias sin que el conjunto lo note.
#   (b) el conjunto de entradas del HEAD contiene la UNIÓN EXACTA de main-side ∪ piece-side.
#       Cualquier entrada de la unión ausente en HEAD ⇒ FAIL, con la lista literal de lo perdido.
#   (c) el HEAD puede tener entradas ADICIONALES a la unión (ampliación legítima de la propia
#       pieza, u otro trabajo ya integrado) — eso NUNCA es motivo de fallo. El control negativo
#       de esta pieza es exactamente que una ampliación legítima siga en verde.
#
# Uso:
#   scripts/check-run-tests-registry.sh <head_ref> [--main-side <ref>] [--piece-side <ref>]
#
#   - Si <head_ref> resuelve a un commit con EXACTAMENTE 2 padres (merge real) y no se pasan
#     --main-side/--piece-side, se derivan solos: main-side=padre1, piece-side=padre2
#     (convención de `git merge`: al fusionar `pieza` sobre `main`, el padre1 es el `main`
#     previo y el padre2 es la punta de `pieza`).
#   - Si <head_ref> resuelve a un commit con 1 SOLO padre (rebase/commit lineal), NADA se
#     deriva: `--main-side` Y `--piece-side` son AMBOS obligatorios. La ausencia de cualquiera
#     de los dos es exit 2 fail-closed con el motivo explícito, no una suposición (el padre
#     inmediato NO se asume como la base — ver el porqué arriba).
#   - >2 padres (octopus merge) no soportado: exit 2 fail-closed.
#   - --main-side/--piece-side, si se pasan, SIEMPRE ganan sobre la derivación automática.
#
# Exit: 0 verde (unión completa presente) · 1 entrada(s) perdida(s) · 2 error de uso/derivación.

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RUTA_REGISTRO="tests/run-tests.sh"

morir() { echo "check-run-tests-registry: $*" >&2; exit 2; }

# entradas_check <ref> — imprime, una por línea, el texto de descripción de cada línea
# `check "..."` de tests/run-tests.sh EN ESE ref. No normaliza ni ordena por sí sola (lo hace
# el llamador) para poder detectar duplicados exactos antes de deduplicar.
entradas_check() {
  local ref="$1" contenido
  contenido="$(git -C "$REPO_ROOT" show "$ref:$RUTA_REGISTRO" 2>/dev/null)" \
    || { echo "check-run-tests-registry: no pude leer $RUTA_REGISTRO en '$ref'" >&2; return 1; }
  printf '%s\n' "$contenido" | grep -oE '^ *check "[^"]*"' | sed -E 's/^ *check "//; s/"$//'
}

# sin_duplicados <etiqueta> <ref> — contrato (a). Imprime el conjunto (deduplicado, ordenado)
# por stdout si pasa; si hay duplicados, los lista en stderr y retorna 1.
sin_duplicados() {
  local etiqueta="$1" ref="$2" entradas dupes
  entradas="$(entradas_check "$ref")" || return 1
  dupes="$(printf '%s\n' "$entradas" | sort | uniq -d)"
  if [ -n "$dupes" ]; then
    echo "check-run-tests-registry: descripciones DUPLICADAS en $etiqueta ($ref) — identidad ambigua:" >&2
    printf '%s\n' "$dupes" | sed 's/^/  · /' >&2
    return 1
  fi
  printf '%s\n' "$entradas" | sort -u
}

main() {
  local head_ref="${1:-}" main_side="" piece_side="" arg
  [ -n "$head_ref" ] || morir "uso: $0 <head_ref> [--main-side <ref>] [--piece-side <ref>]"
  shift || true
  while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --main-side|--piece-side)
        # [code-gate r1, MAYOR] sin este chequeo, --main-side/--piece-side como ÚLTIMO
        # argumento (sin valor detrás) dejaba "${2:-}" vacío y `shift 2` fallaba en silencio
        # (sin `set -e`): $# no avanzaba y el while repetía para siempre — cuelgue real,
        # reproducido por el auditor con `timeout 1s` (rc=124, sin diagnóstico). Fail-closed
        # explícito: exigir un segundo argumento presente ANTES de tocar $1/$2.
        [ $# -ge 2 ] || morir "uso: $arg requiere un valor (ref) a continuación"
        [ -n "$2" ] || morir "uso: $arg no puede llevar un valor vacío"
        if [ "$arg" = "--main-side" ]; then main_side="$2"; else piece_side="$2"; fi
        shift 2
        ;;
      *) morir "argumento no reconocido: $arg" ;;
    esac
  done

  local head_sha
  head_sha="$(git -C "$REPO_ROOT" rev-parse "$head_ref" 2>/dev/null)" \
    || morir "head_ref '$head_ref' no resuelve a un commit"

  local -a padres
  mapfile -t padres < <(git -C "$REPO_ROOT" rev-list --parents -n1 "$head_sha" | cut -d' ' -f2-)
  # rev-list --parents -n1 <sha> imprime "<sha> <padre1> [<padre2> ...]" en UNA línea; tras el
  # cut nos quedamos con los padres separados por espacio en esa misma línea — hay que volver
  # a separarlos por palabra, no por línea.
  local -a padres_reales
  read -r -a padres_reales <<< "${padres[0]:-}"

  case "${#padres_reales[@]}" in
    2)
      [ -n "$main_side" ] || main_side="${padres_reales[0]}"
      [ -n "$piece_side" ] || piece_side="${padres_reales[1]}"
      ;;
    1)
      # [code-gate r1, BLOQUEANTE] el padre inmediato SOLO es la base nueva cuando la pieza
      # rebasa UNA sola confirmación. Con dos o más, el padre inmediato es una confirmación
      # intermedia de la propia pieza ya reproducida sobre la base — una entrada de main
      # perdida en un paso anterior del rebase ya falta tanto ahí como en el head, así que
      # derivar main-side de ese padre la borraría también de la unión esperada, exactamente
      # el falso verde que esta pieza existe para cerrar. Reproducido por el auditor: rebase
      # de 2 confirmaciones perdiendo una entrada de main en la primera → con --piece-side
      # solo, rc=0 (falso verde); con --main-side real explícito, rc=1 y la entrada listada.
      # Por eso NINGÚN lado se deriva con 1 padre: ambos son obligatorios, siempre.
      if [ -z "$main_side" ] || [ -z "$piece_side" ]; then
        morir "integración por REBASE detectada ($head_ref tiene 1 solo padre: ${padres_reales[0]}) — con 1 padre no se deriva NINGÚN lado (el padre inmediato no es de fiar como base con 2+ confirmaciones rebasadas). Pasa AMBOS explícitos: --main-side <sha-base-nueva-real> --piece-side <sha-pre-rebase>. (DoD 3, TAL-5435: resuelto fail-closed, no diferido — dueño = quien invoca este script conociendo ambas puntas.)"
      fi
      ;;
    0)
      morir "$head_ref no tiene padres (commit raíz) — no hay integración que verificar"
      ;;
    *)
      morir "$head_ref tiene ${#padres_reales[@]} padres (octopus merge) — no soportado, fail-closed"
      ;;
  esac

  local main_entries piece_entries head_entries
  main_entries="$(sin_duplicados "main-side" "$main_side")" || exit 1
  piece_entries="$(sin_duplicados "piece-side" "$piece_side")" || exit 1
  head_entries="$(sin_duplicados "head" "$head_sha")" || exit 1

  local union_esperada perdidas n_main n_piece n_head n_union n_perdidas
  union_esperada="$(printf '%s\n%s\n' "$main_entries" "$piece_entries" | sort -u)"
  perdidas="$(comm -23 <(printf '%s\n' "$union_esperada") <(printf '%s\n' "$head_entries"))"

  n_main="$(printf '%s\n' "$main_entries" | grep -c .)"
  n_piece="$(printf '%s\n' "$piece_entries" | grep -c .)"
  n_head="$(printf '%s\n' "$head_entries" | grep -c .)"
  n_union="$(printf '%s\n' "$union_esperada" | grep -c .)"

  echo "check-run-tests-registry: main-side=$main_side ($n_main entradas) · piece-side=$piece_side ($n_piece entradas) · unión esperada=$n_union · head=$head_sha ($n_head entradas)"

  if [ -n "$perdidas" ]; then
    n_perdidas="$(printf '%s\n' "$perdidas" | grep -c .)"
    echo "check-run-tests-registry: ROJO — $n_perdidas entrada(s) de la unión AUSENTE(S) en el head:" >&2
    printf '%s\n' "$perdidas" | sed 's/^/  · /' >&2
    exit 1
  fi

  echo "check-run-tests-registry: VERDE — el head contiene la unión completa (conjunto, no cardinal)."
  exit 0
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi
