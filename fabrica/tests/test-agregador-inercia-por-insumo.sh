#!/usr/bin/env bash
# tests/test-agregador-inercia-por-insumo.sh — TAL-6719. Self-test de la inercia por insumo en
# post-local-gates.sh: un PR DISJUNTO de los insumos de un gate (y del churn que lo hizo caducar)
# se CONSERVA en vez de re-correrse, bajo las cinco condiciones selladas por
# CEO-RULING-T02-INERCIA-POR-INSUMO-0112 (mergeable, merge-tree limpio en el insumo que disparó el
# hit, disjunción de churn, disjunción de insumos, receipt PASS). Lo EJECUTA tests/run-tests.sh:
# un test que nadie corre no es una prueba, es un fichero.
#
# Extrae el SUJETO REAL (no reescrito de memoria) de post-local-gates.sh: mismo patrón que
# tests/test-agregador-identidad-blob.sh (TAL-6674) — ancla de inicio/fin sobre el fichero real,
# fixtures git propios en tmpdir.
#
# Casos (k)-(m): rutas y lecturas completas de insumos — (k) una ruta con
# TAB en el nombre quedaba invisible a la disjunción por el C-quoting de git sin `-z`; (l) un PR
# grande podía dar "disjunto" por error (SIGPIPE + `set -o pipefail` + `grep -q` de salida
# temprana en `_pr_disjunto_de`); (m) el MISMO patrón de SIGPIPE
# en `_blob_tiene_conflicto` (`git cat-file -p | grep -qF`) — un bug que
# el fix de (l) no cerró por estar en una función distinta. Los tres casos reproducen el bug
# ORIGINAL con un mutante controlado antes de fijarse en esta versión (ver los commits que los
# corrigen).
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PLG="$REPO_ROOT/scripts/post-local-gates.sh"
LIB="$REPO_ROOT/scripts/lib/insumos-por-gate.sh"
[ -r "$PLG" ] || { echo "FAIL: no encuentro $PLG"; exit 2; }
[ -r "$LIB" ] || { echo "FAIL: no encuentro $LIB"; exit 2; }

