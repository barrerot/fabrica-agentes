#!/usr/bin/env bash
# tests/scripts/cr-review-harness.sh — harness aislado y VERSIONADO para scripts/cr-review.sh
# (TAL-2816, las garantías de concurrencia probadas manualmente en las rondas de
# code-gate anteriores quedan reproducibles y protegen futuras modificaciones).
#
# Self-contained: crea su propio repo git (bare origin + clone) en un tmpdir, con stubs propios de
# `coderabbit`/`gh` y un `HOME` falso con `auth.json`. CERO red, CERO CLI real de CodeRabbit, CERO
# gasto del bucket CR escaso — el CLI se sustituye por un stub controlado vía `CR_TEST_MODE`.
#
# Corrido por subprocess desde tests/unit/cr-review-harness.test.ts (gate `unit`, patrón
# railway-approval-hook.test.ts). Exit 0 si todos los checks pasan; no-cero (con diagnóstico en
# stdout/stderr) si alguno falla.
#
# Requiere `flock` (util-linux) — igual que el propio cr-review.sh: sin él, el script FALLA
# CERRADO por diseño, así que el harness lo exige también (`it.skipIf` en el spec vitest si falta).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/fixtures/instalacion/gh-dobles.sh" || exit 2
CR_REVIEW_SRC="$REPO_ROOT/scripts/cr-review.sh"
NORMALIZE_SRC="$REPO_ROOT/scripts/lib/cr-finding-normalize.jq"   # TAL-2610: filtro compartido que cr-review.sh consume
[ -f "$CR_REVIEW_SRC" ] || { echo "harness: no encuentro $CR_REVIEW_SRC" >&2; exit 1; }
[ -f "$NORMALIZE_SRC" ] || { echo "harness: no encuentro $NORMALIZE_SRC (filtro TAL-2610)" >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "harness: 'flock' no disponible — SKIP (cr-review.sh también falla cerrado sin él)." >&2; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "harness: 'jq' no disponible — no puedo verificar los artefactos." >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL: %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# --- Fixture: repo git real (bare origin + clone) con cr-review.sh copiado -------------------
ORIGIN="$WORK/origin"
REPO="$WORK/repo"
FAKEHOME="$WORK/fakehome"
FAKEBIN="$WORK/fakebin"
mkdir -p "$ORIGIN" "$FAKEHOME/.coderabbit" "$FAKEBIN"

git init --bare -q "$ORIGIN"
git clone -q "$ORIGIN" "$REPO" 2>/dev/null
(
  cd "$REPO" || exit 1
  git config user.email "harness@test.local"
  git config user.name "harness"
  echo hi > a.txt
  git add a.txt
  git commit -q -m init
)
git -C "$REPO" push -q origin HEAD:main
(
  cd "$REPO" || exit 1
  git checkout -q -b fix/test
  cp "$CR_REVIEW_SRC" cr-review.sh
  mkdir -p .claude scripts/lib
  cp "$NORMALIZE_SRC" scripts/lib/cr-finding-normalize.jq   # cr-review.sh lo referencia como $ROOT/scripts/lib/...
  printf '.claude/.cr-review-*\n' > .gitignore
  git add .gitignore cr-review.sh scripts/lib/cr-finding-normalize.jq a.txt
  git commit -q -m wip
)

# TAL-3562 (de auditoría): fixture con FORMA real de credencial (apiKey + token cr_...), no
# `{}`. Con `{}` la aserción "ningún artefacto contiene material de credencial" pasa aunque una
# regresión copie el fichero COMPLETO a un artefacto — no hay nada que un grep de apiKey/cr_ pudiera
# encontrar. Con contenido real-shaped, esa misma regresión SÍ la detecta el grep.
echo '{"apiKey":"cr_9f3a7c2e8b1d4f56a0c9e7b3d2f18a6c","account":{"email":"harness@test.local"}}' \
  > "$FAKEHOME/.coderabbit/auth.json"

# TAL-3562 (de auditoría): exportados para que el stub (heredoc sin interpolación, corre en
# su propio proceso) pueda referenciar la ruta FIJA del HOME real/compartido y dejar un rastro del
# HOME EFECTIVO visto en cada invocación — ninguno de los dos es parte del contrato de cr-review.sh,
# son instrumentación del harness.
export FAKEHOME
EFFECTIVE_HOME_LOG="$WORK/effective-home.log"
export EFFECTIVE_HOME_LOG
# TAL-3562 (de auditoría): rastro de si `auth.json`, visto desde CADA invocación, es un
# fichero regular (materializado por el snapshot) o SIGUE siendo un symlink (el snapshot no aisló
# nada — cp -a sin dereferenciar lo habría preservado).
MATERIALIZATION_LOG="$WORK/materialization.log"
export MATERIALIZATION_LOG

cat > "$FAKEBIN/coderabbit" <<'STUB'
#!/usr/bin/env bash
# `auth status --agent` emite el NDJSON del contrato REAL del CLI: rc=0 SIEMPRE — la sesión se afirma
# en `authenticated`, nunca en el exit code. CR_TEST_AUTH_FAIL=1 simula el asiento con auth.json
# PRESENTE pero sesión CERRADA: el caso exacto que el guard viejo por exit code no veía (TAL-3562).
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  [ -n "${EFFECTIVE_HOME_LOG:-}" ] && echo "auth:$HOME" >> "$EFFECTIVE_HOME_LOG"
  if [ -n "${MATERIALIZATION_LOG:-}" ]; then
    if [ -L "$HOME/.coderabbit/auth.json" ]; then echo "auth:symlink" >> "$MATERIALIZATION_LOG"
    elif [ -f "$HOME/.coderabbit/auth.json" ]; then echo "auth:regular" >> "$MATERIALIZATION_LOG"
    else echo "auth:missing" >> "$MATERIALIZATION_LOG"
    fi
  fi
  if [ "${CR_TEST_AUTH_FAIL:-0}" = 1 ]; then
    echo '{"type":"status","phase":"auth","status":"not_authenticated","authenticated":false}'
  else
    echo '{"type":"status","phase":"auth","status":"authenticated","authenticated":true,"authType":"api_key"}'
  fi
  exit 0
fi
if [ "$1" = "review" ]; then
  [ -n "${EFFECTIVE_HOME_LOG:-}" ] && echo "review:$HOME" >> "$EFFECTIVE_HOME_LOG"
  # TAL-3629: CR_TEST_REVIEW_SLEEP=<seg> alarga la corrida del CLI para que dos invocaciones de
  # cr-review.sh sobre el MISMO clon se solapen de verdad. Solo simula
  # duración; no cambia la salida.
  [ -n "${CR_TEST_REVIEW_SLEEP:-}" ] && sleep "$CR_TEST_REVIEW_SLEEP"
  if [ -n "${MATERIALIZATION_LOG:-}" ]; then
    if [ -L "$HOME/.coderabbit/auth.json" ]; then echo "review:symlink" >> "$MATERIALIZATION_LOG"
    elif [ -f "$HOME/.coderabbit/auth.json" ]; then echo "review:regular" >> "$MATERIALIZATION_LOG"
    else echo "review:missing" >> "$MATERIALIZATION_LOG"
    fi
  fi
  # TAL-3562 (de auditoría): CR_TEST_MUTATE_SHARED_HOME_DURING_REVIEW=1 simula OTRA torre
  # rotando el asiento en el HOME REAL/compartido ($FAKEHOME, la ruta FIJA — NO $HOME, que aquí ya
  # es el snapshot privado que cr-review.sh congeló) justo mientras `review` corre. Con el snapshot
  # inmutable (reemplaza el sondeo probabilístico de las rondas 2/3), esta mutación NUNCA debería
  # alcanzar la corrida: `review` lee de su copia aislada, no del compartido.
  if [ "${CR_TEST_MUTATE_SHARED_HOME_DURING_REVIEW:-0}" = 1 ] && [ -n "${FAKEHOME:-}" ]; then
    echo '{"apiKey":"cr_rotated0000000000000000000000","account":{"email":"otro-asiento@test.local"}}' \
      > "$FAKEHOME/.coderabbit/auth.json"
  fi
  case "${CR_TEST_MODE:-clean}" in
    clean)
      echo '{"type":"complete","status":"review_completed"}'
      ;;
    incomplete)
      echo '{"type":"error","message":"boom"}'
      ;;
    findings)
      echo '{"type":"finding","severity":"critical","fileName":"x.ts","lineStart":1,"lineEnd":2,"title":"bad","description":"desc","category":"bug","prompt":"fix it","suggestions":["do X"]}'
      echo '{"type":"complete","status":"review_completed"}'
      ;;
    findings2)
      echo '{"type":"finding","severity":"critical","fileName":"x.ts","lineStart":1,"lineEnd":2,"title":"bad","description":"desc","category":"bug","prompt":"totally different fix","suggestions":["do Y"]}'
      echo '{"type":"complete","status":"review_completed"}'
      ;;
    schema065)
      # Schema CR-CLI 0.6.5: cuerpo en .codegenInstructions, archivo en .fileName, líneas embebidas
      # como "around lines N - M", .title/.description/.lineStart null. El filtro compartido debe
      # normalizarlo a un finding TRIAGEABLE (paridad OK) — prueba la integración TAL-2610.
      echo '{"type":"finding","severity":"critical","fileName":"z.ts","codegenInstructions":"Fix the thing around lines 10 - 14 to avoid the bug.","category":"bug"}'
      echo '{"type":"complete","status":"review_completed"}'
      ;;
    phantom)
      # Finding critical SIN cuerpo textual (phantom): el filtro NO lo emite → normalized(0) <
      # blockers(1) → PARIDAD fail-closed → gate abortado con state=error, sin sentinel.
      echo '{"type":"finding","severity":"critical","fileName":"p.ts"}'
      echo '{"type":"complete","status":"review_completed"}'
      ;;
    collapse-a|collapse-b)
      # dos findings IDÉNTICOS salvo por codegenInstructions Y suggestions, con
      # MISMO file/línea/título/description/prompt. description/prompt colapsan igual → antes producían
      # la MISMA huella (fail-open); con fpMaterial deben diferir y NO deduplicarse.
      if [ "$CR_TEST_MODE" = "collapse-a" ]; then ci="detalle real A"; sg='["opcion-A"]'; else ci="detalle real B"; sg='["opcion-B"]'; fi
      echo "{\"type\":\"finding\",\"severity\":\"critical\",\"fileName\":\"c.ts\",\"lineStart\":3,\"lineEnd\":4,\"title\":\"same\",\"description\":\"same body\",\"category\":\"bug\",\"prompt\":\"same fix\",\"codegenInstructions\":\"$ci\",\"suggestions\":$sg}"
      echo '{"type":"complete","status":"review_completed"}'
      ;;
  esac
  exit 0
