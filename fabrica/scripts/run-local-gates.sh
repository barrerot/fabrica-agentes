#!/usr/bin/env bash
# run-local-gates.sh — Motor de gates LOCAL de la fábrica, v2 (TAL-2288 · reemplaza GitHub Actions).
#
# MODELO v2 (runner sin credenciales · un gate por invocación · receipt parcial):
#   - Corre EXACTAMENTE UN gate (`--gate <gate-id>`) sobre un árbol desechable fijado al SHA
#     a certificar, dentro de un RUNNER SIN credenciales (perfil minimal). El runner NO postea
#     nada: escribe un RECEIPT parcial (JSON) que la estación del Mergeador recoge, sella y
#     agrega con `post-local-gates.sh` (única vía de POST del commit-status `local-gates`).
#   - La identidad de la corrida (repo, pr, sha, base_sha, digests, run_group, gate_id) viene
#     SELLADA por la estación en un fichero de asignación (`--assignment`): el runner NO
#     inventa esos valores — los verifica (recomputa digests y aborta ante divergencia).
#     Sin asignación (modo inline, terminal-sola/dry-run) el propio script deriva la identidad
#     y lo deja marcado en el receipt (`assignment: "inline"`).
#   - Los gates con estado compartido (BD/e2e) toman un flock por runner. El lifecycle de
#     Supabase es de los WRAPPERS del producto (scripts/ci/run-*-local.sh) — el motor NO
#     arranca ni para stacks (ownership único, decisión del plan TAL-2288).
#   - Confidencialidad: umask 077, logs 0600 en dir 0700; por defecto NO se imprime el tail
#     del log fallido (solo la ruta protegida). `--show-tail` exige el redactor canónico
#     (scripts/lib/redact.sh) y FALLA sin él — jamás salida cruda.
#
# Invariante heredado de #1 (y reforzado): el receipt que se emite sobre <sha> es el resultado
# de ejecutar el gate sobre <sha> (checkout interno + assert antes y después).
#
# Uso:
#   bash run-local-gates.sh <ruta-repo> --gate <gate-id> [--assignment <json>]
#                           [--sha <sha>] [--base <ref|sha>] [--pr <n>] [--run-group <id>]
#                           [--manifest <ruta>] [--manifest-sha256 <hex>]
#                           [--receipt <ruta-salida>] [--show-tail] [--keep]
#
# gate-id: uno de los TF_GATE_IDS del manifiesto, o `<familia>:<shard>` para E2E
#          (familia ∈ TF_E2E_FAMILIES; shard validado contra TF_SHARDS_REGISTRY del árbol).
#
# Salida: 0 = gate PASS/SKIP-justificado (receipt escrito) · 1 = gate FAIL (receipt escrito)
#         · 2 = error de precondición (SIN receipt — la agregación fail-closed lo detecta).
# TAL-5586: el rc 2 DEL COMANDO DEL GATE (no el de este script) se traduce a SKIP + SKIP_REASON
# con el token `rc2_optin_vacio` si el gate está en TF_GATES_RC2_OPTIN; el script sigue saliendo
# 0 y el agregador lo cuenta como NO MEDIDO y BLOQUEA sin imputárselo al sujeto.
set -uo pipefail
umask 077

die() { echo "ERROR: $*" >&2; exit 2; }

[ $# -ge 1 ] || die "uso: bash run-local-gates.sh <ruta-repo> --gate <gate-id> --manifest <conf> [...]"
REPO="$1"; shift
SHA=""; BASE_IN=""; PR=""; RUN_GROUP=""; GATE=""; MANIFEST=""; MANIFEST_PIN=""
ASSIGNMENT=""; RECEIPT_OUT=""; SHOW_TAIL=0; KEEP=0; LIB_CARVEOUT=""; WRAPPER_IN=""
while [ $# -gt 0 ]; do case "$1" in
  --sha)             SHA="$2"; shift 2;;
  --base)            BASE_IN="$2"; shift 2;;
  --pr)              PR="$2"; shift 2;;
  --run-group)       RUN_GROUP="$2"; shift 2;;
  --gate)            GATE="$2"; shift 2;;
  --assignment)      ASSIGNMENT="$2"; shift 2;;
  --manifest)        MANIFEST="$2"; shift 2;;
  --manifest-sha256) MANIFEST_PIN="$2"; shift 2;;
  --receipt)         RECEIPT_OUT="$2"; shift 2;;
  --wrapper)         WRAPPER_IN="$2"; shift 2;;
  --lib-carveout)    LIB_CARVEOUT="$2"; shift 2;;
  --show-tail)       SHOW_TAIL=1; shift;;
  --keep)            KEEP=1; shift;;
  *) die "argumento desconocido: $1";; esac; done

command -v git >/dev/null || die "git no disponible"
command -v jq  >/dev/null || die "jq no disponible (el receipt es JSON)"
command -v flock >/dev/null || die "flock no disponible (candado por runner)"

# ── Precondiciones. Todas las rutas se resuelven ANTES de cualquier cd. ────────────────────────
[ -d "$REPO" ] || die "no existe el repo: $REPO"
REPO="$(cd "$REPO" && pwd -P)" || die "no puedo resolver $REPO"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# ── Asignación sellada por la estación (identidad de la corrida). ──────────────────────────────
# El runner NO inventa pr/base_sha/digests/gate_id: si hay asignación, MANDAN sus valores y
# cualquier flag CLI contradictorio aborta. Los digests se RECOMPUTAN y se comparan (anti-drift).
ASSIGN_MODE="inline"
A_MANIFEST_DIGEST=""; A_BASE_REG=""; A_HEAD_REG=""; A_REPO_SLUG=""; A_MOTOR_SHA=""; A_BASE_TIP=""; A_CARVEOUT_SHA=""
if [ -n "$ASSIGNMENT" ]; then
  [ -f "$ASSIGNMENT" ] || die "asignación no encontrada: $ASSIGNMENT"
  jq -e '.schema_version == 1' "$ASSIGNMENT" >/dev/null 2>&1 || die "asignación sin schema_version==1"
  for k in run_group repo sha base_sha manifest_digest gate_id; do
    v="$(jq -r --arg k "$k" '.[$k] // ""' "$ASSIGNMENT")"
    [ -n "$v" ] || die "asignación sin campo '$k' (la estación sella la identidad completa)"
  done
  a_sha="$(jq -r '.sha' "$ASSIGNMENT")"; a_gate="$(jq -r '.gate_id' "$ASSIGNMENT")"
  [ -z "$SHA" ]  || [ "$SHA" = "$a_sha" ]   || die "--sha ($SHA) contradice la asignación ($a_sha)"
  [ -z "$GATE" ] || [ "$GATE" = "$a_gate" ] || die "--gate ($GATE) contradice la asignación ($a_gate)"
  SHA="$a_sha"; GATE="$a_gate"
  BASE_IN="$(jq -r '.base_sha' "$ASSIGNMENT")"
  PR="$(jq -r '.pr // ""' "$ASSIGNMENT")"
  RUN_GROUP="$(jq -r '.run_group' "$ASSIGNMENT")"
  A_MANIFEST_DIGEST="$(jq -r '.manifest_digest' "$ASSIGNMENT")"
  A_MOTOR_SHA="$(jq -r '.motor_sha256 // ""' "$ASSIGNMENT")"
  A_CARVEOUT_SHA="$(jq -r '.carveout_sha256 // ""' "$ASSIGNMENT")"
  A_BASE_TIP="$(jq -r '.base_tip_sha // ""' "$ASSIGNMENT")"
  A_BASE_REG="$(jq -r '.base_registry_digest // ""' "$ASSIGNMENT")"
  A_HEAD_REG="$(jq -r '.head_registry_digest // ""' "$ASSIGNMENT")"
  A_REPO_SLUG="$(jq -r '.repo' "$ASSIGNMENT")"
  ASSIGN_MODE="sealed"
