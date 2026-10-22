#!/usr/bin/env bash
# tests/test-check-run-tests-registry.sh — TAL-5435. Self-test de
# scripts/check-run-tests-registry.sh contra los 5 escenarios medidos en la issue (tabla del
# control negativo) + la resolución fail-closed del punto (3) del DoD (rebase sin segundo padre).
# Lo EJECUTA tests/run-tests.sh: un test que nadie corre no es una prueba, es un fichero.
#
# Construye TRES commits sintéticos (main-side, piece-side, head) por escenario usando
# plumbing de git (hash-object + índice scratch + commit-tree) en un repo temporal
# propio, eliminado al finalizar. No requiere git alrededor del paquete.
set -uo pipefail

# TAL-5435: identidad de git EXPLÍCITA. Este arnés fabrica commits sintéticos
# con `git commit-tree`, que EXIGE identidad de committer. Un runner limpio de CI (p. ej.
# actions/checkout, que no configura `user.name`/`user.email`) hacía fallar los 13 casos con rc=2
# mientras en una estación con identidad configurada pasaban los 13 — un test anclado al entorno,
# no al comportamiento. Se fija aquí para que el resultado no dependa de la config ambiental.
# Medido: clon shallow (depth=1, como actions/checkout) SIN identidad -> rc=1, 13 FAIL;
#          el MISMO clon shallow CON identidad -> rc=0, 0 FAIL. La causa es la identidad, no el shallow.
export GIT_AUTHOR_NAME="tal5435-selftest"
export GIT_AUTHOR_EMAIL="tal5435-selftest@localhost"
export GIT_COMMITTER_NAME="tal5435-selftest"
export GIT_COMMITTER_EMAIL="tal5435-selftest@localhost"

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/check-run-tests-registry.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT no existe o no es ejecutable"; exit 2; }

FIX_REPO="$(mktemp -d)" || exit 2
trap 'rm -rf "$FIX_REPO"' EXIT
mkdir -p "$FIX_REPO/scripts" "$FIX_REPO/tests"
cp "$SCRIPT" "$FIX_REPO/scripts/"
cp "$REPO_ROOT/tests/run-tests.sh" "$FIX_REPO/tests/"
REPO_ROOT="$FIX_REPO"; SCRIPT="$REPO_ROOT/scripts/check-run-tests-registry.sh"
git -C "$REPO_ROOT" init -q -b main || exit 2
git -C "$REPO_ROOT" add -A || exit 2
git -C "$REPO_ROOT" commit -qm base || exit 2
BASE_TREE_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
FAIL=0
ok()  { echo "  PASS  $1"; }
bad() { echo "  FAIL  $1" >&2; FAIL=1; }

# construir_registro <check1> <check2> ... — imprime el contenido de un tests/run-tests.sh
# sintético mínimo, con una sección y una línea `check "<desc>" 0 0` por cada argumento.
construir_registro() {
  echo '#!/usr/bin/env bash'
  echo 'echo "== sección sintética =="'
  local desc
  for desc in "$@"; do
    printf 'check "%s" 0 0\n' "$desc"
  done
}

# commit_con_registro <contenido> [padre1 padre2 ...] — escribe <contenido> como
# tests/run-tests.sh sobre el árbol de BASE_TREE_COMMIT (vía índice scratch, sin tocar el
# índice real ni el working tree) y crea un commit (0, 1 o 2 padres). Imprime el sha nuevo.
commit_con_registro() {
  local contenido="$1"; shift
  local -a padres=("$@")
  local blob idx tree commit commit_args=()
  blob="$(printf '%s' "$contenido" | git -C "$REPO_ROOT" hash-object -w --stdin)" || return 2
  idx="$(mktemp)" || return 2
  if ! GIT_INDEX_FILE="$idx" git -C "$REPO_ROOT" read-tree "$BASE_TREE_COMMIT" ||
     ! GIT_INDEX_FILE="$idx" git -C "$REPO_ROOT" update-index --add --cacheinfo "100644,$blob,tests/run-tests.sh" ||
     ! tree="$(GIT_INDEX_FILE="$idx" git -C "$REPO_ROOT" write-tree)"; then
    rm -f "$idx"
    echo 'commit_con_registro: no pude construir el árbol sintético' >&2
    return 2
  fi
  rm -f "$idx"
  local p
  for p in "${padres[@]}"; do commit_args+=(-p "$p"); done
  # -m ya suministra el mensaje: commit-tree no lee stdin. La tubería anterior
  # podía dar SIGPIPE en printf después de imprimir el SHA; pipefail activaba
  # otro commit-tree y concatenaba dos SHA. Una sola ejecución, sin fallback.
  commit="$(git -C "$REPO_ROOT" commit-tree "$tree" "${commit_args[@]}" -m 'sintético de registro')" || {
    echo 'commit_con_registro: commit-tree falló' >&2
    return 2
  }
  if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]] ||
     ! git -C "$REPO_ROOT" cat-file -e "$commit^{commit}"; then
    echo 'commit_con_registro: se esperaba exactamente un identificador de commit válido' >&2
    return 2
  fi
  printf '%s\n' "$commit"
}