FAIL=0
ok()  { echo "  PASS  $1"; }
bad() { echo "  FAIL  $1" >&2; FAIL=1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/tal6719-XXXXXXXX")"
trap 'rm -rf "$T"' EXIT

# ── Extracción del sujeto REAL: bt_merge_tree/bt_prepara/gate_afectado/_pr_disjunto_de/
#    _landing_tree_oid/_blob_tiene_conflicto/pr_inerte_para_gate, en ese orden en el fichero. ──
SUBJ="$T/subj.sh"
ini="$(grep -n '^BT_KEY=""; BT_ANCESTRO=""; BT_CHURN=""$' "$PLG" | head -1 | cut -d: -f1)"
fin="$(awk -v s="$ini" 'NR>=s && /^pr_inerte_para_gate\(\) \{/{p=1} p && /^}$/{print NR; exit}' "$PLG")"
[ -n "$ini" ] && [ -n "$fin" ] && sed -n "${ini},${fin}p" "$PLG" > "$SUBJ"
[ -s "$SUBJ" ] || { echo "FAIL: no pude extraer el bloque de inercia de $PLG (ancla movida)"; exit 2; }
# shellcheck source=/dev/null
. "$SUBJ"
for fn in bt_merge_tree bt_prepara gate_afectado _pr_disjunto_de _landing_tree_oid _blob_tiene_conflicto pr_inerte_para_gate; do
  declare -f "$fn" >/dev/null 2>&1 || { echo "FAIL: no se extrajo $fn() — ancla incompleta o movida"; exit 2; }
done
ok "las 7 funciones del bloque de inercia se extrajeron del fichero REAL"

# ── Extracción de la construcción de PR_FILES (rename-aware) ───────────────────────────────────
PRF="$T/prfiles.sh"
ini2="$(grep -n '^_pr_files_tmp="\$(mktemp' "$PLG" | head -1 | cut -d: -f1)"
fin2="$(awk -v s="$ini2" 'NR>=s && /^rm -f "\$_pr_files_tmp"$/{print NR; exit}' "$PLG")"
[ -n "$ini2" ] && [ -n "$fin2" ] && sed -n "${ini2},${fin2}p" "$PLG" > "$PRF"
[ -s "$PRF" ] || { echo "FAIL: no pude extraer la construcción de PR_FILES de $PLG (ancla movida)"; exit 2; }
die() { echo "PR_FILES-die: $*" >&2; return 1; }  # stub — el bloque real usa `die` en su rama de fallo
ok "la construcción de PR_FILES (rename-aware) se extrajo del fichero REAL"

# shellcheck source=scripts/lib/insumos-por-gate.sh
. "$LIB" || { echo "FAIL: el mapa de insumos no carga"; exit 2; }
_uni_universal="$(insumos_universales)"

# ── Fixture base: repo real, insumos REALES del mapa de producción (academy.conf) ───────────────
# typecheck  → src/** tests/** *.ts *.tsx tsconfig*.json
# e2e        → src/** tests/e2e/** supabase/** messages/** playwright*.config.ts ...
# skills-package → .claude/skills/**  (área de la "unidad" propia — disjunta de las de arriba)
CLONE="$T/repo"; mkdir -p "$CLONE"
git -C "$CLONE" init -q
git -C "$CLONE" config user.email a@b; git -C "$CLONE" config user.name a
mkdir -p "$CLONE/src" "$CLONE/.claude/skills/foo"
printf '{"name":"x"}\n' > "$CLONE/package.json"
printf 'export const x = 1;\n' > "$CLONE/src/main.ts"
git -C "$CLONE" add -A && git -C "$CLONE" commit -qm root
ROOT="$(git -C "$CLONE" rev-parse HEAD)"
# shellcheck disable=SC2034 # leída dentro de $PRF (bloque de PR_FILES sourceado con source=/dev/null), no en este fichero
BASE_SHA="$ROOT"

# HEAD_SHA (la "unidad"/PR): SOLO toca .claude/skills/** — disjunta de typecheck y de e2e.
git -C "$CLONE" checkout -q -B unidad "$ROOT"
printf '# SKILL\n' > "$CLONE/.claude/skills/foo/SKILL.md"
git -C "$CLONE" add -A && git -C "$CLONE" commit -qm "PR: solo skills-package"
HEAD_SHA="$(git -C "$CLONE" rev-parse HEAD)"

# shellcheck source=/dev/null
. "$PRF"   # deriva PR_FILES real desde BASE_SHA..HEAD_SHA (rename-aware)
case "$PR_FILES" in *".claude/skills/foo/SKILL.md"*) ok "PR_FILES ve el fichero del PR (.claude/skills/foo/SKILL.md)";; *) bad "PR_FILES no vio el fichero del PR: '$PR_FILES'"; exit 2;; esac
PR_MERGEABLE="MERGEABLE"

# ── (a) PR disjunto + avance de src/ (insumo de typecheck) ⇒ CONSERVA ──────────────────────────
git -C "$CLONE" checkout -q -B main-a "$ROOT" >/dev/null
printf 'export const x = 2;\n' > "$CLONE/src/main.ts"
git -C "$CLONE" commit -qam "main avanza: toca src/main.ts"
BASE_TIP_SHA="$(git -C "$CLONE" rev-parse HEAD)"
BT_KEY=""; BT_ANCESTRO=""; BT_CHURN=""
bt_prepara "$ROOT"; rc_bt=$?
[ "$rc_bt" = 0 ] || { bad "(a) precondición: bt_prepara debía usar (rc=$rc_bt: $BT_ANCESTRO)"; exit 2; }
hit="$(gate_afectado typecheck)"
case "$hit" in *src/main.ts*) : ;; *) bad "(a) precondición: gate_afectado(typecheck) no vio src/main.ts (hit='$hit')"; exit 2;; esac
if pr_inerte_para_gate typecheck "$hit" PASS; then ok "(a) PR disjunto + avance de src/ → CONSERVA (inerte)"; else bad "(a) debía conservarse y no lo hizo"; fi

