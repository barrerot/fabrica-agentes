#!/usr/bin/env bash
# tests/run-tests.sh — Arnés del motor (TAL-2288). Cubre los controles obligatorios del
# veredicto GO del plan: sentinels OID+ref (incl. delete/push a main y multi-ref), bootstrap
# de motor-go contra remoto bare, matriz de exits del runner v2, y rechazos del agregador
# (receipt fabricado/incompleto/multigate/duplicado/ajeno al run_group, reducción de registro,
# cambio de head mid-run). Sin red: gh se simula por PATH-shim.
set -uo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MOTOR="$(dirname "$HERE")"
# shellcheck source=/dev/null
. "$HERE/fixtures/instalacion/gh-dobles.sh" || exit 2
TMP="$(mktemp -d "${TMPDIR:-/tmp}/motor-tests-XXXXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP"/tmpdir "$TMP"/seal-rec
export TMPDIR="$TMP/tmpdir" TF_RUNNER_LOCK="$TMP/runner.lock" TF_SEAL_REC_ROOT="$TMP/seal-rec"

PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
ko()  { FAIL=$((FAIL+1)); echo "  ✗ $1" >&2; }
check() { # <desc> <rc-esperado> <rc-real>
  if [ "$3" -eq "$2" ]; then ok "$1"; else ko "$1 (rc=$3, esperado $2)"; fi
}

if [ "${TF_FASES_EN_BATERIA:-0}" != 1 ]; then
  fases_rc=0
  bash "$MOTOR/tests/test-instalacion-fases.sh" || fases_rc=$?
  check "test-instalacion-fases.sh (checks F0-F8, estado y núcleo)" 0 "$fases_rc"
fi

awk_rc=0
python3 "$MOTOR/scripts/check-awk-portable.py" --self-test || awk_rc=$?
check "autoprueba del lint de awk portable" 0 "$awk_rc"
awk_rc=0
python3 "$MOTOR/scripts/check-awk-portable.py" --root "$MOTOR" || awk_rc=$?
check "programas awk portables del paquete" 0 "$awk_rc"

echo "== bash -n de todos los scripts del motor =="
for f in "$MOTOR"/scripts/*.sh "$MOTOR"/scripts/lib/*.sh "$MOTOR"/githooks/pre-push; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else ko "bash -n $(basename "$f")"; fi
done

# ── TAL-2672: lector de cuotas multi-proveedor — py_compile + unittest atados a PASS/FAIL. ────
# El arnés usa `set -uo pipefail` (SIN `set -e`): invocar py_compile/unittest sin capturar y
# comparar su exit code dejaría un fallo en silencio con el arnés terminando en VERDE.
# Cada paso pasa por `check`, igual que el resto del arnés.
echo "== TAL-2672: py_compile + unittest del lector de cuotas =="
py_compile_rc=0
python3 -m py_compile \
  "$MOTOR/scripts/lector_cuotas.py" \
  "$MOTOR/scripts/gen-pozos-fragment.py" \
  "$MOTOR/tests/test_lector_cuotas.py" >/dev/null 2>&1 || py_compile_rc=$?
check "py_compile lector_cuotas + gen-pozos-fragment + tests" 0 "$py_compile_rc"

unittest_rc=0
( cd "$MOTOR" && python3 -m unittest tests.test_lector_cuotas ) >/dev/null 2>&1 || unittest_rc=$?
check "unittest tests/test_lector_cuotas.py (fixtures, offline)" 0 "$unittest_rc"

# ── TAL-5352: los TRES estados del marcador db-reset-retry (null / 0 / 1). ───────────────────
# Va atado con `check` como el resto: el arnés corre con `set -uo pipefail` SIN `set -e`, así que
# invocarlo suelto dejaría su fallo en silencio con el arnés en verde. Y va aquí porque un test que
# nadie ejecuta no es una prueba, es un fichero (registro de las pruebas:
# el self-test existía, pasaba `bash -n` y shellcheck, y sus casos no se corrían jamás).
# ── talent-factory#41: envoltorio de `supabase` por gate (enrutado + conducta + contrato). ────
# Atado con `check` como el resto: el arnés corre con `set -uo pipefail` SIN `set -e`.
echo "== #41: envoltorio de supabase (enrutado, reintento único, contrato del marcador) =="
wrap_rc=0
bash "$MOTOR/tests/test-supabase-wrapper.sh" >/dev/null 2>&1 || wrap_rc=$?
check "test-supabase-wrapper.sh (16 casos: par adyacente, reintento, 7 campos, atomicidad)" 0 "$wrap_rc"

echo "== TAL-5352: tres estados del marcador db-reset-retry =="
marker_rc=0
bash "$MOTOR/tests/test-db-reset-marker.sh" "$MOTOR/scripts/run-local-gates.sh" >/dev/null 2>&1 || marker_rc=$?
check "test-db-reset-marker.sh (13 casos: null/0/1, fuera de contrato, reason)" 0 "$marker_rc"

# ── TAL-6759: reintento único por firma de infra ESTRICTA antes de enrojecer. Atado con `check`
# como el resto: el arnés corre con `set -uo pipefail` SIN `set -e`, así que invocarlo suelto
# dejaría su fallo en silencio con el arnés en verde.
echo "== TAL-6759: clasificador de firma de infra (reintento único del motor) =="
infra_retry_rc=0
infra_retry_out="$(bash "$MOTOR/tests/test-infra-retry.sh" "$MOTOR/scripts/run-local-gates.sh" 2>&1)" || infra_retry_rc=$?
[ "$infra_retry_rc" -eq 0 ] || printf '%s\n' "$infra_retry_out" >&2
check "test-infra-retry.sh (GREEN firmas de infra + RED defecto de producto + extensión solo-suma)" 0 "$infra_retry_rc"

echo "== TAL-5435: check-run-tests-registry.sh (conjunto, no cardinal) =="
registry_rc=0
# La salida sólo se vuelca si el arnés falla: un fallo mudo aquí obliga a reproducir el entorno a mano
# (le costó una vuelta entera al gate de Actions, donde no hay identidad de git configurada).
registry_out="$(bash "$MOTOR/tests/test-check-run-tests-registry.sh" 2>&1)" || registry_rc=$?
[ "$registry_rc" -eq 0 ] || printf '%s\n' "$registry_out" >&2
check "test-check-run-tests-registry.sh (13 casos: 5 escenarios + rebase multi-commit fail-closed + args sin valor + duplicados + mutante)" 0 "$registry_rc"

echo "== TAL-CLOBBER: check-function-clobber.sh (pisada silenciosa de funciones SQL) =="
clobber_rc=0
# Igual que arriba: la salida sólo se vuelca si falla, para que un rojo en CI sea diagnosticable
# sin tener que reproducir el entorno a mano.
clobber_out="$(bash "$MOTOR/tests/test-check-function-clobber.sh" 2>&1)" || clobber_rc=$?
[ "$clobber_rc" -eq 0 ] || printf '%s\n' "$clobber_out" >&2
check "test-check-function-clobber.sh (12 casos: causal + selectividad + antes-de-la-base + sin-SQL + comentario + 3 fail-closed + mutante)" 0 "$clobber_rc"

echo "== TAL-5462: insumos por área (exclusiones + always-rerun + cruce manifiesto) =="
area_rc=0
area_out="$(bash "$MOTOR/tests/test-insumos-por-area.sh" 2>&1)" || area_rc=$?
[ "$area_rc" -eq 0 ] || printf '%s\n' "$area_out" >&2
check "test-insumos-por-area.sh (12 casos: fixtures reales #2255/#2241 + fail-closed de área nueva + cruce manifiesto + gramática + mutante)" 0 "$area_rc"

echo "== TAL-6674: bt_prepara() del agregador — identidad de blob, no ancestría =="
blob_rc=0
blob_out="$(bash "$MOTOR/tests/test-agregador-identidad-blob.sh" 2>&1)" || blob_rc=$?
[ "$blob_rc" -eq 0 ] || printf '%s\n' "$blob_out" >&2
# [TAL-6733] añade un caso (SIGPIPE/blob grande) DENTRO del arnés — la descripción de abajo NO
# se toca: check-run-tests-registry.sh identifica cada entrada por el TEXTO EXACTO entre
# comillas (TAL-5435, comparación de CONJUNTO main-side ∪ piece-side); renombrarla haría que
# main-side siguiera teniendo el texto viejo y el head fundido no, disparando un "entrada
# perdida" falso en ESE guard al fundirse esta pieza.
check "test-agregador-identidad-blob.sh (20 casos: mutante de la ancestría rota + propiedad de blob + control sano + insumo universal + conflicto real + 3 NO MEDIDO + sin tubería + sin parseo de texto)" 0 "$blob_rc"

echo "== TAL-6719: inercia por insumo — PR disjunto no re-corre, roster reconcilia head↔main vivo =="
inercia_rc=0
inercia_out="$(bash "$MOTOR/tests/test-agregador-inercia-por-insumo.sh" 2>&1)" || inercia_rc=$?
[ "$inercia_rc" -eq 0 ] || printf '%s\n' "$inercia_out" >&2
check "test-agregador-inercia-por-insumo.sh (13 casos a-m: conserva/rechaza/universal/conflicto/mergeable/sin-mapa/FAIL/roster-mixto/roster-replantar/rename/TAB-en-ruta/PR-grande-sin-SIGPIPE/blob-conflicto-grande-sin-SIGPIPE + mutante de la condición 2)" 0 "$inercia_rc"

echo "== TAL-5563/TAL-8040: provision-tf-manifest.sh (rojo/verde + idempotencia + fail-closed + cwd + mutante) =="
provman_rc=0
provman_out="$(bash "$MOTOR/tests/test-provision-tf-manifest.sh" \
  "$MOTOR/scripts/provision-tf-manifest.sh" \
  "$MOTOR/scripts/verify-handoff.sh" \
  "$MOTOR/scripts/lib/handoff.sh" \
  "$MOTOR/manifiestos/ejemplo.conf" 2>&1)" || provman_rc=$?
[ "$provman_rc" -eq 0 ] || printf '%s\n' "$provman_out" >&2
check "test-provision-tf-manifest.sh (14 casos: rojo sin manifiesto + verde tras provisionar + idempotencia + no-pisa-sin-force + --force + cwd-independencia + mutante + sin fuente fail-closed + TCO_TF_MANIFEST + manifiesto inválido)" 0 "$provman_rc"

# ── Fixture: repo de trabajo + remoto bare, con el hook del motor activado. ───────────────────
mk_repo() { # <dir>
  git init -q -b main "$1"
  git -C "$1" config user.email t@t && git -C "$1" config user.name t
  mkdir -p "$1/scripts" "$1/.claude"
  # [NO-GO-3] Con shebang: sin él, en hosts CON shellcheck el gate real de motor-go marca
  # SC2148 sobre el fixture y los tests de manifiestos daban 3 falsos FAIL (solo pasaban
  # donde shellcheck no estaba instalado).
  printf '#!/usr/bin/env bash\necho ok\n' > "$1/scripts/x.sh"
  git -C "$1" add -A && git -C "$1" commit -qm base
}
WORK="$TMP/work"; BARE="$TMP/origin.git"
mk_repo "$WORK"
git clone -q --bare "$WORK" "$BARE"
git -C "$WORK" remote add origin "$BARE"
mkdir -p "$WORK/.githooks"
cp "$MOTOR/githooks/pre-push" "$WORK/.githooks/pre-push" && chmod +x "$WORK/.githooks/pre-push"
git -C "$WORK" config core.hooksPath .githooks

sha() { git -C "$WORK" rev-parse HEAD; }
mkbranch() { git -C "$WORK" checkout -qb "$1"; echo "$RANDOM" >> "$WORK/scripts/x.sh"; git -C "$WORK" commit -qam "c-$1"; }
draft_sentinel() { # <sha> <branch>
  printf '%s\n%s\n%s\ndb-reset: n/a\n' "$1" "$2" "$(date -u +%FT%TZ)" > "$WORK/.claude/.draft-handoff"
}
motor_sentinel() { # <sha> <ref>
  printf '%s\n%s\n%s\ngates: test\n' "$1" "$2" "$(date -u +%FT%TZ)" > "$WORK/.claude/.motor-go"
}
cr_sentinel() { # <sha>
  printf '%s\nrama\nok\nx\n%s\n' "$1" "$(date -u +%FT%TZ)" > "$WORK/.claude/.cr-review-ok"
  # formato real: L1 sha · L3 estado · L5 ts
  printf '%s\n-\nok\n-\n%s\n' "$1" "$(date -u +%FT%TZ)" > "$WORK/.claude/.cr-review-ok"
}
clean_sentinels() { rm -f "$WORK/.claude/.draft-handoff" "$WORK/.claude/.motor-go" "$WORK/.claude/.cr-review-ok"; }

echo "== pre-push del motor: sentinels OID+ref =="
mkbranch feat/a
clean_sentinels; draft_sentinel "$(sha)" "feat/a"
git -C "$WORK" push -q origin feat/a >/dev/null 2>&1; check "draft (OID+rama correctos) → push feat/a pasa" 0 $?
[ ! -f "$WORK/.claude/.draft-handoff" ] && ok "sentinel draft consumido one-shot" || ko "sentinel draft NO consumido"

mkbranch feat/b
clean_sentinels; draft_sentinel "$(sha)" "feat/a"
git -C "$WORK" push -q origin HEAD:refs/heads/feat/b >/dev/null 2>&1; check "draft de feat/a NO autoriza feat/b (binding de rama)" 1 $?

clean_sentinels; draft_sentinel "$(sha)" "feat/b"
git -C "$WORK" push -q origin HEAD:refs/heads/main >/dev/null 2>&1; check "draft (aunque válido para su rama) NO autoriza main" 1 $?

clean_sentinels; cr_sentinel "$(sha)"
git -C "$WORK" push -q origin HEAD:refs/heads/main >/dev/null 2>&1; check "sentinel CR NO autoriza main" 1 $?

clean_sentinels
git -C "$WORK" push -q origin :refs/heads/feat/a >/dev/null 2>&1; check "delete de rama normal pasa sin sentinel" 0 $?
git -C "$WORK" push -q origin :refs/heads/main >/dev/null 2>&1; check "delete de main RECHAZADO (antes del bypass de deletes)" 1 $?

clean_sentinels; draft_sentinel "$(sha)" "feat/b"
git -C "$WORK" push -q origin feat/b HEAD:refs/heads/main >/dev/null 2>&1; check "push multi-ref (feat válida + main) → bloqueado" 1 $?
[ -f "$WORK/.claude/.draft-handoff" ] && ok "fallo parcial NO quema el sentinel draft" || ko "el sentinel draft se quemó en un push fallido"

clean_sentinels; motor_sentinel "$(sha)" "refs/heads/main"
git -C "$WORK" checkout -q main; git -C "$WORK" merge -q feat/b >/dev/null 2>&1
motor_sentinel "$(sha)" "refs/heads/main"
git -C "$WORK" push -q origin main >/dev/null 2>&1; check "sentinel del motor (SHA, main) → push main pasa" 0 $?
[ ! -f "$WORK/.claude/.motor-go" ] && ok "sentinel del motor consumido one-shot" || ko "sentinel del motor NO consumido"

echo "$RANDOM" >> "$WORK/scripts/x.sh"; git -C "$WORK" commit -qam otro
clean_sentinels; motor_sentinel "0000000000000000000000000000000000000000" "refs/heads/main"
git -C "$WORK" push -q origin main >/dev/null 2>&1; check "sentinel del motor con SHA distinto → bloquea" 1 $?
clean_sentinels; motor_sentinel "$(sha)" "refs/heads/otra"
git -C "$WORK" push -q origin main >/dev/null 2>&1; check "sentinel del motor con ref distinta → bloquea" 1 $?

echo "== motor-go.sh: bootstrap contra remoto bare =="
BOOT="$TMP/boot"; BOOTBARE="$TMP/boot.git"
mk_repo "$BOOT"
git clone -q --bare "$BOOT" "$BOOTBARE"
git -C "$BOOT" remote add origin "$BOOTBARE"
mkdir -p "$BOOT/.githooks" "$BOOT/scripts"
cp "$MOTOR/githooks/pre-push" "$BOOT/.githooks/pre-push" && chmod +x "$BOOT/.githooks/pre-push"
cp "$MOTOR/scripts/motor-go.sh" "$BOOT/scripts/motor-go.sh"
printf '.claude/\n' > "$BOOT/.gitignore"
git -C "$BOOT" config core.hooksPath .githooks
git -C "$BOOT" add -A && git -C "$BOOT" commit -qm "bootstrap motor-go + hook"
( cd "$BOOT" && MOTOR_GO_NO_SHELLCHECK="$(command -v shellcheck >/dev/null && echo 0 || echo 1)" bash scripts/motor-go.sh >/dev/null 2>&1 )
check "motor-go.sh emite sentinel sobre su propio HEAD (bootstrap sin excepción)" 0 $?
git -C "$BOOT" push -q origin main >/dev/null 2>&1; check "primer push del motor pasa SOLO vía motor-go" 0 $?
echo x >> "$BOOT/scripts/x.sh" && git -C "$BOOT" commit -qam n
git -C "$BOOT" push -q origin main >/dev/null 2>&1; check "push del motor SIN motor-go → bloqueado" 1 $?

echo "== [review PR #13] motor-go.sh: git diff ROTO → aborta fail-closed SIN sentinel =="
# origin/main apunta a un commit cuyo TREE se borra del object store: rev-parse resuelve la
# ref (lee refs, no el objeto), pero `git diff base..HEAD` tiene que ABRIR ese tree y falla
# DE VERDAD ("unable to read tree"). Antes del fix, mapfile tragaba el fallo del proceso
# sustituido (lista vacía) → "no toca shell" → gates saltados → sentinel emitido.
GDF="$TMP/gdf"; mk_repo "$GDF"
cp "$MOTOR/scripts/motor-go.sh" "$GDF/scripts/motor-go.sh"
printf '.claude/\n' > "$GDF/.gitignore"
git -C "$GDF" add -A && git -C "$GDF" commit -qm gdf-base
GDF_BASE="$(git -C "$GDF" rev-parse HEAD)"
GDF_TREE="$(git -C "$GDF" rev-parse 'HEAD^{tree}')"
printf 'echo y\n' >> "$GDF/scripts/x.sh" && git -C "$GDF" commit -qam gdf-head
git -C "$GDF" update-ref refs/remotes/origin/main "$GDF_BASE"
rm -f "$GDF/.git/objects/${GDF_TREE:0:2}/${GDF_TREE:2}"
( cd "$GDF" && MOTOR_GO_NO_SHELLCHECK=1 bash scripts/motor-go.sh >"$TMP/gdf.out" 2>&1 )
check "git diff roto → motor-go aborta (rc=2, die)" 2 $?
grep -q 'git diff .* FALLÓ' "$TMP/gdf.out" && ok "el abort nombra el fallo de git diff" || ko "no nombra el fallo de git diff: $(tail -2 "$TMP/gdf.out" | tr '\n' ' ')"
[ ! -f "$GDF/.claude/.motor-go" ] && ok "SIN sentinel tras git diff roto" || ko "sentinel emitido con git diff roto"

echo "== [review PR #13, NO-GO-3] motor-go.sh: grep ROTO (shim rc=2) → detección intacta + abort fail-closed SIN sentinel =="
# Reproduce el bypass del review: con un grep que sale 2, la derivación ANTIGUA
# (mapfile + grep || true) dejaba los tres filtros vacíos y el sentinel salía con los gates
# saltados. La derivación nueva es Bash puro (inmune al shim) → DETECTA skills/ → el gate
# del paquete corre validate-package (que SÍ usa grep) → muere DENTRO → cero sentinel.
GSH="$TMP/gsh"; mk_repo "$GSH"
cp "$MOTOR/scripts/motor-go.sh" "$GSH/scripts/motor-go.sh"
mkdir -p "$GSH/skills/skill-creator/scripts" "$GSH/skills/skill-creator/assets"
cp "$MOTOR/skills/skill-creator/scripts/lib-package.sh" "$MOTOR/skills/skill-creator/scripts/validate-package.sh" \
   "$MOTOR/skills/skill-creator/scripts/sync-package.sh" "$GSH/skills/skill-creator/scripts/"
cp "$MOTOR/skills/skill-creator/assets/package.manifest" "$GSH/skills/skill-creator/assets/"
printf '.claude/\n' > "$GSH/.gitignore"
git -C "$GSH" add -A && git -C "$GSH" commit -qm gsh-base
git -C "$GSH" update-ref refs/remotes/origin/main "$(git -C "$GSH" rev-parse HEAD)"
printf '# tocado\n' >> "$GSH/skills/skill-creator/scripts/lib-package.sh"
git -C "$GSH" commit -qam gsh-head
GREPSHIM="$TMP/shim-grep"; mkdir -p "$GREPSHIM"
printf '#!/usr/bin/env bash\nexit 2\n' > "$GREPSHIM/grep"; chmod +x "$GREPSHIM/grep"
( cd "$GSH" && PATH="$GREPSHIM:$PATH" MOTOR_GO_NO_SHELLCHECK=1 bash scripts/motor-go.sh >"$TMP/gsh.out" 2>&1 )
check "grep roto → motor-go aborta fail-closed (rc=2, die del gate del paquete)" 2 $?
[ ! -f "$GSH/.claude/.motor-go" ] && ok "cero sentinel con grep roto" || ko "sentinel emitido con grep roto"
grep -q 'el diff toca skills/' "$TMP/gsh.out" && ok "la detección de skills/ NO dependió de grep" || ko "skills/ no detectado con grep roto: $(tail -2 "$TMP/gsh.out" | tr '\n' ' ')"

echo "== motor-go.sh: anti-reducción semántica de manifiestos =="
NOSC="$(command -v shellcheck >/dev/null && echo 0 || echo 1)"
MGO_OUT="$TMP/mgo.out"
mgo() { ( cd "$BOOT" && MOTOR_GO_NO_SHELLCHECK="$NOSC" "$@" bash scripts/motor-go.sh >"$MGO_OUT" 2>&1 ); }
mgo env; git -C "$BOOT" push -q origin main >/dev/null 2>&1   # base limpia empujada
mkdir -p "$BOOT/manifiestos"
printf 'TF_PROJECT="t"\nTF_GATE_IDS="a b"\nTF_GATE_CMD_a="npm run test:a"\nTF_E2E_FAMILIES="fam"\nTF_DB_GATE="always"\n' > "$BOOT/manifiestos/t.conf"
git -C "$BOOT" add -A && git -C "$BOOT" commit -qm conf-base
mgo env; check "motor-go acepta manifiesto nuevo (sin base que reducir)" 0 $?
git -C "$BOOT" push -q origin main >/dev/null 2>&1
# commit EXCLUSIVAMENTE .conf que elimina un gate → rojo sin ratificación
printf 'TF_PROJECT="t"\nTF_GATE_IDS="a"\nTF_GATE_CMD_a="npm run test:a"\nTF_E2E_FAMILIES="fam"\nTF_DB_GATE="always"\n' > "$BOOT/manifiestos/t.conf"
git -C "$BOOT" commit -qam conf-reduce
mgo env; check "commit solo-.conf que ELIMINA un gate → motor-go ROJO" 1 $?
ratify() { # <ref> [items] — ratificación DURABLE (formato cerrado) committeada en el MISMO push
  mkdir -p "$BOOT/manifiestos"
  printf '%s | ref=%s | items=%s | test\n' "$(date -u +%F)" "$1" "${2:-t.conf}" >> "$BOOT/manifiestos/RATIFICACIONES.log"
  git -C "$BOOT" add -A && git -C "$BOOT" commit -qm "ratifica: $1"
}
# token PARCIAL no ratifica : items=tt.conf no cubre t.conf
ratify TAL-TEST-0 tt.conf
mgo env; check "ratificación con token PARCIAL (tt.conf) NO cubre t.conf → ROJO" 1 $?
ratify TAL-TEST-1
mgo env; check "reducción RATIFICADA vía RATIFICACIONES.log (durable, token exacto) → pasa" 0 $?
{ grep -q "reduccion-manifiesto=RATIFICADA" "$BOOT/.claude/.motor-go" && grep -q "ref=TAL-TEST-1" "$BOOT/.claude/.motor-go"; } && ok "el sentinel traza el ref de la ratificación" || ko "sentinel sin ref de ratificación"
git -C "$BOOT" push -q --no-verify origin main >/dev/null 2>&1
# debilitamiento de TF_DB_GATE (always→never) → rojo
printf 'TF_PROJECT="t"\nTF_GATE_IDS="a"\nTF_GATE_CMD_a="npm run test:a"\nTF_E2E_FAMILIES="fam"\nTF_DB_GATE="never"\n' > "$BOOT/manifiestos/t.conf"
git -C "$BOOT" commit -qam conf-db-weaken
mgo env; check "TF_DB_GATE always→never (debilitamiento) → motor-go ROJO" 1 $?
ratify TAL-TEST-2; mgo env >/dev/null 2>&1; git -C "$BOOT" push -q --no-verify origin main >/dev/null 2>&1
# VACIAR el comando de un gate conservando el ID → rojo
printf 'TF_PROJECT="t"\nTF_GATE_IDS="a"\nTF_GATE_CMD_a="true"\nTF_E2E_FAMILIES="fam"\nTF_DB_GATE="never"\n' > "$BOOT/manifiestos/t.conf"
git -C "$BOOT" commit -qam conf-cmd-true
mgo env; check "TF_GATE_CMD_a vaciado a true (ID intacto) → motor-go ROJO" 1 $?
ratify TAL-TEST-3; mgo env >/dev/null 2>&1; git -C "$BOOT" push -q --no-verify origin main >/dev/null 2>&1
# REESCRIBIR el historial de ratificaciones → rojo (append-only violado)
printf 'TF_PROJECT="t"\nTF_GATE_IDS="a"\nTF_GATE_CMD_a="false"\nTF_E2E_FAMILIES="fam"\nTF_DB_GATE="never"\n' > "$BOOT/manifiestos/t.conf"
sed -i 's/TAL-TEST-1/TAL-FALSO/' "$BOOT/manifiestos/RATIFICACIONES.log"
printf '%s | t.conf | ref=TAL-TEST-4 | test\n' "$(date -u +%F)" >> "$BOOT/manifiestos/RATIFICACIONES.log"
git -C "$BOOT" commit -qam conf-rewrite-log
mgo env; check "RATIFICACIONES.log reescrito (no append-only) → motor-go ROJO" 1 $?
git -C "$BOOT" reset -q --hard origin/main
# BORRAR el manifiesto entero → rojo
git -C "$BOOT" rm -q manifiestos/t.conf && git -C "$BOOT" commit -qm conf-delete
mgo env; check "manifiesto ELIMINADO → motor-go ROJO" 1 $?
ratify TAL-TEST-5
mgo env; check "eliminación RATIFICADA (log durable) → pasa" 0 $?
git -C "$BOOT" push -q --no-verify origin main >/dev/null 2>&1
# RATIFICACIONES.log reescrito en un push INDEPENDIENTE (sin reducción) → rojo
printf 'x\n' >> "$BOOT/scripts/x.sh"
sed -i 's/TAL-TEST-5/TAL-BORRADO/' "$BOOT/manifiestos/RATIFICACIONES.log"
git -C "$BOOT" commit -qam rewrite-log-solo
mgo env; check "RATIFICACIONES.log reescrito en push sin reducción → motor-go ROJO" 1 $?
git -C "$BOOT" reset -q --hard origin/main
# borrado del log de ratificaciones → rojo
git -C "$BOOT" rm -q manifiestos/RATIFICACIONES.log && git -C "$BOOT" commit -qm borra-log
mgo env; check "RATIFICACIONES.log ELIMINADO → motor-go ROJO" 1 $?
git -C "$BOOT" reset -q --hard origin/main

# manifiesto con código embebido (gramática cerrada) → rojo en motor-go
mkdir -p "$BOOT/manifiestos"
printf 'TF_PROJECT="t"\nTF_GATE_IDS="a"\nTF_MAL="$(id)"\n' > "$BOOT/manifiestos/u.conf"
git -C "$BOOT" add -A && git -C "$BOOT" commit -qm conf-evil
mgo env; check "manifiesto fuera de la gramática cerrada → motor-go ROJO" 1 $?
git -C "$BOOT" reset -q --hard origin/main

echo "== run-local-gates.sh v2: matriz de exits + receipt =="
GR="$TMP/gaterepo"; GRB="$TMP/gaterepo.git"
mk_repo "$GR"
git clone -q --bare "$GR" "$GRB"; git -C "$GR" remote add origin "$GRB"; git -C "$GR" push -qu origin main >/dev/null 2>&1
MAN="$TMP/test.conf"
cat > "$MAN" <<EOF
TF_PROJECT="test"
TF_GATE_IDS="verde rojo db-guards"
TF_GATE_CMD_verde="true"
TF_GATE_CMD_rojo="false"
TF_GATE_CMD_db_guards="true"
TF_INSTALL="true"
TF_DB_GATE="never"
TF_MIGRATIONS_DIR="supabase/migrations"
EOF
RLG="$MOTOR/scripts/run-local-gates.sh"
GSHA="$(git -C "$GR" rev-parse HEAD)"

bash "$RLG" >/dev/null 2>&1; check "sin args → exit 2" 2 $?
bash "$RLG" "$GR" --gate verde >/dev/null 2>&1; check "sin manifiesto → exit 2" 2 $?
bash "$RLG" "$GR" --gate inexistente --manifest "$MAN" --sha "$GSHA" >/dev/null 2>&1; check "gate-id desconocido → exit 2" 2 $?
R1="$TMP/r1.json"
bash "$RLG" "$GR" --gate verde --manifest "$MAN" --sha "$GSHA" --base "$GSHA" --receipt "$R1" >/dev/null 2>&1
check "gate PASS → exit 0" 0 $?
jq -e '.schema_version==1 and .gate_id=="verde" and .result=="PASS" and (.sha|length==40) and (has("gates")|not)' "$R1" >/dev/null 2>&1 \
  && ok "receipt PASS: forma única (identidad + UN gate)" || ko "receipt PASS malformado"
R2="$TMP/r2.json"
bash "$RLG" "$GR" --gate rojo --manifest "$MAN" --sha "$GSHA" --base "$GSHA" --receipt "$R2" >/dev/null 2>&1
check "gate FAIL → exit 1 (receipt escrito)" 1 $?
jq -e '.result=="FAIL"' "$R2" >/dev/null 2>&1 && ok "receipt FAIL" || ko "receipt FAIL malformado"
R3="$TMP/r3.json"
bash "$RLG" "$GR" --gate db-guards --manifest "$MAN" --sha "$GSHA" --base "$GSHA" --receipt "$R3" >/dev/null 2>&1
check "db-guards con TF_DB_GATE=never → SKIP exit 0" 0 $?
jq -e '.result=="SKIP" and (.skip_reason|length>0)' "$R3" >/dev/null 2>&1 && ok "SKIP con razón verificable" || ko "SKIP sin razón"

MAN_DUP="$TMP/dup.conf"; cat "$MAN" > "$MAN_DUP"; echo 'TF_INSTALL="otra"' >> "$MAN_DUP"
bash "$RLG" "$GR" --gate verde --manifest "$MAN_DUP" --sha "$GSHA" >/dev/null 2>&1; check "manifiesto con clave duplicada → exit 2" 2 $?
ASG="$TMP/asg.json"
jq -n --arg sha "$GSHA" '{schema_version:1, run_group:"rg1", repo:"o/r", pr:"9", sha:$sha, base_sha:$sha, manifest_digest:"deadbeef", gate_id:"verde"}' > "$ASG"
bash "$RLG" "$GR" --assignment "$ASG" --manifest "$MAN" >/dev/null 2>&1; check "asignación con manifest_digest divergente → exit 2" 2 $?

echo "== run-gate-sealed.sh + post-local-gates.sh: procedencia sellada (ruta canónica por contenedor) =="
PLG="$MOTOR/scripts/post-local-gates.sh"
RGS="$MOTOR/scripts/run-gate-sealed.sh"
SHIM="$TMP/shim"; mkdir -p "$SHIM"
GHLOG="$TMP/gh.log"; : > "$GHLOG"
INCUSLOG="$TMP/incus.log"; : > "$INCUSLOG"

# Estación y runner con REPOS SEPARADOS y UID distinto (el shim ya no puede ocultarlo):
# GR = clon de la estación · RGR = clon del runner, SIN el head a certificar (obliga al bundle).
mkdir -p "$GR/scripts/github"
printf '#!/usr/bin/env bash\ncase "$1" in feat/*|chore/*|fix/*) exit 0;; *) exit 1;; esac\n' > "$GR/scripts/github/validar-rama-pr.sh"
git -C "$GR" add -A && git -C "$GR" commit -qm validador && git -C "$GR" push -q origin main >/dev/null 2>&1
GSHA="$(git -C "$GR" rev-parse HEAD)"
RGR="$TMP/runner-repo"
git clone -q "$GRB" "$RGR" && git -C "$RGR" config user.email t@t && git -C "$RGR" config user.name t
echo delta >> "$GR/scripts/x.sh" && git -C "$GR" commit -qam head-nuevo
GSHA2="$(git -C "$GR" rev-parse HEAD)"   # head a certificar: NO está en RGR ni en origin
git -C "$RGR" cat-file -e "$GSHA2" 2>/dev/null && ko "fixture roto: el runner ya tiene el head" || ok "fixture: el runner NO tiene el head (bundle obligado)"

MAN_OK="$TMP/ok.conf"; MAN3="$TMP/tres.conf"
printf 'TF_PROJECT="test"\nTF_GATE_IDS="verde db-guards"\nTF_GATE_CMD_verde="true"\nTF_GATE_CMD_db_guards="true"\nTF_INSTALL="true"\nTF_DB_GATE="never"\n' > "$MAN_OK"
printf 'TF_PROJECT="test"\nTF_GATE_IDS="verde rojo db-guards"\nTF_GATE_CMD_verde="true"\nTF_GATE_CMD_rojo="false"\nTF_GATE_CMD_db_guards="true"\nTF_INSTALL="true"\nTF_DB_GATE="never"\n' > "$MAN3"

# Shim de incus : push/pull con flags --uid/--gid/--mode registrados; exec distingue
# preflight (LG-PREFLIGHT → LIMPIO/SUCIO por env), id -u/-g (uid ficticio 1001) y comandos
# del runner (sudo despojado, ejecución local contra el repo SEPARADO del runner).
export INCUSLOG
export RFS="$TMP/runner-fs"; mkdir -p "$RFS"
# El shim traduce el contrato remoto fijo /tmp/lg-* al FS privado del fixture.
# TMPDIR gobierna la estación, no el espacio de nombres del runner remoto.
cat > "$SHIM/incus" <<'INCUSEOF'
#!/usr/bin/env bash
echo "incus $*" >> "$INCUSLOG"
rfs() { case "$1" in /tmp/lg-*) printf '%s' "$RFS$1" ;; *) printf '%s' "$1" ;; esac; }
case "$1" in
  file)
    op="$2"; shift 2
    while [ "${1#--}" != "$1" ]; do shift 2; done
    if [ "$op" = "push" ]; then
      dst="$(rfs "/${2#*/}")"; mkdir -p "$(dirname "$dst")"
      # Simula fs.protected_regular=2 + /tmp sticky: el kernel PROHIBE a root sobrescribir el
      # fichero de otro usuario ahi. Sin esto el shim aceptaba cualquier sobrescritura y el
      # arnes no podia ver el bug del 2o gate del mismo run_group (#40).
      if [ -e "$dst" ] && [ -z "${SHIM_SIN_PROTECTED_REGULAR:-}" ]; then
        echo "Error: permission denied" >&2; exit 1
      fi
      cp "$1" "$dst"; exit $?
    fi
    if [ "$op" = "pull" ]; then cp "$(rfs "/${1#*/}")" "$2"; exit $?; fi
    exit 9 ;;
  exec)
    shift; shift
    [ "$1" = "--" ] && shift
    case "$*" in
      *LG-PREFLIGHT*)
        if [ -n "${SHIM_PREFLIGHT_DIRTY:-}" ]; then echo "SUCIO: /home/runner/.config/gh"; exit 3; fi
        echo "LIMPIO"; exit 0 ;;
    esac
    if [ "$1" = "id" ]; then echo 1001; exit 0; fi
    if [ "$1" = "sudo" ]; then shift 3; fi
    args=(); for a in "$@"; do args+=("$(rfs "$a")"); done
    "${args[@]}"; exit $? ;;
  *) exit 9 ;;
