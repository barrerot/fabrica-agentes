#!/usr/bin/env bash
# run-gate-sealed.sh — Launcher SELLADO de un gate desde la ESTACIÓN (TAL-2288/TAL-2293 B2).
#
# OPERACIÓN ATÓMICA de extremo a extremo, controlada íntegramente por la estación:
#   1. PREFLIGHT fail-closed del runner: el usuario de gates debe estar LIMPIO — sin
#      ~/.config/gh, ~/.codex/auth.json, ~/.claude/.credentials.json, sin credential.helper
#      y sin .env.local en el clon (el código del PR correría con acceso de lectura a todo
#      eso; prohibir TF_ENV_COPY no protege paths legibles por el mismo UID).
#   2. Construye la ASIGNACIÓN sellada (identidad + digests, calculados sobre el CLON LIMPIO
#      de la estación) y TRANSFIERE EL COMMIT como bundle Git (el runner no tiene
#      credenciales para fetchear del repo privado — y no debe tenerlas).
#   3. Empuja asignación + manifiesto + MOTOR (siempre — el motor ejecutado queda atado a la
#      evidencia por su sha256 en el journal) con --uid/--gid/--mode del usuario de gates.
#   4. Ejecuta `incus exec` síncrono y CAPTURA SU RC DIRECTAMENTE (el exit lo observa la
#      estación; el runner no declara nada).
#   5. Recoge el receipt con `incus file pull` y lo sella en `journal.jsonl`: sha256(receipt)
#      + sha256(asignación) + sha256(motor) + exit observado + aislamiento.
#
# AISLAMIENTO (B2 del audit): el código del PR se ejecuta EXCLUSIVAMENTE dentro del
# contenedor runner con un usuario LIMPIO. `--unsafe-local` (diagnóstico del propio motor)
# ejecuta como subprocess de la estación y su journal queda `isolation: station-local` —
# `post-local-gates.sh` lo RECHAZA. Quien tiene credenciales jamás ejecuta código de head_sha.
#
# Uso (canónico, remoto):
#   bash run-gate-sealed.sh <gate-id> --runner <contenedor> --runner-repo <ruta-en-runner> \
#        --repo <clon-limpio-estación> --run-group G --sha S --manifest M --receipts <dir> \
#        [--base B] [--pr N] [--repo-slug owner/repo] [--runner-user <u>]
# Uso (diagnóstico, NO agregable):
#   bash run-gate-sealed.sh <gate-id> --unsafe-local --repo <clon> [misma identidad...]
#
# Salida: propaga el exit del gate observado (0/1) tras sellar · 2 = precondición/preflight.
set -uo pipefail
umask 077

die() { echo "[run-gate-sealed] ERROR: $*" >&2; exit 2; }
command -v jq >/dev/null || die "jq no disponible"

[ $# -ge 1 ] || die "uso: run-gate-sealed.sh <gate-id> --runner <c> --runner-repo <ruta> --repo <clon> --run-group G --sha S --manifest M --receipts <dir> [...]"
GATE="$1"; shift
RUNNER=""; RUNNER_USER="runner"; RUNNER_REPO=""; CLONE=""; UNSAFE_LOCAL=0
RUN_GROUP=""; SHA=""; BASE=""; PR=""; MANIFEST=""; RECEIPTS=""; REPO_SLUG=""
while [ $# -gt 0 ]; do case "$1" in
  --runner)       RUNNER="$2"; shift 2;;
  --runner-user)  RUNNER_USER="$2"; shift 2;;
  --runner-repo)  RUNNER_REPO="$2"; shift 2;;
  --repo)         CLONE="$2"; shift 2;;
  --unsafe-local) UNSAFE_LOCAL=1; shift;;
  --run-group)    RUN_GROUP="$2"; shift 2;;
  --sha)          SHA="$2"; shift 2;;
  --base)         BASE="$2"; shift 2;;
  --pr)           PR="$2"; shift 2;;
  --manifest)     MANIFEST="$2"; shift 2;;
  --receipts)     RECEIPTS="$2"; shift 2;;
  --repo-slug)    REPO_SLUG="$2"; shift 2;;
  *) die "argumento desconocido: $1";; esac; done