# ── (b) PR que toca un insumo del gate ⇒ RECHAZA (y este es el MUTANTE obligatorio) ─────────────
# A PROPÓSITO: el PR toca un fichero DISTINTO (src/other.ts) del que avanzó main (src/main.ts) —
# condición (1) (∩ churn = ∅) PASARÍA sola; solo la condición (2) (insumo del gate, cualquier
# fichero) cierra este caso. Si los dos tocaran el MISMO fichero, la condición (1) rechazaría por
# su cuenta y el mutante de abajo (que quita la condición 2) seguiría en verde por casualidad —
# exactamente el hueco que este diseño evita.
git -C "$CLONE" checkout -q -B unidad-toca-src "$ROOT"
printf 'export const y = 1;\n' > "$CLONE/src/other.ts"
git -C "$CLONE" add -A && git -C "$CLONE" commit -qm "PR: toca src/other.ts (insumo de typecheck, DISTINTO del que avanza main)"
HEAD_SHA_B="$(git -C "$CLONE" rev-parse HEAD)"
HEAD_SHA_REAL="$HEAD_SHA"; HEAD_SHA="$HEAD_SHA_B"
# shellcheck source=/dev/null
. "$PRF"
case "$PR_FILES" in *"src/other.ts"*) : ;; *) bad "(b) precondición: PR_FILES no ve src/other.ts"; exit 2;; esac
case "$PR_FILES" in *"src/main.ts"*) bad "(b) precondición rota: PR_FILES no debía tocar src/main.ts"; exit 2;; esac
git -C "$CLONE" checkout -q -B main-b "$ROOT" >/dev/null
printf 'export const x = 3;\n' > "$CLONE/src/main.ts"
git -C "$CLONE" commit -qam "main avanza: toca src/main.ts (DISTINTO del que toca el PR)"
BASE_TIP_SHA="$(git -C "$CLONE" rev-parse HEAD)"
BT_KEY=""; BT_ANCESTRO=""; BT_CHURN=""
bt_prepara "$ROOT" >/dev/null; hit_b="$(gate_afectado typecheck)"
if pr_inerte_para_gate typecheck "$hit_b" PASS; then bad "(b) debía RECHAZAR (el PR toca un insumo del gate) y CONSERVÓ"; else ok "(b) PR que toca un insumo del gate → RECHAZA"; fi
# Mutante obligatorio (DoD): desactivar la condición (2) — aceptar SOLO por intersección de
# ficheros (condición 1) — debe poner en ROJO este mismo caso (b).
pr_inerte_para_gate_MUTANTE_SIN_COND2() { # idéntica a pr_inerte_para_gate pero SIN la condición (2)
  local hit="$2" rres="$3" overlap  # $1 (gate) no se usa: el mutante nunca llama a insumos_de_gate
  [ "$rres" = "PASS" ] || return 1
  [ "$PR_MERGEABLE" = "MERGEABLE" ] || return 1
  _landing_tree_oid || return 1
  _blob_tiene_conflicto "$_LG_LANDING_TREE" "$hit" && return 1
  overlap="$(comm -12 <(printf '%s\n' "$PR_FILES" | grep -v '^$' | sort -u) <(printf '%s\n' "$BT_CHURN" | grep -v '^$' | sort -u) | head -1 || true)"
  [ -z "$overlap" ] || return 1
  return 0   # MUTANTE: nunca comprueba insumos_de_gate — solo (1)
}
if pr_inerte_para_gate_MUTANTE_SIN_COND2 typecheck "$hit_b" PASS; then
  ok "  MUTANTE (sin condición 2) ATERRIZA en rojo el caso (b): acepta por (1) sola, que es justo el bug que (2) cierra"
else
  bad "  MUTANTE sin condición (2) NO reprodujo el bug — el caso (b) no tiene dientes de verdad"
