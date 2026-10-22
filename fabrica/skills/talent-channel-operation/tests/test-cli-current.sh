#!/usr/bin/env bash
# Regresiones de compositor, turnos locales y brief de instancia. Solo en el arnés.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$TEST_DIR/../scripts"
if [ ! -f "$SC/repo-identity.conf" ] && [ -z "${TCO_REPO_DIR:-}" ]; then
  export TF_LINEAR_TEAM_KEY=ABC TCO_REPO_DIR=Repo-Neutro TCO_REPO_SLUG=org-neutra/Repo-Neutro TCO_REPO_STACK=ninguno
  export TCO_ANEXO_FILE=references/anexo-neutro.md TCO_HOST_ENV_REL=Repo-Neutro/.env.local
  export TCO_LINEAR_INPROGRESS_STATE=00000000-0000-4000-8000-000000000007
  export TCO_LINEAR_INREVIEW_STATE=00000000-0000-4000-8000-000000000008
fi
# shellcheck source=/dev/null
. "$SC/dispatch.sh"
FX="$TEST_DIR/fixtures/cli-current"
TMP_TEST="$(mktemp -d)"
trap 'rm -rf "$TMP_TEST"' EXIT
export TCO_MODELOS_REGISTRO="$TEST_DIR/fixtures/modelos-cli-current.conf"
MODEL_OPUS="$(tco_modelo_read plan)" || exit 1
MODEL_SONNET="$(tco_modelo_read coding)" || exit 1
PASS=0; FAIL=0
ok() {
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'PASS %s\n' "$1";
  else FAIL=$((FAIL+1)); printf 'FAIL %s: esperaba [%s], obtuvo [%s]\n' "$1" "$3" "$2"; fi
}
relay='lee /home/USER/.tco-relay/dispatch.0123456789abcdef.txt — es tu brief de tarea; síguelo y presenta el plan con ExitPlanMode'
ok 'capturas neutralizadas sin secretos ni cuentas' "$(cat "$FX"/*.txt | tco_fixture_secret_scan; echo $?)" 0
for wrap in two three; do
  cap="$(cat "$FX/wrapped-$wrap.txt")"
  ok "eco íntegro en $wrap líneas" "$(printf '%s' "$cap" | tco_tui_regions_from composer | tco_composer_echo_from "$relay"; echo $?)" 0
  ok "pendiente en $wrap líneas" "$(printf '%s' "$cap" | tco_input_pending_from "$relay"; echo $?)" 0
  ok "pendiente no acredita entrega en $wrap líneas" "$(tco_delivered_from "$cap" "$relay"; echo $?)" 1
  incomplete="${cap/plan con ExitPlanMode/plan con}"
  ok "parte ausente en $wrap líneas" "$(printf '%s' "$incomplete" | tco_tui_regions_from composer | tco_composer_echo_from "$relay"; echo $?)" 1
done
cap="$(cat "$FX/triplicated.txt")"
ok 'triplicado parcial bloquea eco íntegro' "$(printf '%s' "$cap" | tco_tui_regions_from composer | tco_composer_echo_from "$relay"; echo $?)" 1
ok 'triplicado es pendiente ambiguo' "$(printf '%s' "$cap" | tco_input_pending_from 'lee /home/USER/.tco-relay/dispatch.0123456789abcdef.txt'; echo $?)" 2
ok 'duplicado íntegro es ambiguo' "$(printf '%s\n%s' "$relay" "$relay" | tco_unique_token_in_region_from "$relay"; echo $?)" 2
ok 'relay parcial no autoriza re-submit por prefijo' "$(sed 's/plan con ExitPlanMode/plan con/' "$FX/wrapped-two.txt" | tco_input_pending_from 'lee /home/USER/.tco-relay/dispatch.0123456789abcdef.txt' "$relay"; echo $?)" 2
ok 'relay íntegro autoriza re-submit sin re-tipear' "$(tco_input_pending_from 'lee /home/USER/.tco-relay/dispatch.0123456789abcdef.txt' "$relay" < "$FX/wrapped-two.txt"; echo $?)" 0
ok 'espacios solos no son token' "$(printf 'texto' | tco_token_in_region_from '  '; echo $?)" 1
ok 'eco dim no acredita envío' "$(printf '\033[2m%s\033[0m' "$relay" | tco_composer_echo_from "$relay"; echo $?)" 1
ok 'entrega reconoce texto partido en transcript' "$(tco_delivered_from "$(printf '%s\n' 'lee /home/USER/.tco-relay/dispatch.0123456789abcdef.txt — es tu brief de' 'tarea; síguelo y presenta el plan con ExitPlanMode'; cat "$FX/plan.txt")" "$relay"; echo $?)" 0