fi
exit 1
STUB
chmod +x "$FAKEBIN/coderabbit"

cat > "$FAKEBIN/gh" <<'STUB'
#!/usr/bin/env bash
# Por defecto exit 1 (sin PR). CR_TEST_GH_PR=1 simula un PR existente con el label cr-review para
# ejercitar el backstop `deferred` autorizante de defer_or_block, reconociendo el argv REAL con el
# BRANCH intercalado (`gh pr view <branch> --json ...`, `gh pr edit <branch> --add-label ...`).
if [ "${CR_TEST_GH_PR:-0}" = 1 ] && [ "$1" = "pr" ]; then
  case "$2" in
    view)
      # `--json labels --jq ...` debe emitir la línea de label; `--json number` solo importa por rc.
      for a in "$@"; do [ "$a" = "labels" ] && { echo "cr-review"; exit 0; }; done
      exit 0
      ;;
    edit) exit 0 ;;   # `--add-label cr-review`
  esac
fi
exit 1
STUB
chmod +x "$FAKEBIN/gh"
cerrar_doble_gh "$FAKEBIN/gh" || exit 1

# Shims fail-closed: interceptan mv/flock/jq SOLO bajo su toggle de env; sin
# el toggle exec-ean el binario REAL (ruta absoluta capturada ANTES de prepend de $FAKEBIN → sin bucle).
REAL_MV="$(command -v mv)"; REAL_FLOCK="$(command -v flock)"; REAL_JQ="$(command -v jq)"
REAL_GIT="$(command -v git)"

cat > "$FAKEBIN/mv" <<STUB
#!/usr/bin/env bash
# CR_TEST_FAIL_PROMOTE=1: falla SOLO la promoción del crudo final (destino *.cr-review-raw-*.jsonl y
# NO .partial). Las escrituras atómicas de commit_run (result/findings/history/gen/sentinel) usan
# otros prefijos → intactas.
if [ "\${CR_TEST_FAIL_PROMOTE:-0}" = 1 ]; then
  dst="\${@: -1}"
  case "\$dst" in *.cr-review-raw-*.jsonl) exit 1 ;; esac
fi
# TAL-3629: CR_TEST_SLOW_HISTORY_MV=<seg> retrasa SOLO el rename final del ledger (destino
# *.cr-review-history.jsonl), abriendo de forma DETERMINISTA la ventana del read-modify-write
# leer→temp→rename de _merge_history_entry. Es lo que permite probar que la exclusión mutua del lock
# es indispensable sin depender de la latencia de dos runs completos (el azar no es un test).
if [ -n "\${CR_TEST_SLOW_HISTORY_MV:-}" ]; then
  dst="\${@: -1}"
  case "\$dst" in *.cr-review-history.jsonl) sleep "\$CR_TEST_SLOW_HISTORY_MV" ;; esac
fi
exec "$REAL_MV" "\$@"
STUB
chmod +x "$FAKEBIN/mv"

cat > "$FAKEBIN/git" <<STUB
#!/usr/bin/env bash
# TAL-3629: CR_TEST_MOVE_HEAD=1 mueve HEAD UNA vez (marcador one-shot en
# \$CR_TEST_MOVE_HEAD_MARK), en la invocación \`git fetch\` de cr-review.sh — que ocurre DESPUÉS de
# capturar HEAD_SHA al arrancar y ANTES de leer REVIEW_HEAD en vivo. Reproduce la carrera real (otro
# proceso commitea mientras el gate arranca) de forma determinista, sin depender de tiempos, para que
# el guard de TOCTOU se ejercite DE VERDAD end-to-end en vez de recalcular la condición en el arnés.
if [ "\${CR_TEST_MOVE_HEAD:-0}" = 1 ] && [ "\$1" = "fetch" ] \\
   && [ -n "\${CR_TEST_MOVE_HEAD_MARK:-}" ] && [ ! -e "\$CR_TEST_MOVE_HEAD_MARK" ]; then
  : > "\$CR_TEST_MOVE_HEAD_MARK"
  "$REAL_GIT" commit --allow-empty -q -m "carrera: HEAD movido tras el arranque del gate" >/dev/null 2>&1
fi
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$FAKEBIN/git"

cat > "$FAKEBIN/flock" <<STUB
#!/usr/bin/env bash
# CR_TEST_FAIL_RUNLOCK=1: falla SOLO la adquisición del lock por-run (flock -n 8); el ledger
# (-w 30 9) y la reconciliación (-n 7) pasan.
if [ "\${CR_TEST_FAIL_RUNLOCK:-0}" = 1 ] && [ "\$1" = "-n" ] && [ "\$2" = "8" ]; then exit 1; fi
exec "$REAL_FLOCK" "\$@"
STUB
chmod +x "$FAKEBIN/flock"

cat > "$FAKEBIN/jq" <<STUB
#!/usr/bin/env bash
# CR_TEST_FAIL_HISTUNIV=1: falla SOLO la proyección de _history_universe (programa jq con el token
# único 'fp:\$fp'); fp_of usa '| tojson', _merge_history_entry otro filtro, y los jq del harness NO
# llevan ese token → todos exec-ean el jq real.
if [ "\${CR_TEST_FAIL_HISTUNIV:-0}" = 1 ]; then
  for a in "\$@"; do case "\$a" in *"fp:\$fp"*) exit 1 ;; esac; done
fi
exec "$REAL_JQ" "\$@"
STUB
chmod +x "$FAKEBIN/jq"

export HOME="$FAKEHOME"
export PATH="$FAKEBIN:$PATH"

run_cr() { # modo -> corre cr-review.sh con CR_TEST_MODE=modo en $REPO; fija CR_RC
  # NO borrar `.claude/.cr-review-*` aquí: el glob se comería también el known-debt store
  # (durable, multi-run) y el historial — `start_run` ya invalida por sí mismo el sentinel/
  # result/findings transitorios de la corrida anterior; no hace falta (ni conviene) ayudarlo.
  ( cd "$REPO" && CR_TEST_MODE="$1" bash cr-review.sh )
  CR_RC=$?
}

hist_last() { jq -c -s '.[-1]' "$REPO/.claude/.cr-review-history.jsonl" 2>/dev/null; }

# ============================================================================================
echo "=== Escenario clean: review limpio -> sentinel ok, RAW promovido (sin .partial), historial ok ==="
run_cr clean
[ "$CR_RC" -eq 0 ] && [ -e "$REPO/.claude/.cr-review-ok" ] \
  && ok "clean: rc=0 y sentinel presente" || bad "clean: rc=$CR_RC (esperaba 0) o sentinel ausente"