fi
# ── Auto-atestación del MOTOR (B3 r5): este script recomputa su propio sha256; en modo
#    sealed DEBE coincidir con el sellado en la asignación (un motor stale o sustituido
#    entre el push y el exec no produce evidencia), y viaja en el receipt para que el
#    agregador lo compare con el motor aprobado de la estación.
SELF_SHA="$(sha256sum "${BASH_SOURCE[0]}" | cut -d' ' -f1)"
if [ "$ASSIGN_MODE" = "sealed" ]; then
  [ -n "$A_MOTOR_SHA" ] || die "asignación sin motor_sha256 (la estación sella el motor que autoriza)"
  [ -n "$A_BASE_TIP" ] || die "asignación sin base_tip_sha (la estación sella el tip de la rama base)"
  [ "$SELF_SHA" = "$A_MOTOR_SHA" ] \
    || die "el motor ejecutado ($SELF_SHA) NO es el sellado por la estación ($A_MOTOR_SHA) — motor stale o sustituido"
fi

[ -n "$GATE" ] || die "falta --gate <gate-id> (o una asignación que lo selle)"
case "$GATE" in
  *[!a-z0-9:_-]*) die "gate-id inválido: '$GATE' (solo [a-z0-9:_-])" ;;
esac

# ── Manifiesto: fail-closed. Nunca defaults en silencio. ──────────────────────────────────────
[ -n "$MANIFEST" ] || die "falta --manifest (v2 exige manifiesto: define los gates del proyecto)"
[ -f "$MANIFEST" ] || die "manifiesto no encontrado: $MANIFEST (¿ruta relativa?). Usa ruta absoluta."
MANIFEST="$(cd "$(dirname "$MANIFEST")" && pwd -P)/$(basename "$MANIFEST")"
MANIFEST_DIGEST="$(sha256sum "$MANIFEST" | cut -d' ' -f1)"
if [ -n "$MANIFEST_PIN" ]; then
  [ "$MANIFEST_DIGEST" = "$MANIFEST_PIN" ] || die "manifiesto derivado: esperado $MANIFEST_PIN, encontrado $MANIFEST_DIGEST"
fi
if [ "$ASSIGN_MODE" = "sealed" ]; then
  [ "$MANIFEST_DIGEST" = "$A_MANIFEST_DIGEST" ] \
    || die "el manifiesto local ($MANIFEST_DIGEST) NO es el sellado por la estación ($A_MANIFEST_DIGEST)"
fi
# Validación inline del manifiesto (TAL-2288): claves TF_* duplicadas ⇒ rechazo (la última
# ganaría en silencio y el digest no lo delataría ante un editor distraído).
dup_keys="$(grep -E '^TF_[A-Za-z0-9_]+=' "$MANIFEST" | cut -d= -f1 | sort | uniq -d)"
[ -z "$dup_keys" ] || die "manifiesto con claves duplicadas: $(echo "$dup_keys" | tr '\n' ' ')"
RUNNER_LOCK="${TF_RUNNER_LOCK:-/tmp/local-gates-runner.lock}"
readonly RUNNER_LOCK
# shellcheck disable=SC1090
. "$MANIFEST" || die "el manifiesto no se pudo cargar: $MANIFEST"

# ── Carve-out docs-only (TAL-2749): el clasificador viaja como lib SELLADA y ATESTADA (r4). En
#    modo sellado su digest DEBE coincidir con el sellado por la estación en la asignación ANTES de
#    sourcearla (código atestado, fail-closed) — como el SELF_SHA del propio motor. En modo inline
#    (sin asignación) se usa un fallback definido en ESTE motor (cubierto por MOTOR_SHA) que nunca
#    SKIPea: no se ejecuta código externo no verificado por ninguna ruta.
CARVEOUT_SELF_SHA=""
if [ "$ASSIGN_MODE" = "sealed" ]; then
  [ -n "$A_CARVEOUT_SHA" ] || die "asignación sin carveout_sha256 (la estación sella la lib de carve-out)"
  [ -n "$LIB_CARVEOUT" ] && [ -f "$LIB_CARVEOUT" ] || die "modo sellado sin lib de carve-out transportada (--lib-carveout)"
  CARVEOUT_SELF_SHA="$(sha256sum "$LIB_CARVEOUT" | cut -d' ' -f1)"
  [ "$CARVEOUT_SELF_SHA" = "$A_CARVEOUT_SHA" ] \
    || die "la lib de carve-out transportada ($CARVEOUT_SELF_SHA) NO es la sellada por la estación ($A_CARVEOUT_SHA) — código no atestado"
  # shellcheck disable=SC1090
  . "$LIB_CARVEOUT" || die "no pude cargar la lib de carve-out: $LIB_CARVEOUT"
else
  carveout_docs_only()      { return 1; }
  carveout_gate_skippable() { return 1; }
fi

GATE_IDS="${TF_GATE_IDS:-}"
[ -n "$GATE_IDS" ] || die "el manifiesto no define TF_GATE_IDS (lista nombrada de gates — v2 no acepta cadenas opacas)"
E2E_FAMILIES="${TF_E2E_FAMILIES:-}"
E2E_WRAPPER="${TF_E2E_WRAPPER:-}"
SHARDS_REGISTRY="${TF_SHARDS_REGISTRY:-}"
INSTALL="${TF_INSTALL:-}"
DB_GATE="${TF_DB_GATE:-always}"        # always | auto (INACTIVO hasta ratificación) | never (justificado en el manifiesto)
MIG_DIR="${TF_MIGRATIONS_DIR:-supabase/migrations}"
BASE_REF="${TF_BASE_REF:-origin/main}"