[ -n "$RUN_GROUP" ] || die "falta --run-group"
[ -n "$RECEIPTS" ]  || die "falta --receipts <dir>"
[ -f "${MANIFEST:-}" ] || die "falta --manifest"
[ ! -L "$MANIFEST" ] || die "el manifiesto es un symlink ($MANIFEST) — prohibido (podría apuntar fuera del motor)"
[ -d "${CLONE:-}" ] || die "falta --repo <clon limpio de la estación> (identidad y digests se calculan AQUÍ)"
if [ "$UNSAFE_LOCAL" = "0" ]; then
  [ -n "$RUNNER" ] || die "falta --runner <contenedor> (la evidencia agregable SOLO se genera en un runner aislado; --unsafe-local es diagnóstico no agregable)"
  [ -n "$RUNNER_REPO" ] || die "falta --runner-repo <ruta del clon dentro del runner>"
fi

# ── Transporte del runner (TAL-2753): local (incus) o remoto (ssh root@host + incus). ────────
# Spec: `vibe-channel-85` = contenedor local · `black-fenix/vibe-channel-95` = contenedor en
# host remoto del tailnet. El slash separa host/contenedor (los nombres de contenedor no lo
# llevan). El código del PR JAMÁS corre en la estación ni en el host remoto a pelo: siempre
# dentro del contenedor runner, con el mismo preflight fail-closed.
R_HOST=""; R_CT="$RUNNER"
case "$RUNNER" in */*) R_HOST="${RUNNER%%/*}"; R_CT="${RUNNER#*/}";; esac
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30)
if [ "$UNSAFE_LOCAL" = "0" ]; then
  if [ -z "$R_HOST" ]; then
    command -v incus >/dev/null || die "incus no disponible en la estación"
  else
    command -v ssh >/dev/null || die "ssh no disponible en la estación"
    case "$R_HOST" in *[!A-Za-z0-9.-]*|'') die "host de runner inválido: '$R_HOST'";; esac
  fi
fi
# rexec [args...] — ejecuta dentro del contenedor runner (local o remoto), argv preservado.
rexec() {
  if [ -z "$R_HOST" ]; then incus exec "$R_CT" -- "$@"; return $?; fi
  local q="" a; for a in "$@"; do q+=" $(printf '%q' "$a")"; done
  ssh "${SSH_OPTS[@]}" "root@$R_HOST" "incus exec $(printf '%q' "$R_CT") --$q"
}
# rpush <local> <path-en-ct> <uid> <gid> <mode> — copia estación → contenedor runner.
#
# SIEMPRE se empuja a un nombre TEMPORAL y se renombra dentro del runner (TAL/#40). Motivo medido:
# con `fs.protected_regular=2` (default en Ubuntu 24.04+) el kernel prohíbe abrir para ESCRITURA un
# fichero de OTRO usuario dentro de un directorio sticky world-writable — y `/tmp` del runner lo es.
# Como el push deja los ficheros con `--uid/--gid` del usuario de gates y `incus file push` escribe
# como root, el SEGUNDO push sobre el mismo destino falla con «Error: permission denied». Los
# destinos `manifest`/`motor`/`carveout`/`envoltorio` se nombran solo por run_group, así que el
# segundo gate del MISMO run_group en el MISMO runner se caía siempre.
# `rename(2)` no está sujeto a esa protección (el sticky bit sí, pero root tiene CAP_FOWNER), así
# que temporal + `mv -f` funciona Y es atómico: ningún lector ve un destino a medio escribir.
# Ojo: esto es del lado ESTACIÓN — no cambia NADA de lo que viaja al runner, así que el
# `motor_sha256` y el `carveout_sha256` de los receipts siguen siendo los mismos.
RPUSH_SEQ=0
rpush() {
  RPUSH_SEQ=$((RPUSH_SEQ + 1))
  local dst="$2" stage rc
  stage="$dst.push-$$-$RPUSH_SEQ"
  if [ -z "$R_HOST" ]; then
    incus file push --uid "$3" --gid "$4" --mode "$5" "$1" "$R_CT$stage" || return 1
    incus exec "$R_CT" -- mv -f "$stage" "$dst"; rc=$?
    [ "$rc" = 0 ] || incus exec "$R_CT" -- rm -f "$stage" >/dev/null 2>&1
    return "$rc"
  fi
  local tmp; tmp="/tmp/lg-xfer-$$.$(basename "$2")"
  scp -q "${SSH_OPTS[@]}" "$1" "root@$R_HOST:$tmp" || return 1
  ssh "${SSH_OPTS[@]}" "root@$R_HOST" "incus file push --uid $(printf '%q' "$3") --gid $(printf '%q' "$4") --mode $(printf '%q' "$5") $(printf '%q' "$tmp") $(printf '%q' "$R_CT$stage"); rc=\$?; rm -f $(printf '%q' "$tmp"); exit \$rc" || return 1
  rexec mv -f "$stage" "$dst"; rc=$?
  [ "$rc" = 0 ] || rexec rm -f "$stage" >/dev/null 2>&1
  return "$rc"
}
# rpull <path-en-ct> <local> — copia contenedor runner → estación.
rpull() {
  if [ -z "$R_HOST" ]; then incus file pull "$R_CT$1" "$2"; return $?; fi
  local tmp="/tmp/lg-xfer-$$.pull"
  ssh "${SSH_OPTS[@]}" "root@$R_HOST" "incus file pull $(printf '%q' "$R_CT$1") $(printf '%q' "$tmp")" || return 1
  scp -q "${SSH_OPTS[@]}" "root@$R_HOST:$tmp" "$2"; local rc=$?
  ssh "${SSH_OPTS[@]}" "root@$R_HOST" "rm -f $(printf '%q' "$tmp")" 2>/dev/null || true
  return "$rc"
}
case "$GATE" in *[!a-z0-9:_-]*) die "gate-id inválido: '$GATE'";; esac
safe_gate="$(printf '%s' "$GATE" | tr ':' '_')"

