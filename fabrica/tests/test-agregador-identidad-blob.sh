#!/usr/bin/env bash
# tests/test-agregador-identidad-blob.sh — TAL-6674. Self-test de `bt_prepara()`/`bt_merge_tree()`
# en post-local-gates.sh: la trampa ancestria-por-contenido y su cierre con `git merge-tree
# --write-tree`, anclando las dos puntas al MISMO `HEAD_SHA` (segunda vuelta: la primera version,
# que comparaba `rbt` contra `BASE_TIP_SHA` a secas, tenia un blind spot real — ver caso 3). Lo
# EJECUTA tests/run-tests.sh: un test que nadie corre no es una prueba, es un fichero.
#
# QUÉ NO ES ESTE ARNÉS: no reproduce los fixtures reales de M1 (casos históricos) — no viven en este
# repo y la reconstruccion del par exacto no convergio (ver HANDOFF, seccion Limite conocido).
# Mide la PROPIEDAD del parche con fixtures git REALES y propios, incluida la reproduccion del
# defecto original (con la funcion VIEJA) y de un segundo defecto encontrado auditando contra los
# arboles reales de M1 antes de descartarlos como oraculo exacto.
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PLG="$REPO_ROOT/scripts/post-local-gates.sh"
[ -r "$PLG" ] || { echo "FAIL: no encuentro $PLG"; exit 2; }

FAIL=0
ok()  { echo "  PASS  $1"; }
bad() { echo "  FAIL  $1" >&2; FAIL=1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/tal6674-XXXXXXXX")"
trap 'rm -rf "$T"' EXIT

# ── Extracción del sujeto REAL, no reescrito de memoria ─────────────────────────────────────────
# El ancla cierra en el `}` de `bt_prepara`, la SEGUNDA función del bloque (la primera es el
# helper `bt_merge_tree`) — se busca la línea de apertura de `bt_prepara` y se corta en su cierre.
BT_NEW="$T/bt_new.sh"
ini="$(grep -n '^BT_KEY=""; BT_ANCESTRO=""; BT_CHURN=""$' "$PLG" | head -1 | cut -d: -f1)"
fin_prepara="$(awk -v s="$ini" 'NR>=s && /^bt_prepara\(\) \{/{p=1} p && /^}$/{print NR; exit}' "$PLG")"
[ -n "$ini" ] && [ -n "$fin_prepara" ] && sed -n "${ini},${fin_prepara}p" "$PLG" > "$BT_NEW"
[ -s "$BT_NEW" ] || { echo "FAIL: no pude extraer bt_prepara()/bt_merge_tree() de $PLG (ancla movida)"; exit 2; }
# shellcheck source=/dev/null
. "$BT_NEW"
declare -f bt_prepara >/dev/null 2>&1 && declare -f bt_merge_tree >/dev/null 2>&1 \
  && ok "bt_prepara() y bt_merge_tree() se extrajeron del fichero REAL" \
  || { bad "extracción incompleta — ancla rota"; exit 1; }

# La función VIEJA-VIEJA (por ancestría, anterior a TODO este rebote) reconstruida a mano, para
# demostrar el PRIMER defecto que cierra este parche.
bt_prepara_ancestria() {
  local rbt="$1"
  BT_CHURN=""
  [ -n "$rbt" ] || { BT_ANCESTRO="ausente"; return 1; }
  git -C "$CLONE" cat-file -e "${rbt}^{commit}" 2>/dev/null || { BT_ANCESTRO="no está en el clon"; return 1; }
  git -C "$CLONE" merge-base --is-ancestor "$rbt" "$BASE_TIP_SHA" 2>/dev/null \
    || { BT_ANCESTRO="NO es ancestro"; return 1; }
  BT_CHURN="$(git -C "$CLONE" diff --name-only "$rbt" "$BASE_TIP_SHA" 2>/dev/null)"
  BT_ANCESTRO=ok; return 0
}

# La función de la PRIMERA vuelta de TAL-6674 (merge-tree de `rbt` contra `BASE_TIP_SHA` a secas,
# SIN `HEAD_SHA`) — cerraba el defecto de ancestría, pero tenía un SEGUNDO defecto (caso 3).
bt_prepara_sin_head() {
  local rbt="$1" mt_out mt_rc=0 mt_tree
  BT_CHURN=""
  [ -n "$rbt" ] || { BT_ANCESTRO="ausente"; return 1; }
  git -C "$CLONE" cat-file -e "${rbt}^{commit}" 2>/dev/null || { BT_ANCESTRO="no está en el clon"; return 1; }
  mt_out="$(git -C "$CLONE" merge-tree --write-tree "$rbt" "$BASE_TIP_SHA" 2>/dev/null)"; mt_rc=$?
  case "$mt_rc" in 0|1) : ;; *) BT_ANCESTRO="merge-tree rc=$mt_rc"; return 1 ;; esac
  mt_tree="$(printf '%s\n' "$mt_out" | head -1)"
  BT_CHURN="$(git -C "$CLONE" diff --name-only "$rbt" "$mt_tree" 2>/dev/null)"
  BT_ANCESTRO=ok; return 0
}

