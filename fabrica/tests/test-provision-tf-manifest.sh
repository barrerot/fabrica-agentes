#!/usr/bin/env bash
# tests/test-provision-tf-manifest.sh — self-test de TAL-5563 (generalizado en TAL-8040):
# scripts/provision-tf-manifest.sh materializa .claude/tf-manifest.conf desde el manifiesto que se le
# PASA (--manifest <ruta> o $TCO_TF_MANIFEST, sin default y fail-closed sin él): idempotente, nunca
# pisa en silencio un manifiesto local que difiere, y no depende del $PWD del invocador.
# NO toca la lógica fail-closed de verify-handoff.sh — el caso 1 prueba que esa lógica sigue
# fallando cerrada SIN el script bajo prueba, exactamente igual que antes de que existiera.
#
# Uso: bash tests/test-provision-tf-manifest.sh <script-bajo-prueba> <verify-handoff-real> \
#        <handoff-lib-real> <manifiesto-real>
# `gh` se SIMULA por PATH (shim que falla): verify-handoff solo necesita que exista; sin red.
# Lo EJECUTA tests/run-tests.sh: un test que nadie corre no es una prueba, es un fichero.
set -u
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/instalacion/gh-dobles.sh" || exit 2
SCRIPT_UNDER_TEST="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
VERIFY_HANDOFF_REAL="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
HANDOFF_LIB_REAL="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"
CANON_REAL="$(cd "$(dirname "$4")" && pwd)/$(basename "$4")"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-provision-tf-manifest-XXXXXXXX"); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
printf '#!/bin/sh\necho "gh simulado: sin red" >&2\nexit 1\n' > "$TMP/bin/gh"; chmod +x "$TMP/bin/gh"
cerrar_doble_gh "$TMP/bin/gh" || exit 1
export PATH="$TMP/bin:$PATH"
FAIL=0
ok() { echo "  ✓ $1"; }
ko() { echo "  ✗ $1" >&2; FAIL=1; }

mk_fixture_repo() { # <dir>
  git init -q -b main "$1"
  git -C "$1" config user.email t@t
  git -C "$1" config user.name t
  mkdir -p "$1/scripts/lib"
  cp "$HANDOFF_LIB_REAL" "$1/scripts/lib/handoff.sh"
  cp "$VERIFY_HANDOFF_REAL" "$1/scripts/verify-handoff.sh"
  cp "$SCRIPT_UNDER_TEST" "$1/scripts/provision-tf-manifest.sh"
  chmod +x "$1/scripts/provision-tf-manifest.sh"
  ( cd "$1" && git add -A && git commit -q -m init ) >/dev/null 2>&1
}

canon_sha="$(sha256sum "$CANON_REAL" | cut -d' ' -f1)"

# ── caso 1 (nace rojo): clon fresco SIN manifiesto → verify-handoff.sh sigue fail-closed,
# exactamente igual que ANTES de que provision-tf-manifest.sh existiera. Este script no lo toca.
REPO1="$TMP/repo1"; mk_fixture_repo "$REPO1"
out1="$(cd "$REPO1" && timeout 10 bash scripts/verify-handoff.sh 999 2>&1)"; rc1=$?
if [ "$rc1" -eq 2 ] && printf '%s' "$out1" | grep -qF 'SIN manifiesto de fábrica'; then
  ok "rojo: clon sin manifiesto -> verify-handoff.sh exit 2, mensaje fail-closed (sin cambios)"
else
  ko "rojo: clon sin manifiesto -> rc=$rc1 salida=[$out1] (esperaba rc=2 + 'SIN manifiesto de fábrica')"
fi
if [ -e "$REPO1/.claude/tf-manifest.conf" ]; then
  ko "rojo: NO debería existir .claude/tf-manifest.conf antes de provisionar"
else
  ok "rojo: .claude/tf-manifest.conf ausente, como se espera"
fi