fi
HEAD_SHA="$HEAD_SHA_REAL"
# shellcheck source=/dev/null
. "$PRF"

# ── (c) PR disjunto pero avance UNIVERSAL ⇒ caducan TODOS (bt_prepara ni llega a la inercia) ────
git -C "$CLONE" checkout -q -B main-c "$ROOT" >/dev/null
printf '{"name":"x","v":2}\n' > "$CLONE/package.json"
git -C "$CLONE" commit -qam "main avanza: toca package.json (insumo universal)"
BASE_TIP_SHA="$(git -C "$CLONE" rev-parse HEAD)"
BT_KEY=""; BT_ANCESTRO=""; BT_CHURN=""
bt_prepara "$ROOT"; rc_c=$?
[ "$rc_c" = 1 ] && case "$BT_ANCESTRO" in *"INSUMO UNIVERSAL"*) ok "(c) PR disjunto pero avance UNIVERSAL → caducan TODOS (bt_prepara rc=1 antes de llegar a la inercia)";; *) bad "(c) rc=1 pero motivo no nombra insumo universal: $BT_ANCESTRO";; esac \
  || bad "(c) el avance universal no caducó (rc=$rc_c) — la inercia NUNCA debe pasar por encima de la caducación universal"

# ── (d) merge-tree con conflicto ⇒ rechaza (helper aislado + integración) ──────────────────────
git -C "$CLONE" checkout -q -B unidad-conflicto "$ROOT"
printf 'export const x = "DE-LA-UNIDAD";\n' > "$CLONE/src/main.ts"
git -C "$CLONE" add -A && git -C "$CLONE" commit -qm "PR: también toca src/main.ts, de forma incompatible"
HEAD_SHA_D="$(git -C "$CLONE" rev-parse HEAD)"
git -C "$CLONE" checkout -q -B main-d "$ROOT" >/dev/null
printf 'export const x = "DE-MAIN";\n' > "$CLONE/src/main.ts"
git -C "$CLONE" commit -qam "main avanza: también toca src/main.ts, de forma incompatible"
BASE_TIP_SHA="$(git -C "$CLONE" rev-parse HEAD)"
HEAD_SHA_REAL="$HEAD_SHA"; HEAD_SHA="$HEAD_SHA_D"
_LG_LANDING_KEY=""; _LG_LANDING_TREE=""
_landing_tree_oid
if _blob_tiene_conflicto "$_LG_LANDING_TREE" "src/main.ts"; then ok "(d) helper aislado: _blob_tiene_conflicto detecta el conflicto real en src/main.ts"; else bad "(d) helper aislado: no detectó el conflicto real"; fi
BT_KEY=""; BT_ANCESTRO=""; BT_CHURN=""
bt_prepara "$ROOT" >/dev/null; hit_d="$(gate_afectado typecheck)"
if pr_inerte_para_gate typecheck "$hit_d" PASS; then bad "(d) merge-tree con conflicto: debía RECHAZAR y CONSERVÓ"; else ok "(d) merge-tree con conflicto ⇒ rechaza (integración)"; fi
HEAD_SHA="$HEAD_SHA_REAL"
# shellcheck source=/dev/null
. "$PRF"

