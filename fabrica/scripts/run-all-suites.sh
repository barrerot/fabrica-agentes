#!/usr/bin/env bash
# Suites del ZIP: ejecución en serie, rc reales y omisiones separadas de PASS.
# --solo <id> reproduce una fila; --sin <id> (repetible) excluye de la batería.
# Desde una sesión activa: --solo validate o --sin talent-channels. La guarda
# solo se evalúa si se selecciona talent-channels; --listar no ejecuta.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 2
cd "$ROOT" || exit 2
export TF_PAQUETE_ESTADO=distribucion
SUITE_TIMEOUT="${TF_SUITE_TIMEOUT:-3060}"
[[ "$SUITE_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo 'FAIL TF_SUITE_TIMEOUT debe ser un entero positivo de segundos'; exit 2; }
declare -a IDS=() CMDS=() RESUMENES=()
add() {
  IDS+=("$1"); CMDS+=("$2")
  # Patrones de resumen FINAL por fila; nunca se buscan FAIL en descripciones.
  local patron=''
  case "$1" in
    validate) patron='^== resumen: miembros=' ;;
    validate-self|sync-self) patron='^SELFTEST: PASS=' ;;
    validate-skill|lector-cuotas) patron='^(OK|FAILED \(.*\))$' ;;
    sentry) patron='^RESULTADO:' ;;
    talent-ceo) patron='^== [0-9]+ ok, [0-9]+ FAIL,' ;;
    instalacion) patron='^== [0-9]+ ok, [0-9]+ FAIL \(esperados: [0-9]+ casos\) ==$' ;;
    instalacion-fases) patron='^PASS=[0-9]+ FAIL=[0-9]+ esperados=[0-9]+$' ;;
    talent-context) patron='^== RESULTADO: [0-9]+ ok, [0-9]+ FAIL ==' ;;
    talent-channel-operation|talent-orchestrator|test-package-suites.sh|test-runner-lock.sh) patron='^RESULTADO: PASS=' ;;
    talent-channels) patron='^=+  PASS=[0-9]+  FAIL=' ;;
    talent-repo-onboarding) patron='^── Resultados:' ;;
    talent-buzz/probar-antifugas.sh) patron='^probar-antifugas: (LIMPIO|[0-9]+ hallazgo\(s\))' ;;
    talent-buzz/*) patron="^${1##*/}"; patron="${patron%.sh}:" ;;
    talent-memoria/*|talent-prd/*) patron='^---- resultado: PASA=' ;;
    talent-llm-local/probar-sonda.sh) patron='^  [0-9]+ casos correctos · [0-9]+ fallidos$' ;;
    talent-llm-local/*) patron='^  [0-9]+ correctas · [0-9]+ fallidas' ;;
    llm-referencia) patron='^  (OK    La unidad|DIFERENCIAS entre la unidad)' ;;
    total-derivado) patron='^(OK: invariants.tsv|DESFASE\(S\) DETECTADO\(S\):)' ;;
    syntax) patron='^\[check-bash-syntax\] [0-9]+ ficheros revisados$' ;; # censo final; errores mandan rc
    shellcheck) : ;; # imprime inventario ANTES del análisis, sin resultado final; manda rc
    relay) patron='^RESULTADO: [0-9]+ PASS / [0-9]+ FAIL$' ;;
    proc-m13) patron='^RESULTADO:' ;;
    proc13-pointers) patron='^\[test-proc13-pointer-integrity\]' ;;
    pozos) patron='^---- selftest: [0-9]+ fallos$' ;;
    test-agregador-*.sh) patron="^${1%.sh}: FAIL=" ;;
    test-check-function-clobber.sh|test-check-run-tests-registry.sh|test-insumos-por-area.sh) patron="^\\[${1%.sh}\\]" ;;
    test-db-reset-marker.sh) patron='^TEST-A2:' ;;
    test-infra-retry.sh) patron='^TEST-INFRA-RETRY:' ;;
    test-provision-tf-manifest.sh) patron='^TEST-TAL5563:' ;;
    test-supabase-wrapper.sh) patron='^TEST-SUPABASE-WRAPPER:' ;;
    canarios) patron='^OK=[0-9]+ FALLOS=' ;;
    motor) patron='^======== motor tests: PASS=' ;;
    *) echo "FAIL inventario sin contrato de resumen: $1"; exit 2 ;;
  esac
  RESUMENES+=("$patron")
}
add validate 'bash skills/skill-creator/scripts/validate-package.sh --root skills --estado distribucion'
add validate-self 'bash skills/skill-creator/scripts/validate-package.sh --self-test'
add sync-self 'bash skills/skill-creator/scripts/sync-package.sh --self-test'
add validate-skill 'python3 skills/skill-creator/scripts/test_validate_skill.py'
add lector-cuotas 'python3 tests/test_lector_cuotas.py'
add sentry 'python3 skills/talent-sentry-guard/scripts/test-sentry-python-guards.py'
add instalacion 'bash instalacion/tests/run-tests.sh'
add instalacion-fases 'bash tests/test-instalacion-fases.sh'
for skill in talent-ceo talent-channel-operation talent-channels talent-context talent-orchestrator talent-repo-onboarding; do
  add "$skill" "bash skills/$skill/tests/run-tests.sh"
done
# CEO [r16-1] ejecuta test-supervision.sh (560 casos, autoconteo y rc propio),
# que carga supervision-ronda3.sh y supervision-manifiesto.sh. Su formato es «== N ok, N FAIL (esperados:
# N casos; saltados: N...) ==»; CEO propaga su rc mediante el assert r16-1.
# No son filas adicionales: quedan cubiertas por esa invocación original.
for skill in talent-buzz talent-memoria talent-prd talent-llm-local; do
  case "$skill" in
    talent-buzz) nombres='antifugas-fixtures antifugas contexto-imagen genkeys movil patches publicacion reconcilia-env sonda' ;;
    talent-memoria) nombres='diagnostico escenarios standalone lib invariants salvaguarda verificar' ;;
    talent-prd) nombres='escenarios standalone invariants verificar' ;;
    talent-llm-local) nombres='fallo-cerrado puente sonda' ;;
  esac
  for nombre in $nombres; do
    f="skills/$skill/tests/probar-$nombre.sh"
    add "$skill/${f##*/}" "bash $f"
  done
