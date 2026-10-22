#!/usr/bin/env bash
# post-local-gates.sh — Agregador y ÚNICA vía de POST del commit-status `local-gates` (TAL-2288).
#
# Corre en la ESTACIÓN del Mergeador (única con credenciales gh). El agregador es el ÚNICO
# dueño del conjunto esperado de gates y del estado global: los receipts parciales de los
# runners (run-local-gates.sh --gate …) solo aportan datos, que aquí se validan fail-closed.
#
# LÍMITE DE CONFIANZA (B1-rev6 del plan): la estación JAMÁS ejecuta código de head_sha.
#   - El gate branch-name se ejecuta desde BASE_SHA en subprocess SIN credenciales (env -i).
#   - El registro de shards de base_sha es el MÍNIMO confiable: una reducción en head ⇒ FALLO
#     con diagnóstico, salvo RATIFICACIÓN DURABLE (entrada append-only con ref= en
#     <dir-registro>/REGISTRY-RATIFICACIONES.log, versionada en el head del PR);
#     las adiciones de head SÍ se incorporan al conjunto esperado.
#
# Agregación por (repo, pr, head_sha, base_sha, manifest_digest, run_group): un receipt con
# identidad distinta, duplicado, sin gate, multigate o fuera del inventario ⇒ RECHAZO (exit 2,
# no se postea nada). El `gh api` manual queda FUERA del flujo normal (break-glass trazado).
#
# Uso:
#   bash post-local-gates.sh <run_group> <owner/repo> <pr> --receipts <dir> \
#        --manifest <ruta> --repo <clon-limpio-de-la-estación> [--context local-gates|local-gates-test]
#
# Salida: 0 = agregado y POSTEADO success · 1 = agregado y POSTEADO failure ·
#         2 = precondición/agregación inválida o head/base cambió (NO se postea) ·
#         3 = el POST (o su relectura) falló — el resultado NO quedó trazado (FATAL).
set -uo pipefail
umask 077

die()  { echo "ERROR: $*" >&2; exit 2; }
die3() { echo "FATAL: $*" >&2; exit 3; }

RUN_GROUP="${1:?run_group}"; OWNER_REPO="${2:?owner/repo}"; PR="${3:?nº de PR}"; shift 3
RECEIPTS=""; MANIFEST=""; CLONE=""; CONTEXT="local-gates"
while [ $# -gt 0 ]; do case "$1" in
  --receipts) RECEIPTS="$2"; shift 2;;
  --manifest) MANIFEST="$2"; shift 2;;
  --repo)     CLONE="$2"; shift 2;;
  --context)  CONTEXT="$2"; shift 2;;
  *) die "argumento desconocido: $1";; esac; done

case "$CONTEXT" in local-gates|local-gates-test) : ;; *) die "--context solo acepta local-gates|local-gates-test (recibido: $CONTEXT)";; esac
command -v gh >/dev/null || die "gh no disponible (esto corre en la estación)"
command -v jq >/dev/null || die "jq no disponible"
[ -d "${RECEIPTS:-}" ] || die "falta --receipts <dir> con los receipts del run_group"
# Procedencia SELLADA (B2 audit TAL-2293): el journal lo escribe SOLO la estación
# (run-gate-sealed.sh) al lanzar cada runner de forma síncrona — sha256 del receipt +
# exit code OBSERVADO. Sin journal no hay agregación: un dir de receipts "sueltos"
# (fabricables) no es evidencia.
JOURNAL="$RECEIPTS/journal.jsonl"
[ -f "$JOURNAL" ] || die "falta $JOURNAL — los receipts deben sellarse con run-gate-sealed.sh (procedencia); receipts sin journal NO son agregables"
[ -f "${MANIFEST:-}" ] || die "falta --manifest"
[ -d "${CLONE:-}" ]    || die "falta --repo <clon limpio de la estación> (jamás el árbol de un canal)"
CLONE="$(cd "$CLONE" && pwd -P)"
git -C "$CLONE" rev-parse --git-dir >/dev/null 2>&1 || die "$CLONE no es un repo git"
# [TAL-5644] `--git-dir` responde rc 0 desde CUALQUIER subdirectorio. Se exige el toplevel porque
# las rutas del manifiesto son relativas a la raíz del repo: con --repo por debajo, un fichero
# presente se leería como ausente y el suelo anti-reducción se apagaría sin dejar rastro.
[ "$(git -C "$CLONE" rev-parse --show-toplevel 2>/dev/null)" = "$CLONE" ] \
  || die "$CLONE no es la RAÍZ del repo (--repo tiene que apuntar al toplevel: las rutas del manifiesto son relativas a la raíz)"