# TF_PROJECT debe corresponder al repo objetivo (validación inline del manifiesto).
if [ -n "${TF_REPO_URL:-}" ]; then
  want="$(basename "${TF_REPO_URL%.git}")"
  have="$(git -C "$REPO" remote get-url origin 2>/dev/null || true)"; have="$(basename "${have%.git}")"
  [ -n "$have" ] && [ "$want" = "$have" ] \
    || die "el manifiesto es de '$want' pero el repo objetivo es '${have:-desconocido}' (TF_PROJECT/TF_REPO_URL no corresponden)"
fi

# TF_INSTALL: sin autodetección silenciosa. Si el manifiesto no lo fija, se deriva del lockfile
if [ "${TF_CHECK_REPO_ONLY:-0}" = 1 ]; then
  [ "$ASSIGN_MODE" != sealed ] || die "TF_CHECK_REPO_ONLY no permite una corrida sellada"
  exit 0 # Comprobación previa, sin checkout, gate ni receipt.
fi
# y COEXISTENCIA de lockfiles incompatibles ⇒ fallo (elegir uno a ciegas oculta drift de deps).
resolve_install() { # se evalúa DENTRO del worktree
  if [ -n "$INSTALL" ]; then return 0; fi
  local n=0
  [ -f package-lock.json ] && n=$((n+1))
  [ -f pnpm-lock.yaml ]    && n=$((n+1))
  [ -f yarn.lock ]         && n=$((n+1))
  [ "$n" -le 1 ] || die "lockfiles incompatibles coexistiendo (package-lock/pnpm-lock/yarn.lock): fija TF_INSTALL en el manifiesto"
  if   [ -f package-lock.json ]; then INSTALL="npm ci --no-audit --no-fund"
  elif [ -f pnpm-lock.yaml ];    then INSTALL="pnpm install --frozen-lockfile"
  elif [ -f yarn.lock ];         then INSTALL="yarn install --frozen-lockfile"
  else INSTALL="npm install --no-audit --no-fund"; fi
}

# ── BEGIN infra_signature_match (TAL-6759) ────────────────────────────────────────────────────
# Firma de infraestructura: lista ESTRICTA de patrones (regex extendida, sin distinguir
# mayúsculas) que identifican un FALLO TRANSITORIO de infraestructura (docker/supabase/red/
# OOM/disco/puertos) — NUNCA patrones genéricos («fail», «error», «Killed» a secas). Un
# clasificador laxo reintentaría un FAIL DE PRODUCTO (typecheck, lint, aserción de test) y un
# segundo PASS daría FALSO VERDE — catastrófico. Ante cualquier duda: NO reintentar (fail-closed
# hacia no-retry). El FAIL de un DEFECTO DE PRODUCTO jamás se reintenta por esta vía.
# ERRORES DE RED (Connection refused/ECONNREFUSED/ETIMEDOUT/DNS/TLS/i-o timeout/…) NO se aceptan
# a secas: un test de producto puede fallar contra un endpoint de producto con el MISMO texto
# («connect ECONNREFUSED api.mi-producto:443») y eso sería un DEFECTO de producto, no infra. Solo
# cuentan si co-ocurren EN LA MISMA LÍNEA con un DISCRIMINADOR de dependencia CONTROLADA por el
# motor (supabase/postgres/docker/containerd/registry npm|yarn/puertos 54321-54329·5432/«npm ERR!
# network»), en cualquiera de los dos órdenes. Sin discriminador → NO reintento (fail-closed):
# perder una flake de infra solo deja el FAIL en pie (seguro); un falso-verde sería catastrófico.
# El MISMO criterio de discriminador aplica a los genéricos de estado transitorio («Timed out
# waiting for», «container …unhealthy», «healthcheck …fail», «is not ready») y a los OOM
# GENÉRICOS («Out of memory», «Cannot allocate memory», «Killed process» — un leak de memoria de
# PRODUCTO no debe reintentarse-verde): solo cuentan con un discriminador controlado en la línea.
# Se mantienen SIN discriminador SOLO los inequívocos de host/contenedor: «OOMKilled» (OOM de
# contenedor), «no space left on device»/«ENOSPC» (disco). Colisión de PUERTO (address already in
# use / EADDRINUSE): solo infra si toca un puerto controlado (supabase/docker o \b5432[1-9]?\b con
# word-boundary — así 15432 embebido y 54320 NO cuentan); un choque en un puerto de producto es un
# bug de aislamiento del test. «signal 9» a secas se retiró por ambiguo.
# Extensión SOLO-SUMA por manifiesto: TF_INFRA_RETRY_EXTRA_PATTERNS (una línea por patrón) se
# AÑADE a la lista base, nunca la reemplaza — sin manifiesto el default es exactamente la lista
# estricta de abajo.
infra_signature_patterns() {
  cat <<'INFRA_PATTERNS_EOF'
Cannot connect to the Docker daemon
Error response from daemon
Is the docker daemon running
failed to start containerd
supabase start.*fail
(Timed out waiting for|container .*unhealthy|healthcheck .*fail|is not ready|Out of memory|Cannot allocate memory|Killed process).*(supabase|postgres|docker|containerd|registry\.(npmjs|yarnpkg)|\b5432[1-9]?\b|npm ERR! network|npm error network)
(supabase|postgres|docker|containerd|registry\.(npmjs|yarnpkg)|\b5432[1-9]?\b|npm ERR! network|npm error network).*(Timed out waiting for|container .*unhealthy|healthcheck .*fail|is not ready|Out of memory|Cannot allocate memory|Killed process)
Postgres .*not ready
(Connection refused|ECONNREFUSED|ETIMEDOUT|EAI_AGAIN|getaddrinfo ENOTFOUND|Temporary failure in name resolution|TLS handshake timeout|i/o timeout|network is unreachable).*(supabase|postgres|docker|containerd|registry\.(npmjs|yarnpkg)|\b5432[1-9]?\b|npm ERR! network|npm error network)
(supabase|postgres|docker|containerd|registry\.(npmjs|yarnpkg)|\b5432[1-9]?\b|npm ERR! network|npm error network).*(Connection refused|ECONNREFUSED|ETIMEDOUT|EAI_AGAIN|getaddrinfo ENOTFOUND|Temporary failure in name resolution|TLS handshake timeout|i/o timeout|network is unreachable)
no space left on device
ENOSPC
OOMKilled
(address already in use|EADDRINUSE|bind: address already in use).*(supabase|docker|containerd|\b5432[1-9]?\b)
(supabase|docker|containerd|\b5432[1-9]?\b).*(address already in use|EADDRINUSE|bind: address already in use)
INFRA_PATTERNS_EOF
  if [ -n "${TF_INFRA_RETRY_EXTRA_PATTERNS:-}" ]; then
    printf '%s\n' "$TF_INFRA_RETRY_EXTRA_PATTERNS"
  fi
}