# ── Fixture base: un repo real con UNA unidad propia (H = HEAD_SHA) y varios estados de "main" ──
CLONE="$T/repo"; mkdir -p "$CLONE"
git -C "$CLONE" init -q
git -C "$CLONE" config user.email a@b; git -C "$CLONE" config user.name a
mkdir -p "$CLONE/src" "$CLONE/docs"
printf 'export const x = 1;\n' > "$CLONE/src/main.ts"
printf '{"name":"x"}\n' > "$CLONE/package.json"
printf '# notas\n' > "$CLONE/docs/notas.md"
git -C "$CLONE" add -A && git -C "$CLONE" commit -qm root
ROOT="$(git -C "$CLONE" rev-parse HEAD)"

# H: la unidad que se está agregando (HEAD_SHA), constante en todo el arnés — su propio branch,
# SIN fundir con nada de main todavía.
git -C "$CLONE" checkout -q -B unidad "$ROOT"
printf 'export const feature = true;\n' > "$CLONE/src/feature.ts"
git -C "$CLONE" add -A && git -C "$CLONE" commit -qm "feature propia"
HEAD_SHA="$(git -C "$CLONE" rev-parse HEAD)"
git -C "$CLONE" checkout -q -B main "$ROOT" >/dev/null

_uni_universal="$(printf '%s\n' '^package\.json$')"

# ── 1. CONTROL sano: rbt=ROOT, BASE_TIP=ROOT+avance normal (ancestro real) ──────────────────────
git -C "$CLONE" checkout -q -B main-sano "$ROOT"
printf 'export const x = 2;\n' > "$CLONE/src/main.ts"
git -C "$CLONE" commit -qam "avance normal, ancestro real"
BASE_SANO="$(git -C "$CLONE" rev-parse HEAD)"
BASE_TIP_SHA="$BASE_SANO"
BT_KEY=""; BT_ANCESTRO=""; BT_CHURN=""
bt_prepara "$ROOT"; rc_sano=$?
[ "$rc_sano" = "0" ] && ok "CONTROL sano: ancestro real sigue aceptándose (rc=0)" \
  || bad "CONTROL sano roto: rc=$rc_sano ($BT_ANCESTRO)"
case "$BT_CHURN" in *src/main.ts*) ok "  y el churn ve el cambio real (src/main.ts)";; *) bad "  el churn no vio src/main.ts: '$BT_CHURN'";; esac

# ── 2. LA PROPIEDAD (squash byte-idéntico): ancestría rota, contenido idéntico → usable ─────────
git -C "$CLONE" checkout -q main >/dev/null
git -C "$CLONE" commit -q --allow-empty -m "rbt: tip cuando corrió el receipt"
RBT_SQ="$(git -C "$CLONE" rev-parse HEAD)"
RBT_SQ_TREE="$(git -C "$CLONE" rev-parse "$RBT_SQ^{tree}")"
SQUASH="$(git -C "$CLONE" commit-tree "$RBT_SQ_TREE" -p "$ROOT" -m "squash: mismo arbol, otro padre")"
! git -C "$CLONE" merge-base --is-ancestor "$RBT_SQ" "$SQUASH" 2>/dev/null \
  && ok "PRECONDICIÓN: rbt NO es ancestro del squash (la ancestría SÍ está rota)" \
  || { bad "PRECONDICIÓN rota: el squash no rompió la ancestría"; exit 2; }