# Mocks registran el submit: un eco negativo debe dejar cero Enters.
_send_test() (
  local capture="$1"
  tco_pane_busy() { return 1; }
  incus() { printf '%s\n' "$*" >> "$TMP_TEST/send.calls"; }
  sleep() { :; }
  tco_cap_pane_e() {
    if grep -q ' -l --' "$TMP_TEST/send.calls"; then cat "$capture"; else cat "$TEST_DIR/fixtures/pane/claude_2.1.289/idle.txt"; fi
  }
  tco_cap_pane() { cat "$capture"; }
  : > "$TMP_TEST/send.calls"
  _tco_send_text_submit 01 v:.0 "$relay" C-m yes >/dev/null 2>&1
  local rc=$?
  printf '%s:%s' "$rc" "$(grep -c 'C-m' "$TMP_TEST/send.calls")"
)
ok 'envío real separado con eco partido' "$(_send_test "$FX/wrapped-two.txt")" '0:1'
ok 'envío bloqueado sin parte del texto' "$(sed 's/plan con ExitPlanMode/plan con/' "$FX/wrapped-two.txt" > "$TMP_TEST/incomplete.txt"; _send_test "$TMP_TEST/incomplete.txt")" '2:0'
ok 'envío bloqueado con compositor triplicado' "$(_send_test "$FX/triplicated.txt")" '2:0'

for tag in local-command-stdout local-command-stderr local-command-caveat command-name command-message; do
  local_rec="$(jq -cn --arg tag "$tag" '{type:"user",uuid:"local",message:{content:("<"+$tag+">token</"+$tag+">")}}')"
  printf '%s\n' "$local_rec" > "$TMP_TEST/$tag.jsonl"
  ok "orden $tag no está en vuelo" "$(tco_transcript_inflight_from < "$TMP_TEST/$tag.jsonl"; echo $?)" 1
  ok "orden $tag no tiene uuid de submisión" "$(tco_user_submit_uuids_from token < "$TMP_TEST/$tag.jsonl")" ''
  ok "orden $tag no tiene uuid posterior" "$(tco_user_submit_after_from token 2000-01-01T00:00:00Z < "$TMP_TEST/$tag.jsonl"; echo $?)" 1
  ok "orden $tag no invalida plan" "$(printf '%s\n%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"plan","name":"ExitPlanMode","input":{"plan":"Plan vigente"}}]}}' "$local_rec" | tco_exitplan_plan_from)" 'Plan vigente'
  ok "orden $tag no borra texto del asistente" "$(printf '%s\n%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Respuesta"}]}}' "$local_rec" | tco_last_assistant_text_from)" 'Respuesta'
  ok "orden $tag no oculta humano sin respuesta" "$(printf '%s\n%s\n' '{"type":"user","message":{"content":"humano"}}' "$local_rec" | tco_transcript_inflight_from; echo $?)" 0