# Fixture común a los 5 escenarios de la tabla: main aporta 10 entradas (M1..M10) DENTRO de la
# misma sección que ya existía (así el conteo de bloques tampoco se movería con el gate viejo,
# igual que describe la issue); la pieza aporta 1 entrada (P1).
BASE_ENTRIES=(A B C)
MAIN_NEW=(M1 M2 M3 M4 M5 M6 M7 M8 M9 M10)
PIECE_NEW=(P1)

registro_main="$(construir_registro "${BASE_ENTRIES[@]}" "${MAIN_NEW[@]}")"
registro_piece="$(construir_registro "${BASE_ENTRIES[@]}" "${PIECE_NEW[@]}")"
registro_union="$(construir_registro "${BASE_ENTRIES[@]}" "${MAIN_NEW[@]}" "${PIECE_NEW[@]}")"

MAIN_SIDE="$(commit_con_registro "$registro_main")" || exit 2
PIECE_SIDE="$(commit_con_registro "$registro_piece")" || exit 2

# El ayudante falla antes de entregar un identificador vacío, múltiple o una
# salida de una orden fallida; nunca intenta crear un segundo commit.
for variante in doble vacio fallo; do
  salida="$(
    git() {
      if [ "${3:-}" = commit-tree ]; then
        case "$variante" in
          doble) printf '%s\n%s\n' "$MAIN_SIDE" "$MAIN_SIDE" ;;
          vacio) return 0 ;;
          fallo) printf '%s\n' "$MAIN_SIDE"; return 1 ;;
        esac
      else
        command git "$@"
      fi
    }
    commit_con_registro "$registro_main" 2> "$FIX_REPO/diagnostico"
  )"
  rc=$?
  if [ "$rc" -eq 2 ] && [ -z "$salida" ] &&
     grep -q 'commit_con_registro:' "$FIX_REPO/diagnostico"; then
    ok "ayudante rechaza $variante sin entregar SHA"
  else
    bad "ayudante debía rechazar $variante sin SHA: rc=$rc"
  fi
done

echo "== TAL-5435: check-run-tests-registry.sh — 5 escenarios + rebase fail-closed =="

# ── Escenario 1: integración correcta (control de falso rojo) → VERDE ─────────────────────
head1="$(commit_con_registro "$registro_union" "$MAIN_SIDE" "$PIECE_SIDE")" || exit 2
out1="$(bash "$SCRIPT" "$head1" 2>&1)"; rc1=$?
if [ "$rc1" -eq 0 ]; then ok "(1) integración correcta -> VERDE (rc=0)"; else bad "(1) esperaba rc=0, obtuve rc=$rc1:
$out1"; fi

# ── Escenario 2: pierde las DIEZ entradas de main → ROJO, 10 ausentes ──────────────────────
registro_pierde_main="$(construir_registro "${BASE_ENTRIES[@]}" "${PIECE_NEW[@]}")"
head2="$(commit_con_registro "$registro_pierde_main" "$MAIN_SIDE" "$PIECE_SIDE")" || exit 2
out2="$(bash "$SCRIPT" "$head2" 2>&1)"; rc2=$?
n_ausentes2="$(printf '%s\n' "$out2" | grep -cE '^  · M[0-9]+$')"
if [ "$rc2" -eq 1 ] && [ "$n_ausentes2" -eq 10 ]; then
  ok "(2) pierde las 10 de main -> ROJO (rc=1), 10 ausentes listadas"