BASE_TIP_SHA="$SQUASH"
bt_prepara_ancestria "$RBT_SQ"; rc_vieja=$?
[ "$rc_vieja" = "1" ] && ok "MUTANTE ATERRIZA (defecto 1, ancestría): la función VIEJA rechaza un árbol byte-idéntico (rc=1: $BT_ANCESTRO)" \
  || bad "la función vieja-vieja no reprodujo el defecto 1 (rc=$rc_vieja)"
BT_KEY=""; BT_ANCESTRO=""; BT_CHURN=""
bt_prepara "$RBT_SQ"; rc_nueva=$?
[ "$rc_nueva" = "0" ] && ok "LA PROPIEDAD: árbol byte-idéntico → usable pese a ancestría rota (rc=0)" \
  || bad "la función nueva rechazó un árbol byte-idéntico (rc=$rc_nueva, motivo: $BT_ANCESTRO)"
[ -z "$BT_CHURN" ] && ok "  y el churn de blobs es VACÍO (no hay diferencia de contenido)" \
  || bad "  churn no vacío pese a árboles idénticos: '$BT_CHURN'"

# ── 3. DEFECTO 2, encontrado validando contra los árboles reales de M1: BASE_TIP_SHA ANCESTRO ───
# de `rbt` (main "detrás" de lo que ya se probó) colapsaba a churn VACÍO en la primera vuelta de
# este mismo rebote (comparar `rbt` contra `BASE_TIP_SHA` sin `HEAD_SHA`), aunque hubiera contenido
# real de diferencia. Medido contra un caso real de M1: 52 ficheros de diferencia real, churn 0.
git -C "$CLONE" checkout -q -B main-adelantado "$ROOT" >/dev/null
mkdir -p "$CLONE/supabase"
printf 'select 1;\n' > "$CLONE/supabase/otro.sql"
git -C "$CLONE" add -A && git -C "$CLONE" commit -qm "avance ya visto por el receipt"
RBT_ADEL="$(git -C "$CLONE" rev-parse HEAD)"
git -C "$CLONE" merge-base --is-ancestor "$ROOT" "$RBT_ADEL" 2>/dev/null \
  && ok "PRECONDICIÓN: BASE_TIP (ROOT) SÍ es ancestro de rbt (main va «detrás»)" \
  || { bad "PRECONDICIÓN rota: ROOT no es ancestro de RBT_ADEL"; exit 2; }
BASE_TIP_SHA="$ROOT"
bt_prepara_sin_head "$RBT_ADEL"; rc_sinh=$?
{ [ "$rc_sinh" = "0" ] && [ -z "$BT_CHURN" ]; } \
  && ok "MUTANTE ATERRIZA (defecto 2): la función SIN HEAD_SHA colapsa a churn VACÍO (rc=0) aunque main vaya detrás" \
  || bad "la función sin HEAD_SHA no reprodujo el defecto 2 (rc=$rc_sinh, churn='$BT_CHURN')"
BT_KEY=""; BT_ANCESTRO=""; BT_CHURN=""
bt_prepara "$RBT_ADEL"; rc_conh=$?
[ "$rc_conh" = "0" ] && ok "LA PROPIEDAD (defecto 2 cerrado): rc=0, pero con churn REAL" \
  || bad "con HEAD_SHA, main-detrás se rechazó cuando no debía (rc=$rc_conh: $BT_ANCESTRO)"
case "$BT_CHURN" in *supabase/otro.sql*) ok "  y el churn SÍ ve la diferencia real (supabase/otro.sql)";; *) bad "  el churn sigue vacío: '$BT_CHURN'";; esac