esac
INCUSEOF
chmod +x "$SHIM/incus"

cat > "$SHIM/gh" <<SHIMEOF
#!/usr/bin/env bash
echo "\$@" >> "$GHLOG"
case "\$*" in
  *"pr view"*)
    n="\$(cat "$TMP/viewcount" 2>/dev/null || echo 0)"; echo \$((n+1)) > "$TMP/viewcount"
    oid="$GSHA2"
    if [ -f "$TMP/flip-head" ] && [ "\$n" -ge 1 ]; then oid="1111111111111111111111111111111111111111"; fi
    if [ -f "$TMP/advance-base" ] && [ "\$n" -ge 1 ]; then bash "$TMP/advance-base.sh" >/dev/null 2>&1; fi
    printf '{"headRefOid":"%s","headRefName":"feat/x","baseRefName":"main","author":{"login":"dev"}}\n' "\$oid" ;;
  *"-X POST"*) echo '{}' ;;
  *"/status"*) echo "\${LG_STATE_EXPECTED:-success}" ;;
esac
SHIMEOF
chmod +x "$SHIM/gh"
cerrar_doble_gh "$SHIM/gh" || exit 1
# Mapa de insumos para el arnés: el REAL + el gate sintético `verde` (que en produccion no existe
# y por eso el mapa real lo rechaza fail-closed, como debe).
INSUMOS_TEST="$TMP/insumos-test.sh"
# El cargador busca el .conf JUNTO A SÍ MISMO: la copia en $TMP no lo encontraría. Se copia al lado.
cp "$MOTOR/scripts/lib/insumos-por-gate.conf" "$TMP/insumos-por-gate.conf"
{ cat "$MOTOR/scripts/lib/insumos-por-gate.sh"
  cat <<'EOFI'
# OJO: hay que RENOMBRAR la original antes de redefinir. Un envoltorio que la llame por su
# nombre se llama a SI MISMO (recursion infinita → rc!=0 → todos los gates caen como "sin mapa";
# cazado midiendo, no leyendo).
eval "_insumos_real() $(declare -f insumos_de_gate | tail -n +2)"
insumos_de_gate() {
  case "$1" in
    verde) printf '%s\n' '^src/' '^scripts/x\.sh$'; return 0 ;;
    sin-mapa-a-proposito) return 1 ;;
  esac
  _insumos_real "$@"
}
EOFI
} > "$INSUMOS_TEST"
plg() { PATH="$SHIM:$PATH" LG_MANIFEST_DIR="$TMP" LG_INSUMOS_FILE="${LG_INSUMOS_OVERRIDE:-$INSUMOS_TEST}" LG_STATE_EXPECTED="${LG_STATE_EXPECTED:-success}" bash "$PLG" "$@"; }
rgs() { # <gate> <run_group> <manifest> <receipts>
  PATH="$SHIM:$PATH" bash "$RGS" "$1" --runner fake01 --runner-user runner --runner-repo "$RGR" \
    --repo "$GR" --run-group "$2" --sha "$GSHA2" --base "$GSHA" --manifest "$3" --receipts "$4" \
    --pr 9 --repo-slug o/r
}