if compgen -G "$REPO/.claude/.cr-review-raw-*.jsonl" > /dev/null \
   && ! compgen -G "$REPO/.claude/.cr-review-raw-*.jsonl.partial" > /dev/null; then
  ok "clean: RAW final promovido, sin .partial residual (escritura atómica gateada)"
else
  bad "clean: RAW no promovido correctamente (queda .partial o falta el final)"
fi
[ "$(hist_last | jq -r '.state')" = "ok" ] && ok "clean: historial state=ok" || bad "clean: historial incorrecto"

# TAL-3562: el `result` afirma QUÉ asiento (huella, jamás la credencial) gastó la corrida — comparar
# contra la huella calculada del auth.json del FAKEHOME (mismo algoritmo que `sha256_hex` en cr-review.sh).
EXPECTED_SEAT_FP="$(sha256sum "$FAKEHOME/.coderabbit/auth.json" 2>/dev/null | awk '{print substr($1,1,12)}')"
ACTUAL_SEAT_FP="$(jq -r '.seat_fp // empty' "$REPO/.claude/.cr-review-result.json" 2>/dev/null)"
[ -n "$EXPECTED_SEAT_FP" ] && [ "$ACTUAL_SEAT_FP" = "$EXPECTED_SEAT_FP" ] \
  && ok "clean: seat_fp == sha256 truncada de auth.json ($ACTUAL_SEAT_FP)" \
  || bad "clean: seat_fp inesperado (actual='$ACTUAL_SEAT_FP' esperado='$EXPECTED_SEAT_FP')"
# TAL-3637: la MISMA huella debe llegar al LEDGER, no solo al `result` (que la corrida siguiente pisa).
LEDGER_SEAT_FP="$(hist_last | jq -r '.seat_fp // empty' 2>/dev/null)"
[ -n "$EXPECTED_SEAT_FP" ] && [ "$LEDGER_SEAT_FP" = "$EXPECTED_SEAT_FP" ] \
  && ok "clean: seat_fp propagado al ledger append-only ($LEDGER_SEAT_FP) — atribución de asiento que sobrevive" \
  || bad "clean: seat_fp NO llegó al ledger (actual='$LEDGER_SEAT_FP' esperado='$EXPECTED_SEAT_FP')"
# Ningún artefacto persistido debe llevar material de credencial — solo la huella. El glob cubre
# TODOS los artefactos, ledger incluido (`.cr-review-history.jsonl` cae dentro de `.cr-review-*`).
if grep -RlqE 'apiKey|cr_[A-Za-z0-9]{8,}' "$REPO/.claude/.cr-review-"* 2>/dev/null; then
  bad "clean: artefacto con material de credencial detectado en .claude/.cr-review-*"
else
  ok "clean: ningún artefacto .claude/.cr-review-* contiene material de credencial"
fi

echo ""
echo "=== Escenario snapshot-aislado : el review corre contra un HOME privado, inmune a que el compartido rote ==="
# Reemplaza los escenarios seat-rotate/seat-rotate-aba (rondas 2/3, sondeo probabilístico): con el
# snapshot inmutable no hay ventana que sondear, así que la prueba correcta ya no es "¿lo detecta?"
# sino "¿le afecta?" — la respuesta debe ser NO, siempre, determinísticamente.
ORIGINAL_SEAT_FP="$(sha256sum "$FAKEHOME/.coderabbit/auth.json" 2>/dev/null | awk '{print substr($1,1,12)}')"
rm -f "$EFFECTIVE_HOME_LOG"
export CR_TEST_MUTATE_SHARED_HOME_DURING_REVIEW=1
run_cr clean
unset CR_TEST_MUTATE_SHARED_HOME_DURING_REVIEW
[ "$CR_RC" -eq 0 ] && [ -e "$REPO/.claude/.cr-review-ok" ] \
  && ok "snapshot-aislado: rc=0 y sentinel presente (la mutación del HOME compartido durante el review NO afectó el resultado)" \
  || bad "snapshot-aislado: rc=$CR_RC o sentinel ausente (la mutación externa SÍ afectó — regresión del aislamiento)"
ISOLATED_SEAT_FP="$(jq -r '.seat_fp // empty' "$REPO/.claude/.cr-review-result.json" 2>/dev/null)"
[ -n "$ORIGINAL_SEAT_FP" ] && [ "$ISOLATED_SEAT_FP" = "$ORIGINAL_SEAT_FP" ] \
  && ok "snapshot-aislado: seat_fp sigue siendo el ORIGINAL ($ISOLATED_SEAT_FP) — la atribución no se movió con la mutación externa" \
  || bad "snapshot-aislado: seat_fp cambió o vino vacío (actual='$ISOLATED_SEAT_FP' original='$ORIGINAL_SEAT_FP') — la corrida SÍ vio la mutación externa"
FAKEHOME_AUTH_NOW="$(cat "$FAKEHOME/.coderabbit/auth.json" 2>/dev/null)"
[ "$FAKEHOME_AUTH_NOW" != '{"apiKey":"cr_9f3a7c2e8b1d4f56a0c9e7b3d2f18a6c","account":{"email":"harness@test.local"}}' ] \
  && ok "snapshot-aislado: el HOME compartido SÍ rotó de verdad (la mutación ocurrió; el aislamiento la volvió irrelevante, no imposible)" \
  || bad "snapshot-aislado: el HOME compartido no rotó — el fixture del escenario está mal construido, no prueba nada"
AUTH_HOME_SEEN="$(grep '^auth:' "$EFFECTIVE_HOME_LOG" 2>/dev/null | tail -1 | cut -d: -f2-)"
REVIEW_HOME_SEEN="$(grep '^review:' "$EFFECTIVE_HOME_LOG" 2>/dev/null | tail -1 | cut -d: -f2-)"
[ -n "$AUTH_HOME_SEEN" ] && [ "$AUTH_HOME_SEEN" != "$FAKEHOME" ] \
  && ok "snapshot-aislado: auth status corrió contra un HOME privado ($AUTH_HOME_SEEN), no el compartido" \
  || bad "snapshot-aislado: auth status vio el HOME compartido directamente (sin snapshot) — regresión"
[ -n "$REVIEW_HOME_SEEN" ] && [ "$REVIEW_HOME_SEEN" != "$FAKEHOME" ] \
  && ok "snapshot-aislado: review corrió contra un HOME privado ($REVIEW_HOME_SEEN), no el compartido" \
  || bad "snapshot-aislado: review vio el HOME compartido directamente (sin snapshot) — regresión"
[ -n "$AUTH_HOME_SEEN" ] && [ "$AUTH_HOME_SEEN" = "$REVIEW_HOME_SEEN" ] \
  && ok "snapshot-aislado: auth status y review vieron EL MISMO HOME privado (huella determinista, no dos lecturas separadas)" \
  || bad "snapshot-aislado: auth status y review vieron HOMEs distintos ($AUTH_HOME_SEEN vs $REVIEW_HOME_SEEN) — sigue sin ser determinista"
if [ -n "$REVIEW_HOME_SEEN" ] && [ ! -d "$REVIEW_HOME_SEEN" ]; then
  ok "snapshot-aislado: el HOME privado se destruyó tras el run (sin residuo en /tmp)"
else
  bad "snapshot-aislado: el HOME privado ($REVIEW_HOME_SEEN) sigue existiendo tras el run — fuga de limpieza"
fi
# Restaurar el fixture (el stub rotó el compartido como parte del escenario) para no arrastrar el
# auth.json "rotado" a los escenarios siguientes.
echo '{"apiKey":"cr_9f3a7c2e8b1d4f56a0c9e7b3d2f18a6c","account":{"email":"harness@test.local"}}' \
  > "$FAKEHOME/.coderabbit/auth.json"

echo ""
echo "=== Escenario symlink-materializado : auth.json simbólico -> el snapshot MATERIALIZA contenido regular, no el enlace ==="
# `cp -a` (sin dereferenciar) preserva symlinks: si el auth.json real es un enlace hacia un almacén
# COMPARTIDO (el guard `-f` de arriba lo sigue y lo acepta igual), copiarlo tal cual dentro del
# snapshot recrearía el MISMO enlace — ambas invocaciones seguirían leyendo el original mutable,
# reabriendo el TOCTOU. El fixture aquí es justo eso: un symlink hacia un destino EXTERNO.
EXTERNAL_AUTH="$WORK/external-auth-target.json"
echo '{"apiKey":"cr_symlinked00000000000000000000","account":{"email":"symlink@test.local"}}' > "$EXTERNAL_AUTH"
rm -f "$FAKEHOME/.coderabbit/auth.json"
ln -s "$EXTERNAL_AUTH" "$FAKEHOME/.coderabbit/auth.json"
EXPECTED_SYMLINK_SEAT_FP="$(sha256sum "$EXTERNAL_AUTH" 2>/dev/null | awk '{print substr($1,1,12)}')"
rm -f "$MATERIALIZATION_LOG"
run_cr clean
[ "$CR_RC" -eq 0 ] && [ -e "$REPO/.claude/.cr-review-ok" ] \
  && ok "symlink-materializado: rc=0 y sentinel presente (el snapshot materializó el symlink sin colgarse ni fallar)" \
  || bad "symlink-materializado: rc=$CR_RC o sentinel ausente"