# infra_signature_which <logfile> → imprime (stdout) el PRIMER patrón de la lista que casa el
# TAIL del log (últimos 64 KiB); rc 1 y sin salida si ninguno casa (log ausente incluido).
infra_signature_which() {
  local logfile="$1" pat tail_content
  [ -f "$logfile" ] || return 1
  tail_content="$(tail -c 65536 "$logfile" 2>/dev/null)"
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    if printf '%s' "$tail_content" | grep -E -i -q -- "$pat"; then
      printf '%s' "$pat"
      return 0
    fi
  done < <(infra_signature_patterns)
  return 1
}

# infra_signature_match <logfile> → rc 0 si el tail del log casa alguna firma de infra ESTRICTA;
# rc 1 si no (o el log no existe). Función PURA: solo clasifica, no muta estado.
infra_signature_match() {
  infra_signature_which "$1" >/dev/null
}

# product_defect_patterns → firmas INEQUÍVOCAS de DEFECTO DE PRODUCTO (compilación TS, aserción,
# resumen de tests con fallos, resumen de lint con errores). NUNCA aparecen en una flake de infra.
# Sirven de VETO del reintento (TAL-6759): un blip de infra HISTÓRICO en el tail (p. ej. un error
# de Docker recuperado) seguido de un fallo TERMINAL de producto (TS2322/aserción) NO debe gatillar
# el reintento — el fallo real se conservaría enmascarado. Si el log trae CUALQUIER firma de
# producto, NO se reintenta aunque también case una firma de infra (fail-closed hacia no-retry).
product_defect_patterns() {
  cat <<'PRODUCT_DEFECT_EOF'
error TS[0-9]
AssertionError
Assertion failed
✖ [1-9][0-9]* problem
[1-9][0-9]* problems? \([1-9][0-9]* error
[1-9][0-9]* (tests?|specs?) (failing|failed)
Tests?:? +[1-9][0-9]* failed
[1-9][0-9]* failed, [0-9]+ passed
[0-9]+ passed,? +[1-9][0-9]* failed
[1-9][0-9]* failed +\| +[0-9]+ passed
[0-9]+ passed +\| +[1-9][0-9]* failed
PRODUCT_DEFECT_EOF
}

# product_defect_match <logfile> → rc 0 si el tail del log casa alguna firma de defecto de PRODUCTO.
# Función PURA. Log ausente → rc 1 (no veta; la decisión de infra ya es fail-closed por su lado).
product_defect_match() {
  local logfile="$1" pat tail_content
  [ -f "$logfile" ] || return 1
  tail_content="$(tail -c 65536 "$logfile" 2>/dev/null)"
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    if printf '%s' "$tail_content" | grep -E -q -- "$pat"; then
      return 0
    fi
  done < <(product_defect_patterns)
  return 1
}
# ── END infra_signature_match (TAL-6759) ──────────────────────────────────────────────────────

# ── Resolver el gate pedido contra manifiesto + registro (fail-closed). ───────────────────────
# Gate base: id ∈ TF_GATE_IDS con comando TF_GATE_CMD_<id con - → _>.
# Gate E2E:  "<familia>:<shard>" con familia ∈ TF_E2E_FAMILIES; el shard se valida contra el
#            registro DEL ÁRBOL (head). La anti-reducción base→head la hace el agregador.
GATE_KIND=""; GATE_CMD=""; GATE_FAMILY=""; GATE_SHARD=""
case "$GATE" in
  *:*)
    GATE_FAMILY="${GATE%%:*}"; GATE_SHARD="${GATE#*:}"
    [ -n "$E2E_FAMILIES" ] || die "gate E2E '$GATE' pero el manifiesto no define TF_E2E_FAMILIES"
    case " $E2E_FAMILIES " in *" $GATE_FAMILY "*) : ;; *) die "familia E2E desconocida: '$GATE_FAMILY' (TF_E2E_FAMILIES=$E2E_FAMILIES)";; esac
    [ -n "$E2E_WRAPPER" ]    || die "el manifiesto no define TF_E2E_WRAPPER"
    [ -n "$SHARDS_REGISTRY" ] || die "el manifiesto no define TF_SHARDS_REGISTRY"
    GATE_KIND="e2e"
    ;;
  *)
    case " $GATE_IDS " in *" $GATE "*) : ;; *) die "gate-id desconocido: '$GATE' (TF_GATE_IDS=$GATE_IDS)";; esac
    id_var="$(printf '%s' "$GATE" | tr '-' '_')"
    GATE_CMD="$(eval "printf '%s' \"\${TF_GATE_CMD_${id_var}:-}\"")"
    [ -n "$GATE_CMD" ] || die "el manifiesto no define TF_GATE_CMD_${id_var} para el gate '$GATE'"
    GATE_KIND="base"
    ;;
esac

# ── Fijar el árbol al SHA. Nunca se tocan el working tree ni el .env.local del canal. ─────────
cd "$REPO" || die "cd $REPO"
git rev-parse --git-dir >/dev/null 2>&1 || die "$REPO no es un repo git"

if [ -z "$SHA" ]; then
  SHA="$(git rev-parse HEAD)" || die "no puedo resolver HEAD"
  echo "== sin --sha: se certifica el HEAD actual ($SHA) =="
fi
if ! git cat-file -e "${SHA}^{commit}" 2>/dev/null; then
  # En modo SEALED el runner NO toca la red (no tiene — ni debe tener — credenciales del
  # remoto privado): el commit lo transfiere la estación como bundle (run-gate-sealed.sh)
  # ANTES del exec. Un fetch aquí sería la disyuntiva inválida del audit r4 (con
  # credenciales rompe el aislamiento; sin ellas no puede). Fetch solo en modo inline.
  if [ "$ASSIGN_MODE" = "sealed" ]; then
    die "commit $SHA ausente en el clon del runner y el modo es SEALED — la estación debe transferirlo por bundle (run-gate-sealed.sh); el runner no fetchea remotos"
  fi
  echo "== $SHA ausente en local: fetch desde origin =="
  git fetch --no-tags --quiet origin "$SHA" 2>/dev/null \
    || { [ -n "$PR" ] && git fetch --no-tags --quiet origin "refs/pull/$PR/head" 2>/dev/null; } \
    || git fetch --no-tags --quiet --prune origin 2>/dev/null \
    || die "no puedo obtener el commit $SHA desde origin (con PR: --pr <n> permite fetch de refs/pull/n/head)"
fi
git cat-file -e "${SHA}^{commit}" 2>/dev/null || die "commit inexistente: $SHA"
SHA="$(git rev-parse "${SHA}^{commit}")"