done
add llm-referencia 'bash skills/talent-llm-local/tests/comparar-con-referencia.sh'
add relay 'bash skills/talent-coordination/scripts/selftest-relay.sh'
add proc-m13 'bash skills/talent-merger/references/proc-m13.selftest.sh'
add proc13-pointers 'bash skills/talent-channel-operation/tests/test-proc13-pointer-integrity.sh'
add pozos 'bash skills/talent-orchestrator/scripts/pozos-selftest.sh'
add total-derivado 'bash skills/talent-channel-operation/scripts/check-total-esperado-derivado.sh'
for nombre in agregador-identidad-blob agregador-inercia-por-insumo check-function-clobber check-run-tests-registry db-reset-marker infra-retry insumos-por-area provision-tf-manifest supabase-wrapper package-suites runner-lock; do
  f="tests/test-$nombre.sh"
  case "$f" in
    *test-db-reset-marker.sh|*test-infra-retry.sh) add "${f##*/}" "bash $f scripts/run-local-gates.sh" ;;
    *test-provision-tf-manifest.sh) add "${f##*/}" "bash $f scripts/provision-tf-manifest.sh scripts/verify-handoff.sh scripts/lib/handoff.sh manifiestos/ejemplo.conf" ;;
    *) add "${f##*/}" "bash $f" ;;
  esac
done
add canarios 'bash tests/scripts/resolve-canarios.sh'
add syntax 'bash scripts/check-bash-syntax.sh'
add shellcheck 'bash scripts/check-shellcheck.sh'
add motor 'bash tests/run-tests.sh'
solo=''; excluidas=()
while [ $# -gt 0 ]; do
  case "$1" in
    --listar) [ $# -eq 1 ] && [ -z "$solo" ] && [ "${#excluidas[@]}" = 0 ] || exit 2; printf '%s\n' "${IDS[@]}"; exit 0 ;;
    --solo) [ $# -ge 2 ] && [ -z "$solo" ] || exit 2; solo="$2"; shift 2 ;;
    --sin) [ $# -ge 2 ] || exit 2; excluidas+=("$2"); shift 2 ;;
    *) exit 2 ;;
  esac