MANIFEST="$(cd "$(dirname "$MANIFEST")" && pwd -P)/$(basename "$MANIFEST")"
# ── B2 r5: la ESTACIÓN (con credenciales) JAMÁS ejecuta el manifiesto — se parsea como
#    DATOS con GRAMÁTICA CERRADA (clave TF_* + valor entre comillas SIN $, backtick ni
#    backslash; comentarios y líneas vacías). Cualquier línea fuera de la gramática ⇒ die.
#    Además la ruta queda limitada al directorio confiable del motor (manifiestos/ junto a
#    este script; LG_MANIFEST_DIR lo re-apunta para otras estaciones o para el arnés).
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TRUSTED_MANIFEST_DIR="${LG_MANIFEST_DIR:-$(cd "$SELF_DIR/.." && pwd -P)/manifiestos}"
TRUSTED_MANIFEST_DIR="$(cd "$TRUSTED_MANIFEST_DIR" 2>/dev/null && pwd -P)" || die "directorio confiable inexistente"
# Symlinks PROHIBIDOS (M5 r6): un enlace DENTRO del dir confiable podría apuntar a un .conf
# arbitrario. Se exige fichero regular y que su ruta REAL siga dentro del dir confiable.
[ ! -L "$MANIFEST" ] || die "el manifiesto es un symlink ($MANIFEST) — prohibido"
REAL_MANIFEST="$(readlink -f "$MANIFEST")" || die "no puedo resolver $MANIFEST"
[ -f "$REAL_MANIFEST" ] || die "el manifiesto no es un fichero regular: $MANIFEST"
case "$REAL_MANIFEST" in
  "$TRUSTED_MANIFEST_DIR"/*) : ;;
  *) die "--manifest fuera del directorio confiable ($TRUSTED_MANIFEST_DIR): $REAL_MANIFEST — la estación solo agrega con manifiestos del motor (LG_MANIFEST_DIR para re-apuntar explícitamente)" ;;
esac
MANIFEST="$REAL_MANIFEST"
bad_lines="$(grep -vnE '^([[:space:]]*(#.*)?|TF_[A-Za-z0-9_]+="[^"$\\`]*"([[:space:]]+#.*)?[[:space:]]*)$' "$MANIFEST" || true)"
[ -z "$bad_lines" ] || die "manifiesto FUERA de la gramática cerrada (posible código embebido — la estación no lo ejecuta): $(echo "$bad_lines" | head -3 | tr '\n' ' ')"
MANIFEST_DIGEST="$(sha256sum "$MANIFEST" | cut -d' ' -f1)"
dup_keys="$(grep -E '^TF_[A-Za-z0-9_]+=' "$MANIFEST" | cut -d= -f1 | sort | uniq -d)"
[ -z "$dup_keys" ] || die "manifiesto con claves duplicadas: $(echo "$dup_keys" | tr '\n' ' ')"
mget() { sed -n "s/^$1=\"\([^\"]*\)\".*\$/\1/p" "$MANIFEST" | tail -1; }
GATE_IDS="$(mget TF_GATE_IDS)"
[ -n "$GATE_IDS" ] || die "el manifiesto no define TF_GATE_IDS"
E2E_FAMILIES="$(mget TF_E2E_FAMILIES)"
SHARDS_REGISTRY="$(mget TF_SHARDS_REGISTRY)"
DB_GATE="$(mget TF_DB_GATE)"; DB_GATE="${DB_GATE:-always}"
# TAL-6719: fail-closed por ausencia — un manifiesto que no declara la clave se comporta como si
# valiera "0" (sin inercia, camino de caducidad mecánica de siempre).
INERCIA_POR_INSUMO="$(mget TF_INERCIA_POR_INSUMO)"; INERCIA_POR_INSUMO="${INERCIA_POR_INSUMO:-0}"
MIG_DIR="$(mget TF_MIGRATIONS_DIR)"; MIG_DIR="${MIG_DIR:-supabase/migrations}"
BRANCH_VALIDATOR="$(mget TF_BRANCH_VALIDATOR)"; BRANCH_VALIDATOR="${BRANCH_VALIDATOR:-scripts/github/validar-rama-pr.sh}"
# Motor APROBADO de la estación (B3 r5): los receipts/journal deben referir EXACTAMENTE
# este motor — un motor stale/sustituido en el runner no produce evidencia aceptable.
APPROVED_MOTOR_SHA="$(sha256sum "$SELF_DIR/run-local-gates.sh" | cut -d' ' -f1)" || die "sin run-local-gates.sh junto al agregador"
# Carve-out docs-only (TAL-2749): el agregador RECOMPUTA la clasificación con SU lib APROBADA
# (autoridad); la copia que corrió en el runner solo PROPUSO el SKIP. La lib lee TF_CARVEOUT_PATHS.
CARVEOUT_ENABLED="$(mget TF_CARVEOUT_DOCS_ONLY)"
CARVEOUT_KEEP="$(mget TF_CARVEOUT_KEEP_GATES)"
# shellcheck disable=SC2034 # leída por lib/carveout.sh (sourced abajo, SC1091 sin -x) como global de entorno, no en este fichero
TF_CARVEOUT_PATHS="$(mget TF_CARVEOUT_PATHS)"
# Autoridad conservadora (ruling del lead vía CEO, ~/.tco-relay/ruling-49-tal2749.txt): el checker
# heurístico (carveout-check en Academy) queda como capa COMPLEMENTARIA; la autoridad fail-closed
# real es este digest ratificado del árbol NO-carveout — ver carveout_noncarveout_digest en la lib.
CARVEOUT_INERT_DIGEST="$(mget TF_CARVEOUT_INERT_DIGEST)"
# shellcheck source=scripts/lib/carveout.sh
. "$SELF_DIR/lib/carveout.sh" || die "sin lib/carveout.sh junto al agregador"
# Lib de carve-out APROBADA (r4): igual que el motor, la copia que corrió en el runner debe ser
# EXACTAMENTE esta (atestada por sha256 en journal y receipt) — nada de código no verificado.
APPROVED_CARVEOUT_SHA="$(sha256sum "$SELF_DIR/lib/carveout.sh" | cut -d' ' -f1)" || die "sin lib/carveout.sh junto al agregador"

# ── 1. Identidad del PR (snapshot inicial). ────────────────────────────────────────────────────
# `mergeable` (TAL-6719): condición (4) de la inercia por insumo — leída UNA vez, del mismo
# snapshot, para no gastar una llamada a la API aparte ni arriesgar un TOCTOU entre dos lecturas.
pr_json="$(gh pr view "$PR" --repo "$OWNER_REPO" --json headRefOid,headRefName,baseRefName,author,mergeable 2>/dev/null)" \
  || die "no pude leer el PR #$PR de $OWNER_REPO"
HEAD_SHA="$(jq -r '.headRefOid' <<<"$pr_json")"
HEAD_REF="$(jq -r '.headRefName' <<<"$pr_json")"
BASE_NAME="$(jq -r '.baseRefName' <<<"$pr_json")"
AUTHOR="$(jq -r '.author.login // ""' <<<"$pr_json")"
PR_MERGEABLE="$(jq -r '.mergeable // ""' <<<"$pr_json")"
echo "[post-local-gates] PR #$PR · $HEAD_REF @ ${HEAD_SHA:0:12} → $BASE_NAME · run_group=$RUN_GROUP · context=$CONTEXT"

# ── 2. Base y registros en el clon limpio de la estación. ─────────────────────────────────────
git -C "$CLONE" fetch --no-tags --quiet origin "$BASE_NAME" || die "fetch de $BASE_NAME falló"
BASE_TIP_SHA="$(git -C "$CLONE" rev-parse "origin/$BASE_NAME")" || die "sin tip de $BASE_NAME"
git -C "$CLONE" cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null \
  || git -C "$CLONE" fetch --no-tags --quiet origin "refs/pull/$PR/head" \
  || die "no puedo traer el head del PR al clon"
BASE_SHA="$(git -C "$CLONE" merge-base "origin/$BASE_NAME" "$HEAD_SHA" 2>/dev/null)" || die "sin merge-base"

# ── PR_FILES (TAL-6719): ficheros que el PR trae, BASE_SHA..HEAD_SHA — usado por la inercia por
# insumo (condiciones (1)-(2)) y por la reconciliación de roster. Un rename cuenta por AMBOS lados
# (origen y destino): si solo se mirara el destino, un insumo renombrado-y-editado en el origen
# quedaría invisible a la prueba de disjunción. `--find-renames` + `--name-status` (no
# `--name-only`) es la única combinación que expone el par completo; `--name-only` colapsa un
# rename a una sola ruta (la de destino) y pierde el origen.
#
# NUL-SAFE (CERO×2, hallazgo BLOQUEANTE): SIN `-z`, git C-quotea rutas con tab/newline/comillas/
# backslash — una ruta real como `src/evil<TAB>.ts` llega como `"src/evil\t.ts"` y la ERE anclada
# `^src/...` deja de casar, así que un insumo real quedaría invisible a la disjunción (falso
# CONSERVA de un receipt que sí debía re-correrse). `-z` entrega bytes crudos NUL-delimitados sin
# quoting. IMPORTANTE: bash NO puede guardar bytes NUL en una variable — `_pr_files_raw="$(...)"`
# los trunca en silencio ("ignored null byte in input"), así que la salida cruda va a un FICHERO
# temporal (los ficheros sí aceptan NUL) y el parseo (`read -r -d ''`) lee de ahí, nunca de una
# variable. `PR_FILES` en sí sigue siendo texto separado por saltos de línea (mismo formato que
# `BT_CHURN` y el resto del fichero) — una ruta con un salto de línea LITERAL en el nombre sigue
# siendo un residuo compartido con `gate_afectado`/`bt_prepara` (no se toca), no un caso nuevo que
# esta pieza introduzca; lo que se cierra aquí es el escapado por comillas/backslash que SÍ
# afectaba a rutas comunes con tabs o comillas.
_pr_files_tmp="$(mktemp "${TMPDIR:-/tmp}/tal6719-pr-files.XXXXXX")" || die "no pude crear el temporal de PR_FILES"
git -C "$CLONE" diff --name-status -z --find-renames "$BASE_SHA" "$HEAD_SHA" > "$_pr_files_tmp" 2>/dev/null \
  || { rm -f "$_pr_files_tmp"; die "no pude derivar los ficheros del PR ($BASE_SHA..$HEAD_SHA) — NO MEDIDO"; }
PR_FILES="$(while IFS= read -r -d '' _st; do
  case "$_st" in
    R*)
      IFS= read -r -d '' _a || break
      IFS= read -r -d '' _b || break
      printf '%s\n%s\n' "$_a" "$_b"
      ;;
    *)
      IFS= read -r -d '' _a || break
      printf '%s\n' "$_a"
      ;;
  esac
done < "$_pr_files_tmp" | grep -v '^$' | sort -u)"
rm -f "$_pr_files_tmp"

# ── Tolerancia de base_tip ANCESTRO, A GRANO DE GATE (CEO 19:04 §3 + ajuste 19:19) ─────────────
# Con el invariante estricto (base_tip == tip ACTUAL) el merge de UNA estación invalidaba las
# suites en vuelo de las otras cuatro — una estación perdió tres suites en una tarde. Pero
# invalidar el run_group ENTERO por cualquier avance también sobra: si main solo tocó `messages/`,
# el gate `typecheck` de esa corrida sigue siendo válido.
#
# Regla: base_tip ANCESTRO del tip actual (si no, rechazo) Y, POR CADA RECEIPT, el avance
# base_tip..tip no puede tocar los INSUMOS DE SU GATE. Los receipts que sí se ven afectados quedan
# inválidos y se listan como accionable; los demás se conservan.
# Fail-closed en todo: gate sin entrada en el mapa ⇒ inválido; lo que no se pueda MEDIR ⇒ rechazo.
# (Esto RELAJA un invariante: la duda cuenta como incumplimiento, nunca como permiso.)
# shellcheck source=scripts/lib/insumos-por-gate.sh
# `LG_INSUMOS_FILE` re-apunta el mapa SOLO para el arnés (mismo patrón que `LG_MANIFEST_DIR`):
# el arnés usa gates sintéticos que —con razón— no están en el mapa de producción, y meter ids de
# prueba en la configuración real sería peor que el problema que resuelve.
INSUMOS_FILE="${LG_INSUMOS_FILE:-$SELF_DIR/lib/insumos-por-gate.sh}"
[ -r "$INSUMOS_FILE" ] || die "sin mapa de insumos por gate ($INSUMOS_FILE)"
# shellcheck source=scripts/lib/insumos-por-gate.sh
. "$INSUMOS_FILE" || die "no pude cargar el mapa de insumos ($INSUMOS_FILE)"
command -v insumos_de_gate >/dev/null || die "el mapa de insumos no define insumos_de_gate ($INSUMOS_FILE) — fail-closed"
# [TAL-5644] La caducación universal ratificada se mide UNA vez, aquí, y su `die` vive fuera del
# bucle de receipts. Comprobar la FUNCIÓN no medía nada (está definida incondicionalmente y su rc
# siempre es 0): lo que puede faltar es el DATO, y si falta, el avance dejaría de caducar receipts.
_uni_universal="$(insumos_universales)"
[ -n "$_uni_universal" ] || die "TF_INPUTS_UNIVERSAL vacío/ausente en el mapa de insumos ($INSUMOS_FILE) — la caducación universal ratificada no se puede aplicar (fail-closed)"

# Frescura del tip contra el REMOTO (M2-PARCHE-LSREMOTE-A-M1): un fetch que falló en silencio
# dejaría un tip local viejo y con él se certificaría contra una historia que ya no existe.
# Fail-closed a propósito y por decisión escrita: sin poder leer el remoto, NO se agrega.
LS_TIP="$(git -C "$CLONE" ls-remote origin "refs/heads/$BASE_NAME" 2>/dev/null | awk '{print $1}' | head -1)"
[ -n "$LS_TIP" ] || die "no pude leer el tip remoto de $BASE_NAME con ls-remote (NO MEDIDO) — no agrego"
[ "$LS_TIP" = "$BASE_TIP_SHA" ] || die "el tip local de $BASE_NAME ($BASE_TIP_SHA) no coincide con el remoto ($LS_TIP) — el fetch quedó atrás; reintenta"

BT_KEY=""; BT_ANCESTRO=""; BT_CHURN=""
# ── IDENTIDAD DE BLOB, no ancestría (TAL-6674) ─────────────────────────────────────────────────
# `merge-base --is-ancestor "$rbt" "$BASE_TIP_SHA"` preguntaba por ANCESTRÍA cuando la pregunta
# correcta es por CONTENIDO. En cola apilada, cualquier reescritura de la historia entre `rbt`
# (el tip de main cuando corrió el receipt) y `BASE_TIP_SHA` (el tip actual) — squash de una
# unidad hermana, rebase, force-push — deja `rbt` fuera de la línea de `main` aunque su ÁRBOL siga
# siendo, para los insumos que importan, byte-idéntico al que va a fundirse. La ancestría rota
# descartaba el receipt ENTERO sin llegar a mirar el contenido: exactamente el vicio de esta
# noche, «un cero por no haber mirado», con el sujeto cambiado de guardia de árbol a guardia de
# receipt.
#
# SEGUNDA VUELTA, validada contra los árboles reales de M1 (`oag/t01-2355-head` y hermanos):
# comparar `rbt` directamente contra `BASE_TIP_SHA` con `merge-tree` TODAVÍA se equivoca cuando
# `BASE_TIP_SHA` resulta ser ANCESTRO de `rbt` (main «detrás» de lo que ya se probó — pasa de
# verdad en la fábrica). `merge-tree(rbt, BASE_TIP_SHA)` colapsa entonces al árbol de `rbt` sin
# nada que fundir, y el churn sale VACÍO aunque haya decenas de ficheros de diferencia real:
# medido contra los árboles de M1, un caso con 52 ficheros distintos dio churn 0 y `rc` ok.
#
# La pregunta correcta no es «¿difieren `rbt` y `BASE_TIP_SHA`?» sino «¿cambió lo que aterrizaría
# si se fundiera `HEAD_SHA` (la unidad que se agrega) HOY, frente a lo que aterrizaba cuando el
# receipt midió?». Eso ancla las dos puntas al MISMO contenido (`HEAD_SHA`) y solo mueve el lado
# de `main`:
#   TESTADO  = árbol de fundir `rbt`          con `HEAD_SHA` (lo que el runner probó de verdad)
#   ATERRIZA = árbol de fundir `BASE_TIP_SHA` con `HEAD_SHA` (lo que se fundiría ahora mismo)
# y el churn es la diferencia de BLOBS entre esos dos árboles, no entre `rbt` y `BASE_TIP_SHA` a
# secas. Confirmado contra el caso real de M1: `merge-tree` del main-nuevo con la unidad propia
# (sin el merge histórico ya hecho) reproduce, oid por oid, el árbol de «T01 replantado» que M1
# entregó como resultado A.
bt_merge_tree() { # <a> <b> → oid del árbol resultante por stdout · rc 0 usable · 1 NO MEDIDO (motivo por stdout)
  local a="$1" b="$2" out rc=0 tree
  out="$(git -C "$CLONE" merge-tree --write-tree "$a" "$b" 2>/dev/null)"; rc=$?
  case "$rc" in
    0|1) : ;;  # 0 limpio · 1 conflicto — LOS DOS están MEDIDOS: hay árbol que inspeccionar.
    *) echo "merge-tree entre ${a:0:12} y ${b:0:12} falló (rc=$rc)"; return 1 ;;
  esac
  # La primera línea de `--write-tree` es el oid del árbol escrito, con o sin conflicto — esto es
  # el CONTRATO documentado del comando, no un mensaje traducido: no depende del idioma del host.
  tree="$(printf '%s\n' "$out" | head -1)"
  case "$tree" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) : ;;
    *) echo "merge-tree(${a:0:12}, ${b:0:12}) no devolvió un árbol reconocible (rc=$rc)"; return 1 ;;
  esac
  git -C "$CLONE" cat-file -e "${tree}^{tree}" 2>/dev/null \
    || { echo "el árbol resultante ${tree:0:12} de merge-tree(${a:0:12}, ${b:0:12}) no se pudo leer del clon"; return 1; }
  printf '%s' "$tree"
}
bt_prepara() { # <base_tip> → rc 0 si es usable; deja el churn en BT_CHURN. rc 1 con motivo en BT_ANCESTRO
  local rbt="$1"
  [ "$rbt" = "$BT_KEY" ] && { [ "$BT_ANCESTRO" = ok ]; return $?; }
  BT_KEY="$rbt"; BT_CHURN=""
  if [ -z "$rbt" ]; then BT_ANCESTRO="base_tip_sha ausente en el receipt (NO MEDIDO)"; return 1; fi
  if ! git -C "$CLONE" cat-file -e "${rbt}^{commit}" 2>/dev/null; then
    BT_ANCESTRO="el commit ${rbt:0:12} no está en el clon de la estación (NO MEDIDO)"; return 1; fi
  local tested_tree landing_tree  # "motivo" (BT_ANCESTRO) se asigna directo, no por esta local sin uso
  tested_tree="$(bt_merge_tree "$rbt" "$HEAD_SHA")" || { BT_ANCESTRO="TESTADO (rbt+HEAD_SHA): $tested_tree (NO MEDIDO)"; return 1; }
  landing_tree="$(bt_merge_tree "$BASE_TIP_SHA" "$HEAD_SHA")" || { BT_ANCESTRO="ATERRIZA (BASE_TIP_SHA+HEAD_SHA): $landing_tree (NO MEDIDO)"; return 1; }
  # Churn por IDENTIDAD DE BLOB entre lo TESTADO y lo que de verdad ATERRIZA — no entre `rbt` y el
  # tip crudo: `git diff` ya compara blobs, no rutas — un fichero con el MISMO contenido en las dos
  # puntas nunca aparece aquí, ancestría aparte.
  if ! BT_CHURN="$(git -C "$CLONE" diff --name-only "$tested_tree" "$landing_tree" 2>/dev/null)"; then
    BT_ANCESTRO="no pude calcular el diff de blobs testado..aterriza (NO MEDIDO)"; return 1; fi
  # TF_INPUTS_UNIVERSAL (ratificado CEO 19:26): dependencias y config de build/runtime. Si el
  # avance los toca, NINGÚN receipt de esa corrida vale — da igual el gate. La regla de blobs se
  # aplica TAMBIÉN aquí, antes de morir (TAL-6674): el hit se re-confirma sobre el ÁRBOL, no sobre
  # la ruta a secas, y si el árbol que aterriza deja un conflicto SIN RESOLVER en ese insumo, se
  # dice así en el motivo — leyendo el blob con `cat-file`, nunca el stdout ni un mensaje de git.
  local uni hit_uni
  # [TAL-5644] `uni` vacío apagaba el `if` de abajo y la caducación universal ratificada
  # desaparecía sin ruido — fail-OPEN del run entero. Se comprueba el DATO (la función está
  # definida incondicionalmente y su rc siempre es 0: comprobarla a ella no medía nada). El `die`
  # NO vive aquí: esta función se invoca desde el bucle de receipts, y morir ahí destruiría el
  # resumen accionable. Se mide una vez al arranque, en `_uni_universal`.
  uni="$_uni_universal"
  if [ -n "$uni" ]; then
    hit_uni="$(printf '%s\n' "$BT_CHURN" | grep -v '^$' | grep -E -f <(printf '%s\n' "$uni") 2>/dev/null | head -1 || true)"
    if [ -n "$hit_uni" ]; then
      local hit_oid="" hit_marca=""
      hit_oid="$(git -C "$CLONE" ls-tree --full-tree -- "$landing_tree" "$hit_uni" 2>/dev/null | awk '{print $3}')"
      if [ -n "$hit_oid" ]; then
        # [TAL-6733] misma clase que _pr_disjunto_de/_blob_tiene_conflicto (TAL-6719): NUNCA
        # `grep -qF` como última pieza de una tubería bajo `set -o pipefail` — con un blob GRANDE
        # cuyo marcador aparece pronto, `grep -q` cierra su stdin al primer match y `cat-file`
        # recibe SIGPIPE (141); pipefail reporta ESE 141 (no el 0 del match) y el `if` caía al
        # `else`, mintiendo el motivo. Se captura el VALOR (nunca el rc crudo de la tubería) y se
        # decide sobre él — un fallo real de `cat-file`/`grep` deja `hit_marca` vacío y cae en la
        # misma rama genérica de siempre (`|| true`), sin abrir ningún camino nuevo de false-accept.
        hit_marca="$(git -C "$CLONE" cat-file -p "$hit_oid" 2>/dev/null | grep -F '<<<<<<<' | head -1 || true)"
      fi
      if [ -n "$hit_marca" ]; then
        BT_ANCESTRO="el avance deja un CONFLICTO SIN RESOLVER en un INSUMO UNIVERSAL ($hit_uni) — caducan TODOS los receipts de la corrida"
      else
        BT_ANCESTRO="el avance toca un INSUMO UNIVERSAL ($hit_uni) — caducan TODOS los receipts de la corrida"
      fi
      return 1
    fi
  fi
  BT_ANCESTRO=ok; return 0
}

gate_afectado() { # <gate> → imprime el fichero que lo invalida, o nada. rc 1 si el gate no está mapeado
  local g="$1" pats excl churn f
  pats="$(insumos_de_gate "$g")" || return 1
  churn="$(printf '%s\n' "$BT_CHURN" | grep -v '^$' || true)"
  # TAL-5462: exclusiones por área, DESPUÉS de las inclusiones. Sólo descuentan rutas que casan
  # positivamente con un patrón declarado del propio gate; un área nueva nunca se descuenta sola.
  # `no_insumos_de_gate` puede no existir en un mapa antiguo: se degrada a "sin exclusiones", que
  # es el comportamiento previo (más caducación, nunca menos).
  if command -v no_insumos_de_gate >/dev/null 2>&1; then
    excl="$(no_insumos_de_gate "$g" || true)"
    if [ -n "$excl" ]; then
      churn="$(printf '%s\n' "$churn" | grep -E -v -f <(printf '%s\n' "$excl") 2>/dev/null || true)"
    fi
  fi
  f="$(printf '%s\n' "$churn" | grep -v '^$' | grep -E -f <(printf '%s\n' "$pats") 2>/dev/null | head -1 || true)"
  printf '%s' "$f"; return 0
}

# ── TAL-6719: inercia por insumo (CEO-RULING-T02-INERCIA-POR-INSUMO-0112) ──────────────────────
# `gate_afectado` mira SOLO el churn de main; nunca qué ficheros trae el PR. Un PR DISJUNTO de los
# insumos de un gate no aporta información nueva al re-correrlo sobre `main_nuevo` — ya se midió,
# en efecto, al fundirse el merge anterior. Gateado por TF_INERCIA_POR_INSUMO (manifiesto);
# `insumos-por-gate.conf` NO cambia — la inercia no redefine qué es insumo, solo decide si el PR
# en curso puede beneficiarse de lo que YA es insumo.
#
# _pr_disjunto_de <gate> <churn> → rc 0 si (1) PR_FILES ∩ churn = ∅ Y (2) ningún fichero de
# PR_FILES casa un insumo de <gate> (tras las exclusiones de `no_insumos_de_gate`, mismo criterio
# que `gate_afectado`). El `churn` es un parámetro — NO siempre es `$BT_CHURN` (el churn
# TESTADO..ATERRIZA de un receipt concreto): la reconciliación de roster no tiene un receipt/rbt
# de referencia, así que usa el avance plano `BASE_SHA..BASE_TIP_SHA` en su lugar (ver bloque de
# roster más abajo).
_pr_disjunto_de() {
  local g="$1" churn="$2" pats excl pr_files_f overlap _hit
  pats="$(insumos_de_gate "$g")" || return 1
  pr_files_f="$(printf '%s\n' "$PR_FILES" | grep -v '^$' || true)"
  if command -v no_insumos_de_gate >/dev/null 2>&1; then
    excl="$(no_insumos_de_gate "$g" || true)"
    if [ -n "$excl" ]; then
      pr_files_f="$(printf '%s\n' "$pr_files_f" | grep -E -v -f <(printf '%s\n' "$excl") 2>/dev/null || true)"
    fi
  fi
  # CERO×2 (hallazgo BLOQUEANTE): NUNCA gatear con `&&`/`||` sobre el rc CRUDO de una tubería que
  # termina en un consumidor de salida temprana (`grep -q`, `head`) bajo `set -o pipefail` (activo
  # en la cabecera del fichero) — un PR grande puede hacer que el productor reciba SIGPIPE al
  # cerrarse `grep -q` tras el primer match, y pipefail reporta ESE 141 (no el 0 de `grep -q`) como
  # rc de la tubería; el `&&` nunca dispara aunque SÍ hubiera match, y un receipt que debía
  # re-correrse se conserva (falso CONSERVA). Mismo idiom SEGURO que ya usa `gate_afectado`:
  # capturar el resultado con `$(...)` (el rc de la tubería interna es irrelevante dentro de una
  # sustitución de comando) y decidir sobre el VALOR capturado, nunca sobre el exit code crudo.
  _hit="$(printf '%s\n' "$pr_files_f" | grep -v '^$' | grep -E -f <(printf '%s\n' "$pats") 2>/dev/null | head -1 || true)"
  [ -z "$_hit" ] || return 1
  overlap="$(comm -12 <(printf '%s\n' "$PR_FILES" | grep -v '^$' | sort -u) \
                      <(printf '%s\n' "$churn" | grep -v '^$' | sort -u) | head -1 || true)"
  [ -z "$overlap" ] || return 1
  return 0
}

# _landing_tree_oid → deja el oid del árbol ATERRIZA (BASE_TIP_SHA+HEAD_SHA) en `_LG_LANDING_TREE`
# (SIDE EFFECT, no por stdout) y devuelve rc 0/1. Reutiliza `bt_merge_tree` como CAJA NEGRA (no se
# edita: el arnés de TAL-6674 la extrae por ancla byte a byte) — recomputa la MISMA fusión que
# `bt_prepara` ya hizo internamente para el `rbt` de cada receipt, pero esta vale para TODOS los
# receipts del run (BASE_TIP_SHA/HEAD_SHA son constantes durante toda la corrida).
#
# CERO×2 (hallazgo MENOR, corregido): la memoización SOLO funciona si esta función se llama como
# comando plano — `landing_tree="$(_landing_tree_oid)"` la invocaría en un SUBSHELL (la sustitución
# de comando siempre crea uno) y las asignaciones a `_LG_LANDING_KEY`/`_LG_LANDING_TREE` morirían
# con él, recalculando en cada llamada sin avisar. Por eso el resultado viaja por variable global,
# no por stdout — el llamante NUNCA debe envolver esta función en `$(...)`.
_LG_LANDING_KEY=""; _LG_LANDING_TREE=""
_landing_tree_oid() {
  local key="$BASE_TIP_SHA:$HEAD_SHA"
  if [ "$key" != "$_LG_LANDING_KEY" ]; then
    _LG_LANDING_KEY="$key"
    _LG_LANDING_TREE="$(bt_merge_tree "$BASE_TIP_SHA" "$HEAD_SHA" 2>/dev/null)" || _LG_LANDING_TREE=""
  fi
  [ -n "$_LG_LANDING_TREE" ]
}

# _blob_tiene_conflicto <tree> <path> → rc 0 si el blob de <path> en <tree> contiene un marcador
# de conflicto SIN RESOLVER. Mismo patrón exacto que el chequeo de insumo universal de
# `bt_prepara` (líneas de arriba, sin tocar) — leído del BLOB real, nunca del stdout de git ni de
# un mensaje traducido.
_blob_tiene_conflicto() {
  local tree="$1" path="$2" oid _marca
  oid="$(git -C "$CLONE" ls-tree --full-tree -- "$tree" "$path" 2>/dev/null | awk '{print $3}')"
  [ -n "$oid" ] || return 1
  # CERO×2 (hallazgo BLOQUEANTE, misma clase que _pr_disjunto_de): NUNCA `grep -qF ... ` como
  # última pieza de una tubería bajo `set -o pipefail` — un blob grande cuyo marcador aparece
  # pronto hace que `grep -q` cierre y `git cat-file` reciba SIGPIPE; pipefail reporta 141, no 0,
  # y el `&&` del llamante interpretaría "sin conflicto" cuando SÍ lo había (falso CONSERVA).
  # Capturar y decidir sobre el VALOR, nunca sobre el rc crudo de la tubería.
  _marca="$(git -C "$CLONE" cat-file -p "$oid" 2>/dev/null | grep -F '<<<<<<<' | head -1 || true)"
  [ -n "$_marca" ]
}

# pr_inerte_para_gate <gate> <hit-file> <receipt-result> → rc 0 si el PR es INERTE para este
# gate: las CINCO condiciones de TAL-6719, en el orden fail-closed
# universal→mergeable→merge-tree→churn→inercia (universal ya se decidió en `bt_prepara`, más
# arriba en el flujo; el `base_tip_sha` usable del receipt ya lo validó el LLAMANTE antes de
# invocar esta función, vía `bt_prepara`, en el bucle de receipts).
#   (5) <receipt-result> == "PASS" — un FAIL/SKIP nunca gana evidencia por disjunción
#   (4) PR_MERGEABLE == "MERGEABLE"
#   (3) el árbol que ATERRIZA no deja un conflicto SIN RESOLVER en el insumo que disparó el hit
#   (1)-(2) _pr_disjunto_de, sobre el churn TESTADO..ATERRIZA del receipt en curso
pr_inerte_para_gate() {
  local g="$1" hit="$2" rres="$3"
  [ "$rres" = "PASS" ] || return 1
  [ "$PR_MERGEABLE" = "MERGEABLE" ] || return 1
  # Llamada PLANA a propósito (nunca `$(...)`) — ver el comentario de `_landing_tree_oid`: la
  # memoización vive en `_LG_LANDING_TREE`, una variable global, no en el stdout de la función.
  _landing_tree_oid || return 1
  _blob_tiene_conflicto "$_LG_LANDING_TREE" "$hit" && return 1
  _pr_disjunto_de "$g" "$BT_CHURN"
}

REHACER=""; INERCIA=""; RECONCILIADOS=""

# ── [TAL-5644] Separar «no hay nada» de «no pude leer» ────────────────────────────────────
# Las lecturas del REGISTRO y del LOG DE RATIFICACIONES pasaban por `2>/dev/null || true`, que
# borra el diagnóstico Y el código de salida: una lectura fallida se volvía «no hay nada».
# ALCANCE, dicho con precisión: este arreglo cubre esas lecturas, las del mapa de insumos, el
# diff de migraciones y la lista de survivors del carve-out. Los tres `grep -E -f` de
# `bt_prepara`/`gate_afectado` conservan el patrón y quedan DECLARADOS, no arreglados: `grep`
# distingue rc 1 («no hay coincidencias», legítimo) de rc ≥ 2 («no pude buscar»), y ahí los dos
# se aplastan en la misma cadena vacía, con dirección permisiva. No se ha conseguido construir
# una ERE inválida con la gramática cerrada del `.conf`: mecanismo real, disparo NO demostrado.
# Reglas del arreglo:
#   · el rc se decide en el LLAMANTE. Un `die` DENTRO de una función invocada en `$( )` mata el
#     SUBSHELL, no el script (rc final 0): sería el mismo `|| true` con otro nombre.
#   · el temporal se borra con `rm -f` EXPLÍCITO en cada salida — `trap … RETURN` no se dispara
#     en un `bash script.sh`, y con `cat` como último comando ni siquiera dentro de la función.
#   · AUSENTE (rc 10) es un vacío legítimo; cualquier otro rc≠0 es NO MEDIDO.
# rc: 0 leído · 3 mktemp · 4 ls-tree · 5 modo no-blob · 6 show · 7 contenido≠blob · 10 ausente
git_blob_at() { # <sha> <ruta> → contenido por stdout
  local sha="$1" path="$2" t ent mode oid
  t="$(mktemp "${TMPDIR:-/tmp}/tf-blob-XXXXXXXX")" || return 3
  # --full-tree: sin él los pathspec de `ls-tree` son relativos al CWD (los de `show <rev>:<path>`
  # son relativos a la RAÍZ), y con --repo bajo el toplevel «presente» se leería como «ausente».
  ent="$(git -C "$CLONE" ls-tree --full-tree -- "$sha" "$path" 2>/dev/null)" || { rm -f "$t"; return 4; }
  [ -n "$ent" ] || { rm -f "$t"; return 10; }
  # Se compara el MODO, no la columna de tipo: `ls-tree` imprime `blob` también para un symlink
  # (120000), y `show <sha>:<symlink>` devuelve la ruta destino como contenido.
  mode="${ent%% *}"
  case "$mode" in 100644|100755) ;; *) rm -f "$t"; return 5 ;; esac
  oid="$(printf '%s' "$ent" | awk '{print $3}')"
  git -C "$CLONE" show "$sha:$path" > "$t" 2>/dev/null || { rm -f "$t"; return 6; }
  # `git show` vuelca el blob CRUDO; `hash-object` aplicaría `core.autocrlf` del clon y dejarían
  # de ser inversas (un clon con autocrlf activo mataría el camino sano). --no-filters lo evita.
  [ "$(git -C "$CLONE" hash-object --no-filters "$t")" = "$oid" ] || { rm -f "$t"; return 7; }
  # El rc de la función en el camino sano es el del VOLCADO, no el del `rm`: un `cat` que fallara
  # a media escritura devolvería 0 y el llamante leería contenido truncado como «leído».
  cat "$t"; _blob_rc=$?; rm -f "$t"; return $_blob_rc
}
reg_at() { git_blob_at "$1" "$SHARDS_REGISTRY"; }
reg_digest() { if [ -z "$1" ]; then echo "absent"; else printf '%s' "$1" | sha256sum | cut -d' ' -f1; fi; }
# Forma del registro, ANTES de derivar nada. Un documento sintácticamente válido puede declarar
# CERO cobertura sin ningún fallo de lectura: `"shards": []` es un array, y `all` sobre lista
# vacía es `true`. Con `.shards` vacío los gates SALEN de `expected` y sus receipts dejan de
# exigirse — peor que `.specs` vacío, donde el receipt se sigue pidiendo.
REG_FORM_MISS=""
reg_form_ok() { # <contenido> <familias-declaradas> → 0 ok · 1 forma inválida · 2 familia ausente
  local content="$1" fams="$2" f prev=0
  jq -s -e '
      if length == 1 and (.[0] | type == "object") then .[0]
      else error("registro JSON inválido") end |
      (.families | type == "object") and (.families | length > 0)
      and all(.families[]; (.shards | type == "array") and (.shards | length > 0))
      and all(.families[].shards[];
              (.id    | type == "string") and (.id | length > 0)
              and (.specs | type == "array") and (.specs | length > 0)
              and all(.specs[]; type == "string"))
      and (([.families | to_entries[] | .key as $k | .value.shards[] | "\($k):\(.id)"] | length)
        == ([.families | to_entries[] | .key as $k | .value.shards[] | "\($k):\(.id)"] | unique | length))
    ' <<<"$content" >/dev/null 2>&1 || return 1
  # Continencia: las familias que el manifiesto declara tienen que estar en el registro. Se parte
  # por espacios con globbing DESACTIVADO (un patrón se expandiría a rutas del cwd).
  case "$-" in *f*) prev=1 ;; esac
  set -f
  for f in $fams; do
    if ! jq -e --arg f "$f" '.families | has($f)' <<<"$content" >/dev/null 2>&1; then
      REG_FORM_MISS="$f"; [ "$prev" = 1 ] || set +f; return 2
    fi
  done
  [ "$prev" = 1 ] || set +f
  return 0
}
# Forma del TOKEN, con `case` y clases explícitas: sin motor de expresiones regulares. `grep -E`,
# `[[ =~ ]]` y `jq test()` NO coinciden entre sí bajo una locale UTF-8, y `LC_ALL=C [[ … ]]` ni
# siquiera es escribible (un prefijo de asignación solo vale delante de un comando SIMPLE).
# Los rangos `A-Z`/`a-z` de un glob se resuelven por ORDEN DE COLACIÓN, que es de la locale: sin
# fijarla, letras exóticas (İ U+0130, ǅ U+01C5) se cuelan bajo UTF-8 y no bajo C. Por eso cada
# función fija `LC_COLLATE=C` en su ámbito — como variable local, que sí funciona delante de `case`.
valida_tok_registro() { # familia:id — exactamente un dos-puntos, alfabeto cerrado
  local tok="$1" fam id LC_COLLATE=C
  case "$tok" in
    *:*:*)  return 1 ;;
    :*|*:)  return 1 ;;
    *:*)    fam="${tok%%:*}"; id="${tok#*:}"
            case "$fam$id" in *[!A-Za-z0-9._-]*) return 1 ;; esac ;;
    *)      return 1 ;;
  esac
}
valida_tok_plano() { local LC_COLLATE=C; case "$1" in ""|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
# El rc de `jq` ya NO se descarta y el stderr ya NO se silencia: el llamante lo comprueba y el
# mensaje que nombra la familia llega al operador.
shards_of() { # <contenido-registro> → líneas "familia:shard"
  [ -n "$1" ] || return 0
  jq -r '.families | to_entries[] | .key as $f | .value.shards[]
         | "\($f):\((.id // error("shard sin .id en la familia \($f)")))"' <<<"$1"
}
specs_of() { # <contenido-registro> → líneas "familia:shard:spec" (B3: la unidad de cobertura)
  [ -n "$1" ] || return 0
  jq -r '.families | to_entries[] | .key as $f | .value.shards[] | .id as $s | (.specs // [])[] | "\($f):\($s):\(.)"' <<<"$1"
}
BASE_REG_CONTENT=""; HEAD_REG_CONTENT=""; BASE_REG_DIGEST="n/a"; HEAD_REG_DIGEST="n/a"
EXPECTED_E2E=""
# [TAL-5644] La ausencia de AMBAS claves es legítima (7 de los 8 manifiestos están así); la de UNA
# SOLA no lo es en ningún caso: el bloque e2e se apagaría entero sin ruido y los shards dejarían de
# exigirse. El AND se convierte en XOR explícito.
if { [ -n "$SHARDS_REGISTRY" ] && [ -z "$E2E_FAMILIES" ]; } || { [ -z "$SHARDS_REGISTRY" ] && [ -n "$E2E_FAMILIES" ]; }; then
  die "el manifiesto declara solo UNA de TF_SHARDS_REGISTRY/TF_E2E_FAMILIES — o las dos o ninguna (con una sola, los gates e2e dejarían de exigirse en silencio)"
fi
if [ -n "$SHARDS_REGISTRY" ] && [ -n "$E2E_FAMILIES" ]; then
  # ── Append-only del log de ratificaciones en TODO PR (B2 r7) ──────────────────────────────
  # Antes se validaba SOLO cuando el PR reducía el registro: un PR A podía reescribir/borrar
  # el log sin reducir nada, y un PR B posterior reducía comparando contra el log ya
  # falsificado de su base. Ahora CUALQUIER PR que toque la historia del log en head debe
  # ser append-only respecto a base (igual que motor-go con el log de manifiestos).
  # [TAL-5644] `${SHARDS_REGISTRY%/*}` no recorta nada si la ruta no lleva `/`, y fabricaría un
  # ratlog que no existe en ningún commit ⇒ `base_rat` vacío ⇒ el append-only no se entraría.
  # Se exige `/` en vez de derivar con `dirname` A PROPÓSITO: `dirname` admitiría un registro en
  # la RAÍZ del repo, disposición legítima para otro producto — exigir `/` la prohíbe.
  case "$SHARDS_REGISTRY" in */*) ;; *) die "TF_SHARDS_REGISTRY='$SHARDS_REGISTRY' sin '/': el registro no puede vivir en la raíz del repo (de ahí se deriva la ruta del log de ratificaciones)" ;; esac
  RATLOG_PATH="${SHARDS_REGISTRY%/*}/REGISTRY-RATIFICACIONES.log"
  # Se declara AQUÍ, fuera de todo condicional: la consume también el bloque de la ratificación,
  # que está gobernado por otra condición (`reduced`). Con `set -u`, declararla dentro del
  # `if [ -n "$base_rat" ]` abortaba el camino de la PRIMERA ratificación de un repo —el log se
  # crea en el mismo PR que retira el shard— con `unbound variable` y rc 1, que la cabecera de
  # este fichero define como «POSTEADO failure» sin haber posteado nada.
  _rat_nl=$'\n'
  base_rat="$(git_blob_at "$BASE_SHA" "$RATLOG_PATH")"; rc=$?
  case $rc in 0) ;; 10) base_rat="" ;; *) die "$RATLOG_PATH ILEGIBLE en base $BASE_SHA (NO MEDIDO, rc=$rc)" ;; esac
  head_rat="$(git_blob_at "$HEAD_SHA" "$RATLOG_PATH")"; rc=$?
  case $rc in 0) ;; 10) head_rat="" ;; *) die "$RATLOG_PATH ILEGIBLE en head $HEAD_SHA (NO MEDIDO, rc=$rc)" ;; esac
  if [ -n "$base_rat" ]; then
    [ -n "$head_rat" ] || die "$RATLOG_PATH ELIMINADO en head — el registro de ratificaciones es append-only en TODO PR (borrar historial de aprobaciones = falso verde posterior)"
    # [TAL-5644] El append-only comparaba un PREFIJO DE BYTES: AMPLIAR la última línea existente
    # pasaba el chequeo, y la ampliación se convertía en `added_rat` y RATIFICABA una reducción
    # SIN añadir ninguna entrada. Se compara por LÍNEA COMPLETA: el byte que sigue al prefijo
    # tiene que ser un salto de línea (o no haber nada más).
    [ "${head_rat:0:${#base_rat}}" = "$base_rat" ] || die "$RATLOG_PATH reescrito (no append-only) respecto a base — en TODO PR, reduzca o no el registro"
    # OJO: `$(printf '\n')` vale CADENA VACÍA — la sustitución de comando se come los saltos
    # finales—, así que comparar contra ella mataría toda línea añadida legítima. Literal `$'\n'`.
    _rat_next="${head_rat:${#base_rat}:1}"
    [ -z "$_rat_next" ] || [ "$_rat_next" = "$_rat_nl" ] || die "$RATLOG_PATH: la ÚLTIMA línea de base fue AMPLIADA en head — append-only significa entradas NUEVAS, no editar una existente"
  fi
  BASE_REG_CONTENT="$(reg_at "$BASE_SHA")"; rc=$?
  case $rc in 0) ;; 10) BASE_REG_CONTENT="" ;; *) die "registro de shards ILEGIBLE en base $BASE_SHA (NO MEDIDO, rc=$rc)" ;; esac
  HEAD_REG_CONTENT="$(reg_at "$HEAD_SHA")"; rc=$?
  case $rc in 0) ;; 10) HEAD_REG_CONTENT="" ;; *) die "registro de shards ILEGIBLE en head $HEAD_SHA (NO MEDIDO, rc=$rc)" ;; esac
  # Forma del registro en AMBOS contenidos, antes de derivar. Sobre base también: si no, un `.id`
  # a null o una familia vacía en base borran tokens de `base_shards` y la reducción real deja de
  # verse — fail-open, justo el que se viene a cerrar.
  for _side in base head; do
    [ "$_side" = base ] && _c="$BASE_REG_CONTENT" || _c="$HEAD_REG_CONTENT"
    [ -n "$_c" ] || continue
    reg_form_ok "$_c" "$E2E_FAMILIES"; _rc=$?
    [ "$_rc" = 0 ] || die "registro de shards con FORMA inválida en $_side ($([ "$_rc" = 2 ] && echo "la familia declarada '$REG_FORM_MISS' no está en el registro" || echo "families/shards/.id/.specs o unicidad del token familia:id"))"
  done
  BASE_REG_DIGEST="$(reg_digest "$BASE_REG_CONTENT")"; HEAD_REG_DIGEST="$(reg_digest "$HEAD_REG_CONTENT")"
  # [TAL-5644] El rc de `jq` se comprueba en el LLAMANTE (dentro de `$( )` un `die` no mataría el
  # script), y el CONTEO emitido tiene que cuadrar con el declarado: `jq` emite por STREAMING, así
  # que una familia malformada deja líneas ya escritas y aborta después.
  _sh_raw="$(shards_of "$BASE_REG_CONTENT")" || die "no pude derivar los shards de BASE (jq rc=$?) — registro ILEGIBLE (NO MEDIDO)"
  _n_decl="$(jq -r '[.families[].shards[]] | length' <<<"${BASE_REG_CONTENT:-{\}}" 2>/dev/null || echo -1)"
  [ -z "$BASE_REG_CONTENT" ] || [ "$(printf '%s\n' "$_sh_raw" | grep -c .)" = "$_n_decl" ] \
    || die "shards de BASE: emitidos $(printf '%s\n' "$_sh_raw" | grep -c .) vs declarados $_n_decl (emisión PARCIAL, NO MEDIDO)"
  base_shards="$(printf '%s\n' "$_sh_raw" | grep . | sort -u || true)"
  _sh_raw="$(shards_of "$HEAD_REG_CONTENT")" || die "no pude derivar los shards de HEAD (jq rc=$?) — registro ILEGIBLE (NO MEDIDO)"
  _n_decl="$(jq -r '[.families[].shards[]] | length' <<<"${HEAD_REG_CONTENT:-{\}}" 2>/dev/null || echo -1)"
  [ -z "$HEAD_REG_CONTENT" ] || [ "$(printf '%s\n' "$_sh_raw" | grep -c .)" = "$_n_decl" ] \
    || die "shards de HEAD: emitidos $(printf '%s\n' "$_sh_raw" | grep -c .) vs declarados $_n_decl (emisión PARCIAL, NO MEDIDO)"
  head_shards="$(printf '%s\n' "$_sh_raw" | grep . | sort -u || true)"
  # Forma del token en el lado del REGISTRO (el otro lado, TF_GATE_IDS, se valida en su sitio).
  while IFS= read -r _t; do
    [ -z "$_t" ] && continue
    valida_tok_registro "$_t" || die "token de registro con forma inválida: '$_t' (familia:id, alfabeto [A-Za-z0-9._-], un solo ':')"
  done <<EOF