# ── Preflight fail-closed  ──
RPF="$TMP/rcpts-pf"; mkdir -p "$RPF"
SHIM_PREFLIGHT_DIRTY=1 rgs verde rgPF "$MAN_OK" "$RPF" >/dev/null 2>&1
check "preflight SUCIO (credenciales en el runner) → exit 2 SIN ejecutar el gate" 2 $?
[ ! -f "$RPF/journal.jsonl" ] && ok "preflight sucio: nada sellado" || ko "preflight sucio dejó journal"
# El preflight real (lib/preflight.sh) se EJECUTA contra fixtures locales : no greps
# del texto sino la función lg_preflight con PF_HOME_ROOTS re-apuntado a un árbol de prueba.
# shellcheck source=scripts/lib/preflight.sh
. "$MOTOR/scripts/lib/preflight.sh"
PFR="$TMP/pf"
GU="$(id -un)"
seed_clean() { rm -rf "$PFR"; mkdir -p "$PFR/home/gates" "$PFR/home/otro" "$PFR/root" "$PFR/repo"; }
pf() { PF_HOME_ROOTS="$PFR/root $PFR/home/*" lg_preflight "$GU" "$PFR/repo" 2>&1; }
# pf() retorna rc=3 (SUCIO); con pipefail el pipe fallaría — capturar la salida primero.
pfg() { local o; o="$(pf)"; printf '%s' "$o" | grep -q "$1"; }
seed_clean; touch "$PFR/home/otro/.env.local"
pfg "home/otro/.env.local" && ok "preflight EJECUTADO caza .env.local en OTRO home" || { ko "preflight no cazó .env.local en otro home"; pf; }
seed_clean; mkdir -p "$PFR/root/.config/gh"
pfg "root/.config/gh" && ok "preflight EJECUTADO caza ~/.config/gh en /root" || ko "preflight no cazó gh en /root"
seed_clean; : > "$PFR/home/otro/.netrc"; : > "$PFR/home/gates/.git-credentials"
pfg ".netrc" && pfg ".git-credentials" && ok "preflight EJECUTADO caza .netrc y .git-credentials" || ko "preflight no cazó netrc/git-credentials"
seed_clean; : > "$PFR/repo/.env.local"
pfg "repo/.env.local" && ok "preflight EJECUTADO caza .env.local en el clon de gates" || ko "preflight no cazó .env.local del repo"
seed_clean; mkdir -p "$PFR/home/gates/.codex" "$PFR/home/otro/.claude"; : > "$PFR/home/gates/.codex/auth.json"; : > "$PFR/home/otro/.claude/.credentials.json"
pfg "codex/auth.json" && pfg "claude/.credentials.json" && ok "preflight EJECUTADO caza auth de Codex y Claude" || ko "preflight no cazó codex/claude"
seed_clean; mkdir -p "$PFR/home/otro/.coderabbit"; : > "$PFR/home/gates/.claude_token.env"; : > "$PFR/home/otro/.coderabbit/auth.json"
pfg "claude_token.env" && pfg "coderabbit/auth.json" && ok "preflight EJECUTADO caza token Claude y auth del revisor" || ko "preflight no cazó token/revisor"
# LIMPIO real: contenedor sin credenciales y usuario de gates sin sudo (fixture con usuario ficticio
# vía getent falla; se valida el veredicto positivo sembrando cero hallazgos y saltando el check de
# sudo con un usuario cuyo home existe y no está en sudo — usamos 'nobody' si tiene home, si no, se
# omite ese único assert declarándolo).
seed_clean
if getent passwd nobody >/dev/null && ! id -nG nobody 2>/dev/null | tr ' ' '\n' | grep -qx sudo; then
  nh="$(getent passwd nobody | cut -d: -f6)"
  out_clean="$(PF_HOME_ROOTS="$PFR/root $PFR/home/*" lg_preflight nobody "$PFR/repo" 2>&1)"; rc=$?
  case "$out_clean" in *LIMPIO*) [ "$rc" = 0 ] && ok "preflight sobre contenedor LIMPIO → LIMPIO rc 0" || ko "limpio rc=$rc";; *) [ -e "$nh/.config/gh" ] && ok "preflight LIMPIO omitido (nobody trae credenciales reales)" || ko "veredicto LIMPIO inesperado: $out_clean";; esac
else
  ok "preflight LIMPIO: caso positivo cubierto por ausencia de hallazgos (nobody no disponible sin sudo)"
fi
_pf="$(PF_HOME_ROOTS="$PFR/root $PFR/home/*" lg_preflight "usuario-inexistente-xyz" "$PFR/repo" 2>&1)"; rc=$?
[ "$rc" = "3" ] && ok "preflight con usuario inexistente → rc 3" || ko "preflight usuario inexistente rc=$rc"

# ── Camino feliz: repos separados + bundle + uid/gid ──
ROK="$TMP/rcpts-ok"; mkdir -p "$ROK"
rgs verde rgS "$MAN_OK" "$ROK" >/dev/null 2>&1
check "run-gate-sealed (contenedor): gate verde sellado, rc observado propagado" 0 $?
git -C "$RGR" cat-file -e "$GSHA2" 2>/dev/null && ok "el head llegó al runner por BUNDLE (sin credenciales)" || ko "el head no llegó al runner"
grep -q -- "--uid 1001 --gid 1001" "$INCUSLOG" && ok "pushes con --uid/--gid del usuario de gates" || ko "pushes sin uid/gid explícitos"
grep -q "file push .*bundle" "$INCUSLOG" && ok "bundle transferido por incus file push" || ko "sin push de bundle"
rgs db-guards rgS "$MAN_OK" "$ROK" >/dev/null 2>&1
check "run-gate-sealed (contenedor): db-guards SKIP por política sellado" 0 $?
[ "$(wc -l < "$ROK/journal.jsonl")" = "2" ] && ok "journal con 2 entradas selladas" || ko "journal incompleto"
# ── #40: 3er gate del MISMO run_group en el MISMO runner ──
# manifiesto/motor/carveout/envoltorio se nombran SOLO por run_group ⇒ al 2º gate sus destinos ya
# existen y pertenecen al usuario de gates. Con fs.protected_regular ni root los sobrescribe: sin el
# temporal+mv de rpush, `incus file push` da «permission denied» y el gate NI ARRANCA (no hay
# receipt que sellar). El shim simula esa negativa del kernel, asi que este caso ENROJECE sin el fix.
rgs verde rgS "$MAN_OK" "$ROK" >/dev/null 2>&1
check "3er gate del MISMO run_group/runner: destinos por-run_group se sobrescriben (#40)" 0 $?
jq -e 'select(.gate_id=="verde") | (.isolation == "container:fake01") and (.assignment_sha256 | test("^[0-9a-f]{64}$")) and (.motor_sha256 | test("^[0-9a-f]{64}$"))' "$ROK/journal.jsonl" >/dev/null 2>&1 \
  && ok "journal: isolation container + assignment y motor sha256 reales" || ko "journal sin isolation/assignment/motor reales"
seq_ok=1
grep -q "file push .*assignment" "$INCUSLOG" || seq_ok=0
grep -q "file push .*manifest" "$INCUSLOG" || seq_ok=0
grep -q "file push .*run-local-gates" "$INCUSLOG" || seq_ok=0
grep -q "^incus exec fake01" "$INCUSLOG" || seq_ok=0
grep -q "file pull .*receipt" "$INCUSLOG" || seq_ok=0
[ "$seq_ok" = "1" ] && ok "secuencia preflight→push(asig+manifiesto+motor)→exec→pull registrada" || ko "secuencia incus incompleta"
rm -f "$TMP/viewcount"
plg rgS o/r 9 --receipts "$ROK" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "agregación con procedencia sellada (PASS+SKIP) → success exit 0" 0 $?
grep -q "statuses/$GSHA2" "$GHLOG" && ok "POST al SHA correcto con context de test" || ko "POST no registrado"

# ── Camino con FAIL real sellado ──
R3="$TMP/rcpts-3"; mkdir -p "$R3"
for g in verde db-guards; do rgs "$g" rg3 "$MAN3" "$R3" >/dev/null 2>&1; done
rgs rojo rg3 "$MAN3" "$R3" >/dev/null 2>&1
check "run-gate-sealed: gate rojo propaga el exit 1 OBSERVADO y aún así sella" 1 $?
rm -f "$TMP/viewcount"
LG_STATE_EXPECTED=failure plg rg3 o/r 9 --receipts "$R3" --manifest "$MAN3" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "receipt FAIL sellado → postea failure y exit 1" 1 $?

# ── Rechazos fail-closed ──
MAN_DIG_OK="$(sha256sum "$MAN_OK" | cut -d' ' -f1)"
RBAD="$TMP/rcpts-bad"
rm -rf "$RBAD"; cp -r "$ROK" "$RBAD"
jq -n --arg sha "$GSHA2" --arg base "$GSHA" --arg md "$MAN_DIG_OK" '{schema_version:1,repo:"o/r",pr:"9",sha:$sha,base_sha:$base,manifest_digest:$md,base_registry_digest:"n/a",head_registry_digest:"n/a",run_group:"rgS",run_id:"t",gate_id:"verde",result:"PASS",skip_reason:null,started_at:"t",finished_at:"t",log:"/dev/null",assignment:"sealed",runner:"t"}' > "$RBAD/verde.json"
rm -f "$TMP/viewcount"
plg rgS o/r 9 --receipts "$RBAD" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "receipt FABRICADO (sin respaldo del journal) → exit 2" 2 $?

rm -rf "$RBAD"; cp -r "$ROK" "$RBAD"
jq '.result="FAIL"' "$ROK/verde.json" > "$RBAD/verde.json"
rm -f "$TMP/viewcount"
plg rgS o/r 9 --receipts "$RBAD" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "receipt MANIPULADO post-sellado (sha divergente) → exit 2" 2 $?

# --unsafe-local: sella con isolation=station-local → NO agregable (B2)
RUL="$TMP/rcpts-ul"; mkdir -p "$RUL"
bash "$RGS" verde --unsafe-local --repo "$GR" --run-group rgU --sha "$GSHA2" --base "$GSHA" --manifest "$MAN_OK" --receipts "$RUL" --pr 9 --repo-slug o/r >/dev/null 2>&1
check "--unsafe-local corre y sella (diagnóstico)" 0 $?
PATH="$SHIM:$PATH" bash "$RGS" db-guards --runner fake01 --runner-user runner --runner-repo "$RGR" --repo "$GR" --run-group rgU --sha "$GSHA2" --base "$GSHA" --manifest "$MAN_OK" --receipts "$RUL" --pr 9 --repo-slug o/r >/dev/null 2>&1
rm -f "$TMP/viewcount"
plg rgU o/r 9 --receipts "$RUL" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "receipt station-local (--unsafe-local) → RECHAZADO en agregación (exit 2)" 2 $?

# journal apócrifo: assignment placeholder / exit incoherente / motor ausente
RAP="$TMP/rcpts-ap"; rm -rf "$RAP"; cp -r "$ROK" "$RAP"
vsha="$(sha256sum "$RAP/verde.json" | cut -d' ' -f1)"
HEX64="$(printf 'x' | sha256sum | cut -d' ' -f1)"
MOTOR_OK="$(sha256sum "$MOTOR/scripts/run-local-gates.sh" | cut -d' ' -f1)"
CARVEOUT_OK="$(sha256sum "$MOTOR/scripts/lib/carveout.sh" | cut -d' ' -f1)"   # lib de carve-out aprobada
grep -v '"gate_id":"verde"' "$ROK/journal.jsonl" > "$RAP/journal.jsonl"
jq -nc --arg rs "$vsha" --arg m "$MOTOR_OK" '{run_group:"rgS",gate_id:"verde",receipt:"verde.json",receipt_sha256:$rs,exit_code:0,assignment_sha256:"collect",motor_sha256:$m,isolation:"container:fake01",sealed_at:"t"}' >> "$RAP/journal.jsonl"
rm -f "$TMP/viewcount"
plg rgS o/r 9 --receipts "$RAP" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "journal con assignment_sha256 placeholder (no 64-hex) → exit 2" 2 $?
grep -v '"gate_id":"verde"' "$ROK/journal.jsonl" > "$RAP/journal.jsonl"
jq -nc --arg rs "$vsha" --arg a "$HEX64" --arg m "$MOTOR_OK" --arg cv "$CARVEOUT_OK" '{run_group:"rgS",gate_id:"verde",receipt:"verde.json",receipt_sha256:$rs,exit_code:1,assignment_sha256:$a,motor_sha256:$m,carveout_sha256:$cv,isolation:"container:fake01",sealed_at:"t"}' >> "$RAP/journal.jsonl"
rm -f "$TMP/viewcount"
plg rgS o/r 9 --receipts "$RAP" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "result PASS con exit observado 1 (incoherencia) → exit 2" 2 $?
grep -v '"gate_id":"verde"' "$ROK/journal.jsonl" > "$RAP/journal.jsonl"
jq -nc --arg rs "$vsha" --arg a "$HEX64" '{run_group:"rgS",gate_id:"verde",receipt:"verde.json",receipt_sha256:$rs,exit_code:0,assignment_sha256:$a,isolation:"container:fake01",sealed_at:"t"}' >> "$RAP/journal.jsonl"
rm -f "$TMP/viewcount"
plg rgS o/r 9 --receipts "$RAP" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "journal SIN motor_sha256 (motor no atado a la evidencia) → exit 2" 2 $?

# duplicado / faltante / run_group ajeno / multigate / head-flip / context
rm -rf "$RBAD"; cp -r "$ROK" "$RBAD"; cp "$RBAD/verde.json" "$RBAD/verde2.json"
rm -f "$TMP/viewcount"
plg rgS o/r 9 --receipts "$RBAD" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "gate DUPLICADO en el run_group → exit 2" 2 $?

rm -rf "$RBAD"; cp -r "$ROK" "$RBAD"; rm -f "$RBAD/verde.json"
rm -f "$TMP/viewcount"
plg rgS o/r 9 --receipts "$RBAD" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "falta un receipt del inventario → exit 2 (NO se postea)" 2 $?

rm -f "$TMP/viewcount"
plg rgX o/r 9 --receipts "$ROK" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "receipts de run_group AJENO → exit 2" 2 $?

# ── base_tip ANCESTRO (CEO-FREEZE-MERGES-19:04 §3) ──────────────────────────────────────────
# Con el invariante estricto, el merge de UNA estación invalidaba las suites de las otras cuatro.
# Se tolera un base_tip ancestro SOLO si el avance de main es demostrablemente inocuo. Los
# receipts NO se tocan en ninguno de estos casos: lo que cambia es el MUNDO (main avanza), que es
# exactamente lo que pasa en producción. Fabricar el receipt probaría otra cosa.
BT="$TMP/rcpts-basetip"; mkdir -p "$BT"
rgs verde rgBT "$MAN_OK" "$BT" >/dev/null 2>&1
rgs db-guards rgBT "$MAN_OK" "$BT" >/dev/null 2>&1
MAIN0="$(git -C "$GR" rev-parse origin/main)"
bt_reset_main() { git -C "$GR" checkout -q main; git -C "$GR" reset -q --hard "$MAIN0"; git -C "$GR" push -q -f origin main >/dev/null 2>&1; }
bt_plg() { rm -f "$TMP/viewcount"; plg rgBT o/r 9 --receipts "$BT" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test 2>&1; }

rm -f "$TMP/viewcount"
plg rgBT o/r 9 --receipts "$BT" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "base_tip: control con main QUIETO → success exit 0" 0 $?

# (1) CAMINO FELIZ: main avanza tocando un fichero AJENO al PR y a las rutas base-dependientes
bt_reset_main
mkdir -p "$GR/docs"; echo ajeno > "$GR/docs/ajeno-al-pr.md"
git -C "$GR" add -A; git -C "$GR" commit -qm "avance inocuo"; git -C "$GR" push -q origin main >/dev/null 2>&1
BTOUT="$(bt_plg)"; rc=$?
check "base_tip ANCESTRO + avance inocuo → ACEPTA (exit 0)" 0 $rc
[ "$rc" = 0 ] || printf '%s\n' "$BTOUT" | tail -5 | sed 's/^/      (1)>> /'
printf '%s' "$BTOUT" | grep -q "es ANCESTRO de" && ok "el aviso explica por qué se aceptó" || ko "aceptó sin explicar"

# (2) MUTANTE A: el avance de main TOCA un fichero del PR → RECHAZO citando el fichero
bt_reset_main
mkdir -p "$GR/supabase/tests"; echo "colision" >> "$GR/supabase/tests/MANIFEST.md"  # INSUMO de tests-manifest y de db-guards
git -C "$GR" add -A && git -C "$GR" commit -qm "avance que colisiona" >/dev/null || ko "montaje mutante A: commit no creado"
git -C "$GR" push -q origin main >/dev/null 2>&1 || ko "montaje mutante A: push falló"
# GUARD ANTI-MONTAJE-MUDO (misma familia que el del mutante B): si el push no movió main, el churn
# sale VACÍO y el "rechazo" no probaría nada. Bajo carga alta esto pasa de verdad: este mismo caso
# salió rojo una vez y verde la siguiente SIN tocar el código — era el montaje, no el agregador.
_a_churn="$(git -C "$GR" diff --name-only "$(jq -r '.base_tip_sha' "$BT/verde.json" 2>/dev/null)" origin/main 2>/dev/null | grep -c .)"
[ "${_a_churn:-0}" -gt 0 ] || ko "montaje mutante A INERTE: churn vacío (el push no movió main) — el caso no mide nada"
BTOUT="$(bt_plg)"; rc=$?
check "MUTANTE A · avance toca un INSUMO del gate → exit 2" 2 $rc
[ "$rc" = 2 ] || printf '%s\n' "$BTOUT" | tail -5 | sed 's/^/      (A)>> /' 
printf '%s' "$BTOUT" | grep -q "toca un INSUMO de este gate: supabase/tests/MANIFEST.md" && ok "el rechazo CITA el insumo que colisiona" || { ko "rechazó sin citar el insumo"; printf '%s\n' "$BTOUT" | grep -E 'RECHAZO|INSUMO|mapa' | head -4 | sed 's/^/      (A)>> /'; }
printf '%s' "$BTOUT" | grep -q "RE-CORRER SOLO ESTOS GATES" && ok "la salida es ACCIONABLE (lista de gates a re-correr)" || ko "sin lista accionable"

# (3) MUTANTE B, REVISADO POR TAL-6674: main reescrito CON avance IRRELEVANTE → ya NO rechaza.
# Hasta el rebote de TAL-6674, `bt_prepara()` decidía por ANCESTRÍA (`merge-base --is-ancestor`):
# si `main` se reescribía por CUALQUIER motivo, el receipt entero caía, aunque el contenido que de
# verdad importa a los gates no hubiera cambiado un byte. Este MISMO montaje —main reescrito de
# V+W1 a V+W2, dos ficheros AJENOS a cualquier insumo— es EXACTAMENTE ese caso, y por eso este test
# cambia de veredicto EN VOZ ALTA en vez de borrarse: antes de TAL-6674 exigía exit 2 («NO es
# ancestro»); desde TAL-6674 exige exit 0, porque `git merge-tree` funde W1 y W2 sin conflicto
# (son ficheros distintos) y el churn resultante (`docs/w2.md`) no toca ningún insumo declarado.
# Aislarlo cuesta un montaje: si se reescribe main por debajo del punto donde se bifurca el PR,
# el MERGE-BASE cae con él y el agregador muere antes por otra precondición (medido: «no existe
# scripts/github/validar-rama-pr.sh en base …»), con lo que el mutante mediría otra cosa. Montaje
# correcto: main avanza a V+W1, se sellan receipts AHÍ (base_tip = V+W1) y DESPUÉS main se
# reescribe a V+W2. Así V+W1 no es ancestro de V+W2 y el merge-base con el head del PR sigue V.
bt_reset_main
BT2="$TMP/rcpts-basetip2"; rm -rf "$BT2"; mkdir -p "$BT2"
mkdir -p "$GR/docs"; echo w1 > "$GR/docs/w1.md"
git -C "$GR" add -A && git -C "$GR" commit -qm W1 >/dev/null || ko "montaje mutante B: el commit W1 no se creó"
git -C "$GR" push -q origin main >/dev/null 2>&1 || ko "montaje mutante B: push de W1 falló"
rgs verde rgBT2 "$MAN_OK" "$BT2" >/dev/null 2>&1
rgs db-guards rgBT2 "$MAN_OK" "$BT2" >/dev/null 2>&1
git -C "$GR" checkout -q -B bt-divergente "$MAIN0"
mkdir -p "$GR/docs"; echo w2 > "$GR/docs/w2.md"
git -C "$GR" add -A && git -C "$GR" commit -qm W2 >/dev/null || ko "montaje mutante B: el commit W2 no se creó"
git -C "$GR" push -q -f origin bt-divergente:main >/dev/null 2>&1 || ko "montaje mutante B: force-push falló"
git -C "$GR" checkout -q main >/dev/null 2>&1; git -C "$GR" fetch -q origin >/dev/null 2>&1
rm -f "$TMP/viewcount"
# GUARD ANTI-MUTANTE-INERTE: si el tip actual coincide con el base_tip sellado, el montaje no
# divergió y este caso no probaría nada. Se falla el montaje en voz alta.
_bt_tip="$(git -C "$GR" rev-parse origin/main)"; _bt_rec="$(jq -r '.base_tip_sha' "$BT2/verde.json" 2>/dev/null)"
[ "$_bt_tip" != "$_bt_rec" ] || ko "montaje mutante B INERTE: tip actual == base_tip sellado (${_bt_tip:0:7}) — no hay divergencia que medir"
git -C "$GR" merge-base --is-ancestor "$_bt_rec" "$_bt_tip" 2>/dev/null \
  && ko "montaje mutante B INERTE: la ancestría NO se rompió (${_bt_rec:0:7} sigue siendo ancestro de ${_bt_tip:0:7})" \
  || ok "PRECONDICIÓN: la ancestría SÍ se rompió (main reescrito de verdad)"
BTOUT="$(plg rgBT2 o/r 9 --receipts "$BT2" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test 2>&1)"; rc=$?
check "MUTANTE B (TAL-6674) · main reescrito + avance IRRELEVANTE → ACEPTA (exit 0)" 0 $rc
[ "$rc" = 0 ] || printf '%s\n' "$BTOUT" | tail -6 | sed 's/^/      (B)>> /'
printf '%s' "$BTOUT" | grep -q "NO es ancestro" && ko "sigue rechazando por ancestría — el parche TAL-6674 no está activo" || ok "ya NO decide por ancestría"
git -C "$GR" branch -qD bt-divergente 2>/dev/null || true

# (3b) MUTANTE B2: main reescrito Y el avance SÍ toca un insumo → sigue RECHAZANDO.
# El (3) de arriba prueba que la ruptura de ancestría por sí sola dejó de bastar; este prueba que
# eso NO es una barra libre: si el contenido que de verdad importa cambió —da igual por qué línea
# de la historia—, el receipt cae igual que antes. Mismo montaje que (3), pero W1 Y W2 tocan el
# MISMO insumo (`supabase/tests/MANIFEST.md`, de `verde` y `db-guards`) con contenido distinto.
bt_reset_main
BT2B="$TMP/rcpts-basetip2b"; rm -rf "$BT2B"; mkdir -p "$BT2B"
mkdir -p "$GR/supabase/tests"; echo "version-W1" > "$GR/supabase/tests/MANIFEST.md"
git -C "$GR" add -A && git -C "$GR" commit -qm W1B >/dev/null || ko "montaje mutante B2: el commit W1B no se creó"
git -C "$GR" push -q origin main >/dev/null 2>&1 || ko "montaje mutante B2: push de W1B falló"
rgs verde rgBT2B "$MAN_OK" "$BT2B" >/dev/null 2>&1
rgs db-guards rgBT2B "$MAN_OK" "$BT2B" >/dev/null 2>&1
git -C "$GR" checkout -q -B bt-divergente-b "$MAIN0"
mkdir -p "$GR/supabase/tests"; echo "version-W2" > "$GR/supabase/tests/MANIFEST.md"
git -C "$GR" add -A && git -C "$GR" commit -qm W2B >/dev/null || ko "montaje mutante B2: el commit W2B no se creó"
git -C "$GR" push -q -f origin bt-divergente-b:main >/dev/null 2>&1 || ko "montaje mutante B2: force-push falló"
git -C "$GR" checkout -q main >/dev/null 2>&1; git -C "$GR" fetch -q origin >/dev/null 2>&1
rm -f "$TMP/viewcount"
_bt_tip2="$(git -C "$GR" rev-parse origin/main)"; _bt_rec2="$(jq -r '.base_tip_sha' "$BT2B/verde.json" 2>/dev/null)"
[ "$_bt_tip2" != "$_bt_rec2" ] || ko "montaje mutante B2 INERTE: tip actual == base_tip sellado — no hay divergencia que medir"
BTOUT2B="$(plg rgBT2B o/r 9 --receipts "$BT2B" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test 2>&1)"; rc=$?
check "MUTANTE B2 (TAL-6674) · main reescrito + avance TOCA un insumo → RECHAZA (exit 2)" 2 $rc
[ "$rc" = 2 ] || printf '%s\n' "$BTOUT2B" | tail -6 | sed 's/^/      (B2)>> /'
printf '%s' "$BTOUT2B" | grep -q "INSUMO" && ok "el rechazo sigue citando el insumo, no la ancestría" || ko "no citó ningún insumo"
git -C "$GR" branch -qD bt-divergente-b 2>/dev/null || true

# (4) ruta BASE-DEPENDIENTE: aunque no colisione con el PR, invalida la corrida
bt_reset_main
mkdir -p "$GR/supabase/migrations"; echo "select 1;" > "$GR/supabase/migrations/999_x.sql"
git -C "$GR" add -A; git -C "$GR" commit -qm "avance en supabase"; git -C "$GR" push -q origin main >/dev/null 2>&1
BTOUT="$(bt_plg)"; rc=$?
check "avance en supabase/ invalida db-guards (insumo) → exit 2" 2 $rc
printf '%s' "$BTOUT" | grep -q "INSUMO de este gate: supabase/" && ok "cita el insumo supabase/ del gate afectado" || ko "no citó el insumo"

# (5) SELECTIVIDAD: el avance toca un insumo de db-guards (supabase/) pero NINGUNO de `verde`
# (^src/, ^scripts/x.sh). Debe caer SOLO db-guards y decirlo; `verde` no aparece en la lista.
bt_reset_main
mkdir -p "$GR/supabase/migrations"; echo "select 2;" > "$GR/supabase/migrations/998_y.sql"
git -C "$GR" add -A && git -C "$GR" commit -qm "solo supabase" >/dev/null
git -C "$GR" push -q origin main >/dev/null 2>&1
BTOUT="$(bt_plg)"; rc=$?
check "SELECTIVIDAD · solo el gate afectado cae → exit 2" 2 $rc
printf '%s' "$BTOUT" | grep -q "db-guards): el avance" && ok "nombra db-guards como invalidado" || ko "no nombró db-guards"
printf '%s' "$BTOUT" | grep -q "verde): el avance" && ko "invalidó \`verde\`, que no comparte insumos" || ok "\`verde\` se CONSERVA (no comparte insumos)"

# (5b) FAIL-OPEN de M2: `$val` sin `set -f` sufre pathname expansion. Desde un árbol con
# `supabase/`, el glob `supabase/**` se expande al DIRECTORIO real y la ERE queda
# `^supabase/migrations$`, que NO casa con `supabase/migrations/x.sql` ⇒ ningún insumo casaría y
# TODOS los receipts rancios se conservarían. El caso corre con CWD DENTRO de ese árbol: sin el
# arreglo, ENROJECE.
FANOUT="$TMP/fanout"; mkdir -p "$FANOUT/supabase/migrations" "$FANOUT/src/lib" "$FANOUT/tests/e2e"
( cd "$FANOUT" && . "$MOTOR/scripts/lib/insumos-por-gate.sh" 2>/dev/null
  echo "supabase/migrations/x.sql" | grep -qE -f <(insumos_de_gate db-guards) ) \
  && ok "insumos_de_gate NO sufre pathname expansion con CWD en un árbol con supabase/ (M2)" \
  || ko "FAIL-OPEN: el glob se expandió y la ERE dejó de casar"
( cd "$FANOUT" && . "$MOTOR/scripts/lib/insumos-por-gate.sh" 2>/dev/null
  echo "src/lib/a.ts" | grep -qE -f <(insumos_de_gate unit) ) \
  && ok "idem para src/** en el gate unit" || ko "FAIL-OPEN en src/** (unit)"
# y que no le dejamos `noglob` puesto al llamante
( set +f; . "$MOTOR/scripts/lib/insumos-por-gate.sh" 2>/dev/null; insumos_de_gate unit >/dev/null
  case $- in *f*) exit 1;; *) exit 0;; esac ) \
  && ok "el mapa restaura el estado de globbing del llamante" || ko "dejó noglob puesto al llamante"

# (6) gate SIN entrada en el mapa → invalido fail-closed
bt_reset_main
mkdir -p "$GR/docs"; echo z > "$GR/docs/z.md"; git -C "$GR" add -A && git -C "$GR" commit -qm z >/dev/null
git -C "$GR" push -q origin main >/dev/null 2>&1
BTOUT="$(LG_INSUMOS_OVERRIDE=/dev/null plg rgBT o/r 9 --receipts "$BT" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test 2>&1)"; rc=$?
check "mapa de insumos vacío (sin insumos_de_gate) → rechazo fail-closed" 2 $rc
rm -f "$TMP/viewcount"
LG_INSUMOS_OVERRIDE="$TMP/no-existe-mapa.sh" plg rgBT o/r 9 --receipts "$BT" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "mapa de insumos INEXISTENTE → rechazo fail-closed" 2 $?
# INSUMO UNIVERSAL: caducan TODOS los receipts, no solo los del gate
bt_reset_main
echo '{}' > "$GR/package.json"; git -C "$GR" add -A && git -C "$GR" commit -qm universal >/dev/null
git -C "$GR" push -q origin main >/dev/null 2>&1
BTOUT="$(bt_plg)"; rc=$?
check "INSUMO UNIVERSAL (package.json) → caducan TODOS → exit 2" 2 $rc
printf '%s' "$BTOUT" | grep -q "INSUMO UNIVERSAL" && ok "cita el insumo universal" || ko "no citó el universal"

bt_reset_main

rm -rf "$RBAD"; cp -r "$ROK" "$RBAD"
jq '. + {gates:["a","b"]}' "$ROK/verde.json" > "$RBAD/verde.json"
mg_sha="$(sha256sum "$RBAD/verde.json" | cut -d' ' -f1)"
jq -nc --arg rs "$mg_sha" --arg a "$HEX64" --arg m "$MOTOR_OK" '{run_group:"rgS",gate_id:"verde",receipt:"verde.json",receipt_sha256:$rs,exit_code:0,assignment_sha256:$a,motor_sha256:$m,isolation:"container:fake01",sealed_at:"t"}' >> "$RBAD/journal.jsonl"
rm -f "$TMP/viewcount"
plg rgS o/r 9 --receipts "$RBAD" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "receipt MULTIGATE → exit 2" 2 $?

rm -f "$TMP/viewcount"; touch "$TMP/flip-head"
plg rgS o/r 9 --receipts "$ROK" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "head cambia durante la corrida → exit 2 (receipts invalidados)" 2 $?
rm -f "$TMP/flip-head"

rm -f "$TMP/viewcount"
plg rgS o/r 9 --receipts "$ROK" --manifest "$MAN_OK" --repo "$GR" --context bogus >/dev/null 2>&1
check "--context fuera de local-gates|local-gates-test → exit 2" 2 $?

# motor divergente: journal con motor_sha256 hex valido pero NO aprobado → rechazo
grep -v '"gate_id":"verde"' "$ROK/journal.jsonl" > "$RAP/journal.jsonl"
jq -nc --arg rs "$vsha" --arg a "$HEX64" --arg m "$HEX64" '{run_group:"rgS",gate_id:"verde",receipt:"verde.json",receipt_sha256:$rs,exit_code:0,assignment_sha256:$a,motor_sha256:$m,isolation:"container:fake01",sealed_at:"t"}' >> "$RAP/journal.jsonl"
rm -f "$TMP/viewcount"
plg rgS o/r 9 --receipts "$RAP" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "journal con motor NO aprobado por la estacion → exit 2" 2 $?

# manifiesto fuera del directorio confiable (sin LG_MANIFEST_DIR) → rechazo
rm -f "$TMP/viewcount"
PATH="$SHIM:$PATH" bash "$PLG" rgS o/r 9 --receipts "$ROK" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "--manifest fuera del directorio confiable del motor → exit 2" 2 $?

# manifiesto con codigo embebido (fuera de la gramatica cerrada) → la estacion NO lo ejecuta
MAN_EVIL="$TMP/evil.conf"; cat "$MAN_OK" > "$MAN_EVIL"
printf 'TF_MALIGNO="$(touch %s/pwned)"\n' "$TMP" >> "$MAN_EVIL"
rm -f "$TMP/viewcount"
plg rgS o/r 9 --receipts "$ROK" --manifest "$MAN_EVIL" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "manifiesto con codigo embebido → exit 2 (gramatica cerrada)" 2 $?
[ ! -e "$TMP/pwned" ] && ok "el codigo embebido NO se ejecuto en la estacion" || ko "la estacion ejecuto codigo del manifiesto"

# concurrencia : 3 gates del MISMO run_group sellando en paralelo → journal integro
RCON="$TMP/rcpts-con"; mkdir -p "$RCON"
rgs verde rgC "$MAN3" "$RCON" >/dev/null 2>&1 &
rgs db-guards rgC "$MAN3" "$RCON" >/dev/null 2>&1 &
rgs rojo rgC "$MAN3" "$RCON" >/dev/null 2>&1 &
wait
[ "$(wc -l < "$RCON/journal.jsonl")" = "3" ] && ok "3 sellados concurrentes → 3 entradas de journal" || ko "journal con $(wc -l < "$RCON/journal.jsonl") lineas (esperaba 3)"
jok=1; while IFS= read -r l; do jq -e . >/dev/null 2>&1 <<<"$l" || jok=0; done < "$RCON/journal.jsonl"
[ "$jok" = "1" ] && ok "entradas concurrentes: JSON valido (flock del journal)" || ko "journal corrupto bajo concurrencia"
rm -f "$TMP/viewcount"
LG_STATE_EXPECTED=failure plg rgC o/r 9 --receipts "$RCON" --manifest "$MAN3" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "agregacion del run_group concurrente (con FAIL real) → failure exit 1" 1 $?

# avance de la rama base durante la corrida : tip cambia, merge-base NO → invalida
GRADV="$TMP/gr-adv"
git clone -q "$GRB" "$GRADV" && git -C "$GRADV" config user.email t@t && git -C "$GRADV" config user.name t
{ echo '#!/usr/bin/env bash'; echo "cd '$GRADV' && git commit -q --allow-empty -m avance && git push -q origin main"; } > "$TMP/advance-base.sh"
chmod +x "$TMP/advance-base.sh"
touch "$TMP/advance-base"
rm -f "$TMP/viewcount"
plg rgS o/r 9 --receipts "$ROK" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "la base AVANZA mid-run (merge-base intacto) → exit 2 (receipts invalidados)" 2 $?
rm -f "$TMP/advance-base"

# manifiesto SYMLINK dentro del dir confiable → rechazo
ln -sf "$MAN_EVIL" "$TMP/link.conf"
rm -f "$TMP/viewcount"
plg rgS o/r 9 --receipts "$ROK" --manifest "$TMP/link.conf" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "manifiesto SYMLINK → exit 2" 2 $?

# base_tip sellado: si la base avanzo ANTES de agregar, el receipt lo delata
RBT="$TMP/rcpts-bt"; rm -rf "$RBT"; cp -r "$ROK" "$RBT"
jq '.base_tip_sha="0000000000000000000000000000000000000000"' "$ROK/verde.json" > "$RBT/verde.json"
bt_sha="$(sha256sum "$RBT/verde.json" | cut -d' ' -f1)"
grep -v '"gate_id":"verde"' "$ROK/journal.jsonl" > "$RBT/journal.jsonl"
jq -nc --arg rs "$bt_sha" --arg a "$HEX64" --arg m "$MOTOR_OK" --arg cv "$CARVEOUT_OK" '{run_group:"rgS",gate_id:"verde",receipt:"verde.json",receipt_sha256:$rs,exit_code:0,assignment_sha256:$a,motor_sha256:$m,carveout_sha256:$cv,isolation:"container:fake01",sealed_at:"t"}' >> "$RBT/journal.jsonl"
rm -f "$TMP/viewcount"
plg rgS o/r 9 --receipts "$RBT" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "receipt con base_tip_sha divergente del tip actual → exit 2" 2 $?
jq -e '.base_tip_sha | test("^[0-9a-f]{40}$")' "$ROK/verde.json" >/dev/null 2>&1 && ok "el receipt real lleva base_tip_sha sellado" || ko "receipt sin base_tip_sha"

# TF_ENV_COPY en modo sealed → prohibido (B1)
MAN_ENV="$TMP/env.conf"; cat "$MAN_OK" > "$MAN_ENV"; echo 'TF_ENV_COPY=".env.local"' >> "$MAN_ENV"
RENV="$TMP/rcpts-env"; mkdir -p "$RENV"
PATH="$SHIM:$PATH" bash "$RGS" verde --runner fake01 --runner-user runner --runner-repo "$RGR" --repo "$GR" --run-group rgE --sha "$GSHA2" --base "$GSHA" --manifest "$MAN_ENV" --receipts "$RENV" --pr 9 --repo-slug o/r >/dev/null 2>&1
check "TF_ENV_COPY con asignación SEALED → exit 2 (aislamiento del runner, B1)" 2 $?
bash "$MOTOR/scripts/run-local-gates.sh" "$GR" --gate verde --manifest "$MAN_ENV" --sha "$GSHA2" --base "$GSHA" --receipt "$TMP/env-inline.json" >/dev/null 2>&1
check "TF_ENV_COPY en modo inline (trabajo propio) → permitido" 0 $?


echo "== anti-reducción del registro de shards (base = mínimo confiable) =="
# Repo PROPIO: base (main) con 2 shards → head REDUCE a 1 → el agregador falla ANTES del POST.
RGR2="$TMP/reg-repo"; RGR2B="$TMP/reg-repo.git"
mk_repo "$RGR2"
mkdir -p "$RGR2/scripts/ci" "$RGR2/scripts/github"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RGR2/scripts/github/validar-rama-pr.sh"
printf '{"schema_version":1,"families":{"fam":{"shards":[{"id":"s1","specs":["a"]},{"id":"s2","specs":["b"]}]}}}\n' > "$RGR2/scripts/ci/e2e-shards.json"
git -C "$RGR2" add -A && git -C "$RGR2" commit -qm registro2
git clone -q --bare "$RGR2" "$RGR2B"; git -C "$RGR2" remote add origin "$RGR2B"; git -C "$RGR2" fetch -q origin
printf '{"schema_version":1,"families":{"fam":{"shards":[{"id":"s1","specs":["a"]}]}}}\n' > "$RGR2/scripts/ci/e2e-shards.json"
git -C "$RGR2" commit -qam reduccion
RSHA="$(git -C "$RGR2" rev-parse HEAD)"
MAN_REG="$TMP/reg.conf"
cat "$MAN" > "$MAN_REG"
cat >> "$MAN_REG" <<'EOF'
TF_E2E_FAMILIES="fam"
TF_E2E_WRAPPER="true"
TF_SHARDS_REGISTRY="scripts/ci/e2e-shards.json"
EOF
mkshim2() { # <sha>
  cat > "$SHIM2/gh" <<SHIM2EOF
#!/usr/bin/env bash
case "\$*" in
  *"pr view"*) printf '{"headRefOid":"%s","headRefName":"feat/x","baseRefName":"main","author":{"login":"dev"}}\n' "$1" ;;
  *"-X POST"*) echo '{}' ;;
  *"/status"*) echo success ;;
esac
SHIM2EOF
  chmod +x "$SHIM2/gh"
  cerrar_doble_gh "$SHIM2/gh" || exit 1
}
SHIM2="$TMP/shim2"; mkdir -p "$SHIM2"; mkshim2 "$RSHA"
RREG="$TMP/rcpts-reg"; mkdir -p "$RREG"; : > "$RREG/journal.jsonl"
preg() { PATH="$SHIM2:$PATH" LG_MANIFEST_DIR="$TMP" "$@" bash "$PLG" rg2 o/r 9 --receipts "$RREG" --manifest "$MAN_REG" --repo "$RGR2" --context local-gates-test 2>&1; }

out_red="$(preg env)"; rc=$?
check "reducción de SHARDS sin ratificación durable → exit 2" 2 "$rc"
printf '%s' "$out_red" | grep -q "REDUCE el registro" && ok "diagnóstico de reducción de shards" || ko "sin diagnóstico de reducción"
out_red="$(preg env TF_ALLOW_REGISTRY_REDUCTION=1)"; rc=$?
check "TF_ALLOW_REGISTRY_REDUCTION=1 (env efímera) ya NO ratifica → exit 2" 2 "$rc"

# Ratificación DURABLE: log versionado append-only en el head, con ref= y el shard nombrado.
printf '%s | ref=TAL-TEST-REG | items=fam:s2 | retiro planificado\n' "$(date -u +%F)" > "$RGR2/scripts/ci/REGISTRY-RATIFICACIONES.log"
git -C "$RGR2" add -A && git -C "$RGR2" commit -qm ratifica-registro
RSHA_R="$(git -C "$RGR2" rev-parse HEAD)"; mkshim2 "$RSHA_R"
out_red="$(preg env)"
printf '%s' "$out_red" | grep -q "RATIFICADA en" && ok "reducción con ratificación DURABLE pasa el check del registro" || { ko "la ratificación durable no fue reconocida"; printf '%s\n' "$out_red" | head -3; }

# ratificación con TOKEN PARCIAL — fixture INDEPENDIENTE desde RSHA (reducción SIN ratificación
# previa): el ÚNICO contenido del log es items=fam:s20, que NO cubre fam:s2 → rechazo específico.
git -C "$RGR2" reset -q --hard "$RSHA"
printf '%s | ref=TAL-X | items=fam:s20 | otra cosa\n' "$(date -u +%F)" > "$RGR2/scripts/ci/REGISTRY-RATIFICACIONES.log"
git -C "$RGR2" add -A && git -C "$RGR2" commit -qm rat-token-parcial
mkshim2 "$(git -C "$RGR2" rev-parse HEAD)"
out_red="$(preg env)"; rc=$?
check "ratificación con token PARCIAL (fam:s20 no cubre fam:s2) → exit 2" 2 "$rc"
printf '%s' "$out_red" | grep -q "no ratifica 'fam:s2'" && ok "el rechazo es por token no coincidente (no por falta de receipts)" || { ko "rechazo por motivo equivocado"; printf '%s\n' "$out_red" | tail -2; }
# ratificación SIN campo items= (ref= suelto) — fixture INDEPENDIENTE, log añadido con add -A.
git -C "$RGR2" reset -q --hard "$RSHA"
printf '%s | ref=TAL-Y | sin items | x\n' "$(date -u +%F)" > "$RGR2/scripts/ci/REGISTRY-RATIFICACIONES.log"
git -C "$RGR2" add -A && git -C "$RGR2" commit -qm rat-sin-items
mkshim2 "$(git -C "$RGR2" rev-parse HEAD)"
out_red="$(preg env)"; rc=$?
check "ratificación sin campo items= → exit 2" 2 "$rc"
printf '%s' "$out_red" | grep -q "no ratifica 'fam:s2'" && ok "el rechazo es por items= ausente (log SÍ existe y committeado)" || { ko "rechazo por motivo equivocado (¿log untracked?)"; printf '%s\n' "$out_red" | tail -2; }

# PR SIN reducción que REESCRIBE el registry-log → exit 2 (append-only en TODO PR).
git -C "$RGR2" reset -q --hard "$RSHA_R"
# volver e2e-shards.json al estado de base (2 shards) → este PR NO reduce
printf '{"schema_version":1,"families":{"fam":{"shards":[{"id":"s1","specs":["a"]},{"id":"s2","specs":["b"]}]}}}\n' > "$RGR2/scripts/ci/e2e-shards.json"
sed -i 's/TAL-TEST-REG/TAL-FALSO/' "$RGR2/scripts/ci/REGISTRY-RATIFICACIONES.log"
git -C "$RGR2" commit -qam pr-sin-reduccion-reescribe-log
mkshim2 "$(git -C "$RGR2" rev-parse HEAD)"
RREG2="$TMP/rcpts-reg2"; mkdir -p "$RREG2"; : > "$RREG2/journal.jsonl"
PATH="$SHIM2:$PATH" LG_MANIFEST_DIR="$TMP" bash "$PLG" rg2b o/r 9 --receipts "$RREG2" --manifest "$MAN_REG" --repo "$RGR2" --context local-gates-test >/dev/null 2>&1
check "PR SIN reducción que REESCRIBE el registry-log → exit 2 (append-only en todo PR)" 2 $?
# PR SIN reducción que BORRA el registry-log → exit 2
git -C "$RGR2" reset -q --hard "$RSHA_R"
printf '{"schema_version":1,"families":{"fam":{"shards":[{"id":"s1","specs":["a"]},{"id":"s2","specs":["b"]}]}}}\n' > "$RGR2/scripts/ci/e2e-shards.json"
git -C "$RGR2" rm -q scripts/ci/REGISTRY-RATIFICACIONES.log && git -C "$RGR2" commit -qam borra-registry-log
mkshim2 "$(git -C "$RGR2" rev-parse HEAD)"
: > "$RREG2/journal.jsonl"
PATH="$SHIM2:$PATH" LG_MANIFEST_DIR="$TMP" bash "$PLG" rg2c o/r 9 --receipts "$RREG2" --manifest "$MAN_REG" --repo "$RGR2" --context local-gates-test >/dev/null 2>&1
check "PR SIN reducción que BORRA el registry-log → exit 2" 2 $?
git -C "$RGR2" reset -q --hard "$RSHA_R"

# B3: reducción a nivel de SPEC — el shard conserva su id pero pierde un spec → mismo NO-GO.
# Repo PROPIO (aislado de las mutaciones de $GR en las secciones anteriores).
SGR="$TMP/spec-repo"; SGRB="$TMP/spec-repo.git"
mk_repo "$SGR"
mkdir -p "$SGR/scripts/ci" "$SGR/scripts/github"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SGR/scripts/github/validar-rama-pr.sh"
printf '{"schema_version":1,"families":{"fam":{"shards":[{"id":"s1","specs":["a","a2"]},{"id":"s2","specs":["b"]}]}}}\n' > "$SGR/scripts/ci/e2e-shards.json"
git -C "$SGR" add -A && git -C "$SGR" commit -qm registro-specs
git clone -q --bare "$SGR" "$SGRB"; git -C "$SGR" remote add origin "$SGRB"; git -C "$SGR" fetch -q origin
printf '{"schema_version":1,"families":{"fam":{"shards":[{"id":"s1","specs":["a"]},{"id":"s2","specs":["b"]}]}}}\n' > "$SGR/scripts/ci/e2e-shards.json"
git -C "$SGR" commit -qam reduccion-spec
SSHA="$(git -C "$SGR" rev-parse HEAD)"
SHIM3="$TMP/shim3"; mkdir -p "$SHIM3"
cat > "$SHIM3/gh" <<SHIM3EOF
#!/usr/bin/env bash
case "\$*" in
  *"pr view"*) printf '{"headRefOid":"%s","headRefName":"feat/x","baseRefName":"main","author":{"login":"dev"}}\n' "$SSHA" ;;
  *"-X POST"*) echo '{}' ;;
  *"/status"*) echo success ;;
esac
SHIM3EOF
chmod +x "$SHIM3/gh"
cerrar_doble_gh "$SHIM3/gh" || exit 1
out_spec="$(PATH="$SHIM3:$PATH" LG_MANIFEST_DIR="$TMP" bash "$PLG" rg3s o/r 9 --receipts "$RREG" --manifest "$MAN_REG" --repo "$SGR" --context local-gates-test 2>&1)"; rc=$?
check "reducción de SPECS dentro de un shard (id intacto) → exit 2" 2 "$rc"
printf '%s' "$out_spec" | grep -q "fam:s1:a2" && ok "el diagnóstico nombra el spec reducido" || { ko "diagnóstico sin el spec reducido"; printf '%s\n' "$out_spec" | tail -2; }
# restaurar main del fixture principal
git -C "$GR" reset -q --hard origin/main

# ══════════════════════════════════════════════════════════════════════════════════════════════
# TAL-2749: carve-out fail-closed docs-only/skills-only
# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "== TAL-2749: carve-out — clasificador (lib REAL, M4 ) =="
# shellcheck source=scripts/lib/carveout.sh
. "$MOTOR/scripts/lib/carveout.sh"
TF_CARVEOUT_PATHS="docs/ .claude/skills/"
CO="$TMP/co-unit"; git init -q -b main "$CO"; git -C "$CO" config user.email t@t; git -C "$CO" config user.name t
mkdir -p "$CO/docs" "$CO/.claude/skills/s" "$CO/src"
echo base > "$CO/docs/index.md"; git -C "$CO" add -A; git -C "$CO" commit -qm base
COB="$(git -C "$CO" rev-parse HEAD)"
co_case() { local rc; carveout_docs_only "$CO" "$COB" "$(git -C "$CO" rev-parse HEAD)"; rc=$?; check "$1" "$2" "$rc"; }
git -C "$CO" checkout -q -b c1 "$COB"; mkdir -p "$CO/docs/api"; echo a >> "$CO/docs/index.md"; echo b > "$CO/docs/api/README.md"; echo c > "$CO/.claude/skills/s/g.md"; git -C "$CO" add -A; git -C "$CO" commit -qm docsonly
co_case "docs-only (A+M anidado + skills .md) → 0" 0
git -C "$CO" checkout -q -b c2 "$COB"; echo a >> "$CO/docs/index.md"; echo x > "$CO/src/app.ts"; git -C "$CO" add -A; git -C "$CO" commit -qm mixto
co_case "mixto docs+código → 1 (suite completa)" 1
git -C "$CO" checkout -q -b c3 "$COB"; mkdir -p "$CO/.claude/skills/s/scripts"; echo x > "$CO/.claude/skills/s/scripts/d.sh"; git -C "$CO" add -A; git -C "$CO" commit -qm sksh
co_case "scripts/ de skills (.sh, no .md) → 1" 1
git -C "$CO" checkout -q -b c4 "$COB"; echo '{}' > "$CO/docs/data.json"; git -C "$CO" add -A; git -C "$CO" commit -qm dj
co_case "docs/data.json (no .md) → 1" 1
git -C "$CO" checkout -q -b c5 "$COB"; git -C "$CO" commit -q --allow-empty -m vacio
co_case "diff vacío → 1 (fail-closed)" 1
git -C "$CO" checkout -q -b c6 "$COB"; git -C "$CO" mv docs/index.md docs/index2.md; git -C "$CO" commit -qm rename
co_case "rename de un doc → 1 (fail-closed)" 1
git -C "$CO" checkout -q -b c7 "$COB"; echo x > "$CO/docs/R.MD"; git -C "$CO" add -A; git -C "$CO" commit -qm upper
co_case ".MD mayúscula (case-sensitive) → 1" 1
git -C "$CO" checkout -q -b c8 "$COB"; echo x > "$CO/docs/a.mdx"; git -C "$CO" add -A; git -C "$CO" commit -qm mdx
co_case ".mdx → 1" 1
git -C "$CO" checkout -q -b c9 "$COB"; ln -s index.md "$CO/docs/l.md"; git -C "$CO" add -A; git -C "$CO" commit -qm symlink
co_case "symlink .md (modo 120000) → 1 (fail-closed)" 1
git -C "$CO" checkout -q -b c10 "$COB"; git -C "$CO" rm -q docs/index.md; mkdir -p "$CO/docs"; echo y > "$CO/docs/o.md"; git -C "$CO" add -A; git -C "$CO" commit -qm deladd
co_case "delete+add de docs → 0" 0
carveout_gate_skippable typecheck "tenant markdownlint" && ok "gate_skippable: typecheck elegible (∉ keep)" || ko "typecheck debería ser elegible"
carveout_gate_skippable tenant "tenant markdownlint" && ko "tenant NO debería ser elegible (survivor)" || ok "gate_skippable: tenant survivor (∈ keep)"

echo "== TAL-2749: carve-out — digest no-carveout (autoridad conservadora, auditoría código ) =="
# Auditoría de código : excluir el prefijo COMPLETO (cualquier
# extensión) del digest era demasiado ancho — el clasificador solo permite CAMBIAR .md, pero un
# script NO-md dentro de .claude/skills/ (consumidor real) quedaba invisible al
# digest. El conjunto excluido debe ser EXACTAMENTE lo que el clasificador permite tocar sin correr
# la suite: .md bajo un prefijo permitido. Todo lo demás bajo esos prefijos (scripts, json, …) debe
# invalidar el digest si cambia.
TF_CARVEOUT_PATHS="docs/ .claude/skills/"
D0="$(carveout_noncarveout_digest "$CO" "$COB")"
[ -n "$D0" ] && ok "digest base calculado" || ko "digest base vacío"
git -C "$CO" checkout -q -b dg1 "$COB"; echo cambio >> "$CO/docs/index.md"; git -C "$CO" add -A; git -C "$CO" commit -qm dg1
D1="$(carveout_noncarveout_digest "$CO" "$(git -C "$CO" rev-parse HEAD)")"
[ "$D0" = "$D1" ] && ok "cambio SOLO en .md bajo docs/ → digest SIN cambios (fast-path se preserva)" || ko "digest cambió por un .md (demasiado estricto)"
git -C "$CO" checkout -q -b dg2 "$COB"; mkdir -p "$CO/.claude/skills/s/scripts"; echo x > "$CO/.claude/skills/s/scripts/d.sh"; git -C "$CO" add -A; git -C "$CO" commit -qm dg2
D2="$(carveout_noncarveout_digest "$CO" "$(git -C "$CO" rev-parse HEAD)")"
[ "$D0" != "$D2" ] && ok "cambio en .sh DENTRO de .claude/skills/ → digest CAMBIA (regresión corregida)" || ko "regresión: script no-md dentro de skills invisible al digest"
git -C "$CO" checkout -q -b dg3 "$COB"; mkdir -p "$CO/src"; echo x > "$CO/src/app.ts"; git -C "$CO" add -A; git -C "$CO" commit -qm dg3
D3="$(carveout_noncarveout_digest "$CO" "$(git -C "$CO" rev-parse HEAD)")"
[ "$D0" != "$D3" ] && ok "cambio fuera de docs/skills (src/app.ts) → digest CAMBIA" || ko "digest no detectó cambio fuera del carve-out"
carveout_noncarveout_digest "$CO" "0000000000000000000000000000000000000000" >/dev/null 2>&1
check "digest: sha inexistente → fail-closed (rc 1)" 1 $?
unset TF_CARVEOUT_PATHS

echo "== TAL-2749: carve-out — fallo PARCIAL de git diff (exit code decisivo) =="
GSHIM="$TMP/gitshim"; mkdir -p "$GSHIM"
# git shim: `cat-file -e` siempre OK (pasa los guards); `diff` emite un registro --raw -z 100% docs
# y luego SALE con LG_SHIM_DIFF_RC (default 1) — simula un git que streamea salida parcial y falla.
cat > "$GSHIM/git" <<'GITEOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in
  cat-file) exit 0 ;;
  diff) printf ':100644 100644 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 M\0docs/guia.md\0'; exit "${LG_SHIM_DIFF_RC:-1}" ;;
esac; done
exit 0
GITEOF
chmod +x "$GSHIM/git"
( PATH="$GSHIM:$PATH"; export TF_CARVEOUT_PATHS="docs/ .claude/skills/"; carveout_docs_only /x b h ); rc=$?
check "git diff FALLA con salida PARCIAL 100% docs (rc≠0) → 1 (fail-closed, no fast-path)" 1 "$rc"
( PATH="$GSHIM:$PATH"; export TF_CARVEOUT_PATHS="docs/ .claude/skills/" LG_SHIM_DIFF_RC=0; carveout_docs_only /x b h ); rc=$?
check "CONTROL: MISMO output con git EXIT 0 → 0 (docs-only) — el exit code es lo decisivo " 0 "$rc"

echo "== TAL-2749: carve-out — pipeline SELLADO docs-only (transporte de la lib + agregador) =="
MAN_CO="$TMP/co.conf"
# Autoridad conservadora: digest del árbol no-carveout
# EN GSHA (la base que usarán estos runs), ratificado en el fixture — mismo cómputo que hará el
# agregador al recomputar sobre BASE_SHA.
CO_DIGEST="$(TF_CARVEOUT_PATHS="docs/ .claude/skills/" carveout_noncarveout_digest "$GR" "$GSHA")"
printf 'TF_PROJECT="test"\nTF_GATE_IDS="verde tenant"\nTF_GATE_CMD_verde="true"\nTF_GATE_CMD_tenant="true"\nTF_INSTALL="true"\nTF_DB_GATE="never"\nTF_BRANCH_VALIDATOR="scripts/github/validar-rama-pr.sh"\nTF_CARVEOUT_DOCS_ONLY="1"\nTF_CARVEOUT_KEEP_GATES="tenant"\nTF_CARVEOUT_PATHS="docs/ .claude/skills/"\nTF_CARVEOUT_INERT_DIGEST="%s"\nTF_CARVEOUT_INERT_DIGEST_SHA="%s"\n' "$CO_DIGEST" "$GSHA" > "$MAN_CO"
# head DOCS-ONLY sobre la base (origin/main = GSHA): solo docs/*.md
git -C "$GR" checkout -q -b co-docs "$GSHA"; mkdir -p "$GR/docs"; echo doc > "$GR/docs/note.md"; git -C "$GR" add -A; git -C "$GR" commit -qm docs-only
DOCSHEAD="$(git -C "$GR" rev-parse HEAD)"
SHIMD="$TMP/shimd"; mkdir -p "$SHIMD"
cat > "$SHIMD/gh" <<SHIMDEOF
#!/usr/bin/env bash
echo "\$@" >> "$GHLOG"
case "\$*" in
  *"pr view"*) printf '{"headRefOid":"%s","headRefName":"feat/x","baseRefName":"main","author":{"login":"dev"}}\n' "$DOCSHEAD" ;;
  *"-X POST"*) echo '{}' ;;
  *"/status"*) echo "\${LG_STATE_EXPECTED:-success}" ;;
esac
SHIMDEOF
chmod +x "$SHIMD/gh"
cerrar_doble_gh "$SHIMD/gh" || exit 1
rgs_d() { PATH="$SHIMD:$SHIM:$PATH" bash "$RGS" "$1" --runner fake01 --runner-user runner --runner-repo "$RGR" --repo "$GR" --run-group "$2" --sha "$DOCSHEAD" --base "$GSHA" --manifest "$MAN_CO" --receipts "$3" --pr 9 --repo-slug o/r; }
plg_d() { PATH="$SHIMD:$SHIM:$PATH" LG_MANIFEST_DIR="$TMP" bash "$PLG" "$@"; }
RCD="$TMP/rcpts-cod"; mkdir -p "$RCD"
rgs_d verde rgCOD "$RCD" >/dev/null 2>&1
check "sellado docs-only: verde (heavy) → SKIP por carve-out, exit 0" 0 $?
jq -e '.result=="SKIP" and (.skip_reason|startswith("carve-out-docs-only:"))' "$RCD/verde.json" >/dev/null 2>&1 \
  && ok "receipt verde: carve-out SKIP con token (lib transportada Y clasificó en el runner)" || ko "verde no quedó en carve-out SKIP"
grep -q "file push .*carveout" "$INCUSLOG" && ok "lib carveout transportada al runner (incus file push)" || ko "sin push de carveout al runner"
rgs_d tenant rgCOD "$RCD" >/dev/null 2>&1
check "sellado docs-only: tenant (survivor) corre, exit 0" 0 $?
jq -e '.result=="PASS"' "$RCD/tenant.json" >/dev/null 2>&1 && ok "receipt tenant: PASS (survivor no SKIPea)" || ko "tenant no PASS"
rm -f "$TMP/viewcount"
plg_d rgCOD o/r 9 --receipts "$RCD" --manifest "$MAN_CO" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "agregador docs-only: carve-out SKIP RECOMPUTADO + survivor → success exit 0" 0 $?

echo "== TAL-2749: carve-out — autoridad conservadora (digest) rechaza tras deriva no-carveout =="
# Avanza origin/main con un cambio FUERA de docs/skills (drift) DESPUÉS de ratificar CO_DIGEST
# (calculado contra GSHA, el tip ANTERIOR). El diff base..head del nuevo PR sigue siendo 100% docs
# —el clasificador y el recompute docs-only dirían "sí"— pero el digest no-carveout de la NUEVA base
# ya NO coincide con el ratificado: el fast-path debe RECHAZARSE aunque el diff clasifique docs-only
# (un consumidor pudo introducirse en scripts/x.sh por CUALQUIER vía sintáctica;
# el digest lo detecta sin analizar una sola línea de ese cambio).
git -C "$GR" checkout -q main; echo more >> "$GR/scripts/x.sh"; git -C "$GR" commit -qam drift-no-carveout; git -C "$GR" push -q origin main >/dev/null 2>&1
DRIFTBASE="$(git -C "$GR" rev-parse HEAD)"
git -C "$GR" checkout -q -b co-docs-drift "$DRIFTBASE"; mkdir -p "$GR/docs"; echo doc2 > "$GR/docs/note2.md"; git -C "$GR" add -A; git -C "$GR" commit -qm docs-drift
DRIFTHEAD="$(git -C "$GR" rev-parse HEAD)"
SHIMDR="$TMP/shimdrift"; mkdir -p "$SHIMDR"
cat > "$SHIMDR/gh" <<SHIMDREOF
#!/usr/bin/env bash
echo "\$@" >> "$GHLOG"
case "\$*" in
  *"pr view"*) printf '{"headRefOid":"%s","headRefName":"feat/x","baseRefName":"main","author":{"login":"dev"}}\n' "$DRIFTHEAD" ;;
  *"-X POST"*) echo '{}' ;;
  *"/status"*) echo "\${LG_STATE_EXPECTED:-success}" ;;
esac
SHIMDREOF
chmod +x "$SHIMDR/gh"
cerrar_doble_gh "$SHIMDR/gh" || exit 1
RCDR="$TMP/rcpts-codrift"; mkdir -p "$RCDR"
rgs_dr() { PATH="$SHIMDR:$SHIM:$PATH" bash "$RGS" "$1" --runner fake01 --runner-user runner --runner-repo "$RGR" --repo "$GR" --run-group rgCODRIFT --sha "$DRIFTHEAD" --base "$DRIFTBASE" --manifest "$MAN_CO" --receipts "$RCDR" --pr 9 --repo-slug o/r; }
rgs_dr verde >/dev/null 2>&1
check "sellado docs-drift: verde SKIP por carve-out (runner clasifica por diff, no ve el digest), exit 0" 0 $?
rgs_dr tenant >/dev/null 2>&1
rm -f "$TMP/viewcount"
PATH="$SHIMDR:$SHIM:$PATH" LG_MANIFEST_DIR="$TMP" bash "$PLG" rgCODRIFT o/r 9 --receipts "$RCDR" --manifest "$MAN_CO" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "agregador RECHAZA el carve-out tras deriva no-carveout (digest ya no coincide) → exit 2" 2 $?

echo "== TAL-2749: carve-out — adversarial (runner miente sobre un diff MIXTO) =="
RCX="$TMP/rcpts-cox"; mkdir -p "$RCX"
# GSHA2 = head MIXTO (cambio en scripts/x.sh). El runner honesto NO debe SKIPear.
rgs verde rgCOX "$MAN_CO" "$RCX" >/dev/null 2>&1
check "sellado mixto: verde corre (runner honesto NO SKIPea en mixto), exit 0" 0 $?
jq -e '.result=="PASS"' "$RCX/verde.json" >/dev/null 2>&1 && ok "mixto: verde PASS (sin carve-out SKIP)" || ko "mixto: verde no PASS"
rgs tenant rgCOX "$MAN_CO" "$RCX" >/dev/null 2>&1
# Runner COMPROMETIDO: forjar un carve-out SKIP sobre el diff MIXTO con procedencia VÁLIDA (la
# estación honesta sella lo que el runner emitió). El agregador debe RECHAZAR por RECOMPUTE.
jq '.result="SKIP" | .skip_reason="carve-out-docs-only: forjado por runner comprometido"' "$RCX/verde.json" > "$RCX/verde.tmp" && mv "$RCX/verde.tmp" "$RCX/verde.json"
newsha="$(sha256sum "$RCX/verde.json" | cut -d' ' -f1)"
orig_v="$(grep '"gate_id":"verde"' "$RCX/journal.jsonl" | tail -1)"
grep -v '"gate_id":"verde"' "$RCX/journal.jsonl" > "$RCX/journal.tmp" || true
printf '%s\n' "$orig_v" | jq -c --arg rs "$newsha" '.receipt_sha256=$rs' >> "$RCX/journal.tmp"
mv "$RCX/journal.tmp" "$RCX/journal.jsonl"
rm -f "$TMP/viewcount"
plg rgCOX o/r 9 --receipts "$RCX" --manifest "$MAN_CO" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "agregador: carve-out SKIP sobre diff MIXTO (procedencia válida) → RECHAZADO exit 2" 2 $?
git -C "$GR" checkout -q main 2>/dev/null; git -C "$GR" reset -q --hard origin/main

# TAL-5196 E1: identidad de runner — seal-suite.sh exige TF_STATION_HOST + un mapa de
# identidad resoluble desde AQUÍ en adelante (el mapa de identidad es OBLIGATORIO, no
# opt-in). Fixture COMPARTIDA para todas las fixtures QS_*/SS_* de abajo, que usan runners
# bare (r0/r1/r2, sin slash -> alias de estación).
SEAL_STATION="station"
SEAL_ID_MAP="$TMP/seal-identity.map"; printf 'station=station\n' > "$SEAL_ID_MAP"
# [TAL-8037] seal-suite ya NO trae runners por defecto de casa: la flota de la instancia llega por argumentos o TF_RUNNERS.
export TF_RUNNERS="vibe-channel-85 vibe-channel-86 vibe-channel-87 vibe-channel-88"