done
human='{"type":"user","uuid":"human","message":{"content":"token"}}'
ok 'humano está en vuelo' "$(printf '%s' "$human" | tco_transcript_inflight_from; echo $?)" 0
ok 'humano acredita uuid' "$(printf '%s' "$human" | tco_user_submit_uuids_from token)" human
ok 'humano invalida plan anterior' "$(printf '%s\n%s' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"plan","name":"ExitPlanMode","input":{"plan":"Plan"}}]}}' "$human" | tco_exitplan_plan_from; echo $?)" 4
ok 'texto local en array no es turno' "$(printf '%s' '{"type":"user","message":{"content":[{"type":"text","text":"<command-message>token"}]}}' | tco_transcript_inflight_from; echo $?)" 1
ok 'humano en array está en vuelo' "$(printf '%s' '{"type":"user","message":{"content":[{"type":"text","text":"humano"}]}}' | tco_transcript_inflight_from; echo $?)" 0
ok 'JSON corrupto no acredita uuid' "$(printf '%s' '{invalido' | tco_user_submit_uuids_from token; echo $?)" 1
meta_result='{"type":"user","isMeta":true,"message":{"content":[{"type":"tool_result","tool_use_id":"plan","content":"ok"}]}}'
ok 'resultado meta cierra herramienta pendiente' "$(printf '%s\n%s' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"plan"}]}}' "$meta_result" | tco_transcript_inflight_from; echo $?)" 1
ok 'resultado meta acredita aprobación del plan' "$(printf '%s\n%s' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"plan","name":"ExitPlanMode","input":{"plan":"Plan"}}]}}' "$meta_result" | tco_exitplan_plan_from; echo $?)" 3

for state in idle busy plan; do
  expected=1
  [ "$state" = busy ] && expected=0
  ok "captura real $state" "$(tco_pane_busy_from < "$FX/$state.txt"; echo $?)" "$expected"
done
for modal in 'How is Claude doing this session? (optional)' 'How would you rate this session?' 'Can Anthropic look at your session transcript?' 'Yes, I trust this folder' 'Select model' 'Bypass Permissions mode'; do
  case "$modal" in How*) expected=survey-rating ;; Can*) expected=survey ;; Yes*) expected=trust ;; *) expected=modal ;; esac
  ok "modal conocido: $modal" "$(printf '%s' "$modal" | tco_pane_anomaly)" "$expected"
  ok "frase histórica con compositor identificable: $modal" "$( { printf '%s\n' "$modal"; cat "$FX/idle.txt"; } | tco_pane_busy_from; echo $?)" 1
done
ok 'redibujado incompleto es desconocido' "$(printf '───\n❯ texto\n' | tco_pane_busy_from; echo $?)" 2
ok 'separadores de prosa sin prompt no son compositor' "$(printf '───\ntexto\n───\nshift+tab\n' | tco_pane_busy_from; echo $?)" 2
ok 'prosa que cita actividad no está ocupada' "$( { printf '%s\n' 'El informe cita esc to interrupt'; cat "$FX/idle.txt"; } | tco_pane_busy_from; echo $?)" 1
ok 'encuesta reconocida' "$(printf 'How would you rate this session?' | tco_pane_anomaly)" survey-rating
ok 'encuesta real del ensayo nunca idle' "$(tco_pane_busy_from < "$FX/survey-rating.txt"; echo $?)" 2
ok 'encuesta descartada con cero' "$(
  incus() { printf '%s\n' "$*" > "$TMP_TEST/heal.calls"; }; sleep() { :; }
  tco_cap_pane() { cat "$FX/survey-rating.txt"; }
  tco_pane_heal 01 v:.0 survey-rating >/dev/null
  grep -c 'v:.0.* 0' "$TMP_TEST/heal.calls"
)" 1
ok 'idle persistido con encuesta sigue bloqueado' "$(
  _tco_carril_session() { printf 'sid idle 1'; }
  _tco_transcript_lines() { printf '%s' '{"type":"user","message":{"content":"<local-command-stdout>done"}}'; }
  tco_cap_pane() { printf 'How would you rate this session?'; }
  tco_pane_busy 01 v:.0; echo $?
)" 2
picker="$(printf '%s\n' 'Select model' '  1. Sonnet 5.5' '❯ 2. Opus 5.5 ✔' 'Kept model as Opus 5.5')"
ok 'picker reconoce modelo activo con respuesta local' "$(printf '%s' "$picker" | tco_model_is "$MODEL_OPUS"; echo $?)" 0
ok 'picker selecciona opción actual por número' "$(printf '%s' "$picker" | tco_model_picker_pick "$MODEL_OPUS")" 2
ok 'respuesta local sola no confirma modelo' "$(printf 'Kept model as Opus 5.5' | tco_model_is "$MODEL_OPUS"; echo $?)" 1