mkdir -p "$RECEIPTS" && chmod 700 "$RECEIPTS"
JOURNAL="$RECEIPTS/journal.jsonl"
MANIFEST="$(cd "$(dirname "$MANIFEST")" && pwd -P)/$(basename "$MANIFEST")"
MANIFEST_DIGEST="$(sha256sum "$MANIFEST" | cut -d' ' -f1)"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MOTOR_SH="$SELF_DIR/run-local-gates.sh"
[ -f "$MOTOR_SH" ] || die "no encuentro run-local-gates.sh junto a este launcher"
MOTOR_SHA="$(sha256sum "$MOTOR_SH" | cut -d' ' -f1)"
# TAL-2749: el clasificador docs-only se transporta al runner y ESTÁ ATESTADO igual que el motor
# (r4): su sha256 se sella en la asignación y el journal; el runner verifica el digest ANTES de
# sourcearlo y el agregador exige que sea el aprobado — ninguna ruta ejecuta código no atestado.
CARVEOUT_LIB="$SELF_DIR/lib/carveout.sh"
[ -f "$CARVEOUT_LIB" ] || die "no encuentro lib/carveout.sh junto a este launcher"
CARVEOUT_SHA="$(sha256sum "$CARVEOUT_LIB" | cut -d' ' -f1)"
# Envoltorio de `supabase` (talent-factory#41). Viaja al runner como un fichero MAS: el motor solo
# recibe los ficheros que se le empujan, así que sin esto la precondición del envoltorio dejaría en
# SKIP todos los gates de BD de la flota — el mismo modo de fallo que ya arreglé para los ligeros.
WRAPPER_SH="$SELF_DIR/lib/wrapper/supabase"
[ -f "$WRAPPER_SH" ] || die "no encuentro lib/wrapper/supabase junto a este launcher"
WRAPPER_SHA="$(sha256sum "$WRAPPER_SH" | cut -d' ' -f1)"

# ── Identidad calculada sobre el clon LIMPIO de la estación (confiable). ──────────────────────
[ -n "$SHA" ] || die "falta --sha"
git -C "$CLONE" cat-file -e "${SHA}^{commit}" 2>/dev/null \
  || git -C "$CLONE" fetch --no-tags --quiet origin "$SHA" 2>/dev/null \
  || { [ -n "$PR" ] && git -C "$CLONE" fetch --no-tags --quiet origin "refs/pull/$PR/head" 2>/dev/null; } \
  || die "no puedo traer $SHA al clon de la estación"
SHA="$(git -C "$CLONE" rev-parse "${SHA}^{commit}" 2>/dev/null)" || die "SHA irresoluble"
if [ -z "$BASE" ]; then
  git -C "$CLONE" fetch --no-tags --quiet origin main 2>/dev/null || true
  BASE="$(git -C "$CLONE" merge-base origin/main "$SHA" 2>/dev/null)" || die "sin base derivable: pasa --base"