$base_shards
$head_shards
EOF
  # Anti-reducción a DOS niveles (B3 audit TAL-2293): base = mínimo autorizado.
  # (1) shards: head debe ser superconjunto; (2) SPECS dentro de cada shard: quitar un spec
  # conservando el id del shard también reduce cobertura → mismo tratamiento.
  reduced="$(comm -23 <(printf '%s\n' "$base_shards") <(printf '%s\n' "$head_shards") | grep . || true)"
  # [TAL-5644] Ídem para specs. El conteo declarado usa la MISMA semántica que el emisor
  # (`(.specs // [])`): la expresión sin esa tolerancia aborta sobre un shard sin `.specs`, que el
  # emisor admite a propósito, y sería un falso `die` sobre un registro legítimo.
  _sp_raw="$(specs_of "$BASE_REG_CONTENT")" || die "no pude derivar los specs de BASE (jq rc=$?) — registro ILEGIBLE (NO MEDIDO)"
  _n_decl="$(jq -r '[.families[].shards[] | (.specs // [])[]] | length' <<<"${BASE_REG_CONTENT:-{\}}" 2>/dev/null || echo -1)"
  [ -z "$BASE_REG_CONTENT" ] || [ "$(printf '%s\n' "$_sp_raw" | grep -c .)" = "$_n_decl" ] \
    || die "specs de BASE: emitidos $(printf '%s\n' "$_sp_raw" | grep -c .) vs declarados $_n_decl (emisión PARCIAL, NO MEDIDO)"
  base_specs="$(printf '%s\n' "$_sp_raw" | grep . | sort -u || true)"
  _sp_raw="$(specs_of "$HEAD_REG_CONTENT")" || die "no pude derivar los specs de HEAD (jq rc=$?) — registro ILEGIBLE (NO MEDIDO)"
  _n_decl="$(jq -r '[.families[].shards[] | (.specs // [])[]] | length' <<<"${HEAD_REG_CONTENT:-{\}}" 2>/dev/null || echo -1)"
  [ -z "$HEAD_REG_CONTENT" ] || [ "$(printf '%s\n' "$_sp_raw" | grep -c .)" = "$_n_decl" ] \
    || die "specs de HEAD: emitidos $(printf '%s\n' "$_sp_raw" | grep -c .) vs declarados $_n_decl (emisión PARCIAL, NO MEDIDO)"
  head_specs="$(printf '%s\n' "$_sp_raw" | grep . | sort -u || true)"
  reduced_specs="$(comm -23 <(printf '%s\n' "$base_specs") <(printf '%s\n' "$head_specs") | grep . || true)"
  # Un spec "desaparecido" por shard eliminado ya está cubierto por (1); filtra para no duplicar diagnóstico.
  if [ -n "$reduced_specs" ] && [ -n "$reduced" ]; then
    reduced_specs="$(printf '%s\n' "$reduced_specs" | grep -vF -f <(printf '%s\n' "$reduced" | sed 's/$/:/') || true)"
  fi
  if [ -n "$reduced" ] || [ -n "$reduced_specs" ]; then
    # Ratificación DURABLE con FORMATO CERRADO (M4 r6 + M3 r7): entrada nueva y append-only
    # en el log versionado del repo de producto, en el head del PR. Cada entrada:
    #   <fecha> | ref=<TAL-n/URL/quién> | items=<item1,item2> | <motivo>
    # Un item retirado solo queda ratificado si aparece como TOKEN COMPLETO en el campo
    # items= de una entrada añadida que lleve ref= EN ESA MISMA LÍNEA (grep -qF permitiría
    # que 'fam:s10' cubriera 'fam:s1' — por eso la comparación es exacta por token).
    [ -n "$head_rat" ] || die "el head REDUCE el registro (shards: [$(echo "$reduced" | tr '\n' ' ')] specs: [$(echo "$reduced_specs" | tr '\n' ' ')]) y NO existe $RATLOG_PATH en head — exige ratificación durable del lead (entrada '| ref=... | items=... |')"
    # [TAL-5644] La frontera es de LÍNEA: se descarta el salto que separa base de lo añadido, para
    # que `added_rat` sean entradas NUEVAS completas y nunca la cola de una línea ampliada.
    added_rat="${head_rat:${#base_rat}}"
    added_rat="${added_rat#"$_rat_nl"}"
    [ -n "$added_rat" ] || die "el head reduce el registro pero $RATLOG_PATH no añade ninguna entrada nueva"
    rat_line_covers() { # <item> — línea añadida con ref= e items= que contenga el token EXACTO
      local ln its
      while IFS= read -r ln; do
        grep -q 'ref=[^|[:space:]]' <<<"$ln" || continue
        its="$(sed -n 's/.*items=\([^|]*\).*/\1/p' <<<"$ln" | tr -d '[:space:]')"
        [ -n "$its" ] || continue
        printf '%s' "$its" | tr ',' '\n' | grep -qxF "$1" && return 0
      done <<<"$added_rat"
      return 1
    }
    for item in $reduced $reduced_specs; do
      rat_line_covers "$item" || die "$RATLOG_PATH no ratifica '$item' con una entrada estructurada nueva ('<fecha> | ref=<aprobación> | items=${item}[,...] | <motivo>') — el token debe coincidir EXACTO"
    done
    echo "[post-local-gates] ⚠ reducción de registro RATIFICADA en $RATLOG_PATH ($(grep -o 'ref=[^|[:space:]]*' <<<"$added_rat" | tr '\n' ' ')): shards[$(echo "$reduced" | tr '\n' ' ')] specs[$(echo "$reduced_specs" | tr '\n' ' ')]"
  fi
  EXPECTED_E2E="$head_shards"
  [ -n "$EXPECTED_E2E" ] || die "registro de shards vacío/ilegible en head (fail-closed)"

  # ── TAL-6719 (b): reconciliación roster head↔main VIVO ────────────────────────────────────
  # `EXPECTED_E2E` sale del registro en HEAD (arriba) — pero main VIVO puede haber sumado un
  # shard nuevo que el head nunca declaró (ver `e2e-pagos:pagos-o-code-redirect`, #2104, caso real
  # de la issue). Sin esto ese shard queda invisible: nadie lo exige y nadie lo mide para ESTE PR.
  # Gateado por TF_INERCIA_POR_INSUMO — apagado, el comportamiento es el de siempre.
  if [ "$INERCIA_POR_INSUMO" = "1" ]; then
    MAIN_VIVO_REG_CONTENT="$(reg_at "$BASE_TIP_SHA")"; rc=$?
    case $rc in 0) ;; 10) MAIN_VIVO_REG_CONTENT="" ;; *) die "registro de shards ILEGIBLE en main vivo $BASE_TIP_SHA (NO MEDIDO, rc=$rc)" ;; esac
    if [ -n "$MAIN_VIVO_REG_CONTENT" ]; then
      reg_form_ok "$MAIN_VIVO_REG_CONTENT" "$E2E_FAMILIES"; _rc=$?
      [ "$_rc" = 0 ] || die "registro de shards con FORMA inválida en main vivo ($([ "$_rc" = 2 ] && echo "la familia declarada '$REG_FORM_MISS' no está en el registro" || echo "families/shards/.id/.specs o unicidad del token familia:id"))"
      _sh_raw="$(shards_of "$MAIN_VIVO_REG_CONTENT")" || die "no pude derivar los shards de main vivo (jq rc=$?) — registro ILEGIBLE (NO MEDIDO)"
      _n_decl="$(jq -r '[.families[].shards[]] | length' <<<"${MAIN_VIVO_REG_CONTENT:-{\}}" 2>/dev/null || echo -1)"
      [ "$(printf '%s\n' "$_sh_raw" | grep -c .)" = "$_n_decl" ] \
        || die "shards de main vivo: emitidos $(printf '%s\n' "$_sh_raw" | grep -c .) vs declarados $_n_decl (emisión PARCIAL, NO MEDIDO)"
      main_vivo_shards="$(printf '%s\n' "$_sh_raw" | grep . | sort -u || true)"
      nuevos_en_main="$(comm -13 <(printf '%s\n' "$head_shards") <(printf '%s\n' "$main_vivo_shards") | grep . || true)"
      if [ -n "$nuevos_en_main" ]; then
        # OJO (hallazgo de auto-revisión, no del texto literal de la issue): "censo mixto
        # aceptado" NO significa exigir un receipt para el shard nuevo — NINGÚN runner pudo
        # haberlo producido, porque el registro que vio al despachar era el de HEAD (sin este
        # shard). Añadirlo a EXPECTED_E2E convertiría la aceptación en un rechazo GARANTIZADO
        # ("faltan receipts para gates esperados") — exactamente lo contrario de lo que esta
        # pieza busca. Aceptar = NO exigirlo (EXPECTED_E2E se queda en head_shards, sin tocar) y
        # solo ANOTAR que se reconoció y se dejó pasar; rechazar = `die` fail-closed.
        _main_advance_churn="$(git -C "$CLONE" diff --name-only "$BASE_SHA" "$BASE_TIP_SHA" 2>/dev/null)" \
          || die "no pude medir el avance $BASE_SHA..$BASE_TIP_SHA para reconciliar el roster (NO MEDIDO)"
        while IFS= read -r tok; do
          [ -n "$tok" ] || continue
          if _pr_disjunto_de "e2e" "$_main_advance_churn"; then
            RECONCILIADOS="$RECONCILIADOS $tok"
            echo "[post-local-gates] TAL-6719: shard nuevo de main vivo '$tok' — PR disjunto de insumos e2e, censo mixto aceptado (NO exigido para este PR)"
          else
            die "shard nuevo en main no medido para este PR: replantar el head ('$tok' presente en main vivo $BASE_TIP_SHA, ausente en head, y el PR NO es disjunto de los insumos e2e)"
          fi
        done <<EOF