echo "== TAL-2749/B1: seal-suite DERIVA el carril ligero de TF_GATE_IDS =="
ss_ids="$(sed -n 's/^TF_GATE_IDS="\([^"]*\)".*$/\1/p' "$MOTOR/manifiestos/ejemplo.conf" | tail -1)"
printf '%s\n' $ss_ids | grep -qx markdownlint \
  && ok "markdownlint ∈ TF_GATE_IDS de academy (se EJECUTA, no solo esperado)" || ko "markdownlint no está en TF_GATE_IDS de academy"
SS_CLONE="$TMP/ss-clone"; git init -q -b main "$SS_CLONE"; git -C "$SS_CLONE" config user.email t@t; git -C "$SS_CLONE" config user.name t
mkdir -p "$SS_CLONE/scripts/ci"; printf '{"schema_version":1,"families":{"fam":{"shards":[{"id":"s1"}]}}}\n' > "$SS_CLONE/scripts/ci/e2e-shards.json"
git -C "$SS_CLONE" add -A; git -C "$SS_CLONE" commit -qm base
SS_SHA="$(git -C "$SS_CLONE" rev-parse HEAD)"; SS_MAN="$TMP/ss.conf"
printf 'TF_PROJECT="test"\nTF_GATE_IDS="typecheck markdownlint tenant"\n' > "$SS_MAN"
printf 'TF_E2E_FAMILIES="fam"\nTF_SHARDS_REGISTRY="scripts/ci/e2e-shards.json"\n' >> "$SS_MAN"
out_ss="$(TF_ROOT="$MOTOR" TF_CLONE="$SS_CLONE" TF_MANIFEST="$SS_MAN" TF_SLUG="o/r" TF_STATION_HOST="$SEAL_STATION" TF_RUNNER_IDENTITY_MAP="$SEAL_ID_MAP" bash "$MOTOR/scripts/seal-suite.sh" --plan 9 "$SS_SHA" "$SS_SHA" rgPLAN 2>&1)"; rc=$?
check "seal-suite --plan deriva la lista de TF_GATE_IDS y sale 0" 0 "$rc"
printf '%s' "$out_ss" | grep -q "markdownlint" && ok "seal-suite --plan incluye markdownlint (cableado por derivación, B1)" || { ko "seal-suite --plan sin markdownlint"; printf '%s\n' "$out_ss" | tail -3; }
printf '%s' "$out_ss" | grep -q "total gates: 4" && ok "seal-suite --plan: conteo dinámico (3 base + 1 shard)" || { ko "conteo dinámico incorrecto"; printf '%s' "$out_ss" | grep -o "total gates: [0-9]*"; }

# [TAL-8037] Sin defaults de casa: TF_CLONE/TF_MANIFEST/TF_SLUG con `:?` (nombrando la variable) y sin runners por defecto.
_ss8037() { # <var-a-omitir> -> imprime la salida; el rc queda en $?
  local omit="$1" kv; local -a ee=()
  for kv in TF_ROOT="$MOTOR" TF_CLONE="$SS_CLONE" TF_MANIFEST="$SS_MAN" TF_SLUG="o/r" TF_STATION_HOST="$SEAL_STATION" TF_RUNNER_IDENTITY_MAP="$SEAL_ID_MAP"; do
    [ "${kv%%=*}" = "$omit" ] || ee+=("$kv")
  done
  env -u TF_CLONE -u TF_MANIFEST -u TF_SLUG "${ee[@]}" bash "$MOTOR/scripts/seal-suite.sh" --plan 9 "$SS_SHA" "$SS_SHA" rgOM 2>&1
}
for ss_v in TF_CLONE TF_MANIFEST TF_SLUG; do
  out_v="$(_ss8037 "$ss_v")"; rc_v=$?
  check "seal-suite sin $ss_v -> :? fail-closed (rc 1)" 1 "$rc_v"
  printf '%s' "$out_v" | grep -q "$ss_v sin definir" && ok "seal-suite sin $ss_v: el mensaje NOMBRA la variable" || ko "seal-suite sin $ss_v: mensaje mudo"
done
out_nr="$(env -u TF_RUNNERS TF_ROOT="$MOTOR" TF_CLONE="$SS_CLONE" TF_MANIFEST="$SS_MAN" TF_SLUG="o/r" TF_STATION_HOST="$SEAL_STATION" TF_RUNNER_IDENTITY_MAP="$SEAL_ID_MAP" bash "$MOTOR/scripts/seal-suite.sh" --plan 9 "$SS_SHA" "$SS_SHA" rgNR 2>&1)"; rc_nr=$?
check "seal-suite sin runners (ni args ni TF_RUNNERS) -> die exit 2" 2 "$rc_nr"
printf '%s' "$out_nr" | grep -q "TF_RUNNERS" && ok "seal-suite sin runners: el mensaje NOMBRA TF_RUNNERS" || ko "seal-suite sin runners: mensaje mudo"
out_vr="$(env -u TF_MANIFEST TF_STATION_HOST=station bash "$MOTOR/scripts/verify-runner-identity-rollout.sh" station vibe-channel-81 2>&1)"; rc_vr=$?
check "verify-runner-identity-rollout sin TF_MANIFEST -> :? fail-closed (rc 1)" 1 "$rc_vr"
printf '%s' "$out_vr" | grep -q "TF_MANIFEST sin definir" && ok "verify-runner-identity-rollout sin TF_MANIFEST: el mensaje NOMBRA la variable" || ko "verify-runner-identity-rollout sin TF_MANIFEST: mensaje mudo"
out_gm="$(env -u TF_CLONE python3 "$MOTOR/scripts/gen-metricas-fragment.py" 2>&1)"; rc_gm=$?
check "gen-metricas-fragment sin TF_CLONE -> falla cerrado (rc 1)" 1 "$rc_gm"
printf '%s' "$out_gm" | grep -q "TF_CLONE" && ok "gen-metricas-fragment sin TF_CLONE: el mensaje NOMBRA la variable" || ko "gen-metricas-fragment sin TF_CLONE: mensaje mudo"

echo "== TAL-4954: gates de draft-handoff (syntax/shellcheck) — inventario recursivo fail-closed + carve-out estrecho + ratchet =="
# Fixture: un "motor" mínimo pero FUNCIONAL (copias reales de draft-handoff.sh, los dos gate
# scripts, lib/inventory.sh y validar-rama-pr.sh) para probar el mecanismo END-TO-END: rc del
# proceso Y presencia/ausencia del sentinel .claude/.draft-handoff — no solo el rc de los gate
# scripts en aislado.
QH_DIR="$TMP/qh-motor"; QH_MAN="$TMP/qh.conf"
mk_qh_fixture() {
  rm -rf "$QH_DIR"; git init -q -b chore/qh-fixture "$QH_DIR"
  git -C "$QH_DIR" config user.email t@t; git -C "$QH_DIR" config user.name t
  mkdir -p "$QH_DIR/scripts/github" "$QH_DIR/scripts/lib" "$QH_DIR/githooks" "$QH_DIR/tests" "$QH_DIR/skills/fake-skill/scripts" "$QH_DIR/.claude"
  cp "$MOTOR/scripts/draft-handoff.sh" "$QH_DIR/scripts/draft-handoff.sh"
  cp "$MOTOR/scripts/check-bash-syntax.sh" "$QH_DIR/scripts/check-bash-syntax.sh"
  cp "$MOTOR/scripts/check-shellcheck.sh" "$QH_DIR/scripts/check-shellcheck.sh"
  cp "$MOTOR/scripts/lib/inventory.sh" "$QH_DIR/scripts/lib/inventory.sh"
  cp "$MOTOR/scripts/github/validar-rama-pr.sh" "$QH_DIR/scripts/github/validar-rama-pr.sh"
  printf '#!/usr/bin/env bash\necho ok\n' > "$QH_DIR/scripts/ok-top.sh"
  printf '#!/usr/bin/env bash\necho ok\n' > "$QH_DIR/scripts/lib/ok-lib.sh"
  printf '#!/usr/bin/env bash\necho ok\n' > "$QH_DIR/scripts/github/extra-check.sh"
  printf '#!/usr/bin/env bash\necho ok\n' > "$QH_DIR/githooks/pre-push"
  printf '#!/usr/bin/env bash\necho ok\n' > "$QH_DIR/tests/run-tests.sh"
  printf '#!/usr/bin/env bash\necho ok\n' > "$QH_DIR/skills/fake-skill/scripts/nested.sh"
  printf '.claude/.draft-handoff\n' > "$QH_DIR/.gitignore"
  chmod +x "$QH_DIR"/scripts/*.sh "$QH_DIR"/scripts/github/*.sh "$QH_DIR"/scripts/lib/*.sh "$QH_DIR/githooks/pre-push" "$QH_DIR"/tests/*.sh "$QH_DIR"/skills/fake-skill/scripts/*.sh
  git -C "$QH_DIR" add -A; git -C "$QH_DIR" commit -qm base
  printf 'TF_PROJECT="qh-fixture"\nTF_HANDOFF_GATES="syntax shellcheck"\nTF_GATE_CMD_syntax="bash scripts/check-bash-syntax.sh"\nTF_GATE_CMD_shellcheck="bash scripts/check-shellcheck.sh"\n' > "$QH_MAN"
}
qh_run() { # -> rc en $?; stdout+stderr en $QH_OUT
  QH_OUT="$(cd "$QH_DIR" && rm -f .claude/.draft-handoff && TF_MANIFEST="$QH_MAN" bash scripts/draft-handoff.sh 2>&1)"
}
qh_sentinel_absent() { [ ! -f "$QH_DIR/.claude/.draft-handoff" ]; }
qh_mutate_commit() { # <fichero relativo> <contenido> — mutación COMMITEADA (draft-handoff exige árbol limpio)
  printf '%s' "$2" > "$QH_DIR/$1"
  git -C "$QH_DIR" commit -qam "mutate $1"
}
qh_restore() { git -C "$QH_DIR" reset -q --hard HEAD~1; }
# PATH restringido pero COMPLETO salvo por lo que se quiera omitir: incluye TODO lo que
# motor_inventory_files()/draft-handoff.sh necesitan ANTES de llegar a shellcheck (mktemp, find,
# sort, git, etc.) — omitir mktemp/find/sort por accidente aborta el gate en la construcción del
# inventario y el test "prueba" un fallo que nunca llegó al punto que afirma cubrir.
qh_mk_restricted_path() { # <dir destino> [tool...] — tools listados se OMITEN del PATH
  local dir="$1"; shift
  local omit=" $* "
  mkdir -p "$dir"
  local _t _p
  for _t in bash git find sort mktemp touch rm mv cp cat mkdir chmod tr wc printf true false env dirname basename pwd readlink date sed grep head timeout; do
    case "$omit" in *" $_t "*) continue;; esac
    _p="$(command -v "$_t" 2>/dev/null)" && ln -sf "$_p" "$dir/$_t"
  done
}

mk_qh_fixture

# (qh0) baseline: fixture limpio → verde + sentinel presente (confirma que el mecanismo FUNCIONA
# antes de probar que las mutaciones lo ROMPEN — sin esto, un "sentinel ausente" en (qh1)-(qh4)
# no probaría nada).
qh_run; qh_rc=$?
check "(qh0) fixture baseline: draft-handoff sale 0" 0 "$qh_rc"
[ -f "$QH_DIR/.claude/.draft-handoff" ] && ok "(qh0) sentinel presente en el baseline limpio" || ko "(qh0) sentinel ausente en el baseline (debería estar)"

# (qh1) BLOCKER: bash inválido en fichero CUBIERTO de nivel superior (scripts/ok-top.sh).
qh_mutate_commit scripts/ok-top.sh $'#!/usr/bin/env bash\nif [ 1 -eq 1\n'
qh_run; qh_rc=$?
check "(qh1) bash inválido en scripts/ok-top.sh → draft-handoff sale ≠0" 1 "$qh_rc"
printf '%s' "$QH_OUT" | grep -q '✗ bash -n scripts/ok-top.sh' && ok "(qh1) diagnóstico específico: el gate 'syntax' señaló EXACTAMENTE scripts/ok-top.sh" || ko "(qh1) falta el diagnóstico específico — ¿falló por otra razón?"
qh_sentinel_absent && ok "(qh1) sentinel AUSENTE tras bash inválido (fail-closed)" || ko "(qh1) sentinel presente pese al bash inválido"
qh_restore

# (qh2) BLOCKER (núcleo): bash inválido bajo scripts/github/ — subdir NO cubierto por el glob
# scripts/*.sh original (motiva el inventario recursivo).
qh_mutate_commit scripts/github/extra-check.sh $'#!/usr/bin/env bash\nfor i in 1 2\n'
qh_run; qh_rc=$?
check "(qh2) bash inválido bajo scripts/github/ → draft-handoff sale ≠0 (inventario recursivo lo alcanza)" 1 "$qh_rc"
printf '%s' "$QH_OUT" | grep -q '✗ bash -n scripts/github/extra-check.sh' && ok "(qh2) diagnóstico específico: el gate 'syntax' señaló EXACTAMENTE scripts/github/extra-check.sh" || ko "(qh2) falta el diagnóstico específico — ¿scripts/github/ realmente cubierto?"
qh_sentinel_absent && ok "(qh2) sentinel AUSENTE (scripts/github/ cubierto)" || ko "(qh2) sentinel presente — scripts/github/ NO cubierto (regresión del BLOCKER)"
qh_restore

# (qh3) MAJOR: bash inválido bajo skills/**/*.sh (subdir anidado, antes EXCLUIDO por completo).
qh_mutate_commit skills/fake-skill/scripts/nested.sh $'#!/usr/bin/env bash\ncase "$1" in\n'
qh_run; qh_rc=$?
check "(qh3) bash inválido bajo skills/**/*.sh → draft-handoff sale ≠0 (skills/ ya NO tiene carve-out de árbol completo)" 1 "$qh_rc"
printf '%s' "$QH_OUT" | grep -q '✗ bash -n skills/fake-skill/scripts/nested.sh' && ok "(qh3) diagnóstico específico: el gate 'syntax' señaló EXACTAMENTE el fichero anidado bajo skills/" || ko "(qh3) falta el diagnóstico específico — ¿skills/ realmente cubierto?"
qh_sentinel_absent && ok "(qh3) sentinel AUSENTE (skills/ cubierto)" || ko "(qh3) sentinel presente — skills/ NO cubierto (regresión del MAJOR)"
qh_restore

# Shellcheck -S error SIN romper bash -n (SC2168, 'local' fuera de
# función) — prueba que el gate 'shellcheck' detecta lo que 'syntax' NO puede.
qh_mutate_commit scripts/lib/ok-lib.sh $'#!/usr/bin/env bash\nlocal fuera_de_funcion=1\necho "$fuera_de_funcion"\n'
qh_run; qh_rc=$?
check "(qh4) SC2168 (hallazgo shellcheck real) → draft-handoff sale ≠0" 1 "$qh_rc"
printf '%s' "$QH_OUT" | grep -q 'gate: syntax OK' && ok "(qh4) 'syntax' pasó limpio (aísla la detección al gate shellcheck)" || ko "(qh4) 'syntax' no pasó — el control de aislamiento falló"
printf '%s' "$QH_OUT" | grep -q 'scripts/lib/ok-lib.sh' && printf '%s' "$QH_OUT" | grep -q 'SC2168' && ok "(qh4) diagnóstico específico: shellcheck señaló SC2168 en scripts/lib/ok-lib.sh" || ko "(qh4) falta el diagnóstico específico de shellcheck — ¿alcanzó el fichero mutado?"
qh_sentinel_absent && ok "(qh4) sentinel AUSENTE (hallazgo shellcheck real)" || ko "(qh4) sentinel presente pese al hallazgo shellcheck"
bash -n "$QH_DIR/scripts/lib/ok-lib.sh" >/dev/null 2>&1 && ok "(qh4) control: la mutación NO rompe bash -n (aísla la detección al gate shellcheck)" || ko "(qh4) la mutación de control rompió bash -n (test mal diseñado)"
qh_restore

# (qh5) MAJOR: shellcheck AUSENTE del PATH → fail-closed (exit 2 interno del gate), nunca
# "shellcheck no está, me lo salto y sigo verde". El PATH restringido SÍ incluye mktemp/find/
# sort (todo lo que motor_inventory_files() necesita) — solo se omite shellcheck — para que el
# fallo se atribuya al punto correcto y no a un PATH incompleto que aborte antes en el inventario.
QH_NOSHIM="$TMP/qh-no-shellcheck-bin"; qh_mk_restricted_path "$QH_NOSHIM" shellcheck
QH_OUT="$(cd "$QH_DIR" && rm -f .claude/.draft-handoff && PATH="$QH_NOSHIM" TF_MANIFEST="$QH_MAN" bash scripts/draft-handoff.sh 2>&1)"; qh_rc=$?
printf '%s' "$QH_OUT" | grep -q 'shellcheck no disponible' && ok "(qh5) diagnóstico específico: 'shellcheck no disponible' (falló en el punto correcto, no antes por el PATH incompleto)" || ko "(qh5) falta el diagnóstico específico de shellcheck ausente — ¿falló por otra razón (p.ej. inventario incompleto)?"
check "(qh5) shellcheck ausente del PATH → draft-handoff sale ≠0 (fail-closed, no se lo salta)" 1 "$qh_rc"
qh_sentinel_absent && ok "(qh5) sentinel AUSENTE (shellcheck ausente detectado fail-closed)" || ko "(qh5) sentinel presente pese a shellcheck ausente"

# Shellcheck PRESENTE pero con rc OPERACIONAL (no relacionado con hallazgos de
# lint, p.ej. un binario roto) → el rc debe propagarse igual (fail-closed). check-shellcheck.sh
# ya NO tiene capa jq/JSON intermedia que pudiera tragarse un rc operacional distinto de 0/1.
# CRÍTICO : el PATH restringido debe incluir mktemp/find/sort —
# motor_inventory_files() los necesita ANTES de invocar shellcheck; si faltan, el gate aborta en
# la construcción del inventario y el fake shellcheck NUNCA se ejecuta (rc≠0 + sentinel ausente
# saldrían igual, pero por la razón EQUIVOCADA — el test no probaría lo que afirma). El fake
# El fake deja un MARCADOR verificable en disco antes de salir, para probar que la ejecución SÍ
# llegó a invocarlo.
QH_FAKESC="$TMP/qh-fake-shellcheck-bin"; qh_mk_restricted_path "$QH_FAKESC" shellcheck
QH_SC_MARKER="$TMP/qh5b-sc-reached"; rm -f "$QH_SC_MARKER"
cat > "$QH_FAKESC/shellcheck" <<EOF
#!/usr/bin/env bash
touch "$QH_SC_MARKER"
echo "shellcheck: fallo operacional simulado (TAL-4954 qh5b)" >&2
exit 3
EOF
chmod +x "$QH_FAKESC/shellcheck"
QH_OUT="$(cd "$QH_DIR" && rm -f .claude/.draft-handoff && PATH="$QH_FAKESC" TF_MANIFEST="$QH_MAN" bash scripts/draft-handoff.sh 2>&1)"; qh_rc=$?
[ -f "$QH_SC_MARKER" ] && ok "(qh5b) marcador presente: la ejecución SÍ llegó a invocar shellcheck (no abortó antes en el inventario)" || ko "(qh5b) marcador AUSENTE: nunca se llegó a invocar shellcheck — el test NO prueba lo que afirma (falso positivo )"
printf '%s' "$QH_OUT" | grep -q 'fallo operacional simulado (TAL-4954 qh5b)' && ok "(qh5b) la salida contiene el fallo operacional simulado (confirma que shellcheck SÍ corrió y su rc se propagó)" || ko "(qh5b) no aparece el mensaje del fallo operacional simulado en la salida"
check "(qh5b) shellcheck con rc operacional (3, sin relación a hallazgos) → draft-handoff sale ≠0" 1 "$qh_rc"
qh_sentinel_absent && ok "(qh5b) sentinel AUSENTE (rc operacional de shellcheck propagado, fail-closed)" || ko "(qh5b) sentinel presente pese al rc operacional de shellcheck"

# (qh6) inventario LEGÍTIMAMENTE vacío: las 4 carpetas EXISTEN pero ninguna tiene ficheros que
# matcheen → find sale 0 (sin error) pero MOTOR_INVENTORY queda vacío → exit 2 fail-closed en
# AMBOS gate scripts ("0 ficheros" nunca es "todo verde" en silencio). Distinto de (qh7): aquí
# find NO falla — se prueba a nivel de gate script directo (un draft-handoff funcional real
# nunca tiene inventario vacío, porque sus propios gate scripts viven bajo scripts/).
QH_EMPTY="$TMP/qh-empty"; rm -rf "$QH_EMPTY"; git init -q -b chore/qh-empty "$QH_EMPTY"
git -C "$QH_EMPTY" config user.email t@t; git -C "$QH_EMPTY" config user.name t
mkdir -p "$QH_EMPTY/scripts" "$QH_EMPTY/githooks" "$QH_EMPTY/tests" "$QH_EMPTY/skills"   # las 4 EXISTEN, todas vacías
(cd "$QH_EMPTY" && bash "$MOTOR/scripts/check-bash-syntax.sh") >"$TMP/qh-empty-syntax.out" 2>&1; qh_rc=$?
check "(qh6) inventario legítimamente vacío → check-bash-syntax.sh sale 2 (fail-closed)" 2 "$qh_rc"
grep -q 'inventario VACÍO' "$TMP/qh-empty-syntax.out" && ok "(qh6) check-bash-syntax.sh: diagnóstico específico 'inventario VACÍO' (no el de find/sort fallido — find SÍ tuvo éxito aquí)" || ko "(qh6) check-bash-syntax.sh: falta el diagnóstico específico de vacío — ¿exit 2 por otra razón?"
(cd "$QH_EMPTY" && bash "$MOTOR/scripts/check-shellcheck.sh") >"$TMP/qh-empty-shellcheck.out" 2>&1; qh_rc=$?
check "(qh6) inventario legítimamente vacío → check-shellcheck.sh sale 2 (fail-closed)" 2 "$qh_rc"
grep -q 'inventario VACÍO' "$TMP/qh-empty-shellcheck.out" && ok "(qh6) check-shellcheck.sh: diagnóstico específico 'inventario VACÍO'" || ko "(qh6) check-shellcheck.sh: falta el diagnóstico específico de vacío — ¿exit 2 por otra razón?"
[ ! -f "$QH_EMPTY/.claude/.draft-handoff" ] && ok "(qh6) sin sentinel en el fixture vacío (ni se invocó draft-handoff.sh)" || ko "(qh6) sentinel inesperado en el fixture vacío"

# (qh7) BLOCKER (núcleo de la regresión): inventario PARCIAL por FALLO de find — un árbol
# REQUERIDO (githooks/tests/skills) está AUSENTE del todo, no solo vacío; find sale ≠0 aunque
# scripts/ SÍ tenga ficheros. Antes del fix, el rc de `sort` (0, éxito) enmascaraba el rc de
# `find` (≠0) al no usar pipefail, y el inventario PARCIAL (solo lo hallado en scripts/) se
# trataba como un resultado no-vacío válido → ambos gates podían salir verdes omitiendo
# superficie material. Ahora motor_inventory_files() debe devolver ≠0 y AMBOS gate scripts deben
# salir 2 SIN llegar a procesar ese inventario parcial (ni siquiera para reportarlo).
QH_PARTIAL="$TMP/qh-partial"; rm -rf "$QH_PARTIAL"; git init -q -b chore/qh-partial "$QH_PARTIAL"
git -C "$QH_PARTIAL" config user.email t@t; git -C "$QH_PARTIAL" config user.name t
mkdir -p "$QH_PARTIAL/scripts"; printf '#!/usr/bin/env bash\necho ok\n' > "$QH_PARTIAL/scripts/a.sh"   # githooks/tests/skills AUSENTES del todo
(cd "$QH_PARTIAL" && bash "$MOTOR/scripts/check-bash-syntax.sh") >"$TMP/qh-partial-syntax.out" 2>&1; qh_rc=$?
check "(qh7) árbol requerido ausente (find falla) → check-bash-syntax.sh sale 2, no el parcial" 2 "$qh_rc"
grep -q 'find/sort del inventario falló' "$TMP/qh-partial-syntax.out" && ok "(qh7) check-bash-syntax.sh: diagnóstico específico 'find/sort del inventario falló' (no el de vacío — find SÍ falló aquí)" || ko "(qh7) check-bash-syntax.sh: falta el diagnóstico específico de find fallido — ¿exit 2 por otra razón?"
grep -q "scripts/a.sh" "$TMP/qh-partial-syntax.out" && ko "(qh7) check-bash-syntax.sh procesó el inventario PARCIAL en vez de fallar-cerrado (regresión del BLOCKER)" || ok "(qh7) check-bash-syntax.sh NO procesó el parcial (fail-closed antes de iterar)"
(cd "$QH_PARTIAL" && bash "$MOTOR/scripts/check-shellcheck.sh") >"$TMP/qh-partial-shellcheck.out" 2>&1; qh_rc=$?
check "(qh7) árbol requerido ausente (find falla) → check-shellcheck.sh sale 2, no el parcial" 2 "$qh_rc"
grep -q 'find/sort del inventario falló' "$TMP/qh-partial-shellcheck.out" && ok "(qh7) check-shellcheck.sh: diagnóstico específico 'find/sort del inventario falló'" || ko "(qh7) check-shellcheck.sh: falta el diagnóstico específico de find fallido — ¿exit 2 por otra razón?"
[ ! -f "$QH_PARTIAL/.claude/.draft-handoff" ] && ok "(qh7) sin sentinel en el fixture parcial (ni se invocó draft-handoff.sh)" || ko "(qh7) sentinel inesperado en el fixture parcial"

echo "== TAL-4946: fase quieta in-proceso (unit no solapa el pico e2e) — harness determinista =="
# Fixture: TF_ROOT propio con un run-gate-sealed.sh FALSO que registra start/end por gate en
# $QS_LOG (epoch-ns), duerme una duración de fixture y sale con un rc de fixture — permite
# afirmar el ORDEN REAL de ejecución sin incus/ssh/gh (offline, determinista). incus se shimmea
# no-op (las llamadas de limpieza de slate_exec son best-effort, pero sin shim ensucian stderr).
QS_ROOT="$TMP/qs-root"; mkdir -p "$QS_ROOT/scripts"
cat > "$QS_ROOT/scripts/post-local-gates.sh" <<'QSPOST'
#!/usr/bin/env bash
exit 0
QSPOST
chmod +x "$QS_ROOT/scripts/post-local-gates.sh"
cat > "$QS_ROOT/scripts/run-gate-sealed.sh" <<'QSFAKE'
#!/usr/bin/env bash
set -uo pipefail
GATE="$1"
LOG="${QS_LOG:?QS_LOG unset}"
dur="0.05"; rc=0
case "$GATE" in
  unit)   dur="${QS_DUR_UNIT:-0.05}"; rc="${QS_RC_UNIT:-0}" ;;
  fam:s1) dur="${QS_DUR_S1:-0.5}";    rc="${QS_RC_S1:-0}" ;;
  fam:s2) dur="${QS_DUR_S2:-0.25}";   rc="${QS_RC_S2:-0}" ;;