fi
BASE="$(git -C "$CLONE" rev-parse "${BASE}^{commit}" 2>/dev/null)" || die "base irresoluble"
# TIP de la rama base al lanzar el gate (B2 r6): viaja SELLADO en la asignación y en el
# receipt — el agregador lo compara con el tip vigente, así el avance de main invalida la
# corrida aunque el merge-base no se mueva (y la evidencia no depende solo de la agregación).
BASE_REF_NAME="${BASE_REF_NAME:-main}"
git -C "$CLONE" fetch --no-tags --quiet origin "$BASE_REF_NAME" 2>/dev/null || true
BASE_TIP="$(git -C "$CLONE" rev-parse "origin/$BASE_REF_NAME" 2>/dev/null)" || die "sin tip de origin/$BASE_REF_NAME"
if [ -z "$REPO_SLUG" ]; then
  url="$(git -C "$CLONE" remote get-url origin 2>/dev/null || echo desconocido)"
  REPO_SLUG="$(printf '%s' "$url" | sed -E 's#(\.git)$##; s#^.*[:/]([^/]+/[^/]+)$#\1#')"
fi
reg="$(sed -n 's/^TF_SHARDS_REGISTRY="\([^"]*\)".*$/\1/p' "$MANIFEST" | tail -1)"
BASE_REG="n/a"; HEAD_REG="n/a"
if [ -n "$reg" ]; then
  b="$(git -C "$CLONE" show "$BASE:$reg" 2>/dev/null)" && BASE_REG="$(printf '%s' "$b" | sha256sum | cut -d' ' -f1)" || BASE_REG="absent"
  h="$(git -C "$CLONE" show "$SHA:$reg" 2>/dev/null)" && HEAD_REG="$(printf '%s' "$h" | sha256sum | cut -d' ' -f1)" || HEAD_REG="absent"
fi

ASG="$(mktemp "${TMPDIR:-/tmp}/assignment-XXXXXXXX.json")" || die "mktemp"
BUNDLE="$(mktemp "${TMPDIR:-/tmp}/lg-bundle-XXXXXXXX.bundle")" || die "mktemp"
TRANSFER_REF="refs/lg/transfer-$RUN_GROUP-$safe_gate"
RECEIPT_TMP=""
trap 'rm -f "$ASG" "$BUNDLE" "${RECEIPT_TMP:-}"; git -C "$CLONE" update-ref -d "$TRANSFER_REF" 2>/dev/null || true' EXIT
jq -n --arg rg "$RUN_GROUP" --arg repo "$REPO_SLUG" --arg pr "${PR:-}" --arg sha "$SHA" \
      --arg base "$BASE" --arg md "$MANIFEST_DIGEST" --arg br "$BASE_REG" --arg hr "$HEAD_REG" \
      --arg g "$GATE" --arg motor "$MOTOR_SHA" --arg btip "$BASE_TIP" --arg cvsha "$CARVEOUT_SHA" \
  '{schema_version:1, run_group:$rg, repo:$repo, pr:$pr, sha:$sha, base_sha:$base,
    base_tip_sha:$btip, manifest_digest:$md, base_registry_digest:$br,
    head_registry_digest:$hr, gate_id:$g, motor_sha256:$motor, carveout_sha256:$cvsha}' > "$ASG"
chmod 600 "$ASG"
ASG_SHA="$(sha256sum "$ASG" | cut -d' ' -f1)"
RECEIPT="$RECEIPTS/$safe_gate.json"

journal_entry() { # <receipt-sha256> <run-group> <gate-id> <journal>
  jq -R -c --arg rs "$1" --arg rg "$2" --arg g "$3" \
    'fromjson? | select(type == "object") | select(has("kind") | not) | select(.receipt_sha256 == $rs and .run_group == $rg and .gate_id == $g)' "$4" | tail -1
}

seal() { # <receipt-file> <receipt-name> <exit-code> <isolation>
  [ -f "$1" ] || die "receipt inexistente: $1 (el runner no lo emitió — exit $3)"
  local rsha; rsha="$(sha256sum "$1" | cut -d' ' -f1)"
  jq -nc --arg rg "$RUN_GROUP" --arg g "$GATE" --arg f "$2" \
         --arg rs "$rsha" --arg ec "$3" --arg asg "$ASG_SHA" --arg iso "$4" \
         --arg motor "$MOTOR_SHA" --arg cvsha "$CARVEOUT_SHA" --arg ts "$(date -u +%FT%TZ)" \
    '{run_group:$rg, gate_id:$g, receipt:$f, receipt_sha256:$rs, exit_code:($ec|tonumber),
      assignment_sha256:$asg, motor_sha256:$motor, carveout_sha256:$cvsha, isolation:$iso, sealed_at:$ts}' \
    | flock -x "$JOURNAL.lock" bash -c '
        set -euo pipefail
        if [ -s "$1" ] && [ "$(tail -c 1 "$1" | od -An -tu1 | tr -d "[:space:]")" != 10 ]; then
          printf "\n" | tee -a "$1" >/dev/null
        fi
        tee -a "$1" >/dev/null
      ' _ "$JOURNAL" \
    || die "no pude sellar en el journal"
  chmod 600 "$JOURNAL"
  local jentry
  jentry="$(journal_entry "$rsha" "$RUN_GROUP" "$GATE" "$JOURNAL")" \
    || die "sello no recuperable del journal"
  [ -n "$jentry" ] || die "sello no recuperable del journal"
  echo "[run-gate-sealed] sellado: $GATE exit=$3 iso=$4 receipt=$2 sha=${rsha:0:12}"
}