# base_sha: sellado por la asignación, o derivado (merge-base con TF_BASE_REF). Fail-closed.
# (red solo en modo inline — ver arriba)
[ "$ASSIGN_MODE" = "sealed" ] || git fetch --no-tags --quiet origin "${BASE_REF#origin/}" 2>/dev/null || true
if [ -n "$BASE_IN" ]; then
  git cat-file -e "${BASE_IN}^{commit}" 2>/dev/null || die "base_sha inexistente: $BASE_IN"
  BASE_SHA="$(git rev-parse "${BASE_IN}^{commit}")"
else
  BASE_SHA="$(git merge-base "$BASE_REF" "$SHA" 2>/dev/null)" \
    || die "no puedo derivar base ($BASE_REF): pásala sellada (--base / asignación)"
fi

# Digests del registro de shards en base y head (identidad anti-reducción del agregador).
reg_digest_at() { # <sha> → sha256 del registro en ese commit, o "absent"
  local c; c="$(git show "$1:$SHARDS_REGISTRY" 2>/dev/null)" || { echo "absent"; return; }
  printf '%s' "$c" | sha256sum | cut -d' ' -f1
}
BASE_REG_DIGEST="n/a"; HEAD_REG_DIGEST="n/a"
if [ -n "$SHARDS_REGISTRY" ]; then
  BASE_REG_DIGEST="$(reg_digest_at "$BASE_SHA")"
  HEAD_REG_DIGEST="$(reg_digest_at "$SHA")"
fi
if [ "$ASSIGN_MODE" = "sealed" ]; then
  [ -z "$A_BASE_REG" ] || [ "$A_BASE_REG" = "$BASE_REG_DIGEST" ] \
    || die "base_registry_digest local ($BASE_REG_DIGEST) != sellado ($A_BASE_REG)"
  [ -z "$A_HEAD_REG" ] || [ "$A_HEAD_REG" = "$HEAD_REG_DIGEST" ] \
    || die "head_registry_digest local ($HEAD_REG_DIGEST) != sellado ($A_HEAD_REG)"
fi

RUN_GROUP="${RUN_GROUP:-inline-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUNS_ROOT="${TMPDIR:-/tmp}/local-gates"
mkdir -p "$RUNS_ROOT" && chmod 700 "$RUNS_ROOT"
RUN_DIR="$RUNS_ROOT/$RUN_ID"
mkdir "$RUN_DIR" || die "no pude crear $RUN_DIR"
chmod 700 "$RUN_DIR"
WT="$RUN_DIR/tree"
LOG="$RUN_DIR/gate.log"; : >"$LOG"; chmod 600 "$LOG"
RECEIPT_OUT="${RECEIPT_OUT:-$RUN_DIR/receipt.json}"

cleanup() {
  if [ "$KEEP" = "1" ]; then echo "== --keep: conservo $RUN_DIR para debug ==" >&2; return; fi
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  rm -rf "$WT"
}
trap cleanup EXIT

echo "== árbol desechable en $WT, fijado a $SHA (gate: $GATE · run_group: $RUN_GROUP) =="
git worktree add --detach --quiet "$WT" "$SHA" || die "no pude crear el worktree en $SHA"
cd "$WT" || die "cd $WT"
ACTUAL="$(git rev-parse HEAD)"
[ "$ACTUAL" = "$SHA" ] || die "el worktree quedó en $ACTUAL, no en $SHA"
echo "== checkout == --sha OK ($SHA) — anti-self-report =="

# Ficheros de entorno no versionados (p.ej. .env.local) — SOLO en modo inline (terminal-sola
# certificando SU propio trabajo). En modo SEALED está PROHIBIDO (B1 del audit TAL-2293): el
# árbol desechable ejecuta CÓDIGO DEL PR y copiarle el .env del clon rompería el aislamiento
# "runner sin credenciales" (canal de exfiltración de tokens). Los gates que reproducen
# Actions no lo necesitan: los workflows corrían sin .env.local (env explícito por job, y
# los wrappers derivan el env de Supabase efímero en runtime).
if [ -n "${TF_ENV_COPY:-}" ]; then
  if [ "$ASSIGN_MODE" = "sealed" ]; then
    die "TF_ENV_COPY está definido pero el modo es SEALED (runner): copiar env no versionado a un árbol que ejecuta código del PR está PROHIBIDO (exfiltración). Retira TF_ENV_COPY del manifiesto o corre el gate en modo inline (trabajo propio)."
  fi
  for f in ${TF_ENV_COPY:-}; do
    if [ -f "$REPO/$f" ]; then
      install -m 600 "$REPO/$f" "$WT/$f" && echo "  · copiado $f al árbol desechable (0600, modo inline — trabajo propio)"
    fi
  done
fi

# Validar el shard contra el registro del árbol (head) — fail-closed.
if [ "$GATE_KIND" = "e2e" ]; then
  [ -f "$SHARDS_REGISTRY" ] || die "el árbol @$SHA no tiene el registro $SHARDS_REGISTRY"
  jq -e --arg f "$GATE_FAMILY" --arg s "$GATE_SHARD" \
     '.families[$f].shards | map(.id) | index($s) != null' "$SHARDS_REGISTRY" >/dev/null 2>&1 \
    || die "shard '$GATE_SHARD' no existe en la familia '$GATE_FAMILY' del registro @head"
  GATE_CMD="$E2E_WRAPPER $GATE_FAMILY $GATE_SHARD"
fi

# ── SKIP verificable del gate de BD (TF_DB_GATE) — el agregador lo recomputa. ─────────────────
RESULT=""; SKIP_REASON=""
if [ "$GATE" = "db-guards" ]; then
  case "$DB_GATE" in
    never)
      RESULT="SKIP"; SKIP_REASON="TF_DB_GATE=never (manifiesto $MANIFEST_DIGEST: BD compartida/preexistente — ver justificación en el manifiesto)" ;;
    auto)
      if git diff --name-only "$BASE_SHA" "$SHA" -- "$MIG_DIR" | grep -q .; then
        :
      else
        RESULT="SKIP"; SKIP_REASON="TF_DB_GATE=auto: diff $BASE_SHA..$SHA sin cambios en $MIG_DIR"
      fi ;;
    always) : ;;
    *) die "TF_DB_GATE inválido: '$DB_GATE' (always|auto|never)" ;;
  esac
fi

