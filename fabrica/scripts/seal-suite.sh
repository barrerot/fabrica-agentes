#!/usr/bin/env bash
# seal-suite.sh — Orquestador de la suite de gates SELLADA (TAL-2706, fan-out paralelo).
#
# Reemplaza el for-loop SERIAL sobre un runner (throughput ~60-90min/PR) por un FAN-OUT con
# gobierno de recursos: los runners comparten UN host, así que la única palanca segura es
# repartir los gates entre runners y CAPAR los e2e concurrentes (correr 4 e2e a la vez satura
# el host y reintroduce los flakes por contención — la causa de los re-runs seriales de horas).
#
# MODELO:
#   - CARRIL LIGERO: el primer runner corre los 9 gates rápidos (typecheck…integration) en
#     serie. Son CPU-cortos; ~16 min.
#   - CARRIL PESADO: los runners restantes corren los shards e2e repartidos round-robin, cada
#     runner SERIAL sobre su cola → la concurrencia e2e efectiva = nº de runners pesados,
#     nunca más (dos e2e en el MISMO runner colisionarían por /tmp + puerto Supabase).
#   - Gobierno: TF_E2E_CONCURRENCY (default 3) capa cuántos runners pesados se usan.
#   - Barrera: se espera a TODOS los carriles; luego se agrega con post-local-gates.sh (única
#     vía de POST del commit-status `local-gates`).
#   - FASE QUIETA (TAL-4946): TF_QUIET_GATES (default "unit") sale del carril ligero paralelo y
#     corre SERIAL tras la barrera, cuando el host ya no tiene e2e activo — así no solapa el pico
#     de contención CPU/IO (causa de flakes ajenos al cambio, tal-2916/pricing-crypto-contado, en
#     el registro de shards del PRODUCTO). Se OMITE fail-closed si la fase 1 no terminó 100%
#     limpia (un timeout puede dejar un e2e huérfano en el runner — nunca se arriesga a solapar).
#     TF_QUIET_GATES="" (definida vacía) = comportamiento previo a TAL-4946 (todo el carril
#     ligero en paralelo, sin fase quieta).
#
# SEGURIDAD DE CONCURRENCIA (ya garantizada por run-gate-sealed.sh, no se toca el motor):
#   - Cada gate corre en un CONTENEDOR runner distinto (aislamiento total entre carriles).
#   - El journal.jsonl se sella con `flock` (append serializado seguro entre procesos).
#   - Los receipts son ficheros POR-GATE (sin colisión de nombres).
#   - Dentro de un runner los gates son SERIALES (misma /tmp/lg-$RG.* por run-group) → sin
#     colisión intra-runner.
#
# Uso:  bash seal-suite.sh <PR> <SHA> <BASE> <RUNGROUP> [RUNNER...]
#       TF_E2E_CONCURRENCY=3 bash seal-suite.sh 964 <sha> origin/main pr964
# Runners: argumentos o TF_RUNNERS (lista separada por espacios) — SIN lista por defecto de ninguna casa [TAL-8037].
# Runner remoto (TAL-2753): spec `host/contenedor` — p. ej. `vibecoder-03/lg-runner-1`
# (carril ligero) o `black-fenix/vibe-channel-95` (pesado). Sin slash = contenedor local.
# El transporte ssh vive en run-gate-sealed.sh; aquí solo el slate necesita distinguirlo.
# Exit: 0 = todos los gates VERDES (ninguno FAIL, ninguno NO MEDIDO) y POST success · 1 = algún gate rojo (POST failure) · 2 = precondición.
set -uo pipefail

die() { echo "[seal-suite] ERROR: $*" >&2; exit 2; }
command -v jq >/dev/null || die "jq no disponible"
command -v flock >/dev/null || die "flock no disponible (agregación de carriles)"

PLAN_ONLY=0; NO_POST=0
while :; do case "${1:-}" in
  --plan)    PLAN_ONLY=1; shift;;
  --no-post) NO_POST=1; shift;;   # validación cronometrada: corre gates pero NO postea status
  *) break;;