cat > "$TMP_TEST/docs.conf" <<'EOF'
TF_GATE_IDS="docs"
TF_GATE_CMD_docs="bash scripts/docs.sh"
EOF
cat > "$TMP_TEST/multi.conf" <<'EOF'
TF_GATE_IDS="docs db-guards"
TF_GATE_CMD_docs="bash scripts/docs.sh"
TF_GATE_CMD_db_guards="bash scripts/db.sh"
EOF
template="$SC/../assets/prompt-dispatch.tmpl"
brief="$(TCO_TF_MANIFEST="$TMP_TEST/docs.conf" TCO_REPO_STACK=ninguno tco_dispatch_instance_blocks "$template")"
ok 'brief solo gate docs' "$(printf '%s' "$brief" | grep -c 'docs: bash scripts/docs.sh')" 1
ok 'brief sin rutas ni gates ajenos' "$(printf '%s' "$brief" | grep -cE 'npm run|supabase/migrations|migration_slots|typecheck/lint/build')" 0
brief="$(TCO_TF_MANIFEST="$TMP_TEST/multi.conf" TCO_REPO_STACK=supabase tco_dispatch_instance_blocks "$template")"
ok 'brief incluye todos los gates' "$(printf '%s' "$brief" | grep -cE 'docs: bash scripts/docs.sh|db-guards: bash scripts/db.sh')" 2
ok 'brief con stack de migraciones' "$(printf '%s' "$brief" | grep -c 'MIGRACIONES:')" 1
ok 'brief sin manifiesto falla cerrado' "$(TCO_TF_MANIFEST="$TMP_TEST/absent.conf" TCO_REPO_STACK=ninguno tco_dispatch_instance_blocks "$template"; echo $?)" 1
printf 'TF_GATE_IDS="missing"\n' > "$TMP_TEST/missing.conf"
ok 'gate sin comando falla cerrado' "$(tco_dispatch_gate_lines "$TMP_TEST/missing.conf"; echo $?)" 1
printf 'TF_GATE_IDS="docs docs"\nTF_GATE_CMD_docs="true"\n' > "$TMP_TEST/duplicate.conf"
ok 'gates repetidos fallan cerrado' "$(tco_dispatch_gate_lines "$TMP_TEST/duplicate.conf" >/dev/null; echo $?)" 1
ok 'stack desconocido falla cerrado' "$(TCO_TF_MANIFEST="$TMP_TEST/docs.conf" TCO_REPO_STACK=otro tco_dispatch_instance_blocks "$template"; echo $?)" 1
ok 'canales arrancan sin encuestas en ambos paneles' "$(grep -c 'send-keys.*CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1' "$SC/../../talent-channels/assets/launcher-v.tmpl")" 2
ok 'despacho arranca sin encuestas en ambos paneles' "$(grep -c 'respawn-pane.*CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1' "$SC/dispatch.sh")" 2
ok 'torre arranca sin encuestas' "$(grep -c 'CMD=.*CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1' "$SC/../../talent-orchestrator/scripts/torre-resume.sh")" 1

REAL_FX="$TEST_DIR/fixtures/pane/claude_2.1.289"
ok 'busy conserva exactamente la captura con contador' "$(cmp -s "$REAL_FX/busy.txt" "$REAL_FX/t-5.txt"; echo $?)" 0
for state in idle busy modal redraw done t-1 t-3 t-5; do
  case "$state" in idle|done) expected=1 ;; modal|redraw) expected=2 ;; *) expected=0 ;; esac
  ok "captura de versión actual $state" "$(tco_pane_busy_from < "$REAL_FX/$state.txt"; echo $?)" "$expected"
  ok "captura de versión actual publicable $state" "$(tco_fixture_secret_scan < "$REAL_FX/$state.txt"; echo $?)" 0