esac
printf 'start %s %s\n' "$GATE" "$(date +%s%N)" >> "$LOG"
sleep "$dur"
printf 'end %s %s\n' "$GATE" "$(date +%s%N)" >> "$LOG"
exit "$rc"
QSFAKE
chmod +x "$QS_ROOT/scripts/run-gate-sealed.sh"
QS_SHIM="$TMP/qs-shim"; mkdir -p "$QS_SHIM"
cat > "$QS_SHIM/incus" <<'QSINCUS'
#!/usr/bin/env bash
# TAL-5196 E1: seal-suite ahora consulta `incus list --format csv -c ns` para el filtro
# RUNNING exacto — este fixture no prueba ese mecanismo (lo prueba TAL-5196 E1 más abajo),
# así que aquí SIEMPRE reporta RUNNING para cualquier nombre consultado.
if [ "$1" = "list" ]; then
  pat="${*: -1}"
  printf '%s,RUNNING\n' "$(printf '%s' "$pat" | sed 's/^\^//; s/\$$//')"
  exit 0
fi
exit 0
QSINCUS
chmod +x "$QS_SHIM/incus"
QS_CLONE="$TMP/qs-clone"; mkdir -p "$QS_CLONE/scripts/ci"
git init -q -b main "$QS_CLONE"; git -C "$QS_CLONE" config user.email t@t; git -C "$QS_CLONE" config user.name t
printf '{"schema_version":1,"families":{"fam":{"shards":[{"id":"s1"},{"id":"s2"}]}}}\n' > "$QS_CLONE/scripts/ci/e2e-shards.json"
git -C "$QS_CLONE" add -A; git -C "$QS_CLONE" commit -qm base
QS_SHA="$(git -C "$QS_CLONE" rev-parse HEAD)"
QS_MAN="$TMP/qs.conf"
printf 'TF_PROJECT="test"\nTF_GATE_IDS="typecheck lint build unit i18n"\n' > "$QS_MAN"
printf 'TF_E2E_FAMILIES="fam"\nTF_SHARDS_REGISTRY="scripts/ci/e2e-shards.json"\n' >> "$QS_MAN"
QS_EXPECTED="typecheck lint build unit i18n fam:s1 fam:s2"   # multiconjunto esperado (TF_GATE_IDS ∪ shards)