SYMLINK_SEAT_FP="$(jq -r '.seat_fp // empty' "$REPO/.claude/.cr-review-result.json" 2>/dev/null)"
[ -n "$EXPECTED_SYMLINK_SEAT_FP" ] && [ "$SYMLINK_SEAT_FP" = "$EXPECTED_SYMLINK_SEAT_FP" ] \
  && ok "symlink-materializado: seat_fp == huella del CONTENIDO apuntado por el symlink en el momento del snapshot" \
  || bad "symlink-materializado: seat_fp inesperado (actual='$SYMLINK_SEAT_FP' esperado='$EXPECTED_SYMLINK_SEAT_FP')"
AUTH_MATERIALIZATION="$(grep '^auth:' "$MATERIALIZATION_LOG" 2>/dev/null | tail -1 | cut -d: -f2)"
REVIEW_MATERIALIZATION="$(grep '^review:' "$MATERIALIZATION_LOG" 2>/dev/null | tail -1 | cut -d: -f2)"
[ "$AUTH_MATERIALIZATION" = "regular" ] \
  && ok "symlink-materializado: auth status vio un fichero REGULAR (dereferenciado) — el enlace no sobrevivió al snapshot" \
  || bad "symlink-materializado: auth status vio '$AUTH_MATERIALIZATION' (esperaba 'regular' — el symlink sobrevivió al snapshot, TOCTOU reabierto)"
[ "$REVIEW_MATERIALIZATION" = "regular" ] \
  && ok "symlink-materializado: review vio un fichero REGULAR (dereferenciado) — el enlace no sobrevivió al snapshot" \
  || bad "symlink-materializado: review vio '$REVIEW_MATERIALIZATION' (esperaba 'regular' — el symlink sobrevivió al snapshot, TOCTOU reabierto)"
# Restaurar el fixture regular (archivo normal, no symlink) para el resto de escenarios.
rm -f "$FAKEHOME/.coderabbit/auth.json"
echo '{"apiKey":"cr_9f3a7c2e8b1d4f56a0c9e7b3d2f18a6c","account":{"email":"harness@test.local"}}' \
  > "$FAKEHOME/.coderabbit/auth.json"

echo ""
echo "=== Escenario findings: finding bloqueante -> sin sentinel, historial afirma el universo real ==="
run_cr findings
[ "$CR_RC" -ne 0 ] && [ ! -e "$REPO/.claude/.cr-review-ok" ] \
  && ok "findings: rc!=0 sin sentinel" || bad "findings: sentinel indebido o rc=0"
[ "$(hist_last | jq -r '.finding_count')" = "1" ] \
  && ok "findings: historial afirma 1 finding" || bad "findings: finding_count inesperado"
# TAL-2816 (invariante #1127): la review completó limpio -> el RAW YA fue promovido por el `mv -f`
# ATÓMICO real (RAW_PARTIAL -> RAW) ANTES de que el bloqueante hiciera fallar commit_run. Confirma
# que "promoción de RAW exitosa -> fallo INMEDIATAMENTE DESPUÉS en commit_run -> sin sentinel=ok"
# no pierde el crudo: persiste en su nombre FINAL (no .partial), disponible para triage.
# NO usar un glob global: run_cr no borra artefactos de escenarios previos (el propio "clean" de
# arriba deja su RAW final en disco), así que un glob ancho lo satisface aunque el run bajo prueba
# (findings) no hubiera promovido nada. Se deriva la ruta EXACTA del run_id real de este run (el
# mismo que usó commit_run para esta entrada del historial) vía hist_last.
FINDINGS_RUN_ID="$(hist_last | jq -r '.run_id // empty')"
FINDINGS_RAW="$REPO/.claude/.cr-review-raw-${FINDINGS_RUN_ID}.jsonl"
if [ -n "$FINDINGS_RUN_ID" ] && [ -s "$FINDINGS_RAW" ] && [ ! -e "${FINDINGS_RAW}.partial" ]; then
  ok "findings (#1127): RAW final promovido ANTES del fallo de commit_run y SIGUE en disco tras él"
else
  bad "findings (#1127): el RAW exacto de este run (${FINDINGS_RUN_ID:-<vacío>}) no persistió en su nombre final tras el bloqueante (regresión del invariante fail-closed)"
fi

echo ""
echo "=== Escenario incomplete : sin sentinel, .partial preservado Y SÍ entra al historial ==="
run_cr incomplete
[ "$CR_RC" -ne 0 ] && [ ! -e "$REPO/.claude/.cr-review-ok" ] \
  && ok "incomplete: rc!=0 sin sentinel" || bad "incomplete: rc=$CR_RC o sentinel presente"
compgen -G "$REPO/.claude/.cr-review-raw-*.jsonl.partial" > /dev/null \
  && ok "incomplete: .partial preservado como evidencia" || bad "incomplete: falta el .partial"
if [ -s "$REPO/.claude/.cr-review-history.jsonl" ] && [ "$(hist_last | jq -r '.state')" = "error" ]; then
  ok "run incompleto SÍ quedó registrado en el historial (antes se saltaba por completo)"
else
  bad "el historial no registró el run incompleto (regresión)"
fi