done
ok 'actividad citada antes de otra línea es reposo' "$( { printf '✽ Schlepping…\nRespuesta terminada\n'; cat "$REAL_FX/idle.txt"; } | tco_pane_busy_from; echo $?)" 1
ok 'turno terminado es reposo' "$(tco_pane_busy_from < "$REAL_FX/done.txt"; echo $?)" 1
ok 'actividad citada cerca del compositor no ocupa' "$( { printf '✻ Schlepping… (3s · ↓ 98 tokens)\nRespuesta terminada\n\n'; sed -n '/^───/,$p' "$REAL_FX/idle.txt"; } | tco_pane_busy_from; echo $?)" 1
for activity in '✶ Schlepping…' '· Schlepping… (3s · ↓ 74 tokens)' '✻ Schlepping… (3s · ↓ 98 tokens · thinking with high effort)'; do
  ok "actividad pegada al compositor $activity" "$( { printf '%s\n\n' "$activity"; sed -n '/^───/,$p' "$REAL_FX/idle.txt"; } | tco_pane_busy_from; echo $?)" 0
done

_activity_capture() {
  printf '%s\n' "$1"
  sed -n '/^───/,$p' "$REAL_FX/idle.txt"
}
ok 'actividad con consejo debajo sigue ocupada' "$( _activity_capture $'✢ Onioning… (32s · ↓ 2.9k tokens)\n  ⎿  Tip: consejo\n     continuación' | tco_pane_busy_from; echo $?)" 0
ok 'actividad con tareas anexas sigue ocupada' "$( _activity_capture $'✶ Schlepping…\n  ⎿  ☐ Primera tarea\n     ☐ Segunda tarea\n     ☑ Tercera tarea' | tco_pane_busy_from; echo $?)" 0
ok 'actividad citada sangrada deja el panel en reposo' "$( _activity_capture $'Respuesta terminada\n  ✻ Schlepping… (3s · ↓ 98 tokens)' | tco_pane_busy_from; echo $?)" 1
ok 'turno terminado con shell pendiente está en reposo' "$( _activity_capture '✻ Baked for 7s · done 7:33 PM · 1 shell still running' | tco_pane_busy_from; echo $?)" 1
ok 'línea posterior en columna cero decide reposo' "$( _activity_capture $'✶ Schlepping…\n  ⎿  Tip: consejo\nRespuesta terminada' | tco_pane_busy_from; echo $?)" 1

ok 'redraw sin compositor falla' "$(printf 'solo transcript\n' | tco_redraw_fixture_from >/dev/null; echo $?)" 1
ok 'redraw con transcript vacío falla' "$(sed -n '/^───/,$p' "$REAL_FX/idle.txt" | tco_redraw_fixture_from >/dev/null; echo $?)" 1
ok 'redraw derivado es desconocido' "$(tco_redraw_fixture_from < "$REAL_FX/busy.txt" | tco_pane_busy_from; echo $?)" 2
ok 'redraw coincide con recorte versionado' "$(tco_redraw_fixture_from < "$REAL_FX/busy.txt")" "$(cat "$REAL_FX/redraw.txt")"
rc=0
TCO_FIXTURE_DIR="$TMP_TEST/redraw-fixture" bash "$SC/capture-pane-fixtures.sh" --from-stdin --cli-version claude:2.1.289 redraw < "$REAL_FX/busy.txt" >/dev/null 2>&1 || rc=$?
ok 'capturador deriva redraw con el mismo método' "$rc:$(cat "$TMP_TEST/redraw-fixture/claude_2.1.289/redraw.txt")" "0:$(cat "$REAL_FX/redraw.txt")"
rc=0
printf 'sin compositor\n' | TCO_FIXTURE_DIR="$TMP_TEST/rejected-redraw" bash "$SC/capture-pane-fixtures.sh" --from-stdin --cli-version claude:2.1.289 redraw >/dev/null 2>&1 || rc=$?
ok 'capturador rechaza redraw sin compositor y no escribe' "$rc:$([ -e "$TMP_TEST/rejected-redraw/claude_2.1.289/redraw.txt" ] && echo escrito || echo ausente)" 1:ausente