if [ "$UNSAFE_LOCAL" = "1" ]; then
  # ── Diagnóstico local: subprocess de la estación. NO agregable (isolation=station-local). ──
  echo "[run-gate-sealed] ⚠ --unsafe-local: el código del PR corre como subprocess de la estación — evidencia NO agregable" >&2
  RECEIPT_TMP="$(mktemp "$RECEIPTS/.$safe_gate.XXXXXXXX")" || die "mktemp del receipt local falló"
  set +e
  bash "$MOTOR_SH" "$CLONE" --assignment "$ASG" --manifest "$MANIFEST" --receipt "$RECEIPT_TMP" --lib-carveout "$CARVEOUT_LIB" --wrapper "$WRAPPER_SH"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || die "el runner terminó con precondición rc=$rc"
  [ -s "$RECEIPT_TMP" ] || die "el runner no emitió un receipt nuevo (exit observado: $rc)"
  chmod 600 "$RECEIPT_TMP" || die "no pude proteger el receipt temporal"
  seal "$RECEIPT_TMP" "$(basename "$RECEIPT")" "$rc" "station-local"
  # Si falla el renombrado, el receipt anterior conserva su propia entrada del journal.
  mv -f "$RECEIPT_TMP" "$RECEIPT" || die "no pude reemplazar el receipt local"
  exit "$rc"
fi

# ── PREFLIGHT fail-closed del runner (B1 r4/r5/r6): CONTENEDOR limpio, no solo el UID. ───────
# Lógica compartida en lib/preflight.sh (el arnés ejecuta ESA MISMA función contra fixtures —
# M4 r7: los tests ejercitan la lógica real, no greps del texto). Corre como root DENTRO del
# contenedor (código del motor, no del PR).
PREFLIGHT_LIB="$SELF_DIR/lib/preflight.sh"
[ -f "$PREFLIGHT_LIB" ] || die "sin lib/preflight.sh junto al launcher"
case "$RUNNER_USER" in *[!A-Za-z0-9._-]*|'') die "runner-user inválido: '$RUNNER_USER'";; esac
case "$RUNNER_REPO" in *"'"*) die "runner-repo con comilla simple — inválido";; esac
pf_out="$(rexec bash -c "$(cat "$PREFLIGHT_LIB"); lg_preflight '$RUNNER_USER' '$RUNNER_REPO'" 2>&1)" || {
  die "PREFLIGHT del runner '$RUNNER' FALLÓ (contenedor NO limpio): $pf_out
El perfil runner exige un CONTENEDOR sin credenciales (ningún home con auth de gh/Codex/Claude,
.netrc, .git-credentials ni .env.local; sin credential.helper de usuario/repo/sistema; clon sin
.env.local) y un usuario de gates SIN sudo (docker sí — el contenedor es el sandbox). Sanea o
re-provisiona el runner (ver talent-merger references/08-gates-locales.md)."; }
case "$pf_out" in *LIMPIO*) : ;; *) die "PREFLIGHT ilegible: $pf_out";; esac
echo "[run-gate-sealed] preflight: contenedor '$RUNNER' LIMPIO (usuario de gates '$RUNNER_USER' sin sudo)"

RUID="$(rexec id -u "$RUNNER_USER" 2>/dev/null | tr -d '[:space:]')"
RGID="$(rexec id -g "$RUNNER_USER" 2>/dev/null | tr -d '[:space:]')"
case "$RUID" in ''|*[!0-9]*) die "no pude resolver el uid de $RUNNER_USER en $RUNNER";; esac