# ── 4. INSUMO UNIVERSAL: sigue caducando TODO el run_group cuando cambia de verdad ──────────────
git -C "$CLONE" checkout -q -B main-universal "$ROOT" >/dev/null
printf '{"name":"x","v":2}\n' > "$CLONE/package.json"
git -C "$CLONE" commit -qam "toca un insumo universal"
BASE_UNI="$(git -C "$CLONE" rev-parse HEAD)"
BASE_TIP_SHA="$BASE_UNI"
BT_KEY=""; BT_ANCESTRO=""; BT_CHURN=""
bt_prepara "$ROOT"; rc_uni=$?
[ "$rc_uni" = "1" ] && ok "insumo universal tocado → caduca (rc=1)" || bad "no caducó con insumo universal tocado (rc=$rc_uni)"
case "$BT_ANCESTRO" in *"INSUMO UNIVERSAL"*package.json*) ok "  motivo nombra el insumo (package.json)";; *) bad "  motivo no nombra el insumo: $BT_ANCESTRO";; esac
case "$BT_ANCESTRO" in *"CONFLICTO SIN RESOLVER"*) bad "  falso positivo de conflicto (no lo había)";; *) ok "  y NO lo confunde con un conflicto sin resolver";; esac

# ── 5. CONFLICTO REAL en el insumo universal: se detecta por el ÁRBOL, no por stdout ────────────
# Aquí la UNIDAD (HEAD_SHA) también toca el insumo, de forma incompatible con lo que hace main.
git -C "$CLONE" checkout -q -B unidad-conflicto "$ROOT" >/dev/null
printf '{"name":"x-DE-LA-UNIDAD"}\n' > "$CLONE/package.json"
git -C "$CLONE" add -A && git -C "$CLONE" commit -qm "la unidad tambien toca package.json"
HEAD_CONFLICTO="$(git -C "$CLONE" rev-parse HEAD)"
git -C "$CLONE" checkout -q -B main-conflicto "$ROOT" >/dev/null
printf '{"name":"x-DE-MAIN"}\n' > "$CLONE/package.json"
git -C "$CLONE" add -A && git -C "$CLONE" commit -qm "main tambien toca package.json"
BASE_CONFLICTO="$(git -C "$CLONE" rev-parse HEAD)"
HEAD_SHA_REAL="$HEAD_SHA"; HEAD_SHA="$HEAD_CONFLICTO"; BASE_TIP_SHA="$BASE_CONFLICTO"
BT_KEY=""; BT_ANCESTRO=""; BT_CHURN=""
bt_prepara "$ROOT"; rc_conf=$?
HEAD_SHA="$HEAD_SHA_REAL"
[ "$rc_conf" = "1" ] && ok "conflicto real en insumo universal → caduca igualmente (rc=1)" \
  || bad "conflicto real no caducó (rc=$rc_conf)"
case "$BT_ANCESTRO" in *"CONFLICTO SIN RESOLVER"*) ok "  y el motivo dice CONFLICTO SIN RESOLVER (leído del árbol)";; *) bad "  no distinguió el conflicto real: $BT_ANCESTRO";; esac

# ── 6. LOS TRES NO-MEDIDO FAIL-CLOSED, con mutantes de \`git\` ──────────────────────────────────
BASE_TIP_SHA="$BASE_SANO"
FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN"
REALGIT="$(command -v git)"

# (a) merge-tree devuelve rc≠{0,1} (herramienta rota) — dispara en el PRIMER merge-tree (TESTADO).
cat > "$FAKEBIN/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "merge-tree" ] && exit 7; done
exec "$REALGIT" "\$@"
EOF
chmod +x "$FAKEBIN/git"
BT_KEY=""; BT_ANCESTRO=""; BT_CHURN=""
PATH="$FAKEBIN:$PATH" bt_prepara "$ROOT" >/dev/null 2>&1; rc_a=$?
[ "$rc_a" = "1" ] && ok "NO MEDIDO (a): merge-tree rc=7 → rechazado" || bad "NO MEDIDO (a) no disparó (rc=$rc_a)"
case "$BT_ANCESTRO" in *"NO MEDIDO"*) ok "  y lo dice NO MEDIDO, no lo confunde con limpio ni con conflicto";; *) bad "  motivo no dice NO MEDIDO: $BT_ANCESTRO";; esac