for state in idle busy t-1 t-3 t-5; do
  ok "ancla real sin quitar relleno inferior $state" "$(tco_tui_anchor_from < "$REAL_FX/$state.txt" | grep -cE '^[0-9]+ [0-9]+$')" 1
  for region in transcript composer status; do
    ok "región real $state $region" "$(tco_tui_regions_from "$region" < "$REAL_FX/$state.txt" >/dev/null; echo $?)" 0
  done
done
for region in transcript composer status; do
  ok "modal sin región inventada $region" "$(tco_tui_regions_from "$region" < "$REAL_FX/modal.txt" >/dev/null; echo $?)" 2
done
audit_capture="$(printf 'STOP-AUDIT — ABC-1234 · informe pre-push\n──────\nInforme completo\n'; sed -n '/^───/,$p' "$REAL_FX/idle.txt")"
ok 'extractor conserva separador de prosa y excluye compositor recto' "$(printf '%s\n' "$audit_capture" | tco_extract_stop_audit | grep -cE '^❯|ctx:|bypass permissions')" 0
ok 'extractor conserva informe y separador' "$(printf '%s\n' "$audit_capture" | tco_extract_stop_audit | grep -cE '^──────$|^Informe completo$')" 2

_model_current_test() (
  local requested="$1" final="$2" rc=0
  # La familia y versión se derivan del registro; Default no es la fila Sonnet.
  sleep() { :; }
  tco_cap_pane_e() { cat "$REAL_FX/idle.txt"; }
  tco_pane_busy() { return 1; }
  tco_clear_input() { :; }
  # El transporte se prueba con capturas cambiantes en las regresiones de envío.
  _tco_send_text_submit() { :; }
  printf '0\n' > "$TMP_TEST/model-clock"
  : > "$TMP_TEST/model-calls"
  date() { local n; read -r n < "$TMP_TEST/model-clock"; n=$((n+1)); printf '%s\n' "$n" > "$TMP_TEST/model-clock"; printf '%s\n' "$n"; }
  tco_cap_pane() {
    if [ -e "$TMP_TEST/model-chosen" ]; then
      printf 'Kept model as %s\n' "$final"
      cat "$REAL_FX/idle.txt"
    else cat "$REAL_FX/modal.txt"; fi
  }
  incus() {
    printf '%s\n' "$*" >> "$TMP_TEST/model-calls"
    [[ "$*" != *"v:.0' 4"* ]] || : > "$TMP_TEST/model-chosen"
    return 0
  }
  rm -f "$TMP_TEST/model-chosen"
  tco_current_model_dialog() {
    case "$final" in
      Opus*) sed 's/Sonnet ✔/Sonnet/; s/4\. Opus /4. Opus ✔ /' "$REAL_FX/modal.txt" ;;
      *) cat "$REAL_FX/modal.txt" ;;
    esac
  }
  TCO_EFFORT_CONFIRM_MAX=2 tco_set_model 01 v:.0 "$requested" > "$TMP_TEST/model-result" 2>&1 || rc=$?
  printf '%s:%s:%s' "$rc" "$(grep -c 'ERROR:' "$TMP_TEST/model-result")" "$(grep -cE 'send-keys.* [0-9]+$' "$TMP_TEST/model-calls")"
)
ok 'modelo ya activo con captura real y Kept es éxito sin error' "$(_model_current_test "$MODEL_SONNET" 'Sonnet 5.5')" 0:0:0
ok 'Kept durante cambio confirmado es éxito sin error' "$(_model_current_test "$MODEL_OPUS" 'Opus 5.5')" 0:0:1
ok 'Kept con modelo activo distinto falla cerrado' "$(_model_current_test "$MODEL_OPUS" 'Sonnet 5.5')" 2:1:1