qs_run() { # <run-group> <runner...> — corre seal-suite.sh --no-post contra el fixture QS_*
  local rg="$1"; shift
  PATH="$QS_SHIM:$PATH" TF_ROOT="$QS_ROOT" TF_CLONE="$QS_CLONE" TF_MANIFEST="$QS_MAN" TF_SLUG="o/r" \
    TF_STATION_HOST="$SEAL_STATION" TF_RUNNER_IDENTITY_MAP="$SEAL_ID_MAP" \
    bash "$MOTOR/scripts/seal-suite.sh" --no-post 9 "$QS_SHA" "$QS_SHA" "$rg" "$@"
}
qs_ts()    { grep "^$1 $2 " "$QS_LOG" | awk '{print $3}'; }   # <start|end> <gate> -> epoch-ns
qs_count() { grep -c "^$1 $2 " "$QS_LOG"; }                    # <start|end> <gate> -> nº de líneas

# (te) EJECUCIÓN — multiconjunto REAL (guard de cobertura: detecta array desnudo/duplicados).
QS_LOG="$TMP/qs-te.log"; : > "$QS_LOG"
# shellcheck disable=SC2034  # qs_out captura la salida a PROPOSITO para descartarla (solo se usa el rc); quitar la asignacion la volcaria a stdout
qs_out="$(QS_LOG="$QS_LOG" qs_run rgTE r0 r1 r2 2>&1)"; qs_rc=$?
check "(te) corrida normal: seal-suite --no-post sale 0" 0 "$qs_rc"
te_ok=1
for g in $QS_EXPECTED; do
  sc=$(qs_count start "$g"); ec=$(qs_count end "$g")
  if [ "$sc" != "1" ] || [ "$ec" != "1" ]; then te_ok=0; echo "  ! $g: start=$sc end=$ec" >&2; fi
done
qs_lines=$(wc -l < "$QS_LOG"); qs_expected_lines=$(( $(printf '%s\n' $QS_EXPECTED | wc -w) * 2 ))
[ "$qs_lines" -eq "$qs_expected_lines" ] || { te_ok=0; echo "  ! líneas de log: $qs_lines (esperadas $qs_expected_lines)" >&2; }
[ "$te_ok" = 1 ] && ok "(te) multiconjunto EJECUTADO == TF_GATE_IDS ∪ shards, exactamente 1 c/u (detecta array desnudo / duplicados)" \
  || ko "(te) multiconjunto ejecutado NO coincide con lo esperado"

# (t1) invariante temporal esencial: unit corre DESPUÉS de terminar TODOS los e2e (fines desordenados).
u_start="$(qs_ts start unit)"; s1_end="$(qs_ts end fam:s1)"; s2_end="$(qs_ts end fam:s2)"
if [ -n "$u_start" ] && [ -n "$s1_end" ] && [ -n "$s2_end" ] \
   && [ "$u_start" -gt "$s1_end" ] && [ "$u_start" -gt "$s2_end" ]; then
  ok "(t1) start(unit) > max(end(fam:s1), end(fam:s2)) — unit corre tras el pico e2e completo"
else
  ko "(t1) unit NO respeta el orden temporal (start=$u_start s1_end=$s1_end s2_end=$s2_end)"
fi

# (t2) timeout de un shard (rc=124, proceso termina LIMPIO, no señal externa) → fail-closed;
# además prueba el FIX de rc-masking (p6): sin él, run_lane devolvía 0 tras un timeout y
# LANE_RC nunca se marcaba — 'coordinacion(lane-rc)' es la huella específica de ese fix.
QS_LOG="$TMP/qs-t2.log"; : > "$QS_LOG"
out_t2="$(QS_LOG="$QS_LOG" QS_DUR_S1=3 TF_GATE_TIMEOUT=1 qs_run rgT2 r0 r1 r2 2>&1)"; rc_t2=$?
check "(t2) timeout de un shard (rc=124) → seal-suite sale 1" 1 "$rc_t2"
[ "$(qs_count start unit)" = 0 ] && ok "(t2) unit AUSENTE del log tras timeout de fase 1 (fail-closed)" || ko "(t2) unit se ejecutó pese al timeout"
printf '%s' "$out_t2" | grep -q "coordinacion(lane-rc)" \
  && ok "(t2/p6) 'coordinacion(lane-rc)' presente — prueba el fix de rc-masking (run_one/run_lane propagan el rc real vía barrera)" \
  || ko "(t2/p6) falta 'coordinacion(lane-rc)' — regresión del fix de rc-masking"

# (t3) rc≠0 normal de un shard (sin timeout) → también fail-closed.
QS_LOG="$TMP/qs-t3.log"; : > "$QS_LOG"
# shellcheck disable=SC2034  # out_t3 captura la salida a PROPOSITO para descartarla (solo se usa el rc); quitar la asignacion la volcaria a stdout
out_t3="$(QS_LOG="$QS_LOG" QS_RC_S1=1 qs_run rgT3 r0 r1 r2 2>&1)"; rc_t3=$?
check "(t3) shard con rc=1 → seal-suite sale 1" 1 "$rc_t3"
[ "$(qs_count start unit)" = 0 ] && ok "(t3) unit AUSENTE del log tras rc≠0 de fase 1" || ko "(t3) unit se ejecutó pese al rc≠0"

# (t4) MUERTE REAL de un carril de fondo (kill -9 del PID hijo, no del gate) — la BARRERA (rc de
# `wait`) debe detectarlo, no FAILDIR (un carril SIGKILLeado no llega a escribirlo).
QS_LOG="$TMP/qs-t4.log"; : > "$QS_LOG"
PATH="$QS_SHIM:$PATH" QS_LOG="$QS_LOG" QS_DUR_S1=2 QS_DUR_S2=2 \
  TF_ROOT="$QS_ROOT" TF_CLONE="$QS_CLONE" TF_MANIFEST="$QS_MAN" TF_SLUG="o/r" \
  TF_STATION_HOST="$SEAL_STATION" TF_RUNNER_IDENTITY_MAP="$SEAL_ID_MAP" \
  bash "$MOTOR/scripts/seal-suite.sh" --no-post 9 "$QS_SHA" "$QS_SHA" rgT4 r0 r1 r2 >"$TMP/qs-t4.out" 2>&1 &
QS_SS=$!
qs_polled=0
for _ in $(seq 1 100); do
  grep -q "^start fam:s1 " "$QS_LOG" 2>/dev/null && { qs_polled=1; break; }
  sleep 0.05
done
if [ "$qs_polled" = 1 ]; then
  qs_lane_pid="$(pgrep -P "$QS_SS" | head -1)"
  [ -n "$qs_lane_pid" ] && kill -9 "$qs_lane_pid" 2>/dev/null
  wait "$QS_SS"; rc_t4=$?
  check "(t4) muerte REAL de un carril de fondo (kill -9 del PID hijo) → seal-suite sale 1" 1 "$rc_t4"
  [ "$(qs_count start unit)" = 0 ] && ok "(t4) unit AUSENTE del log tras la muerte del carril" || ko "(t4) unit se ejecutó pese al carril muerto"
else
  wait "$QS_SS" 2>/dev/null
  ko "(t4) no se pudo observar el carril activo a tiempo (poll agotado) — test no concluyente"
fi

# (t5) single-runner REAL con ≥1 shard (el caso "sin e2e" es inejecutable: el script exige
# ≥1 shard). Carril ligero Y pesado comparten el mismo runner; unit debe correr tras el ÚLTIMO
# shard de la ÚNICA cola pesada.
QS_LOG="$TMP/qs-t5.log"; : > "$QS_LOG"
# shellcheck disable=SC2034  # out_t5 captura la salida a PROPOSITO para descartarla (solo se usa el rc); quitar la asignacion la volcaria a stdout
out_t5="$(QS_LOG="$QS_LOG" qs_run rgT5 r0 2>&1)"; rc_t5=$?
check "(t5) single-runner (≥1 shard) → seal-suite sale 0" 0 "$rc_t5"
u_start5="$(qs_ts start unit)"; s2_end5="$(qs_ts end fam:s2)"
if [ -n "$u_start5" ] && [ -n "$s2_end5" ] && [ "$u_start5" -gt "$s2_end5" ]; then
  ok "(t5) single-runner: start(unit) > end(último shard de la única cola pesada)"
else
  ko "(t5) single-runner: unit no respeta el orden temporal (start=$u_start5 s2_end=$s2_end5)"
fi

# (p1) partición multiconjunto CALCULADO (complementa a (te), que valida el EJECUTADO). --plan
# no toca run-gate-sealed.sh: se puede usar TF_ROOT=$MOTOR directamente (como el test B1).
out_plan="$(TF_ROOT="$MOTOR" TF_CLONE="$QS_CLONE" TF_MANIFEST="$QS_MAN" TF_SLUG="o/r" TF_STATION_HOST="$SEAL_STATION" TF_RUNNER_IDENTITY_MAP="$SEAL_ID_MAP" bash "$MOTOR/scripts/seal-suite.sh" --plan 9 "$QS_SHA" "$QS_SHA" rgP1 2>&1)"
par_line="$(printf '%s\n' "$out_plan" | sed -n 's/^  carril ligero (paralelo): //p' | tail -1)"
quiet_line="$(printf '%s\n' "$out_plan" | sed -n 's/^  fase quieta (serial, sin e2e): //p' | tail -1)"
if [ "$(printf '%s %s\n' "$par_line" "$quiet_line" | tr -s ' ' '\n' | sort)" = "$(printf '%s\n' typecheck lint build unit i18n | sort)" ]; then
  ok "(p1) multiconjunto CALCULADO: carril-paralelo ⊎ fase-quieta == TF_GATE_IDS"
else
  ko "(p1) partición calculada no coincide: par='$par_line' quiet='$quiet_line'"
fi

# (p2) TF_QUIET_GATES con duplicados → die fail-closed.
TF_ROOT="$MOTOR" TF_CLONE="$QS_CLONE" TF_MANIFEST="$QS_MAN" TF_SLUG="o/r" TF_QUIET_GATES="unit unit" \
  TF_STATION_HOST="$SEAL_STATION" TF_RUNNER_IDENTITY_MAP="$SEAL_ID_MAP" \
  bash "$MOTOR/scripts/seal-suite.sh" --plan 9 "$QS_SHA" "$QS_SHA" rgP2 >/dev/null 2>&1
check "(p2) TF_QUIET_GATES con duplicados → die exit 2" 2 $?

# (p3) TF_QUIET_GATES con token ausente de TF_GATE_IDS → die fail-closed (cobertura).
TF_ROOT="$MOTOR" TF_CLONE="$QS_CLONE" TF_MANIFEST="$QS_MAN" TF_SLUG="o/r" TF_QUIET_GATES="noexiste" \
  TF_STATION_HOST="$SEAL_STATION" TF_RUNNER_IDENTITY_MAP="$SEAL_ID_MAP" \
  bash "$MOTOR/scripts/seal-suite.sh" --plan 9 "$QS_SHA" "$QS_SHA" rgP3 >/dev/null 2>&1
check "(p3) TF_QUIET_GATES con token ausente de TF_GATE_IDS → die exit 2" 2 $?

# (p4) contrato de los 3 estados: unset -> default "unit"; definida VACÍA -> desactivada (retrocompat exacto).
out_unset="$(TF_ROOT="$MOTOR" TF_CLONE="$QS_CLONE" TF_MANIFEST="$QS_MAN" TF_SLUG="o/r" TF_STATION_HOST="$SEAL_STATION" TF_RUNNER_IDENTITY_MAP="$SEAL_ID_MAP" bash "$MOTOR/scripts/seal-suite.sh" --plan 9 "$QS_SHA" "$QS_SHA" rgP4a 2>&1)"
printf '%s' "$out_unset" | grep -q "fase quieta (serial, sin e2e): unit" \
  && ok "(p4) TF_QUIET_GATES sin definir → default 'unit' en fase quieta" \
  || ko "(p4) default de TF_QUIET_GATES no aplicado"
out_empty="$(TF_ROOT="$MOTOR" TF_CLONE="$QS_CLONE" TF_MANIFEST="$QS_MAN" TF_SLUG="o/r" TF_QUIET_GATES="" TF_STATION_HOST="$SEAL_STATION" TF_RUNNER_IDENTITY_MAP="$SEAL_ID_MAP" bash "$MOTOR/scripts/seal-suite.sh" --plan 9 "$QS_SHA" "$QS_SHA" rgP4b 2>&1)"
printf '%s' "$out_empty" | grep -q "fase quieta (serial, sin e2e): (ninguna)" \
  && ok "(p4) TF_QUIET_GATES=\"\" (definida vacía) → fase quieta desactivada (retrocompat exacto)" \
  || ko "(p4) TF_QUIET_GATES=\"\" no desactiva la fase quieta"
printf '%s' "$out_empty" | grep -q "carril ligero (paralelo): typecheck lint build unit i18n" \
  && ok "(p4) TF_QUIET_GATES=\"\": TODOS los gates vuelven al carril paralelo (comportamiento previo íntegro)" \
  || ko "(p4) TF_QUIET_GATES=\"\": el carril paralelo no recupera todos los gates"

# (p5) --plan: total gates intacto (cobertura) con la fase quieta activa por default.
printf '%s' "$out_unset" | grep -q "total gates: 7" \
  && ok "(p5) --plan: total gates intacto (cobertura) con fase quieta activa" \
  || ko "(p5) total gates cambió con la fase quieta activa"

# (p4c) default BEST-EFFORT: un manifiesto SIN gate "unit" (p.ej. talent-comms/talent-media,
# que usan "test") NO debe morir con el default sin definir — el default se ignora en silencio.
QS_MAN_NOUNIT="$TMP/qs-nounit.conf"
printf 'TF_PROJECT="test"\nTF_GATE_IDS="typecheck lint build test"\n' > "$QS_MAN_NOUNIT"
printf 'TF_E2E_FAMILIES="fam"\nTF_SHARDS_REGISTRY="scripts/ci/e2e-shards.json"\n' >> "$QS_MAN_NOUNIT"
out_nounit="$(TF_ROOT="$MOTOR" TF_CLONE="$QS_CLONE" TF_MANIFEST="$QS_MAN_NOUNIT" TF_SLUG="o/r" TF_STATION_HOST="$SEAL_STATION" TF_RUNNER_IDENTITY_MAP="$SEAL_ID_MAP" bash "$MOTOR/scripts/seal-suite.sh" --plan 9 "$QS_SHA" "$QS_SHA" rgP4c 2>&1)"; rc_nounit=$?
check "(p4c) TF_QUIET_GATES sin definir + manifiesto SIN gate 'unit' → NO muere (default best-effort)" 0 "$rc_nounit"
printf '%s' "$out_nounit" | grep -q "fase quieta (serial, sin e2e): (ninguna)" \
  && ok "(p4c) default 'unit' ausente del manifiesto → fase quieta vacía, sin fail-closed espurio" \
  || ko "(p4c) el default best-effort no se comportó como esperado"

echo "== Contrato: atestación de la lib de carve-out =="
# F-runner: asignación válida SALVO carveout_sha256 (bogus) + lib real ⇒ el motor MUERE antes de
# sourcear (no ejecuta código no atestado). Muere en el bloque de verificación, antes del worktree.
ASG_BADCV="$TMP/asg-badcv.json"
jq -n --arg sha "$GSHA2" --arg base "$GSHA" --arg md "$MAN_DIG_OK" --arg motor "$MOTOR_OK" --arg btip "$GSHA" \
  '{schema_version:1,run_group:"rgBADCV",repo:"o/r",pr:"9",sha:$sha,base_sha:$base,base_tip_sha:$btip,manifest_digest:$md,base_registry_digest:"n/a",head_registry_digest:"n/a",gate_id:"verde",motor_sha256:$motor,carveout_sha256:"0000000000000000000000000000000000000000000000000000000000000000"}' > "$ASG_BADCV"
bash "$RLG" "$RGR" --assignment "$ASG_BADCV" --manifest "$MAN_OK" --lib-carveout "$MOTOR/scripts/lib/carveout.sh" >/dev/null 2>&1
check "runner: carveout_sha256 sellado ≠ digest de la lib transportada → exit 2 (código no atestado)" 2 $?
# F-agregador: journal con carveout_sha256 NO aprobado (64-hex ≠ APPROVED) ⇒ rechazo.
grep -v '"gate_id":"verde"' "$ROK/journal.jsonl" > "$RAP/journal.jsonl"
jq -nc --arg rs "$vsha" --arg a "$HEX64" --arg m "$MOTOR_OK" --arg cv "$HEX64" '{run_group:"rgS",gate_id:"verde",receipt:"verde.json",receipt_sha256:$rs,exit_code:0,assignment_sha256:$a,motor_sha256:$m,carveout_sha256:$cv,isolation:"container:fake01",sealed_at:"t"}' >> "$RAP/journal.jsonl"
rm -f "$TMP/viewcount"
plg rgS o/r 9 --receipts "$RAP" --manifest "$MAN_OK" --repo "$GR" --context local-gates-test >/dev/null 2>&1
check "agregador: journal con carveout_sha256 NO aprobado (lib no atestada) → exit 2" 2 $?