# (b) merge-tree "funciona" (rc 0) pero no imprime un oid reconocible.
cat > "$FAKEBIN/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "merge-tree" ] && { echo "no-soy-un-oid"; exit 0; }; done
exec "$REALGIT" "\$@"
EOF
chmod +x "$FAKEBIN/git"
BT_KEY=""; BT_ANCESTRO=""; BT_CHURN=""
PATH="$FAKEBIN:$PATH" bt_prepara "$ROOT" >/dev/null 2>&1; rc_b=$?
[ "$rc_b" = "1" ] && ok "NO MEDIDO (b): salida sin oid reconocible → rechazado" || bad "NO MEDIDO (b) no disparó (rc=$rc_b)"
case "$BT_ANCESTRO" in *"NO MEDIDO"*) ok "  y lo dice NO MEDIDO";; *) bad "  motivo no dice NO MEDIDO: $BT_ANCESTRO";; esac

# (c) el árbol resultante no se puede leer del clon (cat-file -e falla para ese oid).
cat > "$FAKEBIN/git" <<EOF
#!/usr/bin/env bash
args=("\$@")
for i in "\${!args[@]}"; do
  if [ "\${args[\$i]}" = "cat-file" ] && [ "\${args[\$i+1]:-}" = "-e" ]; then
    case "\${args[\$i+2]:-}" in *"^{tree}") exit 1 ;; esac
  fi
done
exec "$REALGIT" "\$@"
EOF
chmod +x "$FAKEBIN/git"
BT_KEY=""; BT_ANCESTRO=""; BT_CHURN=""
PATH="$FAKEBIN:$PATH" bt_prepara "$ROOT" >/dev/null 2>&1; rc_c=$?
[ "$rc_c" = "1" ] && ok "NO MEDIDO (c): árbol resultante ilegible → rechazado" || bad "NO MEDIDO (c) no disparó (rc=$rc_c)"
case "$BT_ANCESTRO" in *"NO MEDIDO"*) ok "  y lo dice NO MEDIDO";; *) bad "  motivo no dice NO MEDIDO: $BT_ANCESTRO";; esac

# ── 7. AUSENCIA DE TUBERÍA: el rc de merge-tree se lee de la variable, no del último eslabón ────
if grep -nE 'merge-tree --write-tree' "$PLG" | grep -v '^\s*#' | grep -q '|'; then
  bad "hay una tubería en la línea de merge-tree"
else
  ok "AUSENCIA DE TUBERÍA: ninguna invocación de merge-tree va seguida de '|'"
fi

# ── 8. Los marcadores NUNCA se leen de stdout/mensajes: sin grep del TEXTO que emite git ────────
# Anclado a las cadenas EXACTAS de `merge-tree` («CONFLICT (» con el paréntesis, «Auto-merging»),
# no a la palabra española «conflicto» de nuestros propios mensajes (falso positivo descartado).
if grep -nE 'CONFLICT \(|Auto-merging' "$PLG" | grep -q .; then
  bad "el sujeto contiene un grep del texto literal que emite merge-tree (CONFLICT (/Auto-merging)"
else
  ok "sin parseo de texto: cero coincidencias de los mensajes literales de merge-tree"
fi