$nuevos_en_main
EOF
      fi
    fi
  fi
fi

# ── 3. Gate branch-name: validador canónico desde BASE_SHA, subprocess sin credenciales. ──────
# Excepción Dependabot por AUTOR (preservada de pr-gate.yml): sus ramas dependabot/** no siguen
# la convención del repo y el workflow original las eximía.
BRANCH_GATE="PASS"
case "$AUTHOR" in
  dependabot*|app/dependabot*) BRANCH_GATE="SKIP"; echo "[post-local-gates] branch-name: SKIP (excepción Dependabot por autor: $AUTHOR)";;
  *)
    vtmp="$(mktemp "${TMPDIR:-/tmp}/branch-validator-XXXXXXXX.sh")" || die "mktemp"
    if ! git -C "$CLONE" show "$BASE_SHA:$BRANCH_VALIDATOR" > "$vtmp" 2>/dev/null; then
      rm -f "$vtmp"; die "no existe $BRANCH_VALIDATOR en base $BASE_SHA (fail-closed)"
    fi
    if env -i PATH="/usr/bin:/bin" bash "$vtmp" "$HEAD_REF" >/dev/null 2>&1; then
      BRANCH_GATE="PASS"; echo "[post-local-gates] branch-name: PASS ($HEAD_REF, validador de base ${BASE_SHA:0:12}, subprocess sin credenciales)"
    else
      BRANCH_GATE="FAIL"; echo "[post-local-gates] branch-name: FAIL ($HEAD_REF rechazada por el validador canónico de base)"
    fi
    rm -f "$vtmp"
    ;;