echo "== Contrato: gate de inercia cableado (survivor + always-on, motor-go) =="
acad="$MOTOR/manifiestos/ejemplo.conf"
# TAL-3439: el contrato depende del ESTADO del carve-out — 1 exige el cableado; 0 exige la
# coherencia inversa; cualquier otro valor (o la clave ausente) es FALLO EXPLÍCITO, para que un
# typo jamás se interprete en silencio como «apagado» y deje pasar una config no ratificada.
co="$(sed -n 's/^TF_CARVEOUT_DOCS_ONLY="\([^"]*\)".*$/\1/p' "$acad" | tail -1)"
ig="$(sed -n 's/^TF_CARVEOUT_INERT_GATE="\([^"]*\)".*$/\1/p' "$acad" | tail -1)"
cids="$(sed -n 's/^TF_GATE_IDS="\([^"]*\)".*$/\1/p' "$acad" | tail -1)"
ckeep="$(sed -n 's/^TF_CARVEOUT_KEEP_GATES="\([^"]*\)".*$/\1/p' "$acad" | tail -1)"
case "$co" in
  1) { printf '%s\n' $cids | grep -qx "$ig" && printf '%s\n' $ckeep | grep -qx "$ig"; } \
       && ok "academy: carve-out ON — inert-gate '$ig' ∈ TF_GATE_IDS ∩ TF_CARVEOUT_KEEP_GATES" \
       || ko "academy: carve-out ON pero inert-gate no cableado" ;;
  0) { [ -z "$ig" ] && ! printf '%s\n' $cids | grep -qx "carveout-check" \
       && ! printf '%s\n' $ckeep | grep -qx "carveout-check"; } \
       && ok "academy: carve-out OFF — INERT_GATE vacío y carveout-check fuera de ambas listas" \
       || ko "academy: carve-out OFF con restos del gate de inercia (INERT_GATE='$ig')" ;;
  *) ko "academy: TF_CARVEOUT_DOCS_ONLY='$co' no reconocido (ni 1 ni 0, o clave ausente)" ;;
esac
# motor-go: carve-out habilitado + ratificado, pero SIN inert-gate cableado ⇒ sin sentinel.
MG="$TMP/mg"; git init -q -b main "$MG"; git -C "$MG" config user.email t@t; git -C "$MG" config user.name t
mkdir -p "$MG/scripts" "$MG/manifiestos" "$MG/.claude"
cp "$MOTOR/scripts/motor-go.sh" "$MG/scripts/"
printf 'TF_PROJECT="x"\nTF_GATE_IDS="a"\nTF_GATE_CMD_a="true"\nTF_DB_GATE="always"\n' > "$MG/manifiestos/academy.conf"
printf '# rat\n' > "$MG/manifiestos/RATIFICACIONES.log"
git -C "$MG" add -A; git -C "$MG" commit -qm base >/dev/null
git clone -q --bare "$MG" "$TMP/mg-origin.git"; git -C "$MG" remote add origin "$TMP/mg-origin.git"; git -C "$MG" push -q origin main >/dev/null 2>&1
MG_DUMMY_DIGEST="$(printf 'dummy' | sha256sum | cut -d' ' -f1)"
mg_co() { # <inert-gate-name-o-vacío>
  { printf 'TF_PROJECT="x"\nTF_GATE_IDS="a"\nTF_GATE_CMD_a="true"\nTF_DB_GATE="always"\nTF_CARVEOUT_DOCS_ONLY="1"\nTF_CARVEOUT_KEEP_GATES="a"\nTF_CARVEOUT_PATHS="docs/"\nTF_CARVEOUT_INERT_DIGEST="%s"\nTF_CARVEOUT_INERT_DIGEST_SHA="deadbeef"\n' "$MG_DUMMY_DIGEST"
    [ -n "$1" ] && printf 'TF_CARVEOUT_INERT_GATE="%s"\n' "$1"; } > "$MG/manifiestos/academy.conf"
}
mg_run() { ( cd "$MG" && MOTOR_GO_NO_SHELLCHECK=1 bash scripts/motor-go.sh >/dev/null 2>&1 ); }
printf '%s | ref=TEST | items=academy.conf | x\n' "$(git -C "$MG" log -1 --format=%cd --date=short 2>/dev/null || echo 2026-01-01)" >> "$MG/manifiestos/RATIFICACIONES.log"
mg_co ""       # carve-out ratificado pero SIN TF_CARVEOUT_INERT_GATE
git -C "$MG" commit -qam sin-inert >/dev/null; rm -f "$MG/.claude/.motor-go"; mg_run; rc=$?
check "motor-go: carve-out ratificado SIN inert-gate cableado → sin sentinel (rc 1)" 1 "$rc"
[ ! -f "$MG/.claude/.motor-go" ] && ok "no se emitió sentinel (config de carve-out inválida)" || ko "sentinel emitido pese a inert-gate ausente"
mg_co "a"      # inert-gate 'a' cableado (∈ GATE_IDS ∩ KEEP)
git -C "$MG" commit -qam con-inert >/dev/null; rm -f "$MG/.claude/.motor-go"; mg_run; rc=$?
check "motor-go: carve-out ratificado + inert-gate cableado → sentinel (rc 0)" 0 "$rc"
[ -f "$MG/.claude/.motor-go" ] && ok "sentinel emitido (inert-gate correctamente cableado)" || ko "sin sentinel pese a inert-gate cableado"

# ── TAL-3629: arnés del gate CR-CLI absorbido (scripts/cr-review.sh). ─────────────────────────
# El motor arrastraba un espejo congelado de 148 líneas sin las defensas de TOCTOU ni de
# concurrencia que el spike TAL-3568 midió en sandbox. Con la absorción llega también su arnés,
# que es lo que las convierte en verificables AQUÍ: sin este cableado el arnés estaría en el repo sin
# gatear nada, y una regresión de las dos defensas del gate que autoriza TODOS los pushes de la
# fábrica volvería a pasar inadvertida. Se ata a PASS/FAIL con `check`, igual que el resto del arnés
# (el arnés corre con `set -uo pipefail`, SIN `set -e`: invocarlo sin comparar su rc dejaría el fallo
# en silencio y el motor terminaría en VERDE).
# Autocontenido: crea su propio repo git en un tmpdir con stubs de `coderabbit`/`gh` → cero red, cero
# bucket real de CodeRabbit. Sin `flock` (util-linux) el propio arnés sale 0 declarándolo, igual que
# `cr-review.sh` falla cerrado sin él.
echo "== TAL-3629: arnés de scripts/cr-review.sh (concurrencia + TOCTOU, offline) =="
cr_harness_rc=0
cr_harness_out="$TMP/cr-review-harness.out"
bash "$MOTOR/tests/scripts/cr-review-harness.sh" > "$cr_harness_out" 2>&1 || cr_harness_rc=$?
check "tests/scripts/cr-review-harness.sh (todos los escenarios)" 0 "$cr_harness_rc"
if [ "$cr_harness_rc" -ne 0 ]; then
  echo "  ---- salida del arnés de cr-review ----" >&2
  cat "$cr_harness_out" >&2
fi

# ── TAL-3854: el sync del paquete NO debe revertir el fix del gate-red ────────
# El fix (gitleaks:allow por-línea + guard anti-drift, Refs TAL-3812) vive en
# skills/talent-channels/tests/run-tests.sh. Si el motor lo pierde, sync-package
# (rsync -rcl --delete) lo REVERTIRÍA en los repos de producto. Este guard exige
# que el motor porte el fix, y lo demuestra por mutación con un dry-run de rsync
# (misma mecánica -rcln --delete que sync-package; -i para que itemice el cambio).
TCRT="$MOTOR/skills/talent-channels/tests/run-tests.sh"
if [ -f "$TCRT" ]; then
  n_allow="$(grep -c '# gitleaks:allow' "$TCRT")"
  n_drift="$(grep -cE 'fixture-drift' "$TCRT")"
  if [ "$n_allow" -ge 2 ]; then ok "TAL-3854: fix gitleaks:allow presente en el motor ($n_allow)"; else ko "TAL-3854: faltan marcadores gitleaks:allow ($n_allow<2)"; fi
  if [ "$n_drift" -ge 2 ]; then ok "TAL-3854: guards anti-drift presentes ($n_drift)"; else ko "TAL-3854: faltan guards anti-drift ($n_drift<2)"; fi
  SR="$TMP/tc-sync"; mkdir -p "$SR/src" "$SR/dst"
  cp "$TCRT" "$SR/src/f"; cp "$TCRT" "$SR/dst/f"
  chg="$(rsync -rclni --delete "$SR/src/" "$SR/dst/" 2>/dev/null)"
  if [ -z "$chg" ]; then ok "TAL-3854 VERDE: sync dry-run no revierte (motor==producto)"; else ko "TAL-3854: sync reporta cambio con el fix presente"; fi
  grep -v '# gitleaks:allow' "$TCRT" > "$SR/src/f"
  chg2="$(rsync -rclni --delete "$SR/src/" "$SR/dst/" 2>/dev/null)"
  if [ -n "$chg2" ]; then ok "TAL-3854 ROJO (mutación): sin el fix, el sync SÍ revertiría (detectado)"; else ko "TAL-3854: mutación no detectada (guard sin dientes)"; fi
else
  ko "TAL-3854: no se encontró $TCRT"
fi

# ── TAL-3842 (item 2): guard PreToolUse cierra la clase «sustitución+push en argumento» ──
# Cierre POR CONSTRUCCIÓN: $()/backtick/${} con evidencia de push → DENY fail-closed. Verdes de
# no-regresión (status/commit/fetch/$() sin push) → ALLOW. Evidencia por MUTACIÓN: neutralizada la
# detección de sustitución (línea CLASS-CHECK), la clase vuelve a pasar (ALLOW) — dientes.
GUARD="$MOTOR/.claude/hooks/guard-git-push.sh"
if [ -f "$GUARD" ]; then
  # Clasificador explícito DENY/ALLOW/ERROR (CR major): JAMÁS convertir error/crash/vacío-inesperado
  # en ALLOW por búsqueda de texto. allow = silencio+exit0; deny = permissionDecision "deny";
  # cualquier otra cosa (rc!=0, JSON inválido, decisión desconocida) = ERROR → el test FALLA.
  g_verdict() { # <cmd-string> <guard-path>  → imprime DENY|ALLOW|ERROR
    # Salida a fichero (bytes EXACTOS, sin que $() recorte newlines) + rc del guard (no del pipe).
    local of="$TMP/gv.out" rc
    python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1" | bash "$2" >"$of" 2>/dev/null
    rc=${PIPESTATUS[1]}
    [ "$rc" -ne 0 ] && { echo ERROR; return; }        # guard reventó → ERROR (nunca ALLOW)
    [ ! -s "$of" ] && { echo ALLOW; return; }          # 0 bytes exactos = allow (silencio del guard)
    # bytes presentes → exigir JSON válido con permissionDecision EXACTO; deny→DENY, cualquier otro→ERROR
    python3 -c 'import json,sys
try: dec=json.load(open(sys.argv[1]))["hookSpecificOutput"]["permissionDecision"]
except Exception: print("ERROR"); sys.exit(0)
print("DENY" if dec=="deny" else "ERROR")' "$of"
  }
  g_assert() { # <cmd> <guard> <esperado> <etiqueta>
    local v; v="$(g_verdict "$1" "$2")"
    if [ "$v" = "$3" ]; then ok "guard[$4] $3"; else ko "guard[$4] esperaba $3 obtuvo $v :: $1"; fi
  }
  # Clase (sustituciones ejecutables $() ` ${} <() ; incl. git -C … push) × portadores → DENY
  for gc in \
    'git commit -m "$(git push --no-verify origin main)"' \
    'git tag -m "$(git -C /r push origin main)" v9' \
    'git commit -m "`git push origin main`"' \
    'git commit -m "${x:=$(git push origin main)}"' \
    'git commit -m msg <(git push origin main)'; do
    g_assert "$gc" "$GUARD" DENY clase
  done
  # Verdes de no-regresión → ALLOW
  for gc in 'git status' 'git commit -m "fix normal"' 'git fetch origin' 'git diff' 'git commit -m "$(date)"'; do
    g_assert "$gc" "$GUARD" ALLOW verde
  done
  # Fail-closed: parse-error con push → DENY ; sin push → ALLOW (silencio)
  if printf '{roto git push x' | bash "$GUARD" 2>/dev/null | grep -qE '"deny"'; then ok "guard[fail-closed] parse-error+push DENY"; else ko "guard[fail-closed] parse-error+push NO denegado"; fi
  po="$(printf '{roto sin nada' | bash "$GUARD" 2>/dev/null)"; if [ -z "$po" ]; then ok "guard[fail-closed] parse-error sin push ALLOW"; else ko "guard[fail-closed] parse-error sin push emitió: $po"; fi
  # Mutación (dientes): sin la línea CLASS-CHECK, la clase → ALLOW LIMPIO (no ERROR)
  GMUT="$TMP/guard-mut.sh"
  python3 -c 'import sys; open(sys.argv[2],"w").write("".join(("  if false; then  # CLASS-CHECK mutado\n" if "# CLASS-CHECK" in l else l) for l in open(sys.argv[1])))' "$GUARD" "$GMUT"
  g_assert 'git commit -m "$(git push --no-verify origin main)"' "$GMUT" ALLOW mutación
else
  SKIP=$((SKIP+1))
  echo '  SKIP guard PreToolUse: hook de instancia no distribuido; no se evaluó su conducta'
fi

echo "== TAL-5586: NO MEDIDO — el rc 2 de instrumento NO se imputa al sujeto =="
# Fixture PROPIO y aislado: no reutiliza $GR/$MAN porque otras secciones los mutan.
# `rc2_optin_vacio` es PREFIJO RESERVADO del canal SKIP_REASON (plan §2.2).
T86="$TMP/tal5586"; mkdir -p "$T86"
G86="$T86/repo"; G86B="$T86/repo.git"
mk_repo "$G86"
git clone -q --bare "$G86" "$G86B"; git -C "$G86" remote add origin "$G86B"
git -C "$G86" push -qu origin main >/dev/null 2>&1
S86="$(git -C "$G86" rev-parse HEAD)"
MAN86="$T86/m.conf"
cat > "$MAN86" <<EOF
TF_PROJECT="test"
TF_GATE_IDS="zzgate otro db-guards"
TF_GATE_CMD_zzgate="exit 2"
TF_GATE_CMD_otro="true"
TF_GATE_CMD_db_guards="true"
TF_INSTALL="true"
TF_DB_GATE="never"
TF_MIGRATIONS_DIR="supabase/migrations"
TF_GATES_RC2_OPTIN="zzgate"
EOF
# TMPDIR aislado por invocación: RUN_DIR cuelga de él y el `trap` NO lo borra (solo el worktree),
# así que el log del gate queda inspeccionable — es el observable de retención del log.
t86_run() { # <manifiesto> <gate> <dir-aislado>
  mkdir -p "$3"
  TMPDIR="$3" bash "$RLG" "$G86" --gate "$2" --manifest "$1" \
    --sha "$S86" --base "$S86" --receipt "$3/receipt.json" >/dev/null 2>&1
}
t86_log() { find "$1/local-gates" -name gate.log -type f 2>/dev/null | head -1; }

# NOTA DE REGISTRO (TAL-5586): cada CASO aporta UNA entrada `check` EN INICIO DE LÍNEA — es lo
# único que ve el extractor del guardián (`^ *check "`). Los observables adicionales y los
# controles negativos van por `ok`/`ko`, como el resto del arnés. Un `check` a media línea NO
# entra en el universo del guardián y su pérdida quedaría VERDE.

# rc 2 CON opt-in ⇒ SKIP + token + exit 0. Hoy: FAIL/1 ⇒ ROJO.
t86_run "$MAN86" zzgate "$T86/m1"; m1_rc=$?
check "rc 2 con opt-in → exit 0 (NO MEDIDO)" 0 "$m1_rc"
jq -e '.result=="SKIP" and ((.skip_reason//"")|startswith("rc2_optin_vacio"))' "$T86/m1/receipt.json" >/dev/null 2>&1 \
  && ok "receipt SKIP con token rc2_optin_vacio" || ko "receipt sin SKIP/token"
# Control negativo: mismo camino, rc 1 ⇒ FAIL (discrimina el 2 del resto).
sed 's/TF_GATE_CMD_zzgate="exit 2"/TF_GATE_CMD_zzgate="exit 1"/' "$MAN86" > "$T86/m-rc1.conf"
t86_run "$T86/m-rc1.conf" zzgate "$T86/m1n"; m1n_rc=$?
[ "$m1n_rc" -eq 1 ] && ok "rc 1 con opt-in → FAIL, no NO MEDIDO" \
  || ko "rc 1 con opt-in no dio FAIL (rc=$m1n_rc)"

# VERDE HOY por diseño. Su prueba es el mutante (default opta=1).
sed 's/TF_GATES_RC2_OPTIN="zzgate"/TF_GATES_RC2_OPTIN=""/' "$MAN86" > "$T86/m-vacia.conf"
t86_run "$T86/m-vacia.conf" zzgate "$T86/m2"; m2_rc=$?
check "rc 2 SIN opt-in → exit 1 (sin regresión)" 1 "$m2_rc"
jq -e '.result=="FAIL"' "$T86/m2/receipt.json" >/dev/null 2>&1 \
  && ok "receipt FAIL con lista vacía" || ko "receipt no FAIL con lista vacía"
# Control negativo: lista NO vacía que no casa (más limpio que usar M1).
sed 's/TF_GATES_RC2_OPTIN="zzgate"/TF_GATES_RC2_OPTIN="otrogate"/' "$MAN86" > "$T86/m-otro.conf"
t86_run "$T86/m-otro.conf" zzgate "$T86/m2n"; m2n_rc=$?
[ "$m2n_rc" -eq 1 ] && ok "opt-in que NO casa → FAIL" \
  || ko "opt-in que no casa no dio FAIL (rc=$m2n_rc)"

# VERDE HOY. Variable AUSENTE bajo `set -u`: FAIL, no aborto (exit 1, no 2).
grep -v '^TF_GATES_RC2_OPTIN=' "$MAN86" > "$T86/m-ausente.conf"
t86_run "$T86/m-ausente.conf" zzgate "$T86/m3"; m3_rc=$?
# COMPUESTO: el rc SOLO no discrimina — abortar bajo `set -u` también sale 1, el MISMO valor que
# un FAIL legítimo. Un observable que comparte valor con el modo de fallo que debe excluir no
# prueba nada: hay que exigir además el RECEIPT, que el aborto nunca llega a escribir.
m3_ok=1
if [ "$m3_rc" -eq 1 ] && jq -e '.result=="FAIL"' "$T86/m3/receipt.json" >/dev/null 2>&1; then m3_ok=0; fi
check "variable AUSENTE + rc 2 → FAIL con receipt, sin abortar bajo set -u" 0 "$m3_ok"
jq -e '.result=="FAIL"' "$T86/m3/receipt.json" >/dev/null 2>&1 \
  && ok "receipt escrito con la variable ausente (no hubo aborto)" || ko "sin receipt: la variable ausente abortó"

# observable COMPUESTO: SKIP con token Y el log conservado a 0600.
# Compuesto a propósito: la supervivencia del log SOLA ya se cumple hoy (FAIL también lo conserva),
# así que un observable que solo mirase el log estaría VERDE hoy y no probaría nada.
t86_run "$MAN86" zzgate "$T86/m4"; m4_rc=$?
m4_log="$(t86_log "$T86/m4")"
m4_ok=1
if [ "$m4_rc" -eq 0 ] \
   && jq -e '.result=="SKIP" and ((.skip_reason//"")|startswith("rc2_optin_vacio"))' "$T86/m4/receipt.json" >/dev/null 2>&1 \
   && [ -n "$m4_log" ] && [ "$(stat -c %a "$m4_log")" = "600" ]; then m4_ok=0; fi
check "NO MEDIDO: SKIP con token Y log conservado a 0600" 0 "$m4_ok"
# Control negativo: rc 0 ⇒ PASS y el log SE BORRA.
sed 's/TF_GATE_CMD_zzgate="exit 2"/TF_GATE_CMD_zzgate="true"/' "$MAN86" > "$T86/m-rc0.conf"
t86_run "$T86/m-rc0.conf" zzgate "$T86/m4n"
[ -z "$(t86_log "$T86/m4n")" ] && ok "PASS: el log SE BORRA" || ko "PASS conservó el log"

# P1 (M) — END-TO-END SELLADO: motor REAL → run-gate-sealed REAL → receipt sellado → posteador REAL.
# Sin artefacto sintético en medio: es lo que cubre la costura motor→sellador (plan §2.4).
MAN86S="$T86/sealed.conf"
cat > "$MAN86S" <<EOF
TF_PROJECT="test"
TF_GATE_IDS="zzgate"
TF_GATE_CMD_zzgate="exit 2"
TF_INSTALL="true"
TF_DB_GATE="never"
TF_MIGRATIONS_DIR="supabase/migrations"
TF_GATES_RC2_OPTIN="zzgate"
EOF
RC86="$T86/receipts"; mkdir -p "$RC86"
rgs zzgate rg5586 "$MAN86S" "$RC86" >/dev/null 2>&1; p1a_rc=$?
rm -f "$TMP/viewcount"
out86="$(LG_STATE_EXPECTED=failure plg rg5586 o/r 9 --receipts "$RC86" --manifest "$MAN86S" --repo "$GR" --context local-gates-test 2>&1)"; p1b_rc=$?
# Los CUATRO asserts del recorrido sellado, en UNA entrada de registro: si cualquiera de los
# cuatro tramos se rompe, el caso enrojece — no hay que prever DÓNDE se romperá.
p1_ok=1
if [ "$p1a_rc" -eq 0 ] \
   && jq -e '.result=="SKIP" and ((.skip_reason//"")|startswith("rc2_optin_vacio"))' "$RC86/zzgate.json" >/dev/null 2>&1 \
   && [ "$p1b_rc" -eq 1 ] \
   && printf '%s' "$out86" | grep -q "○ zzgate: NO MEDIDO" \
   && printf '%s' "$out86" | grep -q "0 FAIL, 1 NO MEDIDO"; then p1_ok=0; fi
check "(5586-P1) end-to-end SELLADO: motor→lanzador→receipt→posteador, 4 asserts" 0 "$p1_ok"
[ "$p1a_rc" -eq 0 ] && ok "(5586-P1a) el NO MEDIDO cruza el lanzador sin tocarlo (exit 0)" \
  || ko "(5586-P1a) el lanzador no dejó pasar el NO MEDIDO (rc=$p1a_rc)"
jq -e '.result=="SKIP" and ((.skip_reason//"")|startswith("rc2_optin_vacio"))' "$RC86/zzgate.json" >/dev/null 2>&1 \
  && ok "(5586-P1b) receipt SELLADO lleva result=SKIP y el token" || ko "(5586-P1b) receipt sellado sin SKIP/token"
[ "$p1b_rc" -eq 1 ] && ok "(5586-P1c) agregador: failure posteado (exit 1)" \
  || ko "(5586-P1c) agregador no posteó failure (rc=$p1b_rc)"
printf '%s' "$out86" | grep -q "0 FAIL, 1 NO MEDIDO" \
  && ok "(5586-P1d) resumen: 0 FAIL, 1 NO MEDIDO (bloquea SIN imputar)" || ko "(5586-P1d) resumen sin el recuento NO MEDIDO"
# P1 control negativo: casi-acierto de token ⇒ recorre el MISMO switch y NO emite la línea.
RC86N="$T86/receipts-ctrl"; mkdir -p "$RC86N"
cp "$RC86/zzgate.json" "$RC86N/zzgate.json" 2>/dev/null || true
if [ -f "$RC86N/zzgate.json" ]; then
  jq '.skip_reason="rc2_optin_vacia: casi-acierto"' "$RC86N/zzgate.json" > "$RC86N/t" && mv "$RC86N/t" "$RC86N/zzgate.json"
  out86n="$(LG_STATE_EXPECTED=failure plg rg5586 o/r 9 --receipts "$RC86N" --manifest "$MAN86S" --repo "$GR" --context local-gates-test 2>&1)"
  printf '%s' "$out86n" | grep -q "NO MEDIDO" \
    && ko "(5586-P1-ctrl) casi-acierto de token clasificó como NO MEDIDO" || ok "(5586-P1-ctrl) casi-acierto NO emite la línea (prefijo específico)"
fi

# P2 (R) — VERDE HOY: los receipts CLÁSICOS siguen clasificando, contando y dando success.
# Conduce PASS y SKIP-clásico (db-guards con TF_DB_GATE=never) hasta el agregador REAL: así el
# caso enrojece si la rama nueva se traga un SKIP legítimo. El mutante que el plan proponía
# —ignorar `no_medidos` en STATE— NO discrimina aquí: con receipts clásicos `no_medidos` vale 0
# y la mutación es invisible. El discriminante real es ENSANCHAR el patrón del token.
RC86C="$T86/receipts-clasicos"; mkdir -p "$RC86C"
# Manifiesto dedicado: el agregador exige receipt de TODOS los TF_GATE_IDS, así que la lista
# tiene que ser exactamente la de los gates que este caso produce (sin `zzgate`).
MAN86C="$T86/clasicos.conf"
grep -v '^TF_GATE_IDS=' "$MAN86" | grep -v '^TF_GATES_RC2_OPTIN=' > "$MAN86C"
printf 'TF_GATE_IDS="otro db-guards"\nTF_GATES_RC2_OPTIN=""\n' >> "$MAN86C"
rgs otro rg5586c "$MAN86C" "$RC86C" >/dev/null 2>&1; p2a_rc=$?
rgs db-guards rg5586c "$MAN86C" "$RC86C" >/dev/null 2>&1; p2b_rc=$?
rm -f "$TMP/viewcount"
out86c="$(plg rg5586c o/r 9 --receipts "$RC86C" --manifest "$MAN86C" --repo "$GR" --context local-gates-test 2>&1)"; p2c_rc=$?
p2_ok=1
if [ "$p2a_rc" -eq 0 ] && [ "$p2b_rc" -eq 0 ] && [ "$p2c_rc" -eq 0 ] \
   && printf '%s' "$out86c" | grep -q "0 NO MEDIDO" \
   && ! printf '%s' "$out86c" | grep -q "○ db-guards: NO MEDIDO"; then p2_ok=0; fi
check "(5586-P2) receipts clásicos: PASS y SKIP legítimo → success, 0 NO MEDIDO" 0 "$p2_ok"
printf '%s' "$out86c" | grep -q "0 NO MEDIDO" \
  && ok "(5586-P2-det) el recuento NO MEDIDO no contamina una corrida clásica" || ko "(5586-P2-det) recuento NO MEDIDO contaminado"

# ── seal-suite (§5): fixture QS5 cuyo fake SÍ escribe receipts (el de C11 no escribe ninguno).
QS5_ROOT="$T86/qs5"; mkdir -p "$QS5_ROOT/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$QS5_ROOT/scripts/post-local-gates.sh"
chmod +x "$QS5_ROOT/scripts/post-local-gates.sh"
cat > "$QS5_ROOT/scripts/run-gate-sealed.sh" <<'QS5FAKE'
#!/usr/bin/env bash
set -uo pipefail
GATE="$1"; shift
REC=""
while [ $# -gt 0 ]; do case "$1" in --receipts) REC="$2"; shift 2;; *) shift;; esac; done
sg="$(printf '%s' "$GATE" | tr ':' '_')"
rc=0
case "$GATE" in
  "${QS5_NOMED_GATE:-}")   printf '{"schema_version":1,"gate_id":"%s","result":"SKIP","skip_reason":"%s"}\n' "$GATE" "${QS5_REASON:-rc2_optin_vacio: fixture}" > "$REC/$sg.json" ;;
  "${QS5_CORRUPT_GATE:-}") printf 'esto-no-es-json{' > "$REC/$sg.json" ;;
  "${QS5_FAIL_GATE:-}")    rc=1 ;;
  *)                       printf '{"schema_version":1,"gate_id":"%s","result":"PASS"}\n' "$GATE" > "$REC/$sg.json" ;;
esac
exit "$rc"
QS5FAKE
chmod +x "$QS5_ROOT/scripts/run-gate-sealed.sh"
qs5_run() { # <run-group> <runner...>
  local rg="$1"; shift
  PATH="$QS_SHIM:$PATH" TF_ROOT="$QS5_ROOT" TF_CLONE="$QS_CLONE" TF_MANIFEST="$QS_MAN" TF_SLUG="o/r" \
    TF_STATION_HOST="$SEAL_STATION" TF_RUNNER_IDENTITY_MAP="$SEAL_ID_MAP" \
    bash "$MOTOR/scripts/seal-suite.sh" --no-post 9 "$QS_SHA" "$QS_SHA" "$rg" "$@" 2>&1
}

# S1 (M) — un NO MEDIDO deja de contar verde en el fan-out y --no-post deja de salir 0.
s1_out="$(QS5_NOMED_GATE=unit qs5_run rg5586s1 r0 r1 r2)"; s1_rc=$?
check "(5586-S1) seal-suite --no-post con un NO MEDIDO → exit 1" 1 "$s1_rc"
printf '%s' "$s1_out" | grep -q "NO MEDIDO:" \
  && ok "(5586-S1) el fan-out nombra el gate NO MEDIDO" || ko "(5586-S1) el fan-out no nombra el NO MEDIDO"
# S1 control negativo: SKIP LEGÍTIMO (carve-out) ⇒ sigue verde y exit 0.
QS5_NOMED_GATE=unit QS5_REASON="carve-out-docs-only: legítimo" qs5_run rg5586s1n r0 r1 r2 >/dev/null 2>&1; s1n_rc=$?
[ "$s1n_rc" -eq 0 ] && ok "(5586-S1-ctrl) SKIP legítimo → exit 0 (no todo SKIP es NO MEDIDO)" \
  || ko "(5586-S1-ctrl) un SKIP legítimo enrojeció el fan-out (rc=$s1n_rc)"

# S2 (R) — VERDE HOY y debe seguirlo: el fixture ORIGINAL (C11) no escribe ningún receipt.
# Su mutante —hacer la detección fail-closed ante $REC vacío— pondría ROJO este verde (C9).
QS_LOG="$TMP/qs-5586.log"; : > "$QS_LOG"
QS_LOG="$QS_LOG" qs_run rg5586s2 r0 r1 r2 >/dev/null 2>&1
check "(5586-S2) ausencia REAL de receipts → exit 0 (no se inventa un rojo; protege C9)" 0 $?

# S3 (M) — receipt PRESENTE pero ilegible ⇒ NO MEDIDO, no ausencia. El fallo de `jq` TIÑE.
s3_out="$(QS5_CORRUPT_GATE=unit qs5_run rg5586s3 r0 r1 r2)"; s3_rc=$?
check "(5586-S3) receipt presente e ILEGIBLE → exit 1 (el fallo de jq tiñe)" 1 "$s3_rc"
printf '%s' "$s3_out" | grep -q "receipt-ilegible" \
  && ok "(5586-S3) el fan-out distingue receipt ilegible de ausencia" || ko "(5586-S3) receipt ilegible pasó como ausencia"

# S4 (M) — con FAIL y NO MEDIDO a la vez se imprimen AMBOS (el `elif` ocultaba el segundo).
# AMBOS gates van en la FASE 1 (carril ligero paralelo). No sirve poner el NO MEDIDO en `unit`:
# es el default de TF_QUIET_GATES y la fase quieta se OMITE fail-closed cuando la fase 1 va
# sucia, así que el gate no llegaría a correr y la combinación sería inalcanzable por diseño.
s4_out="$(QS5_FAIL_GATE=lint QS5_NOMED_GATE=typecheck qs5_run rg5586s4 r0 r1 r2)"; s4_rc=$?
# COMPUESTO a propósito: el rc SOLO ya vale 1 hoy —lo pone el FAIL, no el NO MEDIDO—, así que un
# observable de rc habría estado VERDE y no probaría nada (ocurrió
# aquí: la primera redacción de este caso salió verde en la corrida roja).
s4_ok=1
if [ "$s4_rc" -eq 1 ] \
   && printf '%s' "$s4_out" | grep -q "GATES FALLIDOS:" \
   && printf '%s' "$s4_out" | grep -q "NO MEDIDO:"; then s4_ok=0; fi
check "(5586-S4) FAIL + NO MEDIDO: rc 1 y resumen ADITIVO con AMBOS visibles" 0 "$s4_ok"
printf '%s' "$s4_out" | grep -q "NO MEDIDO:" \
  && ok "(5586-S4-det) el NO MEDIDO no queda oculto por el FAIL" || ko "(5586-S4-det) el FAIL oculta el NO MEDIDO"

echo "== TAL-5196 E1: identidad de runner cierra el sobre-despacho INTRA-invocación (rg2118) =="
# Fixture compartida: fake incus (list -> CSV RUNNING/ausente según DOWN_RUNNERS; exec -> no-op)
# + fake ssh (ejecuta localmente el último argumento, delegando en el fake incus del PATH) +
# fake run-gate-sealed.sh (registra start/end/RUNNER en un log compartido) + fake
# post-local-gates.sh (no-op). Reproduce la FORMA exacta de rg2118: una invocación con el
# MISMO runner repetido (round-robin trataba cada posición como capacidad distinta).
RI_SHIM="$TMP/ri-shim"; mkdir -p "$RI_SHIM"
cat > "$RI_SHIM/incus" <<'RIINCUS'
#!/usr/bin/env bash
# Clave de estado = <host-destino>/<contenedor> — el destino es el TARGET real del transporte
# (canónico vía ssh, o "local" para incus directo de la estación), NUNCA el alias original:
# así la simulación respeta que ri_check_running dialoga SIEMPRE al host_canónico.
if [ "$1" = "list" ]; then
  pat="${*: -1}"
  name="$(printf '%s' "$pat" | sed 's/^\^//; s/\$$//')"
  key="${RI_TARGET_HOST:-local}/$name"
  for d in ${DOWN_RUNNERS:-}; do [ "$d" = "$key" ] && exit 0; done
  printf '%s,RUNNING\n' "$name"
  exit 0
fi
exit 0
RIINCUS
chmod +x "$RI_SHIM/incus"
cat > "$RI_SHIM/ssh" <<'RISSH'
#!/usr/bin/env bash
target=""
for a in "$@"; do case "$a" in root@*) target="${a#root@}";; esac; done
for d in ${SSH_FAIL_FOR:-}; do [ "$d" = "$target" ] && exit 255; done
cmd="${*: -1}"
RI_TARGET_HOST="$target" bash -c "$cmd"
RISSH
chmod +x "$RI_SHIM/ssh"

RI_ROOT="$TMP/ri-root"; mkdir -p "$RI_ROOT/scripts/lib"
cp "$MOTOR/scripts/lib/runner-identity.sh" "$RI_ROOT/scripts/lib/runner-identity.sh"
cp "$MOTOR/scripts/seal-suite.sh" "$RI_ROOT/scripts/seal-suite.sh"
cat > "$RI_ROOT/scripts/post-local-gates.sh" <<'RIPOST'
#!/usr/bin/env bash
exit 0
RIPOST
chmod +x "$RI_ROOT/scripts/post-local-gates.sh"
cat > "$RI_ROOT/scripts/run-gate-sealed.sh" <<'RIFAKE'
#!/usr/bin/env bash
set -uo pipefail
GATE="$1"; shift
RUNNER=""
while [ $# -gt 0 ]; do case "$1" in --runner) RUNNER="$2"; shift 2;; *) shift;; esac; done
LOG="${RI_LOG:?RI_LOG unset}"
printf 'start %s %s %s\n' "$GATE" "$RUNNER" "$(date +%s%N)" >> "$LOG"
sleep "${RI_DUR:-0.3}"
printf 'end %s %s %s\n' "$GATE" "$RUNNER" "$(date +%s%N)" >> "$LOG"
exit 0
RIFAKE
chmod +x "$RI_ROOT/scripts/run-gate-sealed.sh"

RI_CLONE="$TMP/ri-clone"; mkdir -p "$RI_CLONE/scripts/ci"
git init -q -b main "$RI_CLONE"; git -C "$RI_CLONE" config user.email t@t; git -C "$RI_CLONE" config user.name t
printf '{"schema_version":1,"families":{"fam":{"shards":[{"id":"s1"},{"id":"s2"},{"id":"s3"}]}}}\n' > "$RI_CLONE/scripts/ci/e2e-shards.json"
git -C "$RI_CLONE" add -A; git -C "$RI_CLONE" commit -qm base
RI_SHA="$(git -C "$RI_CLONE" rev-parse HEAD)"
RI_MAN="$TMP/ri.conf"; printf 'TF_PROJECT="test"\nTF_GATE_IDS="typecheck lint"\n' > "$RI_MAN"
printf 'TF_E2E_FAMILIES="fam"\nTF_SHARDS_REGISTRY="scripts/ci/e2e-shards.json"\n' >> "$RI_MAN"

RI_MAP="$TMP/ri-identity.map"
cat > "$RI_MAP" <<'RIMAP'
station=station
alpha=alpha-host
altalpha=alpha-host
RIMAP

ri_run() { # <run-group> <extra-env...> -- <runner-spec...>
  local rg="$1"; shift
  PATH="$RI_SHIM:$PATH" TF_ROOT="$RI_ROOT" TF_CLONE="$RI_CLONE" TF_MANIFEST="$RI_MAN" TF_SLUG="o/r" \
    TF_STATION_HOST="station" TF_RUNNER_IDENTITY_MAP="$RI_MAP" TF_QUIET_GATES="" \
    bash "$RI_ROOT/scripts/seal-suite.sh" --no-post 9 "$RI_SHA" "$RI_SHA" "$rg" "$@"
}

# (a) MUTACIÓN FORMA-rg2118 — 4 copias del MISMO runner físico en una invocación: tras
# identidad/dedup deben colapsar a un ÚNICO carril, y los gates sobre ese runner NUNCA se
# solapan en el tiempo (antes del fix, el fallback de HEAVY_POOL con 1 runner deduplicado
# lanzaba ligero+pesado EN PARALELO sobre él — ver "Cierres confirmados" del plan v9).
RI_LOG="$TMP/ri-a.log"; : > "$RI_LOG"
out_a="$(RI_LOG="$RI_LOG" ri_run rgA vibe-r0 vibe-r0 vibe-r0 vibe-r0 2>&1)"; rc_a=$?
check "(a) rg2118: 4 copias del mismo runner -> --no-post sale 0" 0 "$rc_a"
printf '%s' "$out_a" | grep -q "duplicado" \
  && ok "(a) rg2118: el log reporta los duplicados descartados" \
  || ko "(a) rg2118: no se ve el aviso de duplicado descartado"
# Overlap check: para cada gate, su ventana [start,end] no debe cruzarse con la de otro gate
# que corrió en el MISMO runner (columna 3 del log: start GATE RUNNER ts).
a_overlap=0
while read -r _ g1 r1 s1; do
  e1="$(grep "^end $g1 $r1 " "$RI_LOG" | awk '{print $4}')"
  while read -r _ g2 r2 s2; do
    [ "$g1" = "$g2" ] && continue
    [ "$r1" = "$r2" ] || continue
    e2="$(grep "^end $g2 $r2 " "$RI_LOG" | awk '{print $4}')"
    # solapan si s1 < e2 Y s2 < e1
    if [ "$s1" -lt "$e2" ] && [ "$s2" -lt "$e1" ]; then a_overlap=1; fi
  done < <(grep '^start ' "$RI_LOG")
done < <(grep '^start ' "$RI_LOG")
[ "$a_overlap" -eq 0 ] && ok "(a) rg2118: CERO solapes de ventana temporal en el runner deduplicado (serializado)" \
  || ko "(a) rg2118: se detectó solape temporal -- el sobre-despacho NO está cerrado"

# (b) filtro RUNNING exacto: un nombre que es PREFIJO de otro no debe confundirse ni colarse.
RI_LOG="$TMP/ri-b.log"; : > "$RI_LOG"
out_b="$(RI_LOG="$RI_LOG" DOWN_RUNNERS="local/vibe-r1" ri_run rgB vibe-r1 vibe-r10 2>&1)"; rc_b=$?
check "(b) RUNNING exacto: --no-post sale 0 con 1 superviviente" 0 "$rc_b"
printf '%s' "$out_b" | grep -q "NO-RUNNING.*vibe-r1$" \
  && ok "(b) RUNNING exacto: vibe-r1 (parado) descartado sin confundirse con vibe-r10" \
  || ko "(b) RUNNING exacto: no se descartó correctamente el runner parado"
grep -q "vibe-r10" "$RI_LOG" && ok "(b) RUNNING exacto: vibe-r10 (vivo) sí corrió" || ko "(b) vibe-r10 no corrió"

# (c) dedup por IDENTIDAD FÍSICA (tupla canónica), no por string literal : dos ALIASES
# DISTINTOS ("alpha" y "altalpha") que el mapa resuelve al MISMO host_canónico + mismo
# contenedor son la MISMA tupla -> colapsan a UNA sola ejecución, conservando el PRIMERO en
# orden de aparición, con SU spec literal (nunca la tupla abstracta ni un string sintético).
RI_LOG="$TMP/ri-c.log"; : > "$RI_LOG"
out_c="$(RI_LOG="$RI_LOG" ri_run rgC alpha/vibe-r9 altalpha/vibe-r9 2>&1)"; rc_c=$?
check "(c) dedup por tupla: --no-post sale 0" 0 "$rc_c"
printf '%s' "$out_c" | grep -q "duplicado" \
  && ok "(c) dedup por tupla: altalpha/vibe-r9 (misma identidad física que alpha/vibe-r9) se descarta" \
  || ko "(c) dedup por tupla: no se detectó como duplicado pese a compartir host canónico"
[ "$(grep -c '^start typecheck' "$RI_LOG")" -eq 1 ] \
  && ok "(c) dedup por tupla: typecheck corrió UNA sola vez (no se despachó dos veces al mismo físico)" \
  || ko "(c) dedup por tupla: typecheck corrió más de una vez"
grep -q "^start typecheck alpha/vibe-r9 " "$RI_LOG" \
  && ok "(c) dedup por tupla: se ejecutó con el PRIMER executable_spec (alpha/vibe-r9) literal" \
  || ko "(c) dedup por tupla: no ejecutó con el spec esperado"

# Identidad y transporte diferentes:
# "alpha" y "altalpha" son la MISMA tupla física, pero el probe debe usar el TRANSPORTE de
# CADA alias por separado (nunca el canónico compartido) — si "alpha" es inalcanzable pero
# "altalpha" (misma tupla) SÍ lo es, debe conservarse y EJECUTARSE con altalpha/vibe-r9, no
# con el alias roto. Antes del fix, ambos "pasaban" el probe vía el canónico compartido y se
# conservaba SIEMPRE el primero (alpha/vibe-r9), aunque su transporte real fallara.
RI_LOG="$TMP/ri-c2.log"; : > "$RI_LOG"
out_c2="$(RI_LOG="$RI_LOG" DOWN_RUNNERS="alpha/vibe-r9" ri_run rgC2 alpha/vibe-r9 altalpha/vibe-r9 2>&1)"; rc_c2=$?
check "(c2) fallback de transporte: --no-post sale 0" 0 "$rc_c2"
printf '%s' "$out_c2" | grep -q "NO-RUNNING.*): alpha/vibe-r9$" \
  && ok "(c2) fallback de transporte: alpha/vibe-r9 (transporte roto) descartado por NO-RUNNING, no por duplicado" \
  || ko "(c2) fallback de transporte: alpha/vibe-r9 no se descartó por la razón esperada"
grep -q "^start typecheck altalpha/vibe-r9 " "$RI_LOG" \
  && ok "(c2) fallback de transporte: se conservó y EJECUTÓ altalpha/vibe-r9 (misma tupla, transporte vivo)" \
  || ko "(c2) fallback de transporte: NO ejecutó con altalpha/vibe-r9 -- el probe sigue prestando el canónico"

# (c3) local/remoto se decide por la SINTAXIS del spec (presencia de '/'), NUNCA comparando
# el alias con la estación:
# "station/vibe-r9" tiene '/' -> debe sondearse por SSH (como hace slate_exec para CUALQUIER
# spec con '/'), aunque el alias literal coincida con TF_STATION_HOST. Con Incus LOCAL vivo
# pero SSH a "station" caído, el spec debe descartarse -- si se colara como RUNNING vía
# Incus local, la ejecución real (que SÍ va por SSH, slate_exec:*/*) fallaría después.
RI_LOG="$TMP/ri-c3.log"; : > "$RI_LOG"
out_c3="$(RI_LOG="$RI_LOG" SSH_FAIL_FOR="station" ri_run rgC3 station/vibe-r9 2>&1)"; rc_c3=$?
check "(c3) station/vibe-r9 con SSH caído -> 0 supervivientes -> die exit 2" 2 "$rc_c3"
printf '%s' "$out_c3" | grep -q "0 runners tras identidad/filtro RUNNING" \
  && ok "(c3) sintaxis-primero: station/vibe-r9 NO se coló como RUNNING vía Incus local" \
  || ko "(c3) sintaxis-primero: station/vibe-r9 se coló pese al SSH caído (bug de auditoría reintroducido)"

# (d) --plan es dry-run puro: NO debe requerir incus/ssh vivos (PATH sin el shim de red).
out_d="$(TF_ROOT="$RI_ROOT" TF_CLONE="$RI_CLONE" TF_MANIFEST="$RI_MAN" TF_SLUG="o/r" \
  TF_STATION_HOST="station" TF_RUNNER_IDENTITY_MAP="$RI_MAP" TF_QUIET_GATES="" \
  bash "$RI_ROOT/scripts/seal-suite.sh" --plan 9 "$RI_SHA" "$RI_SHA" rgD vibe-r0 vibe-r0 2>&1)"; rc_d=$?
check "(d) --plan sin shim de red (sin incus/ssh en PATH) sale 0" 0 "$rc_d"
printf '%s' "$out_d" | grep -q "duplicado" && ok "(d) --plan aplica dedup sin tocar red" || ko "(d) --plan no aplicó dedup"

# (e) mapa de identidad: alias contradictorio (mismo alias, host distinto) -> die fail-closed.
RI_MAP_BAD="$TMP/ri-bad.map"; printf 'station=host-a\nstation=host-b\n' > "$RI_MAP_BAD"
TF_ROOT="$RI_ROOT" TF_CLONE="$RI_CLONE" TF_MANIFEST="$RI_MAN" TF_SLUG="o/r" \
  TF_STATION_HOST="station" TF_RUNNER_IDENTITY_MAP="$RI_MAP_BAD" \
  bash "$RI_ROOT/scripts/seal-suite.sh" --plan 9 "$RI_SHA" "$RI_SHA" rgE vibe-r0 >/dev/null 2>&1
check "(e) mapa con alias contradictorio -> die exit 2" 2 $?

# (f) TF_STATION_HOST ausente -> die fail-closed (nunca se infiere con hostname).
TF_ROOT="$RI_ROOT" TF_CLONE="$RI_CLONE" TF_MANIFEST="$RI_MAN" TF_SLUG="o/r" \
  TF_RUNNER_IDENTITY_MAP="$RI_MAP" \
  bash "$RI_ROOT/scripts/seal-suite.sh" --plan 9 "$RI_SHA" "$RI_SHA" rgF vibe-r0 >/dev/null 2>&1
check "(f) TF_STATION_HOST no declarado -> die exit 2" 2 $?

# (g1) MECANISMO del centinela (regresión, no el estado actual del mapa real -- desde que
# el CEO midió blackvamp-linux, el mapa real YA NO lleva el centinela): un mapa DE PRUEBA
# sintético con RI_PENDING_ROLLOUT debe seguir rechazándose fail-closed si alguien lo
# reintrodujera — el mecanismo, no el dato, es lo que se regresiona aquí.
RI_MAP_CENTINELA="$TMP/ri-centinela.map"; printf 'station=RI_PENDING_ROLLOUT\n' > "$RI_MAP_CENTINELA"
out_g1="$(TF_MANIFEST="$SS_MAN" TF_RUNNER_IDENTITY_MAP="$RI_MAP_CENTINELA" bash "$MOTOR/scripts/verify-runner-identity-rollout.sh" station vibe-channel-81 2>&1)"
check "(g1) mecanismo del centinela: mapa con RI_PENDING_ROLLOUT -> preflight FALLA fail-closed" 1 $?
printf '%s' "$out_g1" | grep -q "PENDIENTE DE ROLLOUT" \
  && ok "(g1) mensaje específico: identidad PENDIENTE DE ROLLOUT, no un falso OK" \
  || ko "(g1) el preflight no reportó el centinela específicamente"

# (g2) ROLLOUT REAL: el mapa del repo (manifiestos/runner-identity.map) YA tiene la
# identidad física real de la estación (blackvamp-linux, medida por el CEO 2026-09-02
# 17:09 -- ver comentario del propio fichero) -- SIN sed, SIN copia de test, contra el
# mapa TAL COMO SE ENTREGA. Los 18 runners de flota vigentes deben resolver.
RI_ROLLOUT="$TMP/ri-rollout.map"
printf 'station=host-local\nalpha=host-alpha\ndelta=host-delta\n' > "$RI_ROLLOUT"
out_g2="$(TF_MANIFEST="$SS_MAN" TF_RUNNER_IDENTITY_MAP="$RI_ROLLOUT" bash "$MOTOR/scripts/verify-runner-identity-rollout.sh" station \
  vibe-channel-81 vibe-channel-82 vibe-channel-83 vibe-channel-84 vibe-channel-85 vibe-channel-86 vibe-channel-87 vibe-channel-88 \
  alpha/vibe-runner-alpha-01 alpha/vibe-runner-alpha-02 alpha/vibe-runner-alpha-03 alpha/vibe-runner-alpha-04 \
  delta/vibe-runner-delta-01 delta/vibe-runner-delta-02 delta/vibe-runner-delta-03 delta/vibe-runner-delta-04 delta/vibe-runner-delta-05 delta/vibe-runner-delta-06 2>&1)"
check "(g2) mapa de instancia neutra: los 18 runners resuelven" 0 $?
printf '%s' "$out_g2" | grep -q "ROLLOUT OK" && ok "(g2) preflight de rollout: ROLLOUT OK" || ko "(g2) preflight de rollout sin confirmación final"
printf '%s' "$out_g2" | grep -q "host-local" \
  && ok "(g2) resuelve contra la identidad adjudicada del fixture" \
  || ko "(g2) no se ve la identidad adjudicada en la resolución"

echo
# [TAL-8037/acta m3] gen-pozos-fragment.py: el acortado del alias es de la INSTANCIA (TF_POZOS_ALIAS_STRIP), sin dominios de casa
echo "== TAL-8037: gen-pozos-fragment.py — TF_POZOS_ALIAS_STRIP (sin dominios de casa) =="
_gp() { # <STRIP> -> alias mostrado de una fila de pozo
  TF_POZOS_ALIAS_STRIP="$1" python3 -c '
import sys; sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1]); import importlib.util
sp = importlib.util.spec_from_file_location("gpf", sys.argv[1] + "/gen-pozos-fragment.py"); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
h = m._pozo_row("p1", {"cuenta": "persona@dominio.test", "estado": "CARGADO"})
print("COMPLETO" if "persona@dominio.test" in h else ("CORTADO" if "persona<" in h or ">persona" in h or "persona " in h else "OTRO"))' "$MOTOR/scripts" 2>&1 | tail -1
}
[ "$(_gp "")" = "COMPLETO" ] && ok "gen-pozos-fragment: sin TF_POZOS_ALIAS_STRIP el alias se muestra completo (cero dominios de casa)" || ko "gen-pozos-fragment: alias no completo sin STRIP"
[ "$(_gp "@dominio.test")" = "CORTADO" ] && ok "gen-pozos-fragment: TF_POZOS_ALIAS_STRIP=@dominio.test recorta el alias" || ko "gen-pozos-fragment: STRIP no recorta"