# ── Transferencia del COMMIT como bundle (el runner no fetchea de remotos privados). ─────────
if ! rexec sudo -u "$RUNNER_USER" git -C "$RUNNER_REPO" cat-file -e "${SHA}^{commit}" 2>/dev/null; then
  git -C "$CLONE" update-ref "$TRANSFER_REF" "$SHA" || die "update-ref del bundle falló"
  if rexec sudo -u "$RUNNER_USER" git -C "$RUNNER_REPO" cat-file -e "${BASE}^{commit}" 2>/dev/null; then
    git -C "$CLONE" bundle create "$BUNDLE" "$TRANSFER_REF" --not "$BASE" >/dev/null 2>&1 \
      || die "bundle incremental falló"
  else
    git -C "$CLONE" bundle create "$BUNDLE" "$TRANSFER_REF" >/dev/null 2>&1 \
      || die "bundle completo falló"
  fi
  R_BUNDLE="/tmp/lg-$RUN_GROUP-$safe_gate.bundle"
  rpush "$BUNDLE" "$R_BUNDLE" "$RUID" "$RGID" 0600 \
    || die "push (bundle) al runner falló"
  rexec sudo -u "$RUNNER_USER" git -C "$RUNNER_REPO" fetch --quiet "$R_BUNDLE" "$TRANSFER_REF:$TRANSFER_REF" \
    || die "fetch del bundle en el runner falló"
  echo "[run-gate-sealed] commit $SHA transferido al runner por bundle (sin credenciales)"
fi

# ── Push de asignación + manifiesto + MOTOR (siempre; atado por sha256 en el journal). ───────
R_ASG="/tmp/lg-$RUN_GROUP-$safe_gate.assignment.json"
R_MAN="/tmp/lg-$RUN_GROUP.manifest.conf"
R_REC="/tmp/lg-$RUN_GROUP-$safe_gate.receipt.json"
R_MOTOR="/tmp/lg-$RUN_GROUP.run-local-gates.sh"
R_CARVEOUT="/tmp/lg-$RUN_GROUP.carveout.sh"
R_WRAPPER="/tmp/lg-$RUN_GROUP.supabase-wrapper"
rpush "$ASG" "$R_ASG" "$RUID" "$RGID" 0600 || die "push (asignación) al runner falló"
rpush "$MANIFEST" "$R_MAN" "$RUID" "$RGID" 0600 || die "push (manifiesto) al runner falló"
rpush "$MOTOR_SH" "$R_MOTOR" "$RUID" "$RGID" 0600 || die "push (motor) al runner falló"
rpush "$CARVEOUT_LIB" "$R_CARVEOUT" "$RUID" "$RGID" 0600 || die "push (lib carveout) al runner falló"
rpush "$WRAPPER_SH" "$R_WRAPPER" "$RUID" "$RGID" 0755 || die "push (envoltorio supabase) al runner falló"

# El receipt remoto es propio del grupo; el local se conserva hasta recibir el nuevo.
rexec rm -f "$R_REC" || die "no pude eliminar el receipt remoto previo"
set +e
rexec sudo -u "$RUNNER_USER" bash "$R_MOTOR" "$RUNNER_REPO" \
  --assignment "$R_ASG" --manifest "$R_MAN" --receipt "$R_REC" --lib-carveout "$R_CARVEOUT" \
  --wrapper "$R_WRAPPER"
rc=$?
set -e
[ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || die "el runner terminó con precondición rc=$rc (sin receipt que sellar)"
rexec test -f "$R_REC" || die "el runner no emitió un receipt nuevo (exit observado: $rc)"
RECEIPT_TMP="$(mktemp "$RECEIPTS/.$safe_gate.XXXXXXXX")" || die "mktemp del receipt local falló"
rpull "$R_REC" "$RECEIPT_TMP" || die "pull (receipt) del runner falló — sin receipt no hay evidencia (exit observado: $rc)"
chmod 600 "$RECEIPT_TMP" || die "no pude proteger el receipt temporal"
seal "$RECEIPT_TMP" "$(basename "$RECEIPT")" "$rc" "container:$RUNNER"
# Si falla el renombrado, el receipt anterior conserva su propia entrada del journal.
mv -f "$RECEIPT_TMP" "$RECEIPT" || die "no pude reemplazar el receipt local"
exit "$rc"