echo ""
echo "=== Escenario crash abrupto : un .partial huérfano con runlock SIN dueño ==="
echo "===   (SIGKILL simulado) se reconcilia; uno con dueño VIVO (flock sostenido) queda intacto ==="
# Huérfano: runlock existe pero NADIE lo sostiene -> _owner_is_dead adquiere el flock -> muerto.
GHOST="$REPO/.claude/.cr-review-raw-ghost-crash-1.jsonl.partial"
echo '{"type":"finding","severity":"critical","fileName":"ghost.ts","lineStart":1,"lineEnd":1,"title":"never-committed","description":"simula un SIGKILL a mitad de review, sin commit_run","category":"bug"}' > "$GHOST"
printf '{"branch":"fix/test"}' > "$REPO/.claude/.cr-review-runlock-ghost-crash-1"   # runlock UNLOCKED = dueño muerto
# En vuelo: un proceso REAL sostiene el flock sobre el runlock -> _owner_is_dead NO lo adquiere -> vivo.
LIVE="$REPO/.claude/.cr-review-raw-live-inflight.jsonl.partial"
LIVE_LOCK="$REPO/.claude/.cr-review-runlock-live-inflight"
echo '{"type":"finding","severity":"critical","fileName":"y.ts"}' > "$LIVE"
printf '{"branch":"fix/test"}' > "$LIVE_LOCK"
LIVE_READY="$WORK/live_ready"; rm -f "$LIVE_READY"
# `>/dev/null 2>&1 <&-`: el holder NO hereda la tubería de captura de stdout (si no, execFileSync del
# spec vitest bloquea leyendo hasta que el holder muera, no al terminar el harness).
( exec 8>>"$LIVE_LOCK"; flock -n 8 && { : > "$LIVE_READY"; sleep 15; } ) >/dev/null 2>&1 <&- &
HOLDER_PID=$!
i=0; while [ ! -e "$LIVE_READY" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done  # espera DETERMINISTA
run_cr clean
if [ ! -e "$GHOST" ] && [ -e "$LIVE" ]; then
  ok "(flock): huérfano con runlock libre podado; .partial con dueño vivo (flock) intacto"
else
  bad "(flock): reconciliación incorrecta (podó el vivo o dejó el huérfano muerto)"
fi
if grep -q '"run_id":"ghost-crash-1".*"state":"orphaned"' "$REPO/.claude/.cr-review-history.jsonl" 2>/dev/null; then
  ok "(flock): el huérfano quedó registrado como 'orphaned' en el historial (evidencia)"
else
  bad "(flock): el huérfano no dejó rastro en el historial"
fi
kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null
rm -f "$LIVE" "$REPO/.claude/.cr-review-runlock-live-inflight"

echo ""
echo "=== B-02: dos findings en la misma posición con prompt/suggestions distintos -> NO se deduplican ==="
run_cr findings
(
  cd "$REPO" || exit 1
  bash cr-review.sh --accept-debt 1 "waiver harness B-02" >/dev/null 2>&1
)
run_cr findings2
if [ "$CR_RC" -ne 0 ]; then
  ok "finding con prompt/suggestions distinto en la misma posición NO fue suprimido como known debt"
else
  bad "se suprimió como known debt un finding materialmente distinto (dedupe fail-open)"
fi
run_cr findings
if [ "$CR_RC" -eq 0 ]; then
  ok "el finding IDÉNTICO al aceptado sigue suprimiéndose"
else
  bad "el finding idéntico ya no se suprime (rompió el caso feliz)"
fi

echo ""
echo "=== colapso de huella — dos findings que difieren SOLO en codegenInstructions/ ==="
echo "===   suggestions (igual description+prompt) NO deben deduplicarse (fpMaterial los distingue) ==="
run_cr collapse-a
(
  cd "$REPO" || exit 1
  bash cr-review.sh --accept-debt 1 "waiver de hallazgos duplicados" >/dev/null 2>&1
)
run_cr collapse-b
if [ "$CR_RC" -ne 0 ]; then
  ok "finding con distinto codegenInstructions/suggestions (mismo description+prompt) NO suprimido (huellas distintas)"
else
  bad "se suprimió un finding materialmente distinto — colapso de huella (fail-open reintroducido)"
fi
run_cr collapse-a
if [ "$CR_RC" -eq 0 ]; then
  ok "(no-regresión): el finding IDÉNTICO al aceptado sigue suprimiéndose"
else
  bad "(no-regresión): el finding idéntico ya no se suprime"
fi

echo ""
echo "=== Integración TAL-2610: schema 0.6.5 (cuerpo en codegenInstructions + 'around lines N-M') ==="
echo "===   se normaliza a un finding TRIAGEABLE y bloquea (paridad OK) ==="
run_cr schema065
if [ "$CR_RC" -ne 0 ] && [ "$(hist_last | jq -r '.state')" = "findings" ] && [ "$(hist_last | jq -r '.finding_count')" = "1" ]; then
  ok "0.6.5: cuerpo en codegenInstructions + líneas embebidas normalizados por el filtro compartido → bloquea"
else
  bad "0.6.5: el filtro no normalizó el schema 0.6.5 (rc=$CR_RC state=$(hist_last | jq -r '.state' 2>/dev/null))"
fi
lines065="$(hist_last | jq -r '.findings[0] | "\(.lineStart)-\(.lineEnd)"' 2>/dev/null)"
if [ "$lines065" = "10-14" ]; then
  ok "0.6.5: rango de líneas extraído de 'around lines 10 - 14' como unidad"
else
  bad "0.6.5: rango de líneas mal extraído (fue '$lines065', esperaba '10-14')"
fi

echo ""
echo "=== Integración TAL-2610: PARIDAD fail-closed — un phantom (critical sin cuerpo) aborta el gate ==="
run_cr phantom
if [ "$CR_RC" -ne 0 ] && [ ! -e "$REPO/.claude/.cr-review-ok" ] && printf '%s' "$(jq -r '.reason // empty' "$REPO/.claude/.cr-review-result.json" 2>/dev/null)" | grep -q 'findings-parse-mismatch'; then
  ok "phantom: normalized(0) < blockers(1) → state=error (findings-parse-mismatch), sin sentinel (doctrina phantom vía paridad)"
else
  bad "phantom: un finding sin cuerpo NO abortó por paridad (rc=$CR_RC, sentinel $( [ -e "$REPO/.claude/.cr-review-ok" ] && echo presente || echo ausente ))"
fi

echo ""
echo "=== raw-promote-failed: la promoción atómica .partial→final FALLA → sin sentinel ==="
export CR_TEST_FAIL_PROMOTE=1
run_cr clean
unset CR_TEST_FAIL_PROMOTE
RP_RID="$(hist_last | jq -r '.run_id // empty')"
RP_REASON="$(jq -r '.reason // empty' "$REPO/.claude/.cr-review-result.json" 2>/dev/null)"
# El `mv -f` de promoción falló → NO existe el `$RAW` final de ESTE run_id, pero su `.partial` (crudo
# ya escrito por el CLI) persiste como evidencia; sin sentinel; RESULT.reason lo delata (HISTORY no
# lleva `reason`, solo `state`).
if [ "$CR_RC" -ne 0 ] && [ ! -e "$REPO/.claude/.cr-review-ok" ] \
   && [ -n "$RP_RID" ] && [ ! -e "$REPO/.claude/.cr-review-raw-${RP_RID}.jsonl" ] \
   && [ -s "$REPO/.claude/.cr-review-raw-${RP_RID}.jsonl.partial" ] \
   && [ "$(hist_last | jq -r '.state')" = "error" ] \
   && printf '%s' "$RP_REASON" | grep -q 'raw-promote-failed'; then
  ok "raw-promote-failed: sin sentinel; RAW final ausente, .partial preservado; HISTORY state=error; RESULT.reason=raw-promote-failed"
else
  bad "raw-promote-failed: no falló cerrado (rc=$CR_RC, state=$(hist_last | jq -r '.state' 2>/dev/null), reason=$RP_REASON)"
fi

echo ""
echo "=== runlock-acquire-failed: sin lock de vivacidad por-run → no se crea crudo → sin sentinel ==="
export CR_TEST_FAIL_RUNLOCK=1
run_cr clean
unset CR_TEST_FAIL_RUNLOCK
RL_RID="$(hist_last | jq -r '.run_id // empty')"
RL_REASON="$(jq -r '.reason // empty' "$REPO/.claude/.cr-review-result.json" 2>/dev/null)"
# Aborta ANTES de crear el `.partial` (fail-closed: nunca un crudo desprotegido) → ni `.jsonl` ni
# `.partial` del run; sin sentinel; RESULT.reason=runlock-acquire-failed.
if [ "$CR_RC" -ne 0 ] && [ ! -e "$REPO/.claude/.cr-review-ok" ] \
   && [ -n "$RL_RID" ] \
   && [ ! -e "$REPO/.claude/.cr-review-raw-${RL_RID}.jsonl" ] \
   && [ ! -e "$REPO/.claude/.cr-review-raw-${RL_RID}.jsonl.partial" ] \
   && [ "$(hist_last | jq -r '.state')" = "error" ] \
   && printf '%s' "$RL_REASON" | grep -q 'runlock-acquire-failed'; then
  ok "runlock-acquire-failed: abortó sin crear crudo (ni .jsonl ni .partial del run); sin sentinel; RESULT.reason=runlock-acquire-failed"
else
  bad "runlock-acquire-failed: no falló cerrado (rc=$CR_RC, state=$(hist_last | jq -r '.state' 2>/dev/null), reason=$RL_REASON)"
fi

echo ""
echo "=== deferred autorizante: CLI no disponible + PR con label cr-review → sentinel deferred ==="
export CR_TEST_AUTH_FAIL=1 CR_TEST_GH_PR=1
run_cr clean
unset CR_TEST_AUTH_FAIL CR_TEST_GH_PR
DF_HEAD="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"
DF_BASE="$(git -C "$REPO" rev-parse origin/main 2>/dev/null)"
DF_L1="$(sed -n 1p "$REPO/.claude/.cr-review-ok" 2>/dev/null)"
DF_L2="$(sed -n 2p "$REPO/.claude/.cr-review-ok" 2>/dev/null)"
DF_L3="$(sed -n 3p "$REPO/.claude/.cr-review-ok" 2>/dev/null)"
DF_L4="$(sed -n 4p "$REPO/.claude/.cr-review-ok" 2>/dev/null)"
DF_REASON="$(jq -r '.reason // empty' "$REPO/.claude/.cr-review-result.json" 2>/dev/null)"
# El sentinel deferred AUTORIZA push: debe estar ligado a HEAD/base EXACTOS (L1/L2 del formato del hook)
# — no a un SHA distinto del que se autorizaría.
if [ "$CR_RC" -eq 0 ] && [ -e "$REPO/.claude/.cr-review-ok" ] \
   && [ -n "$DF_HEAD" ] && [ "$DF_L1" = "$DF_HEAD" ] && [ "$DF_L2" = "$DF_BASE" ] \
   && [ "$DF_L3" = "deferred" ] && [ "$DF_L4" = "no-cli-auth" ] \
   && [ "$(hist_last | jq -r '.state')" = "deferred" ] \
   && [ "$DF_REASON" = "no-cli-auth" ]; then
  ok "deferred: sentinel deferred ligado a HEAD/base exactos (L1/L2), reason no-cli-auth; HISTORY state=deferred; RESULT.reason=no-cli-auth"
else
  bad "deferred: backstop autorizante incorrecto (rc=$CR_RC, L1=$DF_L1 vs HEAD=$DF_HEAD, L3=$DF_L3, L4=$DF_L4, hist=$(hist_last | jq -r '.state' 2>/dev/null))"
fi

# ============================================================================================
# Checks a nivel de función (sourcing de las definiciones, sin ejecutar el flujo principal) —
# escenarios de concurrencia que no se pueden orquestar de forma determinista end-to-end.
DEFS="$WORK/cr-review-defs.sh"
CASE_LINE="$(grep -n '^case "\${1:-}" in' "$REPO/cr-review.sh" | head -1 | cut -d: -f1)"
[ -n "$CASE_LINE" ] || { echo "harness: no encontré la línea del case de modos en cr-review.sh" >&2; exit 1; }
sed -n "1,$((CASE_LINE - 1))p" "$REPO/cr-review.sh" > "$DEFS"

echo ""
echo "=== B-03: sin 'flock' en PATH -> with_ledger_lock falla CERRADO (nunca degrada a un lock inseguro) ==="
NOFLOCK_BIN="$WORK/fakebin-noflock"
mkdir -p "$NOFLOCK_BIN"
for b in jq git sha256sum shasum od date sed awk sort comm grep printf mktemp cat rm mkdir cp mv chmod true false sleep basename dirname tr; do
  p="$(command -v "$b" 2>/dev/null || true)"
  [ -n "$p" ] && ln -sf "$p" "$NOFLOCK_BIN/$b" 2>/dev/null
done
(
  cd "$REPO" || exit 1
  source "$DEFS"
  set +e
  ( PATH="$NOFLOCK_BIN" with_ledger_lock true )
  exit $?
)
rc_noflock=$?
[ "$rc_noflock" -ne 0 ] && ok "with_ledger_lock retorna no-cero sin flock (fail-closed)" \
  || bad "with_ledger_lock retornó 0 sin flock (debería fallar cerrado)"

echo ""
echo "=== si falla la persistencia de la entrada 'orphaned', el crudo NO se borra ==="
(
  cd "$REPO" || exit 1
  source "$DEFS"
  set +e
  rm -f .claude/.cr-review-*
  GHOST=".claude/.cr-review-raw-ghost-persist-fail.jsonl.partial"
  echo '{"type":"finding","severity":"critical","fileName":"g.ts"}' > "$GHOST"
  printf '{"branch":"fix/test"}' > ".claude/.cr-review-runlock-ghost-persist-fail"   # runlock libre = muerto
  mktemp() { return 1; }   # simula fallo de persistencia (disco lleno / historial corrupto)
  reconcile_orphaned_raws >/dev/null 2>&1
  [ -e "$GHOST" ] && ! grep -q '"state":"orphaned"' .claude/.cr-review-history.jsonl 2>/dev/null
  exit $?
)
[ $? -eq 0 ] && ok "fallo de persistencia (mktemp) conserva el crudo intacto (nunca se pierde evidencia sin su registro)" \
  || bad "el crudo se borró (o se registró) a pesar de que la persistencia falló"

echo ""
echo "=== la rama del huérfano viene de SU runlock, nunca de la rama del reconciliador ==="
(
  cd "$REPO" || exit 1
  source "$DEFS"
  set +e
  rm -f .claude/.cr-review-*
  GHOST=".claude/.cr-review-raw-ghost-otherbranch.jsonl.partial"
  echo '{"type":"finding","severity":"critical","fileName":"g.ts"}' > "$GHOST"
  printf '{"branch":"rama-original-del-crash"}' > ".claude/.cr-review-runlock-ghost-otherbranch"   # libre = muerto
  reconcile_orphaned_raws >/dev/null 2>&1
  if [ ! -e "$GHOST" ] && [ "$(jq -r 'select(.run_id=="ghost-otherbranch")|.branch' .claude/.cr-review-history.jsonl 2>/dev/null)" = "rama-original-del-crash" ]; then exit 0; else exit 1; fi
)
[ $? -eq 0 ] && ok "el huérfano se atribuye a SU rama real (del runlock), no a la del proceso reconciliador" \
  || bad "atribución de rama incorrecta (usó la rama del reconciliador o no propagó la del runlock)"

echo ""
echo "=== la propia reconciliación poda el RAW de entradas expulsadas por retención ==="
# La directiva anota el SUBSHELL COMPLETO: las variables que se fijan aquí (HISTORY_RETENTION) las
# consumen las funciones que llegan por `source "$DEFS"`, un source dinámico que shellcheck no sigue
# (SC1091 está excluido en el gate) — por eso las ve "sin usar" siendo el estado de entrada del test.
# shellcheck disable=SC2034
(
  cd "$REPO" || exit 1
  source "$DEFS"
  set +e
  rm -f .claude/.cr-review-*
  # Una entrada previa YA en el historial, en la MISMA rama que el huérfano — con retención=1 la nueva
  # entrada 'orphaned' debe expulsarla, y esa expulsión debe podar su RAW final. HISTORY_RETENTION se
  # relee en cada llamada, así que sobreescribirla tras el `source` basta.
  HISTORY_RETENTION=1
  PREV_RAW=".claude/.cr-review-raw-prev-evicted.jsonl"
  echo '{"type":"complete","status":"review_completed"}' > "$PREV_RAW"
  jq -c -n --arg br "fix/test" '{run_id:"prev-evicted", gen:{epoch:"x",value:1}, sha:"deadbeef", base_sha:"cafebabe", ts:(now|todateiso8601), branch:$br, state:"ok", finding_count:0, findings:[]}' > .claude/.cr-review-history.jsonl
  GHOST=".claude/.cr-review-raw-ghost-evictor.jsonl.partial"
  echo '{"type":"finding","severity":"critical","fileName":"g.ts"}' > "$GHOST"
  printf '{"branch":"fix/test"}' > ".claude/.cr-review-runlock-ghost-evictor"   # libre = muerto
  reconcile_orphaned_raws >/dev/null 2>&1
  [ ! -e "$PREV_RAW" ] && ! jq -e 'select(.run_id=="prev-evicted")' .claude/.cr-review-history.jsonl >/dev/null 2>&1
  exit $?
)
[ $? -eq 0 ] && ok "la reconciliación poda el RAW de la entrada evictada por su PROPIO trimming de retención" \
  || bad "la reconciliación expulsó una entrada del historial sin podar su RAW (huérfano de la poda)"

echo ""
echo "=== un RAW FINAL huérfano (crash POST-promoción) también se reconcilia ==="
(
  cd "$REPO" || exit 1
  source "$DEFS"
  set +e
  rm -f .claude/.cr-review-*
  # Simula SIGKILL entre `mv .partial->final` y `commit_run`: existe un `.jsonl` FINAL sin historial.
  GHOST_FINAL=".claude/.cr-review-raw-ghost-postpromo.jsonl"
  echo '{"type":"complete","status":"review_completed"}' > "$GHOST_FINAL"
  printf '{"branch":"fix/test"}' > ".claude/.cr-review-runlock-ghost-postpromo"   # libre = muerto
  reconcile_orphaned_raws >/dev/null 2>&1
  [ ! -e "$GHOST_FINAL" ] && grep -q '"run_id":"ghost-postpromo".*"state":"orphaned"' .claude/.cr-review-history.jsonl 2>/dev/null
  exit $?
)
[ $? -eq 0 ] && ok "RAW FINAL huérfano (post-promoción) reconciliado y podado (el escaneo cubre .jsonl, no solo .partial)" \
  || bad "un RAW final huérfano quedó inalcanzable (escaneo incompleto — regresión de reconciliación)"

echo ""
echo "=== dueño con flock VIVO nunca se declara huérfano; sin runlock -> muerto ==="
(
  cd "$REPO" || exit 1
  source "$DEFS"
  set +e
  rm -f .claude/.cr-review-*
  # (a) runlock con dueño VIVO (holder real sostiene el flock) -> intacto.
  ALIVE=".claude/.cr-review-raw-ghost-alive.jsonl.partial"
  ALIVE_LOCK=".claude/.cr-review-runlock-ghost-alive"
  echo '{"type":"finding","severity":"critical","fileName":"g.ts"}' > "$ALIVE"
  printf '{"branch":"fix/test"}' > "$ALIVE_LOCK"
  ready="$WORK/alive_ready"; rm -f "$ready"
  # std fds redirigidos: el holder no hereda la tubería de captura (evita bloqueo de execFileSync).
  ( exec 8>>"$ALIVE_LOCK"; flock -n 8 && { : > "$ready"; sleep 15; } ) >/dev/null 2>&1 <&- &
  hp=$!
  i=0; while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done   # espera DETERMINISTA
  reconcile_orphaned_raws >/dev/null 2>&1
  alive_ok=1; [ -e "$ALIVE" ] || alive_ok=0
  kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
  # (b) un crudo SIN runfile alguno -> invariante "vivo siempre tiene lockfile" -> muerto -> reconciliado.
  NORL=".claude/.cr-review-raw-ghost-norunlock.jsonl.partial"
  echo '{"type":"finding","severity":"critical","fileName":"g.ts"}' > "$NORL"
  reconcile_orphaned_raws >/dev/null 2>&1
  norl_ok=1; [ ! -e "$NORL" ] || norl_ok=0
  if [ "$alive_ok" = 1 ] && [ "$norl_ok" = 1 ]; then exit 0; else exit 1; fi
)
[ $? -eq 0 ] && ok "dueño con flock vivo intacto; crudo sin runlock (no puede estar vivo) reconciliado" \
  || bad "se borró un crudo con dueño vivo, o no se reconcilió uno sin runlock"

echo ""
echo "=== sin /dev/urandom -> _mint_epoch falla CERRADO (nunca degrada a \$RANDOM/PID/timestamp) ==="
(
  cd "$REPO" || exit 1
  source "$DEFS"
  set +e
  # od siempre falla -> simula /dev/urandom inaccesible sin tocar el dispositivo real del sistema.
  od() { return 1; }
  _mint_epoch
  exit $?
)
rc_noent=$?
[ "$rc_noent" -ne 0 ] && ok "_mint_epoch retorna no-cero si /dev/urandom no está disponible (sin degradar)" \
  || bad "_mint_epoch degradó a una fuente débil en vez de fallar cerrado"

echo ""
echo "=== HEAD se mueve entre el arranque y la revisión -> el ==="
echo "===   PROPIO cr-review.sh aborta con reason=head-moved-before-review, sin sentinel y sin gastar el CLI ==="
# La versión anterior de este escenario era VACUA: recalculaba `REVIEW_HEAD` en el arnés y comparaba
# contra `HEAD_SHA`, así que probaba la aritmética del arnés y NO el guard del script — borrar el guard
# la dejaba en verde. Ahora se ejecuta el binario completo con el shim `git` moviendo HEAD en la
# ventana real (post-HEAD_SHA, pre-REVIEW_HEAD) y se afirman los efectos OBSERVABLES del guard.
MOVE_MARK="$WORK/move-head.mark"
MOVE_HOMELOG="$WORK/effective-home-moved.log"
rm -f "$MOVE_MARK" "$MOVE_HOMELOG" "$REPO/.claude/.cr-review-ok"
# SHA exacto al que se restaura después: `HEAD~1` sería destructivo si el shim no llegara a crear su
# commit (borraría un commit real del fixture y contaminaría los escenarios siguientes).
B01A_HEAD_BEFORE="$(git -C "$REPO" rev-parse HEAD)"
(
  cd "$REPO" || exit 1
  CR_TEST_MODE=clean CR_TEST_MOVE_HEAD=1 CR_TEST_MOVE_HEAD_MARK="$MOVE_MARK" \
    EFFECTIVE_HOME_LOG="$MOVE_HOMELOG" bash cr-review.sh
) >/dev/null 2>&1
b01a_rc=$?
b01a_state="$(jq -r '.state // empty' "$REPO/.claude/.cr-review-result.json" 2>/dev/null)"
b01a_reason="$(jq -r '.reason // empty' "$REPO/.claude/.cr-review-result.json" 2>/dev/null)"
b01a_hstate="$(hist_last | jq -r '.state' 2>/dev/null)"
if [ "$b01a_rc" -ne 0 ] && [ "$b01a_state" = "error" ] \
   && [ "$b01a_reason" = "head-moved-before-review" ] \
   && [ ! -e "$REPO/.claude/.cr-review-ok" ] && [ "$b01a_hstate" = "error" ]; then
  ok "el guard abortó end-to-end (rc=$b01a_rc state=error reason=head-moved-before-review, sin sentinel, run en el ledger)"
else
  bad "el guard de TOCTOU pre-revisión no produjo el abort esperado (rc=$b01a_rc state='$b01a_state' reason='$b01a_reason' hist='$b01a_hstate' sentinel=$( [ -e "$REPO/.claude/.cr-review-ok" ] && echo PRESENTE || echo ausente ))"
  # Diagnóstico que hace LITERAL el fallo de autorización: si hay sentinel, ¿a qué SHA autoriza frente
  # al HEAD real? L1 != HEAD ⇒ un commit que nunca se revisó queda autorizado para push.
  bad "sentinel autoriza L1='$(sed -n '1p' "$REPO/.claude/.cr-review-ok" 2>/dev/null)' con HEAD real='$(git -C "$REPO" rev-parse HEAD 2>/dev/null)' (L1 != HEAD ⇒ autorización huérfana)"
fi
# El bucket CR es escaso: el guard existe para abortar ANTES de gastar la corrida, no solo para no
# publicar. Si `review` llegó a invocarse, el guard llega tarde aunque el veredicto final sea correcto.
if ! grep -q '^review:' "$MOVE_HOMELOG" 2>/dev/null; then
  ok "la corrida del CLI NO se gastó (ninguna invocación 'review' registrada)"
else
  bad "se invocó 'coderabbit review' pese al drift de HEAD — el guard llega tarde y quema bucket"
fi
# Restaurar la rama al commit exacto que el resto de escenarios espera (idempotente: da igual si el
# shim llegó a crear su commit vacío o no).
git -C "$REPO" reset -q --hard "$B01A_HEAD_BEFORE" 2>/dev/null || true
rm -f "$REPO/.claude/.cr-review-"*

echo ""
echo "=== HEAD se mueve DESPUÉS del snapshot pero ANTES de commit_run -> degrada a error/stale ==="
(
  cd "$REPO" || exit 1
  source "$DEFS"
  set +e
  rm -f .claude/.cr-review-*
  start_run >/dev/null 2>&1
  REVIEW_HEAD="$(git rev-parse HEAD)"; REVIEW_TREE="$(git rev-parse 'HEAD^{tree}')"; REVIEW_BASE=""
  REVIEW_FP="$(snapshot_fp 2>/dev/null || true)"
  echo '{"type":"complete","status":"review_completed"}' > "$RAW"
  git commit --allow-empty -q -m moved >/dev/null 2>&1
  ( trap - EXIT; commit_run 0 ok review_completed ) >/dev/null 2>&1
  rc=$?
  rstate="$(jq -r '.state' "$RESULT" 2>/dev/null)"
  if [ "$rc" -ne 0 ] && [ "$rstate" = "error" ] && [ ! -e "$SENTINEL" ]; then exit 0; else exit 1; fi
)
[ $? -eq 0 ] && ok "revalidación HEAD/tree en vivo detectó el movimiento post-review" \
  || bad "no se detectó el movimiento de HEAD entre revisión y commit (TOCTOU abierto)"

echo ""
echo "=== Superseded: un run cuya generación fue superada por otro NUNCA publica su universo real ==="
(
  cd "$REPO" || exit 1
  source "$DEFS"
  set +e
  rm -f .claude/.cr-review-*
  start_run >/dev/null 2>&1
  jq -c -n --arg e "$RUN_EPOCH" --argjson v "$((RUN_GEN + 1))" '{epoch:$e, value:$v}' > .claude/.cr-review-gen
  echo '{"type":"finding","severity":"critical","fileName":"real.ts","lineStart":9,"lineEnd":9,"title":"REAL","description":"no deberia publicarse","category":"bug"}' > "$RAW"
  ( trap - EXIT; commit_run 0 ok review_completed ) >/dev/null 2>&1
  rc=$?
  hstate="$(hist_last | jq -r '.state' 2>/dev/null)"
  hcount="$(hist_last | jq -r '.finding_count' 2>/dev/null)"
  if [ "$rc" -ne 0 ] && [ ! -e "$SENTINEL" ] && [ "$hstate" = "superseded" ] && [ "$hcount" = "0" ]; then exit 0; else exit 1; fi
)
[ $? -eq 0 ] && ok "superseded: universo vacío en el historial, sin sentinel (fencing token real)" \
  || bad "superseded: un run obsoleto publicó su verdict/universo (fencing roto)"

echo ""
echo "=== H-2a (TAL-3629): la EXCLUSIÓN MUTUA del ledger es INDISPENSABLE — carrera determinista sobre ==="
echo "===   el read-modify-write leer→temp→rename de _merge_history_entry (sin lock: lost update) ==="
# Aísla el lock A PROPÓSITO: llama a `_merge_history_entry` bajo `with_ledger_lock` con entradas
# propias, SIN pasar por `_commit_locked`. Montarlo con dos runs completos NO probaría nada sobre la
# serialización: lo que impide publicar al run tardío es el fencing de generación, así que quitar el
# lock dejaría el escenario en VERDE. Aquí la única defensa en juego es la exclusión mutua.
H2A_OUT="$WORK/h2a-ids.txt"
rm -f "$H2A_OUT"
(
  cd "$REPO" || exit 1
  source "$DEFS"
  set +e
  rm -f .claude/.cr-review-history.jsonl
  mk_entry() { jq -c -n --arg rid "$1" \
    '{run_id:$rid, gen:{epoch:"e",value:1}, sha:"s", base_sha:"b", ts:"t", branch:"br", state:"ok", seat_fp:null, finding_count:0, findings:[]}'; }
  # A entra primero y su rename queda retrasado 3 s → la ventana leer→rename está abierta de verdad
  # (el retardo lo impone el shim `mv`, no el azar de dos procesos compitiendo).
  ( export CR_TEST_SLOW_HISTORY_MV=3; with_ledger_lock _merge_history_entry "$(mk_entry ENTRADA-A)" ) >/dev/null 2>&1 &
  a_pid=$!
  sleep 1                        # A ya leyó el ledger y está dormido dentro de su `mv`
  ( with_ledger_lock _merge_history_entry "$(mk_entry ENTRADA-B)" ) >/dev/null 2>&1 &
  b_pid=$!
  wait "$a_pid"; wait "$b_pid"
  jq -r '.run_id' .claude/.cr-review-history.jsonl 2>/dev/null | sort | tr '\n' ' ' > "$H2A_OUT"
) >/dev/null 2>&1
h2a_ids="$(cat "$H2A_OUT" 2>/dev/null)"
if [ "$h2a_ids" = "ENTRADA-A ENTRADA-B " ]; then
  ok "las DOS entradas concurrentes sobreviven en el ledger (el lock serializó el read-modify-write)"
else
  bad "lost update en el ledger — entradas presentes: '${h2a_ids:-(ninguna)}' (esperado 'ENTRADA-A ENTRADA-B ')"
fi

echo ""
echo "=== H-2b (TAL-3629, smoke end-to-end — NO es el criterio por mutación): dos cr-review.sh ==="
echo "===   simultáneos sobre el MISMO clon no intercalan ledger/result: UN sentinel, un ok + un superseded ==="
rm -f "$REPO/.claude/.cr-review-"*
(
  cd "$REPO" || exit 1
  ( CR_TEST_MODE=clean CR_TEST_REVIEW_SLEEP=3 bash cr-review.sh ) >/dev/null 2>&1 &
  sleep 1                        # el run A está dentro de `coderabbit review`; B arranca y lo adelanta
  ( CR_TEST_MODE=clean bash cr-review.sh ) >/dev/null 2>&1 &
  wait
) >/dev/null 2>&1
h2b_ok="$(jq -r 'select(.state=="ok")|.run_id' "$REPO/.claude/.cr-review-history.jsonl" 2>/dev/null | grep -c . || true)"
h2b_sup="$(jq -r 'select(.state=="superseded")|.run_id' "$REPO/.claude/.cr-review-history.jsonl" 2>/dev/null | grep -c . || true)"
h2b_l1="$(sed -n '1p' "$REPO/.claude/.cr-review-ok" 2>/dev/null)"
h2b_head="$(git -C "$REPO" rev-parse HEAD)"
if [ "${h2b_ok:-0}" -eq 1 ] && [ "${h2b_sup:-0}" -eq 1 ] && [ "$h2b_l1" = "$h2b_head" ]; then
  ok "dos runs simultáneos → 1 ok + 1 superseded en el ledger y un único sentinel para el HEAD real"
else
  bad "runs concurrentes sin serializar (ok=$h2b_ok superseded=$h2b_sup sentinel_L1='${h2b_l1:0:12}' head='${h2b_head:0:12}')"
fi

echo ""
echo "=== H-6 (TAL-3629): stderr sigue VIVO tras tomar el lock por-run — los mensajes de abort de ==="
echo "===   los propios gates de H-1/H-2 son su única observabilidad y no pueden perderse ==="
# `exec 8>>"$RUN_LOCK" 2>/dev/null` (sin comando) redirigía FD 2 del PROCESO COMPLETO a /dev/null: todo
# diagnóstico posterior —incluidos `stale-repo-state` y `superseded`— desaparecía. Se ejercita con el
# camino `incomplete`, cuyo mensaje se emite después de tomar el lock y no depende del known-debt store.
rm -f "$REPO/.claude/.cr-review-"*
h6_stderr="$( ( cd "$REPO" && CR_TEST_MODE=incomplete bash cr-review.sh ) 2>&1 >/dev/null )"
if printf '%s' "$h6_stderr" | grep -q 'el review NO completó limpio'; then
  ok "el diagnóstico posterior al lock por-run llega a stderr (no queda silenciado)"
else
  bad "stderr silenciado tras 'exec 8>>' — el abort no es observable (salida capturada: '${h6_stderr:-(vacía)}')"
fi

echo ""
echo "=== Interrupted: exit inesperado con rc=0 sin estado terminal -> se fuerza a no-cero ==="
(
  cd "$REPO" || exit 1
  source "$DEFS"
  set +e
  rm -f .claude/.cr-review-*
  start_run >/dev/null 2>&1
  echo '{"type":"complete","status":"review_completed"}' > "$RAW"
  ( set +e; trap 'on_exit' EXIT; exit 0 ) >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ] && [ ! -e "$SENTINEL" ]; then exit 0; else exit 1; fi
)
[ $? -eq 0 ] && ok "exit con rc=0 sin COMMITTED se fuerza a no-cero (fail-closed real)" \
  || bad "un exit inesperado con rc=0 escapó como si fuera éxito"

