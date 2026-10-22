#!/usr/bin/env bash
# tests/test-check-function-clobber.sh — Self-test de scripts/check-function-clobber.sh.
# Lo EJECUTA tests/run-tests.sh: un test que nadie corre no es una prueba, es un fichero.
#
# Construye commits sintéticos (base / lado-pieza / lado-main) con plumbing puro de git
# (hash-object + índice scratch + commit-tree) — CERO cambios al working tree, a HEAD o a
# cualquier rama real.
set -uo pipefail

# Identidad de git EXPLÍCITA: `git commit-tree` la exige y un runner limpio de CI
# (actions/checkout) no la configura. Sin esto el arnés pasa en estación y falla en Actions —
# exactamente el fallo que costó una vuelta entera del gate en TAL-5435.
export GIT_AUTHOR_NAME="clobber-selftest"
export GIT_AUTHOR_EMAIL="clobber-selftest@localhost"
export GIT_COMMITTER_NAME="clobber-selftest"
export GIT_COMMITTER_EMAIL="clobber-selftest@localhost"

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/check-function-clobber.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT no existe o no es ejecutable"; exit 2; }

FAIL=0
ok()  { echo "  PASS  $1"; }
bad() { echo "  FAIL  $1" >&2; FAIL=1; }

TMP="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 2; }
trap 'rm -rf "$TMP"' EXIT

# Repo sintético propio: aislado del repo real, sin depender de su historia ni de su estado.
SYN="$TMP/repo"
git init -q "$SYN" 2>/dev/null || { echo "FAIL: git init"; exit 2; }
git -C "$SYN" config user.name clobber-selftest
git -C "$SYN" config user.email clobber-selftest@localhost