_delayed_echo_test() (
  local mode="$1" rc=0 delivery=- polls_seen
  tco_pane_busy() { return 1; }
  incus() { printf '%s\n' "$*" >> "$TMP_TEST/delayed.calls"; }
  sleep() { :; }
  tco_cap_pane_e() {
    local n; read -r n < "$TMP_TEST/echo-count"; n=$((n+1)); printf '%s\n' "$n" > "$TMP_TEST/echo-count"
    if [ "$n" -eq 1 ]; then cat "$REAL_FX/idle.txt"
    elif [ "$mode" = duplicate ]; then cat "$FX/triplicated.txt"
    elif [ "$n" -ge 4 ] && [ "$mode" = delayed ]; then cat "$FX/wrapped-two.txt"
    else cat "$REAL_FX/idle.txt"; fi
  }
  printf '0\n' > "$TMP_TEST/echo-count"; : > "$TMP_TEST/delayed.calls"
  TCO_RELAY_ECHO_POLLS=4 TCO_RELAY_ECHO_GAP=0 _tco_send_text_submit 01 v:.0 "$relay" C-m yes >/dev/null 2>&1 || rc=$?
  polls_seen="$(cat "$TMP_TEST/echo-count")"
  if [ "$rc" -eq 0 ]; then
    # Tras submit el texto pasa al transcript y el compositor queda vacío.
    tco_cap_pane_e() { printf '%s\n' "$relay"; cat "$REAL_FX/idle.txt"; }
    delivery=0; tco_verify_delivered 01 v:.0 1 "$relay" yes || delivery=$?
  fi
  printf '%s:%s:%s:%s:%s' "$rc" "$polls_seen" "$(grep -c ' -l --' "$TMP_TEST/delayed.calls")" "$(grep -c 'C-m' "$TMP_TEST/delayed.calls")" "$delivery"
)
ok 'eco al tercer sondeo entrega con un tecleo y un submit' "$(_delayed_echo_test delayed)" 0:4:1:1:0
ok 'eco ausente al tope es ambiguo sin submit' "$(_delayed_echo_test absent)" 2:5:1:0:-
ok 'eco duplicado no recibe submit ni segundo tecleo' "$(_delayed_echo_test duplicate)" 2:5:1:0:-

# shellcheck source=/dev/null
. "$SC/watch-carril.sh"
header="$(tco_stop_audit_header ABC-1234)"
ok 'cabecera canónica conserva contrato' "$header" 'STOP-AUDIT — ABC-1234 · informe pre-push'
brief="$(TCO_TF_MANIFEST="$TMP_TEST/docs.conf" TCO_REPO_STACK=ninguno tco_dispatch_instance_blocks "$template" | sed 's/__ISSUE__/ABC-1234/g')"
ok 'brief imprime cabecera compartida una vez' "$(printf '%s\n' "$brief" | grep -cF "$header")" 1
ok 'monitor reconoce cabecera emitida por brief' "$(printf '%s\n' "$brief" | grep -cE "$(tco_watch_pattern stop-audit)")" 1
ok 'extractor reconoce cabecera emitida por brief' "$( { printf '%s\n' "$header" 'Informe'; sed -n '/^───/,$p' "$REAL_FX/idle.txt"; } | tco_extract_stop_audit)" "$header
Informe"
ok 'monitor no reconoce cita conversacional' "$(printf 'Estoy en STOP-AUDIT\n' | grep -cE "$(tco_watch_pattern stop-audit)")" 0

_baseline_cleanup_test() {
  set -u
  local sender="$1" send_result="$2" rc=0
  mktemp() { printf '%s\n' "$TMP_TEST/baseline-$sender"; }
  incus() { :; }
  sleep() { :; }
  tco_wait_idle() { return 0; }
  tco_pane_busy() { return 1; }
  tco_clear_input() { :; }
  tco_cap_pane() { cat "$REAL_FX/idle.txt"; }
  tco_cap_pane_e() { cat "$REAL_FX/idle.txt"; }
  tco_delivery_baseline() { : > "$4"; return 1; }
  _tco_send_text_submit() { printf 'tecleo\n' >> "$TMP_TEST/baseline-calls"; return "$send_result"; }
  tco_verify_delivered() { printf 'entrega\n' > "$TMP_TEST/delivery-receipt"; return 0; }
  : > "$TMP_TEST/baseline-calls"
  if [ "$sender" = single ]; then tco_send_dev 01 v:.0 texto >/dev/null 2>&1 || rc=$?
  else tco_relay_file 01 v:.0 "$REAL_FX/idle.txt" brief >/dev/null 2>&1 || rc=$?; fi
  unrelated_return() { :; }
  unrelated_return
  printf '%s:%s:%s' "$rc" "$([ -e "$TMP_TEST/baseline-$sender" ] && echo pendiente || echo limpio)" "$(grep -c tecleo "$TMP_TEST/baseline-calls")"
}
for sender in single file; do
  ok "baseline $sender limpia con nounset tras éxito y retorno ajeno" "$(_baseline_cleanup_test "$sender" 0; printf ':%s' "$?")" 0:limpio:1:0
  ok "baseline $sender limpia tras ambigüedad sin segundo tecleo" "$(_baseline_cleanup_test "$sender" 2; printf ':%s' "$?")" 2:limpio:1:0