esac

# ── 4. Conjunto esperado (dueño: ESTE agregador) y validación de receipts. ────────────────────
expected="$(printf '%s\n%s\n' "$GATE_IDS" "" | tr ' ' '\n' | grep . ; printf '%s\n' "$EXPECTED_E2E" | grep . || true)"
expected="$(printf '%s\n' "$expected" | sort -u)"
# [TAL-5644] Forma del token en el OTRO lado de la comparación. `grep -qx` es estricto byte a byte
# y el bucle de faltantes usa `read -r`, que descarta el espacio final por IFS: el mismo token era
# «desconocido» para un chequeo y «esperado» para el otro, y salían los DOS mensajes con el id
# aparentemente limpio. Los ids del registro llevan `familia:id`; los de TF_GATE_IDS son planos.
while IFS= read -r _t; do
  [ -z "$_t" ] && continue
  case "$_t" in
    *:*) valida_tok_registro "$_t" || die "gate_id esperado con forma inválida: '$_t' (familia:id)" ;;
    *)   valida_tok_plano    "$_t" || die "gate_id esperado con forma inválida: '$_t' (token plano [A-Za-z0-9._-], sin ':')" ;;
  esac
done <<EOF
$expected
EOF

errors=0; fails=0; no_medidos=0
declare -A seen
bad() { echo "[post-local-gates] RECHAZO  $1" >&2; errors=$((errors+1)); }