# commit_con <padre|""> <ruta1> <contenido1> [<ruta2> <contenido2> ...] -> imprime el sha
# Construye un commit que HEREDA el árbol del padre y añade/reemplaza las rutas indicadas.
commit_con() {
  local padre="$1"; shift
  local idx="$TMP/idx.$$"; rm -f "$idx"
  if [ -n "$padre" ]; then
    GIT_INDEX_FILE="$idx" git -C "$SYN" read-tree "$padre" || return 1
  else
    GIT_INDEX_FILE="$idx" git -C "$SYN" read-tree --empty || return 1
  fi
  while [ $# -ge 2 ]; do
    local ruta="$1" contenido="$2"; shift 2
    local blob
    blob="$(printf '%s' "$contenido" | git -C "$SYN" hash-object -w --stdin)" || return 1
    GIT_INDEX_FILE="$idx" git -C "$SYN" update-index --add --cacheinfo "100644,$blob,$ruta" || return 1
  done
  local tree; tree="$(GIT_INDEX_FILE="$idx" git -C "$SYN" write-tree)" || return 1
  local -a args=("$tree")
  [ -n "$padre" ] && args+=(-p "$padre")
  git -C "$SYN" commit-tree "${args[@]}" -m "sintético clobber" || return 1
}

correr() { # <base> <head> <main> -> imprime salida, devuelve rc
  ( cd "$SYN" && bash "$SCRIPT" --base "$1" --head "$2" --main "$3" 2>&1 )
}

sql_fn() { # <nombre_función> -> cuerpo mínimo de migración que la redefine
  printf 'create or replace function %s()\nreturns void language sql as $$ select 1 $$;\n' "$1"
}

echo "== TAL-CLOBBER: check-function-clobber.sh — pisada silenciosa de funciones SQL =="

BASE="$(commit_con "" "supabase/migrations/000_base.sql" "$(sql_fn app_internal.otra)" "README.md" "base")" \
  || { echo "FAIL: no pude crear el commit base"; exit 2; }

# (1) La pieza redefine f; main NO tocó nada -> VERDE.
HEAD1="$(commit_con "$BASE" "supabase/migrations/010_pieza.sql" "$(sql_fn app_internal.f)")"
out="$(correr "$BASE" "$HEAD1" "$BASE")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "(1) pieza redefine f, main no la tocó -> VERDE (rc=0)"
else bad "(1) esperaba rc=0, obtuve rc=$rc: $out"; fi

# (2) CAUSAL (el caso #2264 vs #2253): ambas redefinen la MISMA función, en ficheros DISTINTOS
#     -> git no vería conflicto, pero esto es una pisada -> ROJO con la función listada.
MAIN2="$(commit_con "$BASE" "supabase/migrations/005_main.sql" "$(sql_fn app_internal.f)")"
out="$(correr "$BASE" "$HEAD1" "$MAIN2")"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'app_internal.f'; then
  ok "(2) CAUSAL: misma función en ficheros distintos -> ROJO (rc=1) con app_internal.f listada"
else bad "(2) esperaba rc=1 listando app_internal.f, obtuve rc=$rc: $out"; fi

# (3) Selectividad: la pieza redefine f y g; main sólo tocó g -> ROJO listando SOLO g.
HEAD3="$(commit_con "$BASE" "supabase/migrations/010_pieza.sql" "$(sql_fn app_internal.f)$(sql_fn app_internal.g)")"
MAIN3="$(commit_con "$BASE" "supabase/migrations/005_main.sql" "$(sql_fn app_internal.g)")"
out="$(correr "$BASE" "$HEAD3" "$MAIN3")"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'app_internal.g' && ! printf '%s' "$out" | grep -q 'app_internal\.f$'; then
  ok "(3) selectivo: lista SOLO la función pisada (g), no la limpia (f)"
else bad "(3) esperaba rc=1 listando sólo g, obtuve rc=$rc: $out"; fi

# (4) Lo que main tocó ANTES de la base NO es pisada: la pieza ya partió de ese trabajo.
BASE4="$(commit_con "$MAIN2" "README.md" "base posterior")"
HEAD4="$(commit_con "$BASE4" "supabase/migrations/010_pieza.sql" "$(sql_fn app_internal.f)")"
out="$(correr "$BASE4" "$HEAD4" "$MAIN2")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "(4) main tocó f ANTES de la base -> VERDE (no es pisada)"
else bad "(4) esperaba rc=0, obtuve rc=$rc: $out"; fi

# (5) Pieza sin SQL -> VERDE (nada que comparar), no un falso rojo.
HEAD5="$(commit_con "$BASE" "docs/nota.md" "sin sql")"
out="$(correr "$BASE" "$HEAD5" "$MAIN2")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "(5) pieza sin SQL -> VERDE (nada que comparar)"
else bad "(5) esperaba rc=0, obtuve rc=$rc: $out"; fi

# (6) Una LÍNEA DE COMENTARIO que menciona la frase no declara nada -> no dispara.
#     Defecto real encontrado al probar el guard contra el repo de producto: las migraciones se
#     documentan a sí mismas y mencionan `create or replace function` en prosa.
HEAD6="$(commit_con "$BASE" "supabase/migrations/010_pieza.sql" \
  "-- \`create or replace function\` NO preserva los grants, por eso se re-especifican.
$(sql_fn app_internal.h)")"
out="$(correr "$BASE" "$HEAD6" "$BASE")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "(6) comentario que MENCIONA la frase -> no dispara (verde)"
else bad "(6) esperaba rc=0, obtuve rc=$rc: $out"; fi

# (7) FAIL-CLOSED-ON-UNKNOWN: declara redefinición pero sin identidad en la línea -> rc=2, no se ignora.
HEAD7="$(commit_con "$BASE" "supabase/migrations/010_pieza.sql" \
  "create or replace function
  app_internal.partida() returns void language sql as \$\$ select 1 \$\$;")"
out="$(correr "$BASE" "$HEAD7" "$BASE")"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'sin identidad extraíble'; then
  ok "(7) 'create or replace function' sin identidad en la línea -> fail-closed (rc=2), no se ignora"
else bad "(7) esperaba rc=2 'sin identidad extraíble', obtuve rc=$rc: $out"; fi

# (8) Ref irresoluble -> fail-closed, nunca se adivina.
out="$( cd "$SYN" && bash "$SCRIPT" --base "$BASE" --head no-existe-jamas --main "$BASE" 2>&1 )"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'no resuelve'; then
  ok "(8) ref irresoluble -> fail-closed (rc=2)"
else bad "(8) esperaba rc=2 'no resuelve', obtuve rc=$rc: $out"; fi

# (9) Bandera sin valor -> rc=2 y NO se cuelga esperando argumento.
out="$( cd "$SYN" && timeout 10 bash "$SCRIPT" --base "$BASE" --head 2>&1 )"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'requiere un valor'; then
  ok "(9) --head sin valor -> rc=2 'requiere un valor', sin colgarse"
else bad "(9) esperaba rc=2 'requiere un valor', obtuve rc=$rc (124 = colgado): $out"; fi

# (10) Sin --main y sin main/origin-main derivables -> fail-closed, no se inventa el tronco.
out="$( cd "$SYN" && bash "$SCRIPT" --base "$BASE" --head "$HEAD1" 2>&1 )"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'no se adivina el tronco'; then
  ok "(10) sin --main y sin tronco derivable -> fail-closed (rc=2)"
else bad "(10) esperaba rc=2 'no se adivina el tronco', obtuve rc=$rc: $out"; fi

# (MUTANTE) Si se neutraliza la intersección, el caso CAUSAL (2) pasa a VERDE falso. El arnés
# debe ser capaz de detectarlo: un test que no muere con el mutante no está midiendo nada.
MUT="$REPO_ROOT/scripts/mut-clobber-$$.sh"
sed 's/^COLISION="\$(comm -12.*/COLISION=""/' "$SCRIPT" > "$MUT"
chmod +x "$MUT"
if ! diff -q "$SCRIPT" "$MUT" >/dev/null 2>&1; then
  ok "(mutante, pre-check) intersección neutralizada (diff confirmado)"
else
  bad "(mutante, pre-check) el sed NO cambió nada — el mutante no prueba nada"
fi
out="$( cd "$SYN" && bash "$MUT" --base "$BASE" --head "$HEAD1" --main "$MAIN2" 2>&1 )"; rc=$?
rm -f "$MUT"
if [ "$rc" -eq 0 ]; then
  ok "(mutante) MUERDE: sin la intersección real, el caso causal (2) da VERDE falso — el arnés lo detectaría"
else
  bad "(mutante) esperaba rc=0 (falso verde) en el caso causal, obtuve rc=$rc: $out"
fi

echo
if [ "$FAIL" -eq 0 ]; then echo "[test-check-function-clobber] TODOS los casos OK"; exit 0; fi
echo "[test-check-function-clobber] hubo fallos" >&2; exit 1