# ── (m) CERO×2: _blob_tiene_conflicto no da falso "sin conflicto" con un blob grande (SIGPIPE) ──
# Mismo mecanismo que (l) pero en el helper de conflicto: `git cat-file -p | grep -qF` bajo
# `set -o pipefail` podía cerrar temprano y hacer que `git cat-file` recibiera SIGPIPE, reportando
# 141 en vez de 0 — el `&&` del llamante lo leía como "sin conflicto" pese a haberlo. El marcador
# va al PRINCIPIO del blob (igual que el insumo en (l)) para forzar la misma carrera.
_BIG_CONFLICT_TREE="$T/big-conflict-blob"
{ printf '<<<<<<< HEAD\n'; head -c 3000000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$_BIG_CONFLICT_TREE"
_big_oid="$(git -C "$CLONE" hash-object -w "$_BIG_CONFLICT_TREE")"
_big_tree="$(printf '100644 blob %s\tmain.ts\n' "$_big_oid" | git -C "$CLONE" mktree)"
if _blob_tiene_conflicto "$_big_tree" "main.ts"; then ok "(m) blob grande (~3MB) con marcador al principio: SÍ se detecta el conflicto (sin falso verde de SIGPIPE)"; else bad "(m) blob grande con marcador real: NO se detectó — falso 'sin conflicto' de SIGPIPE/pipefail"; fi

# ── (e) mergeable != MERGEABLE ⇒ rechaza (reusa el escenario inerte de (a)) ────────────────────
# shellcheck disable=SC2034 # última escritura: leída dentro de bt_prepara (extraída/sourceada en $SUBJ), no en este fichero
BASE_TIP_SHA="$(git -C "$CLONE" rev-parse main-a)"
# shellcheck disable=SC2034 # BT_KEY: última escritura, leída como memoización dentro de bt_prepara (sourceada en $SUBJ)
BT_KEY=""; BT_ANCESTRO=""; BT_CHURN=""
bt_prepara "$ROOT" >/dev/null; hit_e="$(gate_afectado typecheck)"
PR_MERGEABLE="CONFLICTING"
if pr_inerte_para_gate typecheck "$hit_e" PASS; then bad "(e) mergeable=CONFLICTING: debía RECHAZAR y CONSERVÓ"; else ok "(e) mergeable != MERGEABLE ⇒ rechaza"; fi
PR_MERGEABLE="MERGEABLE"

# ── (f) gate sin mapa ⇒ rechaza ─────────────────────────────────────────────────────────────────
if pr_inerte_para_gate gate-inexistente-9999 "src/main.ts" PASS; then bad "(f) gate sin mapa: debía RECHAZAR y CONSERVÓ"; else ok "(f) gate sin entrada en el mapa de insumos ⇒ rechaza (fail-closed)"; fi

# ── (g) receipt FAIL ⇒ no se conserva (reusa el escenario inerte de (a)) ───────────────────────
if pr_inerte_para_gate typecheck "$hit_e" FAIL; then bad "(g) receipt FAIL: debía RECHAZAR y CONSERVÓ"; else ok "(g) receipt FAIL ⇒ no se conserva por inercia"; fi

# ── (h) roster: shard nuevo en main + PR disjunto de e2e ⇒ censo mixto aceptado ────────────────
# El "avance de main" para el roster es un diff plano BASE_SHA..BASE_TIP_SHA (sin receipt de
# referencia) — aquí, el mismo avance de (a): toca src/main.ts, insumo de "e2e" también.
main_advance_h="$(git -C "$CLONE" diff --name-only "$ROOT" "$(git -C "$CLONE" rev-parse main-a)")"
if _pr_disjunto_de e2e "$main_advance_h"; then ok "(h) roster: PR disjunto de insumos e2e (y del avance) → censo mixto aceptado"; else bad "(h) debía ser disjunto de e2e y no lo fue"; fi

# ── (i) roster: shard nuevo + PR toca src/ ⇒ rechazo (replantar) ──────────────────────────────
HEAD_SHA_REAL="$HEAD_SHA"; HEAD_SHA="$HEAD_SHA_B"  # el PR de (b), que SÍ toca src/main.ts
# shellcheck source=/dev/null
. "$PRF"
if _pr_disjunto_de e2e "$main_advance_h"; then bad "(i) el PR toca src/ (insumo de e2e) — debía NO ser disjunto"; else ok "(i) roster: PR toca src/ (insumo e2e) → NO disjunto, rechazo/replantar"; fi
HEAD_SHA="$HEAD_SHA_REAL"
# shellcheck source=/dev/null
. "$PRF"

# ── (j) rename en el PR ⇒ ambos lados cuentan ──────────────────────────────────────────────────
git -C "$CLONE" checkout -q -B unidad-rename "$ROOT"
git -C "$CLONE" mv src/main.ts src/principal.ts
git -C "$CLONE" commit -qm "PR: rename src/main.ts -> src/principal.ts"
HEAD_SHA_REAL="$HEAD_SHA"; HEAD_SHA="$(git -C "$CLONE" rev-parse HEAD)"
# shellcheck source=/dev/null
. "$PRF"
case "$PR_FILES" in *"src/main.ts"*) case "$PR_FILES" in *"src/principal.ts"*) ok "(j) rename: PR_FILES trae AMBOS lados (src/main.ts y src/principal.ts)";; *) bad "(j) PR_FILES no trae el destino del rename: '$PR_FILES'";; esac ;; *) bad "(j) PR_FILES no trae el origen del rename: '$PR_FILES'";; esac
HEAD_SHA="$HEAD_SHA_REAL"
# shellcheck source=/dev/null
. "$PRF"