done
[ -z "$solo" ] || [ "${#excluidas[@]}" = 0 ] || exit 2
for seleccion in ${solo:+"$solo"} "${excluidas[@]}"; do
  found=0; for id in "${IDS[@]}"; do [ "$id" != "$seleccion" ] || found=1; done
  [ "$found" = 1 ] || { echo "FAIL suite no declarada: $seleccion"; exit 2; }
done
excluida() { local e; for e in "${excluidas[@]}"; do [ "$e" != "$1" ] || return 0; done; return 1; }
# Antes de cualquier suite seleccionada, solo si channels forma parte de ella.
if { [ -z "$solo" ] || [ "$solo" = talent-channels ]; } && ! excluida talent-channels; then
command -v pgrep >/dev/null || { echo 'FAIL falta pgrep para la guarda'; exit 2; }
pgrep -u "$(id -u)" -x 'claude|codex' >/dev/null 2>&1; guard_rc=$?
case "$guard_rc" in
  0) echo 'ABORT: procesos claude/codex vivos del usuario; talent-channels no se ejecuta'; exit 2 ;;
  1) : ;;
  *) echo "ABORT: pgrep falló (rc=$guard_rc)"; exit 2 ;;
esac
fi
OUT="${TF_SUITES_LOG_DIR:-$(mktemp -d)}"; mkdir -p "$OUT" || exit 2
PASS=0; FAIL=0; SKIP=0; NOTAS=()
skip() { SKIP=$((SKIP+1)); printf '  SKIP %s: %s\n' "$1" "$2"; NOTAS+=("$1: $2"); }
skip_declarado() { # id, línea; únicamente omisiones conocidas, nunca un FAIL real
  case "$1:$2" in
    validate:SKIP-OVERLAY\ talent-merger\ INV-ME-*)
      [[ "$2" =~ ^SKIP-OVERLAY\ talent-merger\ INV-ME-(052|137|138|139|148|318|319|326|345|352)\ .*target\ overlay\ ausente ]] ;;
    # F2 creado sin secretos y con aislamiento local comprobado: cuatro omisiones exactas.
    # Solo se admiten cuando ambos consumidores reales y el recorrido íntegro son verdes.
    instalacion-fases:'  SKIP  vibe-channel-11 .env.local (sin vibe-channel-11.env en el escrow — ruta soportada)'|\
    instalacion-fases:'  SKIP  vibe-channel-12 .env.local (sin vibe-channel-12.env en el escrow — ruta soportada)'|\
    instalacion-fases:'  SKIP  vibe-channel-11 en tailnet (TC_LOCAL_ONLY=yes — acceso local vía incus exec)'|\
    instalacion-fases:'  SKIP  vibe-channel-12 en tailnet (TC_LOCAL_ONLY=yes — acceso local vía incus exec)')
      grep -qFx 'CONSUMIDOR F2 verify real creado rc=0' "$log" &&
      grep -qFx 'CONSUMIDOR F2 verify restaurado rc=0' "$log" &&
      grep -qFx 'positivos-reales: PASS=41 FAIL=0' "$log" ;;
    talent-ceo:*'SKIP sin raiz de repo;'*) ! git rev-parse --show-toplevel >/dev/null 2>&1 ;;
    talent-channel-operation:*'SKIP pre-push:'*': ruta canónica de producto .githooks/pre-push ausente'*) return 0 ;;
    talent-channel-operation:'== '*'tooling raíz en modelo defer-AUTOMÁTICO'*'tests de root-model v5.0 OMITIDOS'*' ==') return 0 ;;
    proc-m13:SKIP-OVERLAY:*'0 asserts ejecutados;'*) return 0 ;;
    proc13-pointers:*'SKIP-OVERLAY  (4) distribución'*'caso no evaluable aquí') return 0 ;;
    talent-buzz/probar-movil.sh:'SKIP host_acreditado positivo (esta maquina no tiene tailnet)') return 0 ;;
    motor:*'SKIP guard PreToolUse: hook de instancia no distribuido; no se evaluó su conducta') return 0 ;;
    talent-memoria/probar-lib.sh:*'OMIT  tm_manifest/tm_git_baseline con symlink (ln no disponible)') return 0 ;;
    talent-memoria/probar-diagnostico.sh:*'OMIT  symlink en el corpus (ln no disponible)') return 0 ;;
    talent-memoria/probar-salvaguarda.sh:*'OMIT  criterio git (git no instalado)'|talent-memoria/probar-salvaguarda.sh:*'OMIT  symlink (ln no disponible)'|talent-memoria/probar-salvaguarda.sh:*'OMIT  worktree (git no instalado)') return 0 ;;
    talent-memoria/probar-verificar.sh:*'OMIT  [7 error de diff] (root lee ficheros 000)') return 0 ;;
    talent-llm-local/probar-fallo-cerrado.sh:*'OMIT  no se ha podido provocar el caso con este parametro') return 0 ;;
    *) return 1 ;;
  esac
}
for i in "${!IDS[@]}"; do
  id="${IDS[$i]}"; [ -z "$solo" ] || [ "$id" = "$solo" ] || continue
  if excluida "$id"; then skip "$id" 'excluida por el operador'; continue; fi
  case "$id" in
    talent-buzz/probar-antifugas.sh)
      if ! git rev-parse --verify main >/dev/null 2>&1; then skip "$id" 'sin repo/main para auditar historia; el detector se prueba en probar-antifugas-fixtures.sh'; continue; fi
      if [ "$(git rev-list --count main..HEAD)" = 0 ]; then skip "$id" 'sin commits de rama para auditar; el detector se prueba en probar-antifugas-fixtures.sh'; continue; fi ;;
    talent-buzz/probar-patches.sh)
      if ! bash -c '. skills/talent-buzz/scripts/00-config.sh; proveedor="${TB_BUZZ_GIT:-$HOME/buzz}"; [ -e "$proveedor/.git" ] && git -C "$proveedor" cat-file -e "$TB_BUZZ_COMMIT^{commit}"' >/dev/null 2>&1; then
        skip "$id" 'sin checkout local con el pin del proveedor; red no permitida en esta batería'; continue
      fi ;;
    talent-llm-local/probar-puente.sh)
      if ! systemctl is-active --quiet llm-bridge 2>/dev/null; then skip "$id" 'llm-bridge no está activo en esta máquina'; continue; fi ;;
    llm-referencia)
      if [ ! -r /etc/systemd/system/vllm.service ]; then skip "$id" 'sin unidad /etc/systemd/system/vllm.service de referencia'; continue; fi ;;
  esac
  log="$OUT/${id//\//_}.log"
  # La fila propia ya cubre fases; --solo motor conserva su ejecución autónoma.
  fases_cubiertas=0
  if [ "$id" = motor ] && [ -z "$solo" ] && ! excluida instalacion-fases; then fases_cubiertas=1; fi
  TF_FASES_EN_BATERIA="$fases_cubiertas" TB_BUZZ_SIN_RED=1 timeout "$SUITE_TIMEOUT" bash -c "${CMDS[$i]}" > "$log" 2>&1; rc=$?
  if [ "$rc" = 124 ]; then
    printf '  FAIL %s: tiempo agotado tras %s s; la máquina es lenta o la suite se colgó (rc=124) log=%s\n' "$id" "$SUITE_TIMEOUT" "$log"
  fi
  bad_skip=0; nskip=0; omisiones_sin_contador=0
  while IFS= read -r line; do
    if skip_declarado "$id" "$line"; then
      NOTAS+=("$id: $line"); nskip=$((nskip+1))
      [[ "$line" != '== '* ]] || omisiones_sin_contador=$((omisiones_sin_contador+1))
    else
      echo "  FAIL $id: SKIP no declarado: $line"; bad_skip=1
    fi
  done < <(grep -E '^[[:space:]]*([[:alnum:]_.-]+:[[:space:]]+)?(SKIP(-[[:alnum:]_-]+)?([[:space:]:]|$)|OMIT([[:space:]:]|$))|^== .* OMITIDOS( .*)? ==$' "$log")
  resumen=''; bad_final=0
  if [ -n "${RESUMENES[$i]}" ]; then
    resumen="$(grep -E "${RESUMENES[$i]}" "$log" | tail -n 1)"
    # Única fila sin asserts: el hijo sale antes de ejecutar, con UNA línea exacta.
    # Comparación byte a byte: ni líneas vacías añadidas ni texto extra.
    omision_completa=0
    if [ "$id" = proc-m13 ] && [ "$nskip" = 1 ] &&
       printf '%s\n' 'SKIP-OVERLAY: distribución (TF_PAQUETE_ESTADO=distribucion) sin anexo por repo (anexo-<proyecto>.md) — 0 asserts ejecutados; esta suite corre en la instancia' | cmp -s - "$log"; then
      omision_completa=1
    fi
    if [ -z "$resumen" ] && [ "$omision_completa" = 0 ]; then
      echo "  FAIL $id: falta resumen final con el formato declarado"; bad_final=1
    fi
  fi
  while IFS= read -r contador; do
    numero="${contador##*=}"; numero="${numero%% *}"
    if [ "$numero" -gt 0 ]; then echo "  FAIL $id: resultado final contradictorio: $resumen"; bad_final=1; fi
  done < <(printf '%s\n' "$resumen" | grep -oE '(FAIL|FALLA|FALLOS)=[0-9]+|[0-9]+ (FAIL|fallos|fallidos|fallidas|FALLOS|NO-MEDIDO|hallazgo\(s\)|caso\(s\) FALLARON)([[:space:],./]|$)')
  if [[ "$resumen" =~ hubo\ fallos|:\ FALLOS|^FAILED|RESULTADO:.*(ROJO|FALLO|NO\ MEDIDA)|Fallidos:|^DESFASE\(S\)|^[[:space:]]+DIFERENCIAS ]]; then bad_final=1; fi
  resumen_skip="$(printf '%s\n' "$resumen" | grep -oE 'SKIP(-[[:alnum:]_-]+)?=[0-9]+' | awk -F= '{n+=$2} END {print n+0}')"
  tiene_resumen_skip=0
  if [[ "$resumen" =~ SKIP(-[[:alnum:]_-]+)?=[0-9]+ ]]; then
    tiene_resumen_skip=1
  elif [[ "$resumen" =~ ,[[:space:]]([0-9]+)[[:space:]]SKIP ]]; then
    resumen_skip="${BASH_REMATCH[1]}"; tiene_resumen_skip=1
  elif [[ "$resumen" =~ SKIP-OVERLAY[[:space:]]declarados:[[:space:]]([0-9]+) ]]; then
    resumen_skip="${BASH_REMATCH[1]}"; tiene_resumen_skip=1
  fi
  if [ "$tiene_resumen_skip" = 1 ] && [ "$resumen_skip" -ne "$((nskip-omisiones_sin_contador))" ]; then
    echo "  FAIL $id: resumen SKIP=$resumen_skip sin $nskip omisiones declaradas concordantes"; bad_skip=1
  fi
  if [ "$rc" -ne 0 ] || [ "$bad_skip" -ne 0 ] || [ "$bad_final" -ne 0 ]; then
    FAIL=$((FAIL+1)); printf '  FAIL %s: rc=%s log=%s\n' "$id" "$rc" "$log"
    tail -n 8 "$log"
  elif [ "$nskip" -gt 0 ]; then
    skip "$id" "$nskip omisiones internas declaradas; resultados ejecutados en $log"
  else
    PASS=$((PASS+1)); printf '  PASS %s: rc=0 log=%s\n' "$id" "$log"
  fi
done
printf '\nSKIP justificados (aparte de PASS):\n'
printf '  %s\n' "${NOTAS[@]}"
printf '\nRESULTADO: PASS=%s FAIL=%s SKIP=%s TOTAL=%s\n' "$PASS" "$FAIL" "$SKIP" "$((PASS+FAIL+SKIP))"
if [ "$FAIL" -gt 0 ]; then echo 'VEREDICTO: FAIL (rc=1)'; exit 1; fi
echo 'VEREDICTO: PASS (rc=0)'