# [TAL-8037/n3,n5] setup-githooks.sh: elección .githooks/githooks (motor: solo githooks/; producto: .githooks/; AMBOS: gana .githooks y se AVISA)
echo "== TAL-8037: setup-githooks.sh — directorio de hooks, aviso con ambos y guía del motor solo en el motor =="
_sgh() { # <dirs a crear con pre-push: "githooks" ".githooks" ...> -> imprime "hooksPath=<v>|<salida stdout+stderr>"
  local r; r="$(mktemp -d)"; git -C "$r" init -q; mkdir -p "$r/scripts"; cp "$MOTOR/scripts/setup-githooks.sh" "$r/scripts/"
  local d; for d in "$@"; do mkdir -p "$r/$d"; printf '#!/bin/sh\n' > "$r/$d/pre-push"; done
  local out; out="$(cd "$r" && bash scripts/setup-githooks.sh 2>&1)"; printf 'hooksPath=%s|%s' "$(git -C "$r" config --local core.hooksPath)" "$out"; rm -rf "$r"
}
o_m="$(_sgh githooks)"; o_p="$(_sgh .githooks)"; o_b="$(_sgh githooks .githooks)"
[ "${o_m%%|*}" = "hooksPath=githooks" ] && ok "setup-githooks (motor, solo githooks/): hooksPath=githooks" || ko "setup-githooks motor: ${o_m%%|*}"
printf '%s' "$o_m" | grep -q 'motor-go.sh' && ok "setup-githooks (motor): imprime la guía de motor-go.sh" || ko "setup-githooks motor sin guía de motor-go"
[ "${o_p%%|*}" = "hooksPath=.githooks" ] && ok "setup-githooks (producto, solo .githooks/): hooksPath=.githooks" || ko "setup-githooks producto: ${o_p%%|*}"
printf '%s' "$o_p" | grep -q 'motor-go' && ko "setup-githooks (producto): NO debe imprimir la guía de motor-go.sh" || ok "setup-githooks (producto): sin la guía de motor-go.sh"
[ "${o_b%%|*}" = "hooksPath=.githooks" ] && ok "setup-githooks (AMBOS dirs): gana .githooks" || ko "setup-githooks ambos: ${o_b%%|*}"
printf '%s' "$o_b" | grep -q 'AVISO: existen .githooks/pre-push Y githooks/pre-push' && ok "setup-githooks (AMBOS dirs): AVISA por stderr (no en silencio)" || ko "setup-githooks ambos sin aviso"
o_s="$(_sgh)"; printf '%s' "$o_s" | grep -q 'no encuentro' && ok "setup-githooks (ningún dir con pre-push): falla cerrado" || ko "setup-githooks sin dirs no falla"

# [TAL-8037/n3] TF_PAQUETE_ESTADO: default INSTANCIA (se evalúa), distribucion = SKIP declarado, valor inválido = exit 2
echo "== TAL-8037: TF_PAQUETE_ESTADO (proc-m13.selftest.sh / test-proc13-pointer-integrity.sh) =="
_st() { env -i PATH="$PATH" HOME="$TMP" "$@" 2>&1; echo "rc=$?"; }
ST="$MOTOR/skills/talent-merger/references/proc-m13.selftest.sh"; PI="$MOTOR/skills/talent-channel-operation/tests/test-proc13-pointer-integrity.sh"
if [ ! -f "$MOTOR/skills/talent-channel-operation/scripts/repo-identity.conf" ]; then   # árbol de distribución (sin overlays)
  o="$(_st bash "$ST" --estado instancia)"; [ "$(printf '%s' "$o" | tail -1)" = "rc=2" ] && ok "selftest: instancia explícita sin anexo -> exit 2" || ko "selftest instancia: $o"
  o="$(_st env TF_PAQUETE_ESTADO=distribucion bash "$ST")"; { printf '%s' "$o" | grep -q 'SKIP-OVERLAY' && [ "$(printf '%s' "$o" | tail -1)" = "rc=0" ]; } && ok "selftest: distribucion -> SKIP-OVERLAY declarado (rc 0)" || ko "selftest distribucion: $o"
  o="$(_st bash "$ST" --estado inventado)"; [ "$(printf '%s' "$o" | tail -1)" = "rc=2" ] && ok "selftest: valor inválido -> exit 2" || ko "selftest estado inválido: $o"
  o="$(_st bash "$PI" --estado instancia)"; [ "$(printf '%s' "$o" | tail -1)" = "rc=2" ] && ok "pointer-integrity: instancia explícita sin anexo -> exit 2" || ko "pointer-integrity instancia: $o"
  o="$(_st env TF_PAQUETE_ESTADO=distribucion bash "$PI")"; { printf '%s' "$o" | grep -q 'SKIP-OVERLAY declarados: 1' && [ "$(printf '%s' "$o" | tail -1)" = "rc=0" ]; } && ok "pointer-integrity: distribucion -> SKIP-OVERLAY contado (rc 0)" || ko "pointer-integrity distribucion: $o"
else
  ok "TF_PAQUETE_ESTADO: árbol con anexos (instancia) — los casos de distribución no aplican aquí"
fi

echo "== TAL-5383 (A2): compose-identity/compose-bootstrap/compose-resolve — compositor de trenes =="
A2_IDENTITY_LIB="$MOTOR/scripts/lib/compose-identity.sh"
A2_IDENTITY_CANARIOS="$MOTOR/tests/scripts/identity-canarios.sh"
if [ -f "$A2_IDENTITY_LIB" ] && [ -f "$A2_IDENTITY_CANARIOS" ]; then
  A2_ID_OUT="$TMP/identity-canarios.out"
  bash "$A2_IDENTITY_CANARIOS" "$A2_IDENTITY_LIB" > "$A2_ID_OUT" 2>&1; a2_id_rc=$?
  check "identity-canarios.sh (extraccion de cierres + dominio Linear)" 0 "$a2_id_rc"
  [ "$a2_id_rc" -eq 0 ] || cat "$A2_ID_OUT" >&2
else
  ko "TAL-5383: falta $A2_IDENTITY_LIB o $A2_IDENTITY_CANARIOS"
fi

A2_RESOLVE_CANARIOS="$MOTOR/tests/scripts/resolve-canarios.sh"
A2_RESOLVE_LIB="$MOTOR/scripts/lib/compose-resolve.sh"
A2_BOOTSTRAP_LIB="$MOTOR/scripts/lib/compose-bootstrap.sh"
if [ -f "$A2_RESOLVE_LIB" ] && [ -f "$A2_BOOTSTRAP_LIB" ] && [ -f "$A2_RESOLVE_CANARIOS" ]; then
  A2_RES_OUT="$TMP/resolve-canarios.out"
  bash "$A2_RESOLVE_CANARIOS" > "$A2_RES_OUT" 2>&1; a2_res_rc=$?
  check "resolve-canarios.sh (anclaje, orden topologico, registro con lock, sin invocacion directa)" 0 "$a2_res_rc"
  [ "$a2_res_rc" -eq 0 ] || cat "$A2_RES_OUT" >&2
else
  ko "TAL-5383: falta $A2_RESOLVE_LIB, $A2_BOOTSTRAP_LIB o $A2_RESOLVE_CANARIOS"
fi

echo
lock_rc=0
bash "$MOTOR/tests/test-runner-lock.sh" > "$TMP/runner-lock.log" 2>&1 || lock_rc=$?
check "candado del runner: siete casos de aislamiento y autoridad del entorno" 0 "$lock_rc"
[ "$lock_rc" = 0 ] || cat "$TMP/runner-lock.log"
optional_rc=0
python3 "$MOTOR/tests/test-seal-optional-e2e.py" > "$TMP/seal-opcional.log" 2>&1 || optional_rc=$?
check "seal-suite e2e opcional: plan y ejecución con un runner y manifiestos completos/incompletos" 0 "$optional_rc"
[ "$optional_rc" = 0 ] || cat "$TMP/seal-opcional.log"
registro_json_rc=0
bash "$MOTOR/tests/test-registro-json.sh" > "$TMP/registro-json.log" 2>&1 || registro_json_rc=$?
check "registro de shards: documento único y cobertura estricta" 0 "$registro_json_rc"
[ "$registro_json_rc" = 0 ] || cat "$TMP/registro-json.log"
taxonomia_json_rc=0
bash "$MOTOR/skills/linear-skill/tests/run-tests.sh" > "$TMP/taxonomia-json.log" 2>&1 || taxonomia_json_rc=$?
check "taxonomía: paridad y documento único en tres ficheros" 0 "$taxonomia_json_rc"
[ "$taxonomia_json_rc" = 0 ] || cat "$TMP/taxonomia-json.log"
echo "======== motor tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ========"
[ "$FAIL" -eq 0 ]