done

# La configuración regional pertenece al proceso de prueba; cada función debe conservarla.
for locale in C C.UTF-8; do
  for state in idle busy modal redraw done t-1 t-3 t-5; do
    case "$state" in idle|done) expected=1 ;; modal|redraw) expected=2 ;; *) expected=0 ;; esac
    file="$REAL_FX/$state.txt"
    ok "ocupado independiente de locale $locale $state" "$(export LC_ALL="$locale"; tco_pane_busy_from < "$file" >/dev/null; echo $?)" "$expected"
    reference="$(export LC_ALL=C.UTF-8; tco_tui_anchor_from < "$file"; printf '\nrc=%s' "$?")"
    ok "ancla independiente de locale $locale $state" "$(export LC_ALL="$locale"; tco_tui_anchor_from < "$file"; printf '\nrc=%s' "$?")" "$reference"
    for region in transcript composer status; do
      reference="$(export LC_ALL=C.UTF-8; tco_tui_regions_from "$region" < "$file"; printf '\nrc=%s' "$?")"
      ok "región independiente de locale $locale $state $region" "$(export LC_ALL="$locale"; tco_tui_regions_from "$region" < "$file"; printf '\nrc=%s' "$?")" "$reference"
    done
    ok "extractor sin informe conserva rc $locale $state" "$(export LC_ALL="$locale"; tco_extract_stop_audit < "$file" >/dev/null; echo $?)" 1
    ok "funciones conservan locale del llamador $locale $state" "$(
      export LC_ALL="$locale"
      tco_pane_busy_from < "$file" >/dev/null || :
      tco_tui_anchor_from < "$file" >/dev/null || :
      tco_tui_regions_from composer < "$file" >/dev/null || :
      tco_extract_stop_audit < "$file" >/dev/null || :
      printf '%s' "$LC_ALL"
    )" "$locale"
    case "$state" in modal|redraw) continue ;; esac
    reference="$(LC_ALL=C.UTF-8 tco_tui_regions_from transcript < "$file")"
    ok "extractor corta captura real con locale $locale $state" "$(
      export LC_ALL="$locale"
      { printf 'STOP-AUDIT — ABC-1234 · informe pre-push\n'; cat "$file"; } | tco_extract_stop_audit
    )" "STOP-AUDIT — ABC-1234 · informe pre-push
$reference"
  done
  old_chrome=$'STOP-AUDIT — ABC-1234 · informe pre-push\nInforme completo\n╭──╮\n❯\n╰──╯\nbypass permissions · ? for shortcuts'
  ok "ancla con esquinas y locale $locale" "$(export LC_ALL="$locale"; printf '%s\n' "$old_chrome" | tco_tui_anchor_from)" '3 5'
  ok "región con esquinas y locale $locale" "$(export LC_ALL="$locale"; printf '%s\n' "$old_chrome" | tco_tui_regions_from composer)" '❯'
  ok "extractor con esquinas y locale $locale" "$(export LC_ALL="$locale"; printf '%s\n' "$old_chrome" | tco_extract_stop_audit)" $'STOP-AUDIT — ABC-1234 · informe pre-push\nInforme completo'
  ok "busy con consejo y locale $locale" "$(export LC_ALL="$locale"; tco_pane_busy_from < "$FX/busy.txt"; echo $?)" 0
done

printf 'PASS=%s FAIL=%s TOTAL=%s\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] && [ "$((PASS+FAIL))" -eq 300 ]