echo ""
echo "=== (histuniv fail-CLOSED): universo del historial irreconstruible → commit aborta SIN sentinel ==="
(
  cd "$REPO" || exit 1
  source "$DEFS"
  set +e
  rm -f .claude/.cr-review-*
  start_run >/dev/null 2>&1
  # Snapshot en vivo (HEAD no se mueve) → el gate TOCTOU pasa y eff_state se queda en ok, llegando a
  # _write_history/_history_universe (si no se fijara, degradaría a stale-repo-state y NO ejercitaría
  # el fail-closed del historial — sería un falso verde).
  REVIEW_HEAD="$(git rev-parse HEAD)"; REVIEW_TREE="$(git rev-parse 'HEAD^{tree}')"; REVIEW_BASE=""
  REVIEW_FP="$(snapshot_fp 2>/dev/null || true)"
  # Universo YA validado por paridad (el mismo shape que emite el filtro compartido).
  RUN_UNIVERSE_LINES='{"severity":"critical","file":"x.ts","lineStart":1,"lineEnd":2,"title":"bad","category":"bug","fpMaterial":["desc"]}'
  echo '{"type":"complete","status":"review_completed"}' > "$RAW"
  export CR_TEST_FAIL_HISTUNIV=1                          # falla SOLO la proyección de _history_universe (token 'fp:$fp')
  ( trap - EXIT; commit_run 0 ok review_completed ) >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ] && [ ! -e "$SENTINEL" ]; then exit 0; else exit 1; fi
)
[ $? -eq 0 ] && ok "universo irreconstruible aborta el commit SIN sentinel (fail-closed; ya no el viejo fail-open findings:[])" \
  || bad "el historial dejó pasar el sentinel pese a no reconstruir el universo (fail-open — regresión del fix)"