else
  bad "(2) esperaba rc=1 con 10 ausentes, obtuve rc=$rc2 ausentes=$n_ausentes2:
$out2"
fi

# ── Escenario 3: pierde la entrada de la pieza → ROJO, 1 ausente ──────────────────────────
registro_pierde_pieza="$(construir_registro "${BASE_ENTRIES[@]}" "${MAIN_NEW[@]}")"
head3="$(commit_con_registro "$registro_pierde_pieza" "$MAIN_SIDE" "$PIECE_SIDE")" || exit 2
out3="$(bash "$SCRIPT" "$head3" 2>&1)"; rc3=$?
if [ "$rc3" -eq 1 ] && printf '%s' "$out3" | grep -qE '^  · P1$'; then
  ok "(3) pierde la entrada de la pieza -> ROJO (rc=1), P1 listada como ausente"
else
  bad "(3) esperaba rc=1 con P1 ausente, obtuve rc=$rc3:
$out3"
fi

# ── Escenario 4 (EL CAUSAL, DoD 1): pierde M10 y añade una entrada X sin relación — cardinal
# INTACTO (14 entradas igual que el escenario 1) pero M10 realmente ausente → ROJO ─────────
registro_causal="$(construir_registro "${BASE_ENTRIES[@]}" M1 M2 M3 M4 M5 M6 M7 M8 M9 X "${PIECE_NEW[@]}")"
n_union="$(printf '%s\n' "$registro_union" | grep -c '^check ')"
n_causal="$(printf '%s\n' "$registro_causal" | grep -c '^check ')"
[ "$n_union" -eq "$n_causal" ] || bad "(4, precondición del fixture) cardinal debía coincidir: union=$n_union causal=$n_causal"
head4="$(commit_con_registro "$registro_causal" "$MAIN_SIDE" "$PIECE_SIDE")" || exit 2
out4="$(bash "$SCRIPT" "$head4" 2>&1)"; rc4=$?
if [ "$rc4" -eq 1 ] && printf '%s' "$out4" | grep -qE '^  · M10$'; then
  ok "(4) CAUSAL (pierde M10, añade X, cardinal intacto=$n_causal) -> ROJO (rc=1), M10 ausente — cierra el fail-open medido en el DoD (1)"
else
  bad "(4) esperaba rc=1 con M10 ausente pese a cardinal intacto, obtuve rc=$rc4:
$out4"
fi

# ── Escenario 5: ampliación legítima (head añade una entrada NUEVA además de la unión) →
# sigue VERDE — el control negativo en la otra dirección: más estricto no es correcto ──────
registro_ampliado="$(construir_registro "${BASE_ENTRIES[@]}" "${MAIN_NEW[@]}" "${PIECE_NEW[@]}" NUEVA)"
head5="$(commit_con_registro "$registro_ampliado" "$MAIN_SIDE" "$PIECE_SIDE")" || exit 2
out5="$(bash "$SCRIPT" "$head5" 2>&1)"; rc5=$?
if [ "$rc5" -eq 0 ]; then
  ok "(5) ampliación legítima (+1 entrada nueva) -> sigue VERDE (rc=0) — no se limita a ser más estricto"
else
  bad "(5) esperaba rc=0 (ampliación legítima), obtuve rc=$rc5:
$out5"
fi

# ── DoD (3) / cierre del rebase de DOS confirmaciones donde la
# PRIMERA reproducida ya pierde una entrada de main, y el head final (padre = esa primera
# confirmación) sigue sin ella. El padre inmediato del head NO es la base real — es la propia
# confirmación intermedia que ya perdió la entrada. Reproduce EXACTAMENTE el escenario que el
# auditor midió: con solo --piece-side (derivación vieja) esto daba rc=0 (falso verde); ahora
# ningún lado se deriva con 1 padre, así que hace falta --main-side real para detectarlo. ──────
NUEVA_BASE_REAL="$(commit_con_registro "$(construir_registro "${BASE_ENTRIES[@]}" "${MAIN_NEW[@]}")")" || exit 2  # {A,B,C,M1..M10}
PIEZA_PRE_REBASE="$(commit_con_registro "$(construir_registro "${BASE_ENTRIES[@]}" P1 P2)")" || exit 2  # {A,B,C,P1,P2}
primera_confirmacion="$(commit_con_registro "$(construir_registro "${BASE_ENTRIES[@]}" M1 M2 M3 M4 M5 M6 M7 M8 M9 P1)" "$NUEVA_BASE_REAL")" || exit 2  # M10 se pierde aquí
head_rebase_multi="$(commit_con_registro "$(construir_registro "${BASE_ENTRIES[@]}" M1 M2 M3 M4 M5 M6 M7 M8 M9 P1 P2)" "$primera_confirmacion")" || exit 2  # M10 sigue ausente