# [TAL-5644] Si `git diff` FALLA no imprime nada, `grep -q .` devuelve 1 y el `!` lo convierte en 0:
# «no pude medir el diff» se volvía «el diff no toca migraciones», y con TF_DB_GATE=auto eso daba
# db-guards por «cubierto por política» SIN ningún receipt. Se captura salida y rc por separado.
# El `die` se hace UNA vez, AQUÍ, fuera del bucle de receipts: dentro abortaría la agregación en el
# primer receipt y se llevaría por delante el resumen accionable que este fichero construye a
# propósito — el mismo criterio por el que la guarda de carve-out usa `bad … continue`. La función
# que el bucle invoca ya solo compara un valor MEDIDO.
_mig_diff_out="$(git -C "$CLONE" diff --name-only "$BASE_SHA" "$HEAD_SHA" -- "$MIG_DIR")" \
  || die "no pude medir el diff de $MIG_DIR entre $BASE_SHA y $HEAD_SHA (NO MEDIDO)"
_mig_diff_empty=1; [ -z "$(printf '%s\n' "$_mig_diff_out" | grep . || true)" ] || _mig_diff_empty=0
mig_diff_empty() { [ "$_mig_diff_empty" = 1 ]; }

journal_entry() { # <receipt-sha256> <run-group> <gate-id> <journal>
  jq -R -c --arg rs "$1" --arg rg "$2" --arg g "$3" \
    'fromjson? | select(type == "object") | select(has("kind") | not) | select(.receipt_sha256 == $rs and .run_group == $rg and .gate_id == $g)' "$4" | tail -1
}