# ── Carve-out fail-closed docs-only/skills-only (TAL-2749) — el AGREGADOR lo RECOMPUTA. ─────────
# Si el manifiesto lo habilita, el gate NO es survivor (∉ TF_CARVEOUT_KEEP_GATES) y el diff
# base..head es 100% .md inerte bajo TF_CARVEOUT_PATHS, se PROPONE un SKIP (queda ANTES del bloque
# de deps ⇒ evita npm ci + comando). Cualquier duda del clasificador ⇒ RESULT sigue vacío y el
# gate corre (fail-closed). Corre DESPUÉS de db-guards: en TF_DB_GATE=always db-guards no SKIPea
# solo, así el carve-out lo cubre con SU token; el agregador enruta por token. El SKIP es una
# PROPUESTA: el agregador re-deriva la clasificación con su lib aprobada y RECHAZA (NO-GO) un
# carve-out SKIP sobre un diff que no sea 100% docs/skills.
if [ -z "$RESULT" ] && [ "${TF_CARVEOUT_DOCS_ONLY:-0}" = "1" ] \
   && carveout_gate_skippable "$GATE" "${TF_CARVEOUT_KEEP_GATES:-}" \
   && carveout_docs_only "$REPO" "$BASE_SHA" "$SHA"; then
  RESULT="SKIP"
  SKIP_REASON="carve-out-docs-only: PR 100% .md bajo ${TF_CARVEOUT_PATHS:-docs/ .claude/skills/} (diff $BASE_SHA..$SHA) — suite pesada omitida (TAL-2749); recomputado por el agregador"
fi

# ── Ejecutar el gate (si no quedó en SKIP). deps es SETUP del gate, no gate propio: su fallo
#    hace FAIL el gate con detalle, no un resultado aparte. Sin fallbacks suite-fuerte||débil:
#    el comando es EL del manifiesto/registro y su fallo se propaga. ────────────────────────────
LOCK_FD=""
# Gates PESADOS (estado compartido: BD/puertos/navegadores) — configurable por manifiesto:
# el default cubre también un gate base `e2e` (caso atlas, sin registro de shards).
HEAVY_GATES="${TF_HEAVY_GATES:-db-guards integration e2e}"
needs_lock() {
  case "$GATE" in *:*) return 0;; esac
  case " $HEAVY_GATES " in *" $GATE "*) return 0;; *) return 1;; esac
}
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EXIT_CODE=0
# Journal del reintento por firma de infra (TAL-6759) — tres campos que viajan al receipt.
# Default: sin reintento (gate limpio o ni siquiera ejecutado). GATE_INFRA_RETRY_RC queda "null"
# (JSON crudo) hasta que exista al menos un intento fallido que registrar.
GATE_INFRA_RETRIED=0
GATE_INFRA_RETRY_RC="null"
GATE_INFRA_SIGNATURE=""
if [ -z "$RESULT" ]; then
  if needs_lock; then
    exec {LOCK_FD}>"$RUNNER_LOCK"
    flock -n "$LOCK_FD" || die "otro run pesado (BD/e2e) activo en este runner (flock ocupado) — reintenta o usa otro runner"
  fi
  resolve_install
  echo "──── SETUP: deps ($INSTALL) ────"
  if ! bash -c "$INSTALL" >>"$LOG" 2>&1; then
    RESULT="FAIL"; EXIT_CODE=1
    SKIP_REASON=""
    echo "  ✗ setup deps falló (log protegido: $LOG)"
  else
    # ── Envoltorio de `supabase` (talent-factory#41). DESPUÉS del install y no antes: `npm ci`
    # RECREA node_modules/.bin/supabase en cada corrida y npm lo ANTEPONE al PATH, así que un
    # envoltorio instalado antes queda tapado por el que npm regenera.
    # --wrapper lo pone run-gate-sealed (el runner NO tiene el arbol del motor, solo los
    # ficheros empujados); junto al script es el caso de invocacion local.
    WRAP_SRC="${WRAPPER_IN:-$SELF_DIR/lib/wrapper/supabase}"
    WRAP_BIN="$RUN_DIR/bin"
    # Solo los gates que pueden tocar la BD invocan `supabase`: son los mismos que toman el flock
    # (heavy o con shard). Exigir el envoltorio a `typecheck` o `lint` no protegería nada.
    if ! needs_lock; then :
    elif [ ! -x "$WRAP_SRC" ]; then
      RESULT="SKIP"; SKIP_REASON="NO MEDIDO: falta el envoltorio de supabase en el motor ($WRAP_SRC) — dueño: el motor (talent-factory#41)"
      echo "  ✗ $SKIP_REASON"
    else
      mkdir -p "$WRAP_BIN"; install -m 0755 "$WRAP_SRC" "$WRAP_BIN/supabase"
      PATH="$WRAP_BIN:$PATH"; export PATH
      # LG_BASE_SHA (TAL-5504): $BASE_SHA (arriba: sellada por la asignación o derivada por
      # merge-base) SOLO vivía como variable de shell de este proceso — nunca llegaba al hijo
      # de `bash -c "$GATE_CMD"` (línea de abajo). Un gate de producto que necesite anclar su
      # propia base (p.ej. un scope-fence contra una lista de ficheros) no tenía forma de
      # recibirla, ni siquiera declarándola sellada: el mismo gap que ya documenta la cabecera
      # de scripts/ci/check-date-bombs.sh en el repo de producto ("hoy NO exporta BASE_SHA a
      # bash -c $GATE_CMD"). Se exporta aquí, junto a LG_SHA, para que cualquier GATE_CMD que
      # la necesite la lea de su propio entorno.
      export LG_RUN_GROUP="$RUN_GROUP" LG_SHA="$SHA" LG_BASE_SHA="$BASE_SHA"
      # npm regenera node_modules/.bin/supabase en cada install: se sustituye AQUÍ.
      [ -d node_modules/.bin ] && install -m 0755 "$WRAP_SRC" node_modules/.bin/supabase 2>/dev/null || true
      # ── TRES verificaciones FAIL-CLOSED. Si alguna no resuelve al envoltorio: NO MEDIDO CON
      # DUEÑO. No se corre el gate «a ver si suena»: una medición hecha con el binario
      # equivocado es peor que no medir, porque parece una medición.
      # CORRECCIÓN (TAL-5586): este comentario decía «y SIN receipt», y era FALSO — la ruta fija
      # RESULT=SKIP, sigue al bloque común y SÍ escribe el receipt, que el lanzador luego sella.
      _wrap_ok() { [ -x "$1" ] && grep -q 'talent-factory#41' "$1" 2>/dev/null; }
      _v1="$(command -v supabase 2>/dev/null || true)"
      _v2="node_modules/.bin/supabase"
      _v3="$(npx --no-install --offline supabase --version >/dev/null 2>&1; command -v supabase 2>/dev/null || true)"
      _fallo=""
      _wrap_ok "$_v1" || _fallo="type -a supabase resuelve a '${_v1:-nada}'"
      [ -z "$_fallo" ] && [ -d node_modules ] && { _wrap_ok "$_v2" || _fallo="node_modules/.bin/supabase no es el envoltorio"; }
      [ -z "$_fallo" ] && [ -n "$_v3" ] && { _wrap_ok "$_v3" || _fallo="npx resuelve a '$_v3'"; }
      if [ -n "$_fallo" ]; then
        RESULT="SKIP"
        SKIP_REASON="NO MEDIDO: el envoltorio de supabase no intercepta ($_fallo) — dueño: el motor (talent-factory#41); recuperar: reinstalar el envoltorio y re-correr"
        echo "  ✗ $SKIP_REASON"
      fi
    fi
  fi
  if [ -z "$RESULT" ]; then
    echo "──── GATE: $GATE ────"
    # Contrato de marcador (TAL-5352): el gate puede depositar aquí evidencia estructurada
    # que sobreviva al borrado del log en PASS. Hoy lo usa el reintento de db-reset (TAL-5305).
    export LG_GATE_MARKER_DIR="$RUN_DIR"
    # NO MEDIDO (TAL-5586): un gate del opt-in que sale rc 2 declara FALLO DE INSTRUMENTO, no
    # incumplimiento del sujeto. Se traduce al canal EXISTENTE (SKIP + SKIP_REASON con el token
    # RESERVADO `rc2_optin_vacio`), NO a un estado nuevo: el lanzador ya acepta rc 0 y ya sella.
    # Default FAIL-CLOSED: fuera del opt-in, un rc 2 sigue siendo FAIL, como hasta hoy.
    case " ${TF_GATES_RC2_OPTIN:-} " in *" $GATE "*) _opta=1 ;; *) _opta=0 ;; esac
    if bash -c "$GATE_CMD" >>"$LOG" 2>&1; then
      RESULT="PASS"
      echo "  ✓ $GATE"
    else
      _gate_rc1=$?   # PRIMER comando del else: es el rc de la condición, no el del echo
      if [ "$_gate_rc1" -eq 2 ] && [ "$_opta" -eq 1 ]; then
        RESULT="SKIP"
        SKIP_REASON="rc2_optin_vacio: el gate $GATE declaró fallo de instrumento (rc 2) — log conservado: $LOG"
        echo "  ○ $GATE — NO MEDIDO (log conservado: $LOG)"
      else
        # ── Reintento por firma de infra (TAL-6759): SOLO si el FAIL trae en el tail del log una
        # firma de infra ESTRICTA (infra_signature_which, lista cerrada arriba) — un FAIL de
        # DEFECTO DE PRODUCTO (typecheck/lint/aserción) jamás casa y NUNCA se reintenta. Ante duda
        # (sin match) no hay reintento: fail-closed hacia no-retry. El rc del 2º intento MANDA
        # (ley «detectar no es enrojecer; el rc del arnés es el veredicto») — jamás un 3er intento.
        # VETO DE PRODUCTO: si el log trae CUALQUIER firma inequívoca de defecto de producto
        # (product_defect_match), NO se reintenta aunque también case una firma de infra — así un
        # blip de infra HISTÓRICO seguido de un fallo TERMINAL de producto conserva el fallo real
        # (fail-closed; evita que el 2.º intento enmascare el defecto).
        _infra_pat=""; _prod_defect=0
        if product_defect_match "$LOG"; then _prod_defect=1; fi
        if [ "$_prod_defect" -eq 0 ] && _infra_pat="$(infra_signature_which "$LOG")"; then
          GATE_INFRA_SIGNATURE="$_infra_pat"
          echo "  ⟳ $GATE — FAIL con firma de infra ('$_infra_pat'); reintento único"
          echo "──── REINTENTO por firma de infra: $_infra_pat ────" >>"$LOG"
          bash -c "$GATE_CMD" >>"$LOG" 2>&1
          _gate_rc2=$?
          GATE_INFRA_RETRIED=1
          GATE_INFRA_RETRY_RC="[$_gate_rc1,$_gate_rc2]"
          if [ "$_gate_rc2" -eq 0 ]; then
            RESULT="PASS"
            echo "  ✓ $GATE — PASS tras reintento por firma de infra"
          elif [ "$_gate_rc2" -eq 2 ] && [ "$_opta" -eq 1 ]; then
            RESULT="SKIP"
            SKIP_REASON="rc2_optin_vacio: el gate $GATE declaró fallo de instrumento (rc 2) tras el reintento por firma de infra — log conservado: $LOG"
            echo "  ○ $GATE — NO MEDIDO tras reintento (log conservado: $LOG)"
          else
            RESULT="FAIL"; EXIT_CODE=1
            echo "  ✗ $GATE — FAIL tras reintento por firma de infra (log protegido: $LOG)"
          fi
        else
          GATE_INFRA_RETRY_RC="[$_gate_rc1]"
          RESULT="FAIL"; EXIT_CODE=1
          if [ "$_prod_defect" -eq 1 ]; then
            echo "  ✗ $GATE — FAIL con firma de DEFECTO DE PRODUCTO en el log; sin reintento (log protegido: $LOG)"
          else
            echo "  ✗ $GATE (log protegido: $LOG)"
          fi
        fi
      fi
    fi
  fi
  if [ "$RESULT" = "FAIL" ] && [ "$SHOW_TAIL" = "1" ]; then
    # Defensa secundaria: SOLO con el redactor canónico presente. Jamás salida cruda.
    if [ -f "$SELF_DIR/lib/redact.sh" ]; then
      # shellcheck disable=SC1091
      . "$SELF_DIR/lib/redact.sh"
      echo "---- tail redactado ($LOG) ----"
      tail -30 "$LOG" | lg_redact
    else
      echo "ERROR: --show-tail sin redactor canónico (scripts/lib/redact.sh) — no muestro nada (fail-closed)." >&2
    fi
  fi