# ── (k) CERO×2: ruta con TAB en el nombre — el C-quoting de git sin -z rompía la ERE ────────────
git -C "$CLONE" checkout -q -B unidad-tab "$ROOT"
printf 'export const y = 1;\n' > "$CLONE/"$'src/evil\tfile.ts'
git -C "$CLONE" add -A && git -C "$CLONE" commit -qm "PR: fichero con TAB en el nombre (insumo de typecheck)"
HEAD_SHA_REAL="$HEAD_SHA"; HEAD_SHA="$(git -C "$CLONE" rev-parse HEAD)"
# shellcheck source=/dev/null
. "$PRF"
case "$PR_FILES" in *"evil"*"file.ts"*) ok "(k) PR_FILES ve el fichero con TAB en el nombre (sin C-quoting, gracias a -z)";; *) bad "(k) PR_FILES no vio el fichero con TAB: '$PR_FILES'"; exit 2;; esac
if _pr_disjunto_de typecheck ""; then bad "(k) el fichero con TAB SÍ es insumo de typecheck — debía NO ser disjunto"; else ok "(k) el fichero con TAB SÍ se reconoce como insumo de typecheck (disjunción correcta)"; fi
HEAD_SHA="$HEAD_SHA_REAL"
# shellcheck source=/dev/null
. "$PRF"

# ── (l) CERO×2: PR grande no dispara el falso-verde de SIGPIPE+pipefail en la condición (2) ────
# `grep -E -q -f ... && return 1` bajo `set -o pipefail`: si el productor recibe SIGPIPE al
# cerrarse `grep -q` tras el primer match, la tubería reporta 141 (no 0) y el `&&` nunca dispara,
# aunque SÍ hubiera match — un PR grande que toca un insumo real quedaría "disjunto" por error.
# El insumo real va PRIMERO a propósito: el lector (`grep -q`/`head -1`) sale nada más verlo,
# mientras el productor de arriba (`grep -v '^$'`) todavía tiene ~2-3 MB de líneas por escribir —
# eso es lo que dispara el SIGPIPE al chocar contra el buffer de la tubería (64KB típico en
# Linux) con el lector ya cerrado. Con el insumo al FINAL (como en una primera versión de este
# caso) el productor ya había terminado de escribir cuando el lector sale, y el bug no se
# reproduce — no por estar arreglado, sino por no ejercitar la carrera real.
PR_FILES_REAL="$PR_FILES"
PR_FILES="$(printf 'src/other.ts\n'; printf 'docs/pagina-%06d.md\n' $(seq 1 100000))"
if _pr_disjunto_de typecheck ""; then bad "(l) PR grande con src/other.ts (insumo real) dio FALSO VERDE de disjunción — SIGPIPE/pipefail sin corregir"; else ok "(l) PR grande (100001 ficheros) con un insumo real sigue detectándose — sin falso verde de SIGPIPE/pipefail"; fi
PR_FILES="$PR_FILES_REAL"

echo
echo "test-agregador-inercia-por-insumo: FAIL=$FAIL"
exit "$FAIL"