echo ""
echo "=== (no-regresión): con el universo reconstruible, el MISMO commit ok SÍ emite sentinel + universo ==="
# Igual que arriba: REVIEW_HEAD/REVIEW_TREE/REVIEW_BASE/REVIEW_FP/RUN_UNIVERSE_LINES son el snapshot de
# entrada que consume `commit_run` desde `$DEFS` (source dinámico no seguido por shellcheck).
# shellcheck disable=SC2034
(
  cd "$REPO" || exit 1
  source "$DEFS"
  set +e
  rm -f .claude/.cr-review-*
  start_run >/dev/null 2>&1
  REVIEW_HEAD="$(git rev-parse HEAD)"; REVIEW_TREE="$(git rev-parse 'HEAD^{tree}')"; REVIEW_BASE=""
  REVIEW_FP="$(snapshot_fp 2>/dev/null || true)"
  RUN_UNIVERSE_LINES='{"severity":"critical","file":"x.ts","lineStart":1,"lineEnd":2,"title":"bad","category":"bug","fpMaterial":["desc"]}'
  echo '{"type":"complete","status":"review_completed"}' > "$RAW"
  ( trap - EXIT; commit_run 0 ok review_completed ) >/dev/null 2>&1
  rc=$?
  hcount="$(hist_last | jq -r '.finding_count' 2>/dev/null)"
  [ "$rc" -eq 0 ] && [ -e "$SENTINEL" ] && [ "${hcount:-0}" -ge 1 ]
  exit $?
)
[ $? -eq 0 ] && ok "(no-regresión): universo reconstruible → sentinel ok emitido + historial con finding_count>=1" \
  || bad "(no-regresión): el camino feliz dejó de emitir sentinel o el universo quedó vacío"

echo ""
printf '=== RESUMEN: %d pass, %d fail ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