else
  echo "  · gate $GATE en SKIP: $SKIP_REASON"
fi
FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Re-assert del atado ANTES de emitir el receipt (anti-self-report). ─────────────────────────
FINAL="$(git -C "$WT" rev-parse HEAD)" || die "no puedo releer HEAD del worktree"
[ "$FINAL" = "$SHA" ] || die "el árbol probado ($FINAL) ya no es el SHA a certificar ($SHA): NO emito receipt"
NOW_MANIFEST="$(sha256sum "$MANIFEST" | cut -d' ' -f1)"
[ "$NOW_MANIFEST" = "$MANIFEST_DIGEST" ] || die "el manifiesto cambió durante la corrida: NO emito receipt"

# ── Receipt parcial: identidad completa + EXACTAMENTE UN gate (contrato cerrado M2-rev6). ─────
REPO_SLUG="${A_REPO_SLUG:-}"
if [ -z "$REPO_SLUG" ]; then
  url="$(git -C "$REPO" remote get-url origin 2>/dev/null || echo desconocido)"
  REPO_SLUG="$(printf '%s' "$url" | sed -E 's#(\.git)$##; s#^.*[:/]([^/]+/[^/]+)$#\1#')"
fi
# ── Versión del envoltorio de supabase (talent-factory#41). Va ANTES del bloque de TAL-5352 y no
# dentro: el self-test de aquel extrae su lector con `sed` hasta el primer `fi` a columna 0, así que
# un `if` mío en medio le truncaba el bloque y lo hacía fallar. Tres estados igual: null = NO MEDIDO.
SUPABASE_WRAPPER_VERSION="null"
if [ -x "$RUN_DIR/bin/supabase" ]; then
  _wv="$(sed -n 's/^TA_WRAPPER_VERSION="\([^"]*\)".*/\1/p' "$RUN_DIR/bin/supabase" 2>/dev/null | head -1)"
  [ -n "$_wv" ] && SUPABASE_WRAPPER_VERSION="\"$_wv\""
fi

# ── Marcador del gate (TAL-5352): TRES estados. Ausente o ilegible ⇒ null (NO MEDIDO), jamás 0.
# `retried` se acota a {0,1} (M1-O2): el contrato del gate promete UN reintento como máximo, así que
# un 7 no es un dato raro, es un marcador que no cumple el contrato ⇒ NO MEDIDO, no se publica tal cual.
# `reason` y `stop_rc` se leen POR SEPARADO y a propósito (M1-O1): son diagnóstico, y exigirlos dentro
# de la misma validación convertiría un marcador de un gate viejo —que no los escribe— en ilegible
# entero, tirando también el `retried` que sí es válido. Cada campo cae solo.
DB_RESET_RETRIED="null"; DB_RESET_RC="null"; DB_RESET_REASON="null"; DB_RESET_STOP_RC="null"
_marker="$RUN_DIR/db-reset-retry.json"
if [ -f "$_marker" ]; then
  if jq -e 'has("retried") and (.retried|type=="number") and (.retried==0 or .retried==1) and (.rc|type=="array")' "$_marker" >/dev/null 2>&1; then
    DB_RESET_RETRIED="$(jq -c '.retried' "$_marker")"
    DB_RESET_RC="$(jq -c '.rc' "$_marker")"
    jq -e '(.reason|type=="string") and (.reason|length>0)' "$_marker" >/dev/null 2>&1 \
      && DB_RESET_REASON="$(jq -c '.reason' "$_marker")"
    jq -e '.stop_rc|type=="number"' "$_marker" >/dev/null 2>&1 \
      && DB_RESET_STOP_RC="$(jq -c '.stop_rc' "$_marker")"
  else
    echo "AVISO: marcador db-reset-retry.json presente pero ilegible o fuera de contrato (retried debe ser 0 o 1) ⇒ db_reset_retried=null (NO MEDIDO)" >&2
  fi
fi

jq -n \
  --arg  schema "1" \
  --arg  repo "$REPO_SLUG" \
  --arg  pr "${PR:-}" \
  --arg  sha "$SHA" \
  --arg  base_sha "$BASE_SHA" \
  --arg  manifest_digest "$MANIFEST_DIGEST" \
  --arg  base_reg "$BASE_REG_DIGEST" \
  --arg  head_reg "$HEAD_REG_DIGEST" \
  --arg  run_group "$RUN_GROUP" \
  --arg  run_id "$RUN_ID" \
  --arg  gate_id "$GATE" \
  --arg  result "$RESULT" \
  --arg  skip_reason "$SKIP_REASON" \
  --arg  started "$STARTED_AT" \
  --arg  finished "$FINISHED_AT" \
  --arg  log "$LOG" \
  --arg  assignment "$ASSIGN_MODE" \
  --arg  motor "$SELF_SHA" \
  --arg  carveout "$CARVEOUT_SELF_SHA" \
  --arg  base_tip "$A_BASE_TIP" \
  --arg  runner "$(hostname 2>/dev/null || echo desconocido)" \
  --argjson db_reset_retried "$DB_RESET_RETRIED" \
  --argjson db_reset_rc "$DB_RESET_RC" \
  --argjson db_reset_reason "$DB_RESET_REASON" \
  --argjson db_reset_stop_rc "$DB_RESET_STOP_RC" \
  --argjson supabase_wrapper_version "$SUPABASE_WRAPPER_VERSION" \
  --argjson gate_infra_retried "$GATE_INFRA_RETRIED" \
  --argjson gate_infra_retry_rc "$GATE_INFRA_RETRY_RC" \
  --arg  gate_infra_signature "$GATE_INFRA_SIGNATURE" \
  '{schema_version: ($schema|tonumber), repo: $repo, pr: $pr, sha: $sha, base_sha: $base_sha,
    manifest_digest: $manifest_digest, base_registry_digest: $base_reg, head_registry_digest: $head_reg,
    run_group: $run_group, run_id: $run_id, gate_id: $gate_id, result: $result,
    skip_reason: (if $skip_reason == "" then null else $skip_reason end),
    started_at: $started, finished_at: $finished, log: $log, assignment: $assignment,
    motor_sha256: $motor, carveout_sha256: (if $carveout == "" then null else $carveout end),
    base_tip_sha: (if $base_tip == "" then null else $base_tip end),
    runner: $runner,
    db_reset_retried: $db_reset_retried, db_reset_rc: $db_reset_rc,
    db_reset_reason: $db_reset_reason, db_reset_stop_rc: $db_reset_stop_rc,
    supabase_wrapper_version: $supabase_wrapper_version,
    gate_infra_retried: $gate_infra_retried, gate_infra_retry_rc: $gate_infra_retry_rc,
    gate_infra_signature: (if $gate_infra_signature == "" then null else $gate_infra_signature end)}' \
  > "$RECEIPT_OUT" || die "no pude escribir el receipt"
chmod 600 "$RECEIPT_OUT"

# Retención de logs (M7): en PASS/SKIP el log se BORRA por defecto (puede contener secretos
# de builds/tests); en FAIL se conserva 0600 para diagnóstico. LG_KEEP_LOGS=1 lo conserva
# siempre (p.ej. durante el rollout local-gates-test).
# EXCEPCIÓN NO MEDIDO (TAL-5586): un SKIP con el token `rc2_optin_vacio` CONSERVA el log —a 0600,
# el mismo modo que ya fuerza la creación—, porque el diagnóstico de un fallo de instrumento vive
# ahí y sin él nadie puede reparar el instrumento. El resto de SKIP se borra igual que hoy.
if [ "$RESULT" != "FAIL" ] && [ "${SKIP_REASON#rc2_optin_vacio}" = "$SKIP_REASON" ] \
   && [ "${LG_KEEP_LOGS:-0}" != "1" ]; then
  rm -f "$LOG"
fi

echo; echo "======== RESULTADO ========"
echo "gate $GATE: $RESULT${SKIP_REASON:+ ($SKIP_REASON)}"
echo "receipt: $RECEIPT_OUT (run_group=$RUN_GROUP · sha=$SHA · manifiesto=${MANIFEST_DIGEST:0:12})"
echo "El runner NO postea: la estación agrega los receipts con post-local-gates.sh (única vía)."
exit "$EXIT_CODE"