for r in "$RECEIPTS"/*.json; do
  [ -e "$r" ] || die "sin receipts en $RECEIPTS"
  jq -e . "$r" >/dev/null 2>&1 || { bad "$r: JSON ilegible"; continue; }
  jq -e '.schema_version == 1' "$r" >/dev/null 2>&1 || { bad "$r: schema_version != 1"; continue; }
  # Forma ÚNICA (M2-rev6): exactamente UN gate_id string — ni cero ni lista.
  jq -e '(.gate_id | type == "string") and (.gate_id | length > 0) and (has("gates") | not)' "$r" >/dev/null 2>&1 \
    || { bad "$r: el receipt debe declarar EXACTAMENTE un gate_id"; continue; }
  g="$(jq -r '.gate_id' "$r")"
  # ── Procedencia SELLADA (B2): el receipt debe estar respaldado por una entrada del journal
  #    de la estación con su sha256 EXACTO, mismo run_group y mismo gate, y su resultado debe
  #    ser coherente con el EXIT CODE que la estación OBSERVÓ al lanzar el runner. Un receipt
  #    fabricado, manipulado post-sellado, o de un run inline NO entra a la agregación.
  rsha="$(sha256sum "$r" | cut -d' ' -f1)"
  jentry="$(journal_entry "$rsha" "$RUN_GROUP" "$g" "$JOURNAL" 2>/dev/null)"
  [ -n "$jentry" ] || { bad "$r ($g): SIN procedencia sellada (ninguna entrada del journal respalda su sha256 para este run_group) — receipt fabricado o manipulado"; continue; }
  [ "$(jq -r '.assignment // ""' "$r")" = "sealed" ] \
    || { bad "$r ($g): assignment '$(jq -r '.assignment' "$r")' — solo receipts de asignación SELLADA son agregables (inline = trabajo propio, no evidencia)"; continue; }
  # La asignación del sellado debe ser REAL (sha256 de un fichero de asignación, no un
  # placeholder) y la ejecución debe haber ocurrido AISLADA en un contenedor runner —
  # `station-local` (diagnóstico --unsafe-local) NO es evidencia: el código del PR habría
  # corrido con el UID/HOME/credenciales de la estación (B2 audit TAL-2293).
  jq -e '.assignment_sha256 | test("^[0-9a-f]{64}$")' <<<"$jentry" >/dev/null 2>&1 \
    || { bad "$r ($g): journal sin assignment_sha256 real (sellado sin asignación verificable)"; continue; }
  jq -e '.isolation | test("^container:")' <<<"$jentry" >/dev/null 2>&1 \
    || { bad "$r ($g): isolation '$(jq -r '.isolation // "ausente"' <<<"$jentry")' — la evidencia agregable exige ejecución en contenedor runner (station-local = diagnóstico)"; continue; }
  # El MOTOR ejecutado queda atado a la evidencia (M4 r4): el launcher empuja SIEMPRE su
  # run-local-gates.sh y sella su sha256; todos los gates del run_group deben haber corrido
  # el MISMO motor (64-hex consistente).
  jq -e '.motor_sha256 | test("^[0-9a-f]{64}$")' <<<"$jentry" >/dev/null 2>&1 \
    || { bad "$r ($g): journal sin motor_sha256 real (el motor ejecutado no está atado a la evidencia)"; continue; }
  jm="$(jq -r '.motor_sha256' <<<"$jentry")"
  [ "$jm" = "$APPROVED_MOTOR_SHA" ] \
    || { bad "$r ($g): el motor del sellado ($jm) NO es el motor APROBADO de la estación ($APPROVED_MOTOR_SHA)"; continue; }
  rm_hash="$(jq -r '.motor_sha256 // ""' "$r")"
  [ "$rm_hash" = "$APPROVED_MOTOR_SHA" ] \
    || { bad "$r ($g): el receipt declara motor '$rm_hash' — no es el aprobado (auto-atestación del runner divergente)"; continue; }
  # Lib de carve-out ATESTADA (r4): el clasificador que corrió en el runner debe ser EXACTAMENTE el
  # aprobado. Journal y receipt lo atan por sha256, como el motor — sin esto correría código no
  # verificado en el runner sellado.
  jq -e '.carveout_sha256 | test("^[0-9a-f]{64}$")' <<<"$jentry" >/dev/null 2>&1 \
    || { bad "$r ($g): journal sin carveout_sha256 real (la lib de carve-out no está atada a la evidencia)"; continue; }
  [ "$(jq -r '.carveout_sha256' <<<"$jentry")" = "$APPROVED_CARVEOUT_SHA" ] \
    || { bad "$r ($g): la lib de carve-out del sellado NO es la aprobada de la estación"; continue; }
  [ "$(jq -r '.carveout_sha256 // ""' "$r")" = "$APPROVED_CARVEOUT_SHA" ] \
    || { bad "$r ($g): el receipt declara una lib de carve-out no aprobada (auto-atestación divergente)"; continue; }
  jexit="$(jq -r '.exit_code' <<<"$jentry")"
  rres="$(jq -r '.result' "$r")"
  case "$jexit:$rres" in
    0:PASS|0:SKIP|1:FAIL) : ;;
    *) bad "$r ($g): result '$rres' INCOHERENTE con el exit observado por la estación ($jexit)"; continue;;
  esac
  # Identidad completa contra el tuple de agregación.
  id_ok=1
  [ "$(jq -r '.repo' "$r")" = "$OWNER_REPO" ]              || { bad "$r ($g): repo != $OWNER_REPO"; id_ok=0; }
  [ "$(jq -r '.pr // ""' "$r")" = "$PR" ]                  || { bad "$r ($g): pr != $PR"; id_ok=0; }
  [ "$(jq -r '.sha' "$r")" = "$HEAD_SHA" ]                 || { bad "$r ($g): sha != head del PR"; id_ok=0; }
  [ "$(jq -r '.base_sha' "$r")" = "$BASE_SHA" ]            || { bad "$r ($g): base_sha != merge-base actual (¿main avanzó? re-correr el run_group)"; id_ok=0; }
  # B2 r6: el tip de la rama base viaja SELLADO desde la asignación hasta el receipt —
  # el gate se corrió sobre ESE estado de main, no solo sobre ese merge-base.
  rbt="$(jq -r '.base_tip_sha // ""' "$r")"
  if [ "$rbt" != "$BASE_TIP_SHA" ]; then
    if ! bt_prepara "$rbt"; then
      bad "$r ($g): base_tip_sha '$rbt' no vale contra el tip actual de $BASE_NAME ($BASE_TIP_SHA) — $BT_ANCESTRO"; id_ok=0
    else
      [ -n "${BT_AVISADO:-}" ] || { echo "[post-local-gates] base_tip ${rbt:0:12} es ANCESTRO de ${BASE_TIP_SHA:0:12}: se valida gate a gate contra sus insumos (CEO 19:19)"; BT_AVISADO=1; }
      if ! bt_hit="$(gate_afectado "$g")"; then
        bad "$r ($g): el gate no tiene entrada en el mapa de insumos (fail-closed) — no puedo saber si el avance de $BASE_NAME lo afecta"; id_ok=0
        REHACER="$REHACER $g"
      elif [ -n "$bt_hit" ]; then
        if [ "$INERCIA_POR_INSUMO" = "1" ] && pr_inerte_para_gate "$g" "$bt_hit" "$rres"; then
          INERCIA="$INERCIA $g"
          echo "[post-local-gates] TAL-6719: $g CONSERVADO por inercia (PR disjunto de sus insumos y del churn; el avance de $BASE_NAME tocó $bt_hit)"
          _lg_pr_files_sha256="$(printf '%s\n' "$PR_FILES" | sha256sum | cut -d' ' -f1)"
          jq -nc --arg rg "$RUN_GROUP" --arg g "$g" --arg rsha "$rsha" --arg btr "$rbt" \
                 --arg bta "$BASE_TIP_SHA" --arg pfsha "$_lg_pr_files_sha256" --arg hit "$bt_hit" \
                 --arg ts "$(date -u +%FT%TZ)" \
            '{kind:"inercia-por-insumo", run_group:$rg, gate_id:$g, receipt_sha256:$rsha, base_tip_receipt:$btr, base_tip_actual:$bta, pr_files_sha256:$pfsha, churn_hit:$hit, sealed_at:$ts}' \
            | flock -x "$JOURNAL.lock" bash -c '
        set -euo pipefail
        if [ -s "$1" ] && [ "$(tail -c 1 "$1" | od -An -tu1 | tr -d "[:space:]")" != 10 ]; then
          printf "\n" | tee -a "$1" >/dev/null
        fi
        tee -a "$1" >/dev/null
      ' _ "$JOURNAL" \
            || die "no pude sellar en el journal la conservación por inercia de $g"
        else
          bad "$r ($g): el avance de $BASE_NAME toca un INSUMO de este gate: $bt_hit — hay que re-correrlo"; id_ok=0
          REHACER="$REHACER $g"
        fi
      fi
    fi
  fi
  [ "$(jq -r '.manifest_digest' "$r")" = "$MANIFEST_DIGEST" ] || { bad "$r ($g): manifest_digest != manifiesto vigente"; id_ok=0; }
  [ "$(jq -r '.run_group' "$r")" = "$RUN_GROUP" ]          || { bad "$r ($g): run_group ajeno"; id_ok=0; }
  if [ -n "$SHARDS_REGISTRY" ]; then
    [ "$(jq -r '.base_registry_digest' "$r")" = "$BASE_REG_DIGEST" ] || { bad "$r ($g): base_registry_digest divergente"; id_ok=0; }
    [ "$(jq -r '.head_registry_digest' "$r")" = "$HEAD_REG_DIGEST" ] || { bad "$r ($g): head_registry_digest divergente"; id_ok=0; }
  fi
  [ "$id_ok" = "1" ] || continue
  # [TAL-5644] `-F`: sin él, `$g` viene del receipt y entra como EXPRESIÓN REGULAR — `typechec.` o
  # `.*` encajarían, y `.` es un carácter legal del alfabeto de gate_id.
  printf '%s\n' "$expected" | grep -qxF "$g" || { bad "$r: gate_id '$g' fuera del inventario esperado"; continue; }
  [ -z "${seen[$g]:-}" ] || { bad "$r: gate_id '$g' DUPLICADO en el run_group"; continue; }
  seen[$g]="$r"
  res="$(jq -r '.result' "$r")"
  case "$res" in
    PASS) : ;;
    FAIL) fails=$((fails+1)); echo "[post-local-gates]   ✗ $g: FAIL (receipt $r)";;
    SKIP)
      reason="$(jq -r '.skip_reason // ""' "$r")"
      [ -n "$reason" ] || { bad "$r ($g): SKIP sin razón"; continue; }
      # Enrutado por TOKEN del skip_reason. INVARIANTE LOAD-BEARING (H2): `seen[$g]` ya se fijó
      # ARRIBA (antes del switch), así que TODA rama de rechazo DEBE llamar `bad` (nunca un
      # `continue` pelado) — si no, el gate cuenta como visto, evade el check `missing` de abajo,
      # `errors` no sube, y el PR va VERDE (falso verde). El `AND recompute` es innegociable.
      case "$reason" in
        carve-out-docs-only:*)
          # Carve-out docs-only (TAL-2749): RECOMPUTAR con la lib APROBADA de la estación.
          [ "${CARVEOUT_ENABLED:-}" = "1" ] \
            || { bad "$r ($g): SKIP carve-out pero TF_CARVEOUT_DOCS_ONLY!=1 en el manifiesto vigente"; continue; }
          # [TAL-5644] `mget` devuelve la MISMA cadena vacía para «no declarada», «renombrada» y
          # «no pude leerla»; con la lista vacía `carveout_gate_skippable` devuelve 0 para TODO y
          # el fast-path pasaría a saltarse el inventario entero. Va aquí —dentro del case, no en
          # la lectura de :94, que es incondicional y mataría a 7 de los 8 manifiestos— y con
          # `bad … continue` como sus hermanas: un `die` en el bucle abortaría la agregación en el
          # primer receipt y se llevaría por delante el resumen accionable.
          [ -n "${CARVEOUT_KEEP:-}" ] \
            || { bad "$r ($g): TF_CARVEOUT_DOCS_ONLY activo sin TF_CARVEOUT_KEEP_GATES — sin survivors declarados el fast-path saltaría TODO (fail-closed)"; continue; }
          carveout_gate_skippable "$g" "${CARVEOUT_KEEP:-}" \
            || { bad "$r ($g): SKIP carve-out no admitido — el gate está en TF_CARVEOUT_KEEP_GATES (survivor)"; continue; }
          carveout_docs_only "$CLONE" "$BASE_SHA" "$HEAD_SHA" \
            || { bad "$r ($g): SKIP carve-out declarado pero el diff base..head NO es 100% docs/skills (recomputado en la estación) — NO-GO"; continue; }
          # Autoridad conservadora (ruling del lead): el diff puede ser 100% docs/skills y AÚN ASÍ
          # el fast-path debe negarse si el árbol NO-carveout en BASE_SHA ya NO coincide con el
          # ratificado — significa que algo fuera de docs/skills cambió desde la ratificación (un
          # consumidor pudo introducirse, por CUALQUIER vía sintáctica) y la inercia ya no está
          # demostrada. Ausencia de digest ratificado en el manifiesto ⇒ sin autoridad ⇒ fail-closed.
          [ -n "${CARVEOUT_INERT_DIGEST:-}" ] \
            || { bad "$r ($g): SKIP carve-out pero el manifiesto no tiene TF_CARVEOUT_INERT_DIGEST ratificado — sin autoridad conservadora, NO-GO"; continue; }
          base_digest="$(carveout_noncarveout_digest "$CLONE" "$BASE_SHA")" \
            || { bad "$r ($g): no pude recomputar el digest del árbol no-carveout en BASE_SHA — DUDA, NO-GO"; continue; }
          [ "$base_digest" = "$CARVEOUT_INERT_DIGEST" ] \
            || { bad "$r ($g): digest del árbol no-carveout en BASE_SHA ($base_digest) ≠ ratificado ($CARVEOUT_INERT_DIGEST) — la inercia ya no está demostrada, NO-GO"; continue; }
          echo "[post-local-gates]   · $g SKIP carve-out válido (docs-only + digest no-carveout ratificado, TAL-2749)" ;;
        rc2_optin_vacio*)
          # NO MEDIDO (TAL-5586): el motor no pudo MEDIR el gate (fallo de instrumento, rc 2).
          # Esta rama NO rechaza: CUENTA. Por eso no llama a `bad` y no viola la invariante H2
          # de arriba — el falso verde que H2 teme queda cerrado aguas abajo, porque
          # `no_medidos > 0` fuerza STATE=failure. Bloquea SIN imputárselo al sujeto.
          # `rc2_optin_vacio` es PREFIJO RESERVADO de este canal: ningún motivo nuevo puede
          # empezar así salvo que SEA un NO MEDIDO de opt-in.
          no_medidos=$((no_medidos+1))
          echo "[post-local-gates]   ○ $g: NO MEDIDO ($reason)" ;;
        *)
          # SKIP por política: solo válido para db-guards y solo si la POLÍTICA lo respalda.
          if [ "$g" != "db-guards" ]; then bad "$r ($g): SKIP no admitido para este gate"; continue; fi
          case "$DB_GATE" in
            never) echo "[post-local-gates]   · db-guards SKIP válido (TF_DB_GATE=never, manifiesto)";;
            auto)  mig_diff_empty || { bad "$r (db-guards): SKIP declarado pero el diff SÍ toca $MIG_DIR"; continue; } ;;
            *)     bad "$r (db-guards): SKIP con TF_DB_GATE=$DB_GATE (no admitido)"; continue;;
          esac ;;
      esac ;;
    *) bad "$r ($g): result '$res' inválido (PASS|FAIL|SKIP)";;
  esac
done

# db-guards con TF_DB_GATE=never|auto-sin-diff: si NINGÚN runner lo corrió, el agregador lo da
# por cubierto por política (recomputada arriba); en always sigue siendo obligatorio.
if printf '%s\n' "$expected" | grep -qx "db-guards" && [ -z "${seen[db-guards]:-}" ]; then
  if [ "$DB_GATE" = "never" ] || { [ "$DB_GATE" = "auto" ] && mig_diff_empty; }; then
    seen[db-guards]="(cubierto por política TF_DB_GATE=$DB_GATE)"
    echo "[post-local-gates]   · db-guards sin receipt: cubierto por política TF_DB_GATE=$DB_GATE (recomputada)"
  fi
fi

missing="$(printf '%s\n' "$expected" | while IFS= read -r g; do [ -n "${seen[$g]:-}" ] || echo "$g"; done)"
# El resumen accionable va ANTES de cualquier `die`: si un receipt cae por rancio, su gate
# aparece luego como "faltante" y el operador leía «faltan receipts» cuando la verdad era «hay N
# rancios, re-corre ESTOS». El mensaje engañaba justo donde más importa.
if [ -n "${REHACER// /}" ]; then
  echo "[post-local-gates] ── RE-CORRER SOLO ESTOS GATES (los demás receipts se CONSERVAN) ──" >&2
  for _g in $REHACER; do echo "[post-local-gates]     $_g" >&2; done
  echo "[post-local-gates]     (tip actual de $BASE_NAME: $BASE_TIP_SHA)" >&2
fi
# TAL-6719: resumen accionable gate a gate de lo conservado por inercia (evidencia completa en el
# journal — aquí solo la lista, para que el operador vea de un vistazo QUÉ se ahorró re-correr).
if [ -n "${INERCIA// /}" ]; then
  echo "[post-local-gates] ── CONSERVADOS POR INERCIA (PR disjunto de sus insumos y del churn) ──"
  for _g in $INERCIA; do echo "[post-local-gates]     $_g"; done
fi
if [ -n "${RECONCILIADOS// /}" ]; then
  echo "[post-local-gates] ── ROSTER RECONCILIADO (shards nuevos de main vivo, PR disjunto de e2e) ──"
  for _t in $RECONCILIADOS; do echo "[post-local-gates]     $_t"; done
fi
[ -z "$missing" ] || die "faltan receipts para gates esperados: $(echo "$missing" | tr '\n' ' ') — NO se postea (fail-closed)$([ -n "${REHACER// /}" ] && echo ' · OJO: parte de esos gates NO faltan, sus receipts quedaron RANCIOS (lista arriba)')"
[ "$errors" -eq 0 ] || die "$errors receipt(s) rechazados — NO se postea (fail-closed)"
[ "$BRANCH_GATE" != "FAIL" ] || fails=$((fails+1))

# TAL-5586: un gate NO MEDIDO no es un gate verde. `fails` mide incumplimiento del sujeto;
# `no_medidos`, ausencia de medición. Cualquiera de los dos BLOQUEA, y la descripción los
# distingue para que nadie lea «rojo del sujeto» donde hubo un instrumento caído.
STATE=$([ "$fails" -eq 0 ] && [ "$no_medidos" -eq 0 ] && echo success || echo failure)

# ── 5. Relectura final: cualquier cambio de head/base/branch INVALIDA la corrida. ─────────────
pr_json2="$(gh pr view "$PR" --repo "$OWNER_REPO" --json headRefOid,headRefName,baseRefName 2>/dev/null)" \
  || die "no pude releer el PR"
[ "$(jq -r '.headRefOid' <<<"$pr_json2")" = "$HEAD_SHA" ]  || die "headRefOid cambió durante la corrida — receipts INVALIDADOS, re-correr el run_group"
[ "$(jq -r '.headRefName' <<<"$pr_json2")" = "$HEAD_REF" ] || die "headRefName cambió durante la corrida — receipts INVALIDADOS"
[ "$(jq -r '.baseRefName' <<<"$pr_json2")" = "$BASE_NAME" ] || die "base del PR cambió durante la corrida — receipts INVALIDADOS"
git -C "$CLONE" fetch --no-tags --quiet origin "$BASE_NAME" || die "re-fetch de $BASE_NAME falló"
BASE_TIP_NOW="$(git -C "$CLONE" rev-parse "origin/$BASE_NAME")" || die "sin tip en relectura"
# M6 r5: el TIP de la base y el merge-base se registran y comparan POR SEPARADO — un avance
# de main puede no mover el merge-base y aun así invalidar el contrato "la corrida es sobre
# esta base"; el required check es strict y el merge exigiría re-correr igualmente.
[ "$BASE_TIP_NOW" = "$BASE_TIP_SHA" ] || die "la rama base avanzó durante la corrida (tip $BASE_TIP_SHA → $BASE_TIP_NOW) — receipts INVALIDADOS, re-correr el run_group"
BASE_NOW="$(git -C "$CLONE" merge-base "origin/$BASE_NAME" "$HEAD_SHA")" || die "sin merge-base en relectura"
[ "$BASE_NOW" = "$BASE_SHA" ] || die "merge-base cambió durante la corrida ($BASE_SHA → $BASE_NOW) — receipts INVALIDADOS, re-correr"

# ── 6. POST + relectura (un POST aceptado no es un status visible). ───────────────────────────
n_gates="$(printf '%s\n' "$expected" | grep -c .)"
# TAL-6719: conteo de gates conservados por inercia — visible en el resumen posteado, evidencia
# completa (por qué + churn_hit + sha256) vive en el journal (ver bucle de receipts).
n_inercia="$(printf '%s\n' $INERCIA | grep -c . || true)"; n_inercia="${n_inercia:-0}"
desc="fábrica: $n_gates gates · $no_medidos NO MEDIDO · run $RUN_GROUP · manifiesto ${MANIFEST_DIGEST:0:12}$([ "$n_inercia" -gt 0 ] && echo " · $n_inercia conservados por inercia")"
gh api -X POST "repos/$OWNER_REPO/statuses/$HEAD_SHA" -f state="$STATE" -f context="$CONTEXT" \
  -f description="$desc" >/dev/null 2>&1 \
  || die3 "no se pudo postear el commit-status $CONTEXT=$STATE — el resultado NO está trazado"
leido="$(gh api "repos/$OWNER_REPO/commits/$HEAD_SHA/status" \
          --jq ".statuses[] | select(.context==\"$CONTEXT\") | .state" 2>/dev/null | head -1)"
[ "$leido" = "$STATE" ] || die3 "status posteado pero releído como '${leido:-ausente}' (esperado $STATE)"

echo "[post-local-gates] $CONTEXT=$STATE posteado y releído @ ${HEAD_SHA:0:12} ($n_gates gates, $fails FAIL, $no_medidos NO MEDIDO)"
[ "$STATE" = "success" ] && exit 0 || exit 1