# ── caso 2 (verde): mismo clon, TRAS provisionar → verify-handoff.sh resuelve el manifiesto
# LOCAL (el vocabulario de superficies del manifiesto pasado a --manifest).
prov_rc=0
( cd "$REPO1" && bash scripts/provision-tf-manifest.sh --manifest "$CANON_REAL" ) >/dev/null 2>&1 || prov_rc=$?
if [ "$prov_rc" -eq 0 ]; then ok "provision-tf-manifest.sh sobre el fixture -> rc=0"; else ko "provision-tf-manifest.sh sobre el fixture -> rc=$prov_rc"; fi
if [ -f "$REPO1/.claude/tf-manifest.conf" ] && diff -q "$REPO1/.claude/tf-manifest.conf" "$CANON_REAL" >/dev/null 2>&1; then
  ok ".claude/tf-manifest.conf provisionado == canónico"
else
  ko ".claude/tf-manifest.conf no provisionado o no coincide con el canónico"
fi

out2="$(cd "$REPO1" && timeout 10 bash scripts/verify-handoff.sh 999 2>&1)"; rc2=$?
if printf '%s' "$out2" | grep -qF '[verify-handoff] manifiesto: copia local del canal' \
   && printf '%s' "$out2" | grep -qF "$(sed -n 's/^TF_SENSITIVE_SURFACES="\([^ "]*\).*$/"\1"/p' "$CANON_REAL" | tail -1)"; then
  ok "verde: verify-handoff.sh resuelve el manifiesto local tras provisionar (surfaces DEL MANIFIESTO pasado)"
else
  ko "verde: verify-handoff.sh NO resolvió el manifiesto del motor tras provisionar -> [$out2]"
fi
if [ "$rc2" -eq 2 ] && ! printf '%s' "$out2" | grep -qF 'SIN manifiesto de fábrica'; then
  ok "verde: el fallo posterior (fetch del PR falso) ya NO es del manifiesto — frontera respetada"
else
  ko "verde: rc=$rc2 inesperado o seguía citando 'SIN manifiesto de fábrica' -> [$out2]"
fi

# ── caso 3 (idempotencia): correr dos veces no cambia nada la segunda.
before_sha="$(sha256sum "$REPO1/.claude/tf-manifest.conf" | cut -d' ' -f1)"
prov_rc2=0
out3="$(cd "$REPO1" && bash scripts/provision-tf-manifest.sh --manifest "$CANON_REAL" 2>&1)" || prov_rc2=$?
after_sha="$(sha256sum "$REPO1/.claude/tf-manifest.conf" | cut -d' ' -f1)"
if [ "$prov_rc2" -eq 0 ] && [ "$before_sha" = "$after_sha" ] && printf '%s' "$out3" | grep -qF 'Nada que hacer'; then
  ok "idempotente: segunda corrida rc=0, contenido sin cambios, lo declara"
else
  ko "idempotente: prov_rc2=$prov_rc2 before=$before_sha after=$after_sha out=[$out3]"
fi

# ── caso 4: manifiesto local DISTINTO del canónico -> NO se pisa en silencio (sin --force).
# Canales SEPARADOS a propósito: un `2>&1` fusionado no
# prueba NINGÚN contrato de canal — el mensaje "DIFIERE" lo emite fail() (contrato: SIEMPRE
# stderr), así que el caso exige el texto en stderr Y su ausencia en stdout.
printf '\n# drift manual\n' >> "$REPO1/.claude/tf-manifest.conf"
drift_sha="$(sha256sum "$REPO1/.claude/tf-manifest.conf" | cut -d' ' -f1)"
C4_OUT="$TMP/c4.out"; C4_ERR="$TMP/c4.err"
prov_rc3=0
( cd "$REPO1" && bash scripts/provision-tf-manifest.sh --manifest "$CANON_REAL" ) >"$C4_OUT" 2>"$C4_ERR" || prov_rc3=$?
after_drift_sha="$(sha256sum "$REPO1/.claude/tf-manifest.conf" | cut -d' ' -f1)"
c4_stdout="$(cat "$C4_OUT")"; c4_stderr="$(cat "$C4_ERR")"
if [ "$prov_rc3" -ne 0 ] && [ "$drift_sha" = "$after_drift_sha" ] \
   && printf '%s' "$c4_stderr" | grep -qiF 'DIFIERE' \
   && ! printf '%s' "$c4_stdout" | grep -qiF 'DIFIERE'; then
  ok "sin --force: manifiesto local distinto NO se pisa, falla en STDERR (nunca stdout) declarando la diferencia"
else
  ko "sin --force: prov_rc3=$prov_rc3 drift_sha=$drift_sha after=$after_drift_sha stdout=[$c4_stdout] stderr=[$c4_stderr]"
fi

# ── caso 5: --force SÍ sobreescribe, DECLARÁNDOLO explícitamente. Contrato: mensaje informativo
# -> SIEMPRE stdout (nunca stderr) — canales separados por la misma razón que el caso 4.
C5_OUT="$TMP/c5.out"; C5_ERR="$TMP/c5.err"
prov_rc4=0
( cd "$REPO1" && bash scripts/provision-tf-manifest.sh --manifest "$CANON_REAL" --force ) >"$C5_OUT" 2>"$C5_ERR" || prov_rc4=$?
final_sha="$(sha256sum "$REPO1/.claude/tf-manifest.conf" | cut -d' ' -f1)"
c5_stdout="$(cat "$C5_OUT")"; c5_stderr="$(cat "$C5_ERR")"
if [ "$prov_rc4" -eq 0 ] && [ "$final_sha" = "$canon_sha" ] \
   && printf '%s' "$c5_stdout" | grep -qiF -- '--force: sobreescribiendo' \
   && ! printf '%s' "$c5_stderr" | grep -qiF -- '--force: sobreescribiendo'; then
  ok "--force: sobreescribe y lo declara explícitamente en STDOUT (nunca stderr)"
else
  ko "--force: prov_rc4=$prov_rc4 final=$final_sha canon=$canon_sha stdout=[$c5_stdout] stderr=[$c5_stderr]"
fi

# ── caso 6 (cwd-independencia): invocado desde OTRO cwd (ni siquiera un repo), actúa sobre el
# clon que CONTIENE el script (REPO2), nunca sobre el cwd del invocador.
REPO2="$TMP/repo2"; mk_fixture_repo "$REPO2"
FOREIGN="$TMP/foreign-cwd-sin-relacion"; mkdir -p "$FOREIGN"
prov_rc5=0
( cd "$FOREIGN" && bash "$REPO2/scripts/provision-tf-manifest.sh" --manifest "$CANON_REAL" ) >/dev/null 2>&1 || prov_rc5=$?
if [ "$prov_rc5" -eq 0 ] && [ -f "$REPO2/.claude/tf-manifest.conf" ] && [ ! -e "$FOREIGN/.claude" ]; then
  ok "cwd-independencia: invocado desde un cwd ajeno, provisiona el clon del script, no el cwd"
else
  ko "cwd-independencia: prov_rc5=$prov_rc5 repo2-provisionado=$([ -f "$REPO2/.claude/tf-manifest.conf" ] && echo si || echo no) foreign-tocado=$([ -e "$FOREIGN/.claude" ] && echo si || echo no)"
fi

# ── caso 7 (mutación, dientes): sin el guard de "difiere -> no pisar sin --force", el caso 4
# debe volverse ROJO (pisado silencioso) — prueba que el caso 4 vigila una propiedad real.
REPO3="$TMP/repo3"; mk_fixture_repo "$REPO3"
MUT="$REPO3/scripts/provision-tf-manifest.sh"
python3 - "$MUT" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
old = (
    '  if [ "$FORCE" -ne 1 ]; then\n'
    '    fail "\'$DEST\' EXISTE y DIFIERE del manifiesto \'$CANON\' (sha256 destino ${dest_sha:0:12}… vs manifiesto ${canon_sha:0:12}…). No se sobreescribe en silencio — revisa la diferencia o re-ejecuta con --force para sobreescribir DECLARÁNDOLO."\n'
    '  fi\n'
)
n = src.count(old)
if n != 1:
    sys.stderr.write(f"ANCLA-NO-UNICA n={n}\n")
    sys.exit(1)
open(path, "w").write(src.replace(old, ""))
PYEOF
mut_patch_rc=$?
if [ "$mut_patch_rc" -ne 0 ]; then
  ko "mutante: ancla no única/ausente en el script bajo prueba (el mutante no se pudo generar)"
elif ! bash -n "$MUT" >/dev/null 2>&1; then
  ko "mutante: bash -n falló, la mutación rompió la sintaxis"
else
  ( cd "$REPO3" && bash scripts/provision-tf-manifest.sh --manifest "$CANON_REAL" ) >/dev/null 2>&1
  printf '\n# drift manual\n' >> "$REPO3/.claude/tf-manifest.conf"
  mut_drift_sha="$(sha256sum "$REPO3/.claude/tf-manifest.conf" | cut -d' ' -f1)"
  mut_rc=0
  ( cd "$REPO3" && bash scripts/provision-tf-manifest.sh --manifest "$CANON_REAL" ) >/dev/null 2>&1 || mut_rc=$?
  mut_after_sha="$(sha256sum "$REPO3/.claude/tf-manifest.conf" | cut -d' ' -f1)"
  if [ "$mut_rc" -eq 0 ] && [ "$mut_after_sha" = "$canon_sha" ] && [ "$mut_after_sha" != "$mut_drift_sha" ]; then
    ok "mutante (dientes): SIN el guard, el drift sin --force SÍ se pisa en silencio -> caso 4 muerde de verdad"
  else
    ko "mutante (dientes): rc=$mut_rc after=$mut_after_sha canon=$canon_sha drift=$mut_drift_sha (esperaba pisado silencioso)"
  fi
fi

# ── caso 8 (TAL-8040, fail-closed): SIN --manifest ni TCO_TF_MANIFEST -> rc≠0, stderr lo dice, NO escribe.
REPO4="$TMP/repo4"; mk_fixture_repo "$REPO4"
C8_ERR="$TMP/c8.err"; c8_rc=0
( cd "$REPO4" && env -u TCO_TF_MANIFEST bash scripts/provision-tf-manifest.sh ) >/dev/null 2>"$C8_ERR" || c8_rc=$?
if [ "$c8_rc" -ne 0 ] && grep -qF 'sin fuente de manifiesto' "$C8_ERR" && [ ! -e "$REPO4/.claude/tf-manifest.conf" ]; then
  ok "fail-closed: sin --manifest ni TCO_TF_MANIFEST -> rc≠0, lo declara en STDERR y no escribe nada"
else
  ko "fail-closed sin fuente: rc=$c8_rc stderr=[$(cat "$C8_ERR")] escrito=$([ -e "$REPO4/.claude/tf-manifest.conf" ] && echo si || echo no)"
fi

# ── caso 9 (TAL-8040): la fuente por entorno TCO_TF_MANIFEST funciona igual que --manifest.
c9_rc=0
( cd "$REPO4" && TCO_TF_MANIFEST="$CANON_REAL" bash scripts/provision-tf-manifest.sh ) >/dev/null 2>&1 || c9_rc=$?
if [ "$c9_rc" -eq 0 ] && diff -q "$REPO4/.claude/tf-manifest.conf" "$CANON_REAL" >/dev/null 2>&1; then
  ok "TCO_TF_MANIFEST como fuente -> provisiona == manifiesto"
else
  ko "TCO_TF_MANIFEST como fuente: rc=$c9_rc"
fi

# ── caso 10 (TAL-8040, I1): manifiesto INVÁLIDO (relativo · inexistente · sin TF_SENSITIVE_SURFACES con tokens)
# -> rc≠0 y nada escrito (ausencia o manifiesto inválido = fail-closed).
REPO5="$TMP/repo5"; mk_fixture_repo "$REPO5"
printf 'TF_PROJECT="x"\n' > "$TMP/sin-superficies.conf"
printf 'TF_SENSITIVE_SURFACES="   "\n' > "$TMP/superficies-vacias.conf"
c10_bad=""
for _m in "relativo.conf" "$TMP/no-existe.conf" "$TMP/sin-superficies.conf" "$TMP/superficies-vacias.conf"; do
  _rc=0; ( cd "$REPO5" && bash scripts/provision-tf-manifest.sh --manifest "$_m" ) >/dev/null 2>&1 || _rc=$?
  { [ "$_rc" -ne 0 ] && [ ! -e "$REPO5/.claude/tf-manifest.conf" ]; } || c10_bad="$c10_bad [$_m rc=$_rc]"
done
if [ -z "$c10_bad" ]; then
  ok "fail-closed: manifiesto relativo/inexistente/sin superficies/superficies vacías -> rc≠0 y nada escrito"
else
  ko "fail-closed manifiesto inválido:$c10_bad"
fi

echo "TEST-TAL5563: $([ "$FAIL" -eq 0 ] && echo 'TODO OK' || echo 'FALLOS')"
[ "$FAIL" -eq 0 ]