out_rb_sin="$(bash "$SCRIPT" "$head_rebase_multi" 2>&1)"; rc_rb_sin=$?
if [ "$rc_rb_sin" -eq 2 ] && printf '%s' "$out_rb_sin" | grep -qi "rebase"; then
  ok "(6) rebase multi-commit sin ningún lado -> fail-closed (rc=2), motivo explícito ('rebase')"
else
  bad "(6) esperaba rc=2 mencionando 'rebase', obtuve rc=$rc_rb_sin:
$out_rb_sin"
fi

# SOLO --piece-side (sin --main-side) ya NO debe dar un falso
# verde derivando main-side del padre inmediato (que ya perdió M10) — debe seguir fail-closed.
out_rb_solo_pieza="$(bash "$SCRIPT" "$head_rebase_multi" --piece-side "$PIEZA_PRE_REBASE" 2>&1)"; rc_rb_solo_pieza=$?
if [ "$rc_rb_solo_pieza" -eq 2 ] && printf '%s' "$out_rb_solo_pieza" | grep -qi "rebase"; then
  ok "(7) rebase multi-commit con SOLO --piece-side -> sigue fail-closed (rc=2) — cierra el falso verde del BLOQUEANTE "
else
  bad "(7) esperaba rc=2 (ya NO se deriva main-side del padre inmediato), obtuve rc=$rc_rb_solo_pieza:
$out_rb_solo_pieza"
fi

# Con AMBOS lados reales explícitos, la entrada perdida SÍ se detecta.
out_rb_ambos="$(bash "$SCRIPT" "$head_rebase_multi" --main-side "$NUEVA_BASE_REAL" --piece-side "$PIEZA_PRE_REBASE" 2>&1)"; rc_rb_ambos=$?
if [ "$rc_rb_ambos" -eq 1 ] && printf '%s' "$out_rb_ambos" | grep -qE '^  · M10$'; then
  ok "(8) rebase multi-commit con --main-side + --piece-side reales -> ROJO (rc=1), M10 ausente — el BLOQUEANTE queda cerrado y medido"
else
  bad "(8) esperaba rc=1 con M10 ausente, obtuve rc=$rc_rb_ambos:
$out_rb_ambos"
fi

# Camino verde de control: mismo rebase multi-commit, pero SIN pérdida (head final SÍ trae
# M10) — con ambos lados reales explícitos debe dar VERDE. Prueba que el fail-closed de arriba
# es por falta de dato, no un muro ciego que nunca deja pasar un rebase legítimo.
head_rebase_ok="$(commit_con_registro "$(construir_registro "${BASE_ENTRIES[@]}" "${MAIN_NEW[@]}" P1 P2)" "$primera_confirmacion")" || exit 2
out_rb_verde="$(bash "$SCRIPT" "$head_rebase_ok" --main-side "$NUEVA_BASE_REAL" --piece-side "$PIEZA_PRE_REBASE" 2>&1)"; rc_rb_verde=$?
if [ "$rc_rb_verde" -eq 0 ]; then
  ok "(9) rebase multi-commit SIN pérdida, ambos lados explícitos -> VERDE (rc=0)"
else
  bad "(9) esperaba rc=0, obtuve rc=$rc_rb_verde:
$out_rb_verde"
fi

# ── --main-side/--piece-side como ÚLTIMO argumento (sin valor detrás) ──
# ya NO cuelga (antes: shift 2 fallaba en silencio sin set -e, bucle infinito) — ahora rc=2
# inmediato con diagnóstico. timeout de sobra (5s) por si el fix no cerrara el bucle de verdad.
out_sin_valor_main="$(timeout 5 bash "$SCRIPT" "$head1" --main-side 2>&1)"; rc_sin_valor_main=$?
if [ "$rc_sin_valor_main" -eq 2 ] && printf '%s' "$out_sin_valor_main" | grep -qi "requiere un valor"; then
  ok "(10) --main-side sin valor (último argumento) -> fail-closed inmediato (rc=2), sin colgarse"