esac; done
[ $# -ge 4 ] || die "uso: seal-suite.sh [--plan] [--no-post] <PR> <SHA> <BASE> <RUNGROUP> [RUNNER...]"
PR="$1"; SHA="$2"; BASE="$3"; RG="$4"; shift 4
RUNNERS=("$@")
# [TAL-8037] Sin runners por defecto de casa: o argumentos, o TF_RUNNERS (los runners son de la flota de la instancia).
if [ ${#RUNNERS[@]} -lt 1 ] && [ -n "${TF_RUNNERS:-}" ]; then read -r -a RUNNERS <<< "$TF_RUNNERS"; fi
[ ${#RUNNERS[@]} -ge 1 ] || die "sin runners: pásalos como argumentos o en TF_RUNNERS (sin lista por defecto de casa)"

# Rutas de la estación (mismas que el orquestador serial previo; overridables por env).
# [TAL-8037] Sin defaults de casa: la raíz de la fábrica se DERIVA de la ubicación de este script; el clon de
# la estación, el manifiesto y el slug del repo son identidad de la instancia (`:?` fail-closed, nombrando la variable).
TF="${TF_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
CLONE="${TF_CLONE:?seal-suite.sh: TF_CLONE sin definir (clon del repo de producto en la estación; sin default de casa)}"
MAN="${TF_MANIFEST:?seal-suite.sh: TF_MANIFEST sin definir (manifiesto de la fábrica de la instancia; sin default de casa)}"
SLUG="${TF_SLUG:?seal-suite.sh: TF_SLUG sin definir (owner/repo del repo de producto; sin default de casa)}"
REC="${TF_SEAL_REC_ROOT:-/tmp}/lg-$RG"
E2E_CONCURRENCY="${TF_E2E_CONCURRENCY:-3}"
SEALED="$TF/scripts/run-gate-sealed.sh"
GATE_TIMEOUT="${TF_GATE_TIMEOUT:-1500}"

[ -f "$SEALED" ] || die "falta run-gate-sealed.sh en $SEALED"
[ -f "$MAN" ] || die "falta manifiesto en $MAN"
[ -d "$CLONE/.git" ] || die "clon de la estación inválido: $CLONE"
# Misma gramática de datos del agregador: no ignorar claves malformadas ni duplicadas.
bad_lines="$(grep -vnE '^([[:space:]]*(#.*)?|TF_[A-Za-z0-9_]+="[^"$\\`]*"([[:space:]]+#.*)?[[:space:]]*)$' "$MAN" || true)"
[ -z "$bad_lines" ] || die "manifiesto fuera de la gramática cerrada"
dup_keys="$(grep -E '^TF_[A-Za-z0-9_]+=' "$MAN" | cut -d= -f1 | sort | uniq -d)"
[ -z "$dup_keys" ] || die "manifiesto con claves duplicadas"

# Validación numérica del cap.
case "$E2E_CONCURRENCY" in ''|*[!0-9]*) die "TF_E2E_CONCURRENCY inválido: '$E2E_CONCURRENCY'";; esac
[ "$E2E_CONCURRENCY" -ge 1 ] || die "TF_E2E_CONCURRENCY debe ser >= 1"

# ── Identidad de runner + dedup + filtro RUNNING exacto (TAL-5196 E1) ───────────────────────
# Cierra el sobre-despacho INTRA-invocación (rg2118): una lista con duplicados/alias del mismo
# runner físico, o runners caídos contados como capacidad, hace que el round-robin de abajo
# trate slots distintos como runners distintos. NO cubre coordinación cross-invocación (dos
# suites concurrentes al mismo runner) — eso es follow-on, fuera de este cambio.
RI_LIB="$(dirname "${BASH_SOURCE[0]:-$0}")/lib/runner-identity.sh"
[ -f "$RI_LIB" ] || die "falta lib/runner-identity.sh junto a seal-suite.sh"
# shellcheck source=lib/runner-identity.sh
. "$RI_LIB"
TF_STATION_HOST="${TF_STATION_HOST:-}"
[ -n "$TF_STATION_HOST" ] || die "TF_STATION_HOST no declarado — obligatorio para resolver runners locales (ver rollout de identidad en manifiestos/runner-identity.map)"
ri_load_map "$MAN"
[ -n "${RI_ALIAS_TO_HOST[$TF_STATION_HOST]:-}" ] || die "TF_STATION_HOST '$TF_STATION_HOST' no resuelve en el mapa de identidad"
ri_require_real_host "$TF_STATION_HOST" "${RI_ALIAS_TO_HOST[$TF_STATION_HOST]}"
# --plan es dry-run puro: aplica identidad/dedup (para mostrar el reparto real) pero SALTA el
# filtro RUNNING vivo — no toca incus/ssh, sigue usable sin flota arriba.
ri_normalize_runners "$TF_STATION_HOST" "$PLAN_ONLY" "${RUNNERS[@]}"
[ ${#RI_RESULT[@]} -ge 1 ] || die "0 runners tras identidad/filtro RUNNING (ver runner-identity.map y estado de la flota)"
RUNNERS=("${RI_RESULT[@]}")

# Carril ligero = TODOS los gates base del manifiesto (TF_GATE_IDS). Se DERIVA del manifiesto
# (parseado como DATO con la misma gramática que post-local-gates.sh:80, no se ejecuta) para que
# la EJECUCIÓN == el conjunto `expected` del agregador: así añadir un gate a TF_GATE_IDS (p.ej.
# markdownlint, TAL-2749) lo cablea aquí SIN deriva entre dos listas (causa raíz de B1). Antes era
# una lista hardcodeada que el agregador podía esperar sin que la suite la corriera.
FAST_GATES="$(sed -n 's/^TF_GATE_IDS="\([^"]*\)".*$/\1/p' "$MAN" | tail -1)"
[ -n "$FAST_GATES" ] || die "el manifiesto $MAN no define TF_GATE_IDS"
read -ra _FAST_ARR <<< "$FAST_GATES"; NBASE=${#_FAST_ARR[@]}

# Fase quieta (TAL-4946): TF_QUIET_GATES sale del carril ligero PARALELO y corre en una fase
# serial tras la barrera fan-out. Contrato de 3 estados con ${VAR-default} (SIN dos puntos):
# sin definir -> default "unit" BEST-EFFORT (si el manifiesto no tiene un gate "unit" —p.ej.
# talent-comms/talent-media usan "test"— el default se ignora en silencio: no puede romper
# proyectos sin ese gate id); definida VACÍA -> desactivada (comportamiento previo íntegro);
# lista EXPLÍCITA -> cada token DEBE estar en TF_GATE_IDS (si no, cobertura perdida = fail-closed;
# protege contra typos del operador — sólo se releja el default implícito, nunca un valor dado).
_QUIET_EXPLICIT=1; [ -n "${TF_QUIET_GATES+x}" ] || _QUIET_EXPLICIT=0
TF_QUIET_GATES="${TF_QUIET_GATES-unit}"
FAST_GATES_PAR=(); QUIET_GATES=()
if [ -n "${TF_QUIET_GATES// /}" ]; then
  read -ra _Q <<< "$TF_QUIET_GATES"
  _dup="$(printf '%s\n' "${_Q[@]}" | sort | uniq -d)"
  [ -z "$_dup" ] || die "TF_QUIET_GATES con duplicados: $(echo "$_dup" | tr '\n' ' ')"
  _Q_EFFECTIVE=()
  for q in "${_Q[@]}"; do
    case " $FAST_GATES " in
      *" $q "*) _Q_EFFECTIVE+=("$q") ;;
      *) [ "$_QUIET_EXPLICIT" = 1 ] && die "TF_QUIET_GATES: '$q' no está en TF_GATE_IDS del manifiesto (cobertura)" ;;
    esac
  done
  TF_QUIET_GATES="${_Q_EFFECTIVE[*]}"
  # Partición recorriendo _FAST_ARR EN ORDEN (el knob es SOLO un filtro de pertenencia): preserva
  # orden, ejecución única y el multiconjunto exacto FAST_GATES_PAR ⊎ QUIET_GATES == FAST_GATES.
  for g in "${_FAST_ARR[@]}"; do
    case " $TF_QUIET_GATES " in *" $g "*) QUIET_GATES+=("$g");; *) FAST_GATES_PAR+=("$g");; esac
  done
else
  FAST_GATES_PAR=("${_FAST_ARR[@]}")
fi
QUIET_GATES_DISP="(ninguna)"; [ ${#QUIET_GATES[@]} -gt 0 ] && QUIET_GATES_DISP="${QUIET_GATES[*]}"
FAST_PAR_DISP="(ninguno)"; [ ${#FAST_GATES_PAR[@]} -gt 0 ] && FAST_PAR_DISP="${FAST_GATES_PAR[*]}"

# Contrato del agregador: ambas claves activan e2e, ninguna deja solo gates base.
mget() { sed -n "s/^$1=\"\([^\"]*\)\".*\$/\1/p" "$MAN" | tail -1; }
SHARDS_REGISTRY="$(mget TF_SHARDS_REGISTRY)"
E2E_FAMILIES="$(mget TF_E2E_FAMILIES)"
E2E_SHARDS=()
if { [ -n "$SHARDS_REGISTRY" ] && [ -z "$E2E_FAMILIES" ]; } || { [ -z "$SHARDS_REGISTRY" ] && [ -n "$E2E_FAMILIES" ]; }; then
  die "el manifiesto declara solo UNA de TF_SHARDS_REGISTRY/TF_E2E_FAMILIES — o las dos o ninguna"
fi
if [ -n "$SHARDS_REGISTRY" ]; then
  REG_CONTENT="$(git -C "$CLONE" show "$SHA:$SHARDS_REGISTRY")" || die "no pude leer $SHARDS_REGISTRY @ $SHA"
  jq -e '
    (.families | type == "object" and length > 0)
    and all(.families | keys[]; test("^[A-Za-z0-9_.-]+$"))
    and all(.families[]; (.shards | type == "array" and length > 0))
    and all(.families[].shards[]; (.id | type == "string" and test("^[A-Za-z0-9_.-]+$")))
    and (([.families | to_entries[] | .key as $f | .value.shards[] | "\($f):\(.id)"] | length)
      == ([.families | to_entries[] | .key as $f | .value.shards[] | "\($f):\(.id)"] | unique | length))
  ' <<< "$REG_CONTENT" >/dev/null || die "registro de shards inválido @ $SHA"
  read -r -a _E2E_FAMILY_ARRAY <<< "$E2E_FAMILIES"
  for family in "${_E2E_FAMILY_ARRAY[@]}"; do
    jq -e --arg f "$family" '.families | has($f)' <<< "$REG_CONTENT" >/dev/null || die "familia e2e ausente: $family"
  done
  SHARD_LINES="$(jq -r '.families | to_entries[] | .key as $f | .value.shards[] | "\($f):\(.id)"' <<< "$REG_CONTENT")" || die "no pude derivar shards @ $SHA"
  mapfile -t E2E_SHARDS <<< "$SHARD_LINES"
  [ ${#E2E_SHARDS[@]} -ge 1 ] || die "el registro no arrojó shards e2e @ $SHA"
fi

# Reparto de runners: 1er runner = carril ligero; resto = pool pesado (capado por concurrency).
FAST_RUNNER="${RUNNERS[0]}"
HEAVY_POOL=("${RUNNERS[@]:1}")
[ ${#HEAVY_POOL[@]} -ge 1 ] || HEAVY_POOL=("${RUNNERS[0]}")   # 1 solo runner → todo por él
# Concurrencia e2e efectiva: no más runners pesados que los disponibles ni que el cap.
EFF_CONC="$E2E_CONCURRENCY"
[ "$EFF_CONC" -le "${#HEAVY_POOL[@]}" ] || EFF_CONC="${#HEAVY_POOL[@]}"
HEAVY_RUNNERS=("${HEAVY_POOL[@]:0:$EFF_CONC}")
if [ ${#E2E_SHARDS[@]} -eq 0 ]; then HEAVY_RUNNERS=(); EFF_CONC=0; fi

rm -rf "$REC"; mkdir -p "$REC"
STAMP() { TZ=America/Mexico_City date '+%H:%M:%S'; }
T0="$(date +%s)"
echo "===== SEAL-SUITE $RG pr$PR @ $(STAMP) — fan-out ====="
echo "  carril ligero (paralelo):  $FAST_RUNNER  ($FAST_PAR_DISP)"
echo "  fase quieta (serial, sin e2e):  $QUIET_GATES_DISP"
echo "  carril pesado:  ${HEAVY_RUNNERS[*]}  (cap e2e=$EFF_CONC · ${#E2E_SHARDS[@]} shards)"

FAILDIR="$(mktemp -d "${TMPDIR:-/tmp}/seal-$RG-fail-XXXXXX")" || die "mktemp"

# Ejecuta un comando dentro de un runner local (incus) o remoto (ssh root@host + incus).
slate_exec() { # <runner> <cmd...>
  local runner="$1"; shift
  case "$runner" in
    */*) local h="${runner%%/*}" c="${runner#*/}" q="" a
         for a in "$@"; do q+=" $(printf '%q' "$a")"; done
         ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$h" "incus exec $(printf '%q' "$c") --$q";;
    *)   incus exec "$runner" -- "$@";;
  esac
}

# Corre UNA unit sellada en un runner concreto; registra fallo en $FAILDIR si rojo.
run_one() { # <gate-id> <runner>
  local g="$1" runner="$2" sg rc
  sg=$(printf '%s' "$g" | tr ':' '_')
  # slate por gate en ese runner (incus file push --uid no sobrescribe 0600 de otro uid).
  # /tmp/lg-* son destinos REMOTOS fijos de run-gate-sealed.sh, no temporales
  # locales: TMPDIR y TF_SEAL_REC_ROOT solo gobiernan la estación y sus receipts.
  slate_exec "$runner" rm -f \
    "/tmp/lg-$RG.manifest.conf" "/tmp/lg-$RG.run-local-gates.sh" "/tmp/lg-$RG.carveout.sh" \
    "/tmp/lg-$RG-$sg.assignment.json" "/tmp/lg-$RG-$sg.receipt.json" 2>/dev/null || true
  echo "=== [$RG pr$PR] gate $g -> $runner @ $(STAMP) ==="
  timeout "$GATE_TIMEOUT" bash "$SEALED" "$g" \
    --runner "$runner" --runner-user "${TF_RUNNER_USER:-runner}" --runner-repo "${TF_RUNNER_REPO:-/home/runner/repo}" \
    --repo "$CLONE" --run-group "$RG" --sha "$SHA" --base "$BASE" \
    --manifest "$MAN" --receipts "$REC" --pr "$PR" --repo-slug "$SLUG" 2>&1 \
    | grep -vE 'Pushing .*(bundle|assignment|manifest|run-local-gates)' | tail -3
  rc=${PIPESTATUS[0]}
  [ "$rc" -eq 0 ] || echo "$g(rc$rc)" > "$FAILDIR/$sg"
  return "$rc"
}

# Un carril = una cola de gates SERIAL en un runner fijo (subshell de fondo). Propaga el rc: un
# gate rojo/timeout hace que el carril devuelva 1 (la barrera lo detecta vía el rc de `wait`).
run_lane() { # <runner> <gate...>
  local runner="$1"; shift
  slate_exec "$runner" bash -c "rm -f /tmp/lg-$RG* 2>/dev/null" || true
  local g rc=0
  for g in "$@"; do run_one "$g" "$runner" || rc=1; done
  return "$rc"
}

# Reparto round-robin de shards e2e entre los runners pesados.
declare -a LANE_SHARDS
for i in "${!E2E_SHARDS[@]}"; do
  slot=$(( i % ${#HEAVY_RUNNERS[@]} ))
  LANE_SHARDS[slot]="${LANE_SHARDS[slot]:-} ${E2E_SHARDS[i]}"
done

if [ "$PLAN_ONLY" = "1" ]; then
  echo "--- PLAN (dry-run, no se ejecutan gates) ---"
  echo "ligero  $FAST_RUNNER : $FAST_GATES"
  echo "  carril ligero (paralelo): $FAST_PAR_DISP"
  echo "  fase quieta (serial, sin e2e): $QUIET_GATES_DISP"
  for slot in "${!HEAVY_RUNNERS[@]}"; do
    echo "pesado  ${HEAVY_RUNNERS[slot]} :${LANE_SHARDS[slot]:-  (vacío)}"
  done
  echo "e2e concurrentes efectivos: $EFF_CONC · total gates: $(( NBASE + ${#E2E_SHARDS[@]} ))"
  rm -rf "$REC" "$FAILDIR"
  exit 0
fi

# FASE 1 — ligero + pesados. Con >=2 runners FÍSICOS DISTINTOS (post identidad/dedup arriba)
# corren en PARALELO (fan-out, aislados por contenedor). Con EXACTAMENTE 1 runner físico
# (TAL-5196 E1 — antes el fallback de HEAVY_POOL re-metía el mismo runner y lanzaba ligero y
# pesado en paralelo sobre él, reproduciendo rg2118 con 1 solo runner) se corren en SERIE:
# ligero primero, luego cada bucket pesado — NUNCA dos run_lane concurrentes sobre el mismo
# contenedor. Arrays SIEMPRE expandidos con "${arr[@]}" (nunca $arr desnudo).
LANE_RC=0
if [ ${#RUNNERS[@]} -eq 1 ]; then
  if [ ${#FAST_GATES_PAR[@]} -gt 0 ]; then
    run_lane "$FAST_RUNNER" "${FAST_GATES_PAR[@]}" || LANE_RC=1
  fi
  for slot in "${!HEAVY_RUNNERS[@]}"; do
    # shellcheck disable=SC2086  # LANE_SHARDS[slot] es STRING con word-split intencional (lista de shards)
    run_lane "${HEAVY_RUNNERS[$slot]}" ${LANE_SHARDS[$slot]:-} || LANE_RC=1
  done
else
  PIDS=()
  if [ ${#FAST_GATES_PAR[@]} -gt 0 ]; then
    run_lane "$FAST_RUNNER" "${FAST_GATES_PAR[@]}" & PIDS+=($!)
  fi
  for slot in "${!HEAVY_RUNNERS[@]}"; do
    # shellcheck disable=SC2086
    run_lane "${HEAVY_RUNNERS[$slot]}" ${LANE_SHARDS[$slot]:-} & PIDS+=($!)
  done
  # Barrera: esperar TODOS los carriles de la fase 1, ACUMULANDO el rc de cada `wait` — un
  # carril muerto/timeout no escribe FAILDIR por sí solo; la barrera es quien lo detecta.
  for p in "${PIDS[@]}"; do wait "$p" || LANE_RC=1; done
fi

FAILED=""
if compgen -G "$FAILDIR/*" >/dev/null; then FAILED=" $(cat "$FAILDIR"/* | tr '\n' ' ')"; fi
[ "$LANE_RC" = 0 ] || FAILED="${FAILED} coordinacion(lane-rc)"

# FASE 2 — serial "quieta" (TAL-4946): corre DESPUÉS de la barrera, cuando el host ya no tiene
# e2e activo — SOLO si la fase 1 terminó 100% limpia (FAILED vacío == LANE_RC=0 Y FAILDIR vacío).
# Un timeout de fase 1 puede matar run-gate-sealed/incus/ssh y dejar un e2e huérfano en el runner
# (08-runners-del-mergeador.md:189-191): si eso ocurre, la fase quieta se OMITE fail-closed — nunca
# se arriesga a solapar un gate quieto con un e2e que pudiera seguir vivo. La suite ya está en rojo.
if [ ${#QUIET_GATES[@]} -gt 0 ]; then
  if [ -z "$FAILED" ]; then
    run_lane "$FAST_RUNNER" "${QUIET_GATES[@]}" || LANE_RC=1
    if compgen -G "$FAILDIR/*" >/dev/null; then FAILED=" $(cat "$FAILDIR"/* | tr '\n' ' ')"; fi
    [ "$LANE_RC" = 0 ] || FAILED="${FAILED} coordinacion(lane-rc)"
  else
    echo "[seal-suite] fase quieta OMITIDA: fase 1 no limpia (fallos:$FAILED) — $QUIET_GATES_DISP NO se ejecuta (fail-closed)"
    FAILED="${FAILED} fase-quieta-omitida(fase1-sucia)"
  fi
fi

rm -rf "$FAILDIR"
ELAPSED=$(( $(date +%s) - T0 ))
echo "===== SEAL-SUITE $RG pr$PR TERMINADO @ $(STAMP) — wall-clock ${ELAPSED}s (~$((ELAPSED/60))m$((ELAPSED%60))s) ====="
TOTAL=$(( NBASE + ${#E2E_SHARDS[@]} ))
# NO MEDIDO (TAL-5586): un gate no medido sale rc 0 y NO deja rastro en FAILDIR — sin esto el
# fan-out lo contaría verde y --no-post saldría 0 sin haber medido nada. DOS estados distintos:
# directorio sin receipts = verde (ausencia real, no se inventa un rojo); receipt PRESENTE que
# el instrumento no puede interpretar = NO MEDIDO. Detectar no es enrojecer, tampoco aquí dentro.
NOMED=""
for _r in "$REC"/*.json; do
  [ -f "$_r" ] || continue
  _g="$(basename "$_r" .json)"
  _reason="$(jq -r '.skip_reason // ""' "$_r")" \
    || { NOMED="$NOMED $_g(receipt-ilegible)"; continue; }
  case "$_reason" in
    rc2_optin_vacio*) NOMED="$NOMED $(jq -r '.gate_id' "$_r" 2>/dev/null || printf '%s' "$_g")" ;;
  esac
done
if   [ -n "$FAILED" ] || [ -n "$NOMED" ]; then
  if [ -n "$FAILED" ]; then echo "GATES FALLIDOS:$FAILED"; fi
  if [ -n "$NOMED"  ]; then echo "NO MEDIDO:$NOMED — el fan-out NO es verde"; fi
else
  echo "$TOTAL/$TOTAL verdes en fan-out"
fi

if [ "$NO_POST" = "1" ]; then
  echo "===== --no-post: NO se agrega/postea status (validación cronometrada) — wall-clock ${ELAPSED}s ====="
  [ -z "$FAILED" ] && [ -z "$NOMED" ] && exit 0 || exit 1
fi

echo "===== AGREGACIÓN post-local-gates ====="
bash "$TF/scripts/post-local-gates.sh" "$RG" "$SLUG" "$PR" \
  --receipts "$REC" --manifest "$MAN" --repo "$CLONE" 2>&1 | tail -10
POST_RC=${PIPESTATUS[0]}
echo "POST rc=$POST_RC (0=success posteado · 1=failure posteado · 3=post falló)"
exit "$POST_RC"