# ── 9. TAL-6733: SIGPIPE/pipefail no garbla el diagnóstico con un blob GRANDE ────────────────────
# Misma clase que TAL-6719 (l)/(m) en `_pr_disjunto_de`/`_blob_tiene_conflicto`: aquí vive en
# `bt_prepara` mismo. `git cat-file -p "$hit_oid" | grep -qF '<<<<<<<'` como última pieza de una
# tubería bajo `set -o pipefail` recibe SIGPIPE (141) si `grep -q` cierra su stdin al primer match
# — con un blob GRANDE (~3MB) y el marcador al PRINCIPIO, `cat-file` todavía tiene ~3MB por escribir
# cuando `grep -q` ya vio su match y cierra, disparando la carrera real (buffer de tubería « 3MB).
# El `if` caía entonces al `else`: el motivo decía "toca un INSUMO UNIVERSAL" en vez de "CONFLICTO
# SIN RESOLVER" — mensaje equivocado, oráculo intacto (ambas ramas `return 1`, sin false-accept).
BIG="$T/big-conflict-package.json"
{ printf '<<<<<<< HEAD\n'; head -c 3000000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$BIG"
big_oid="$(git -C "$CLONE" hash-object -w "$BIG")"
root_tree="$(git -C "$CLONE" rev-parse "$ROOT^{tree}")"
big_tree="$(git -C "$CLONE" ls-tree "$root_tree" \
  | awk -F'\t' '$2 != "package.json"' \
  | { cat; printf '100644 blob %s\tpackage.json\n' "$big_oid"; } \
  | git -C "$CLONE" mktree)"

RBT_SIGPIPE="$ROOT"
git -C "$CLONE" checkout -q -B main-sigpipe "$ROOT" >/dev/null
printf '# irrelevante\n' >> "$CLONE/docs/notas.md"
git -C "$CLONE" commit -qam "avance irrelevante — el mutante fuerza el árbol de aterrizaje"
BASE_TIP_SIGPIPE="$(git -C "$CLONE" rev-parse HEAD)"

# Discrimina por el PAR COMPLETO de argumentos de `merge-tree --write-tree <a> <b>` (posicional:
# `git -C "$CLONE" merge-tree --write-tree "$a" "$b"` → $1=-C $2=CLONE $3=merge-tree
# $4=--write-tree $5=a $6=b), NUNCA por orden de llamada — un contador en variable de shell no
# sobrevive al subshell de `$(...)` con que `bt_prepara` invoca `bt_merge_tree` dos veces.
cat > "$FAKEBIN/git" <<EOF
#!/usr/bin/env bash
if [ "\$3" = "merge-tree" ] && [ "\$4" = "--write-tree" ]; then
  case "\$5:\$6" in
    "$RBT_SIGPIPE:$HEAD_SHA") echo "$root_tree"; exit 0 ;;
    "$BASE_TIP_SIGPIPE:$HEAD_SHA") echo "$big_tree"; exit 0 ;;
  esac
fi
exec "$REALGIT" "\$@"
EOF
chmod +x "$FAKEBIN/git"

BASE_TIP_SHA="$BASE_TIP_SIGPIPE"
# shellcheck disable=SC2034 # BT_KEY: última escritura, leída como memoización dentro de bt_prepara (sourceada en $BT_NEW) — necesaria para invalidar la caché de casos anteriores, no un reset muerto
BT_KEY=""; BT_ANCESTRO=""; BT_CHURN=""
PATH="$FAKEBIN:$PATH" bt_prepara "$RBT_SIGPIPE"; rc_sigpipe=$?

case "$rc_sigpipe" in
  1) ok "(9) blob grande (~3MB) con conflicto real: sigue caducando (rc=1)" ;;
  *) bad "(9) blob grande con conflicto: rc inesperado ($rc_sigpipe)" ;;
esac
case "$BT_CHURN" in package.json) ok "  y el churn ve exactamente package.json";; *) bad "  churn inesperado: '$BT_CHURN'";; esac
case "$BT_ANCESTRO" in
  *"CONFLICTO SIN RESOLVER"*) ok "  y el motivo dice CONFLICTO SIN RESOLVER — sin garble de SIGPIPE" ;;
  *) bad "  SIGPIPE garbló el motivo (esperaba CONFLICTO SIN RESOLVER): '$BT_ANCESTRO'" ;;
esac

echo
echo "test-agregador-identidad-blob: FAIL=$FAIL"
exit "$FAIL"