else
  bad "(10) esperaba rc=2 'requiere un valor', obtuve rc=$rc_sin_valor_main (rc=124 = SIGUE COLGADO):
$out_sin_valor_main"
fi

out_sin_valor_piece="$(timeout 5 bash "$SCRIPT" "$head1" --piece-side 2>&1)"; rc_sin_valor_piece=$?
if [ "$rc_sin_valor_piece" -eq 2 ] && printf '%s' "$out_sin_valor_piece" | grep -qi "requiere un valor"; then
  ok "(11) --piece-side sin valor (último argumento) -> fail-closed inmediato (rc=2), sin colgarse"
else
  bad "(11) esperaba rc=2 'requiere un valor', obtuve rc=$rc_sin_valor_piece (rc=124 = SIGUE COLGADO):
$out_sin_valor_piece"
fi

# ── Contrato (a): descripciones duplicadas dentro de un mismo lado -> fail-closed ──────────
registro_dup="$(construir_registro "${BASE_ENTRIES[@]}" A "${MAIN_NEW[@]}")"   # "A" repetida
head_dup="$(commit_con_registro "$registro_dup" "$MAIN_SIDE" "$PIECE_SIDE")" || exit 2
# el duplicado vive en el registro sintético "head_dup"; se aísla el contrato (a) apuntando
# --main-side directamente a ese commit, sin depender del resto de la mecánica de unión:
out_dup2="$(bash "$SCRIPT" "$head_dup" --main-side "$head_dup" --piece-side "$PIECE_SIDE" 2>&1)"; rc_dup2=$?
if [ "$rc_dup2" -eq 1 ] && printf '%s' "$out_dup2" | grep -qi "duplicada"; then
  ok "(12) descripción duplicada dentro de un lado -> fail-closed, motivo explícito ('duplicada')"
else
  bad "(12) esperaba rc=1 mencionando 'duplicada', obtuve rc=$rc_dup2:
$out_dup2"
fi

# ── Mutante: neutraliza la comparación de conjunto (comm -23 -> siempre vacío) y confirma
# que el escenario CAUSAL (4) deja de detectarse — el arnés MUERDE donde se declara ─────────
# El mutante se coloca DENTRO de scripts/ (misma profundidad que el original), no en /tmp: el
# propio script auto-localiza REPO_ROOT vía BASH_SOURCE/dirname/.. — copiarlo a otra
# profundidad rompería esa resolución y el fallo sería del arnés, no del mutante.
MUT_SCRIPT="$(mktemp -p "$REPO_ROOT/scripts" mut-tal5435-XXXXXX.sh)"
trap 'rm -rf "$FIX_REPO"' EXIT
# shellcheck disable=SC2016  # comillas simples deliberadas: el patrón busca el '$' literal
sed 's#perdidas="\$(comm -23.*#perdidas=""#' "$SCRIPT" > "$MUT_SCRIPT"
if diff -q "$SCRIPT" "$MUT_SCRIPT" >/dev/null 2>&1; then
  bad "(mutante, pre-check) el sed no produjo ningún cambio — el mutante no ejecuta una línea distinta"
elif ! bash -n "$MUT_SCRIPT" 2>/dev/null; then
  bad "(mutante, pre-check) el mutante generado no es sintácticamente válido"
else
  ok "(mutante, pre-check) comparación de conjunto neutralizada (diff confirmado)"
  chmod +x "$MUT_SCRIPT"
  out_mut="$(bash "$MUT_SCRIPT" "$head4" 2>&1)"; rc_mut=$?
  if [ "$rc_mut" -eq 0 ]; then
    ok "(mutante) MUERDE: sin la comparación real, el caso causal (4) pasa a VERDE falso — el arnés lo detectaría"
  else
    bad "(mutante) esperaba que el mutante diera rc=0 (falso verde) en el caso causal, obtuve rc=$rc_mut:
$out_mut"
  fi
fi
rm -f "$MUT_SCRIPT"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "[test-check-run-tests-registry] TODOS los casos OK"
  exit 0
fi
echo "[test-check-run-tests-registry] hubo fallos" >&2
exit 1
