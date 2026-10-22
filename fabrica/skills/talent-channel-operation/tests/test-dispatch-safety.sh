#!/usr/bin/env bash
# Contrato de diálogos activos y envío con compositor propio. Solo en el arnés.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$TEST_DIR/../scripts"
export TF_LINEAR_TEAM_KEY=ABC TCO_REPO_DIR=Repo-Neutro TCO_REPO_SLUG=org-neutra/Repo-Neutro TCO_REPO_STACK=ninguno
export TCO_ANEXO_FILE=references/anexo-neutro.md TCO_HOST_ENV_REL=Repo-Neutro/.env.local
export TCO_LINEAR_INPROGRESS_STATE=00000000-0000-4000-8000-000000000007
export TCO_LINEAR_INREVIEW_STATE=00000000-0000-4000-8000-000000000008
# shellcheck source=/dev/null
. "$SC/00-config.sh"
# shellcheck source=/dev/null
. "${TCO_SAFETY_LIB:-$SC/lib.sh}"
FX="$TEST_DIR/fixtures/cli-current"
REAL="$TEST_DIR/fixtures/pane/claude_2.1.289"
TMP_TEST="$(mktemp -d)"
trap 'rm -rf "$TMP_TEST"' EXIT
PASS=0; FAIL=0
ok() {
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'PASS %s\n' "$1";
  else FAIL=$((FAIL+1)); printf 'FAIL %s: actual [%s], esperado [%s]\n' "$1" "$2" "$3"; fi
}
rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
_dialog() {
  # Selector y valoración: capturas reales; restantes: controles sintéticos de la suite.
  case "$1" in
    model) cat "$REAL/modal.txt" ;;
    rating) cat "$FX/survey-rating.txt" ;;
    survey) printf 'Can Anthropic look at your session transcript?\n  y: Yes  n: No  d: Details\n' ;;
    trust) printf 'Do you trust this folder?\n❯ 1. Yes, I trust this folder\n  2. No\nEnter to confirm · Esc to cancel\n' ;;
    bypass) printf 'Bypass Permissions mode\n❯ 1. Accept risk and bypass\n  2. Cancel\nEnter to confirm · Esc to cancel\n' ;;
    queue) cat "$REAL/idle.txt"; printf '\nPress up to edit queued messages\n' ;;
  esac
}
for locale in C C.UTF-8; do
  for kind in model rating survey trust bypass queue; do
    case "$kind" in
      model) phrase='Select model'; expected=modal ;;
      rating) phrase='How is Claude doing this session?'; expected=survey-rating ;;
      survey) phrase='Can Anthropic look at your session transcript?'; expected=survey ;;
      trust) phrase='Yes, I trust this folder'; expected=trust ;;
      bypass) phrase='Bypass Permissions mode'; expected=modal ;;
      queue) phrase='Press up to edit queued messages'; expected=queued-dup ;;
    esac
    ok "diálogo activo $kind en $locale" "$(export LC_ALL="$locale"; _dialog "$kind" | tco_pane_anomaly)" "$expected"
    for indent in '' '  '; do
      ok "frase citada $kind sangría [$indent] en $locale" "$(export LC_ALL="$locale"; { printf '%s%s\n' "$indent" "$phrase"; cat "$REAL/idle.txt"; } | rc_of tco_pane_anomaly)" 1
      ok "bloque completo citado $kind sangría [$indent] en $locale" "$(export LC_ALL="$locale"; { _dialog "$kind" | sed "s/^/$indent/"; cat "$REAL/idle.txt"; } | rc_of tco_pane_anomaly)" 1
    done
    ok "diálogo posterior a cita $kind en $locale" "$(export LC_ALL="$locale"; { _dialog "$kind"; printf '\nRespuesta terminada\n'; _dialog "$kind"; } | tco_pane_anomaly)" "$expected"
    ok "frase sin ancla $kind en $locale" "$(export LC_ALL="$locale"; printf '%s' "$phrase" | tco_pane_anomaly)" "$expected"
  done
  for kind in survey trust bypass; do
    case "$kind" in survey) expected=survey ;; trust) expected=trust ;; *) expected=modal ;; esac
    ok "diálogo $kind debajo de compositor antiguo en $locale" "$(export LC_ALL="$locale"; { cat "$REAL/idle.txt"; _dialog "$kind"; } | tco_pane_anomaly)" "$expected"
  done
  ok "encuesta transcript íntegra pegada al compositor en $locale" "$(export LC_ALL="$locale"; { _dialog survey; sed -n '/^───/,$p' "$REAL/idle.txt"; } | tco_pane_anomaly)" survey
  ok "estado persistido con cita en $locale" "$(
    export LC_ALL="$locale"
    _tco_carril_session() { printf 'sid idle 1'; }
    _tco_transcript_lines() { printf '{"type":"assistant","message":{"content":[{"type":"text","text":"fin"}]}}'; }
    tco_cap_pane() { printf 'Select model\n'; cat "$REAL/idle.txt"; }
    rc_of tco_pane_busy 01 v:.0
  )" 1
  ok "wait idle con cita en $locale" "$(
    export LC_ALL="$locale"
    _tco_carril_session() { printf 'sid idle 1'; }
    _tco_transcript_lines() { printf '{"type":"assistant","message":{"content":[{"type":"text","text":"fin"}]}}'; }
    tco_cap_pane() { printf 'Select model\n'; cat "$REAL/idle.txt"; }
    sleep() { :; }
    TCO_AMBIG_MAX=1 rc_of tco_wait_idle 01 v:.0 120
  )" 0
done

_nudge() (
  local mode="$1" rc=0 n=0
  tco_pane_busy() { return 1; } # Autoridad en reposo; la captura todavía debe acreditar vacío.
  : > "$TMP_TEST/calls"; printf '0\n' > "$TMP_TEST/polls"
  incus() { printf '%s\n' "$*" >> "$TMP_TEST/calls"; }
  sleep() { :; }
  tco_cap_pane_e() {
    read -r n < "$TMP_TEST/polls"; n=$((n+1)); printf '%s\n' "$n" > "$TMP_TEST/polls"
    case "$mode" in
      foreign) sed 's/^❯.*/❯ texto de otra persona/' "$REAL/idle.txt" ;;
      wrapped) cat "$FX/wrapped-two.txt" ;;
      busy) cat "$REAL/busy.txt" ;;
      modal) cat "$REAL/modal.txt" ;;
      duplicate) sed 's/^❯.*/❯ continuemos continuemos/' "$REAL/idle.txt" ;;
      no-anchor) printf 'pantalla parcial\n' ;;
      *)
        if [ "$n" -eq 1 ] || { [ "$mode" = delayed ] && [ "$n" -le 3 ]; }; then cat "$REAL/idle.txt"
        elif [ "$mode" = changed ]; then cat "$FX/wrapped-two.txt"
        elif [ "$mode" = anomaly-after ]; then cat "$FX/survey-rating.txt"
        elif [ "$mode" = capture-failed ]; then sed 's/^❯.*/❯ continuemos/' "$REAL/idle.txt"; return 1
        else sed 's/^❯.*/❯ continuemos/' "$REAL/idle.txt"; fi ;;
    esac
  }
  TCO_RELAY_ECHO_POLLS=4 TCO_RELAY_ECHO_GAP=0 _tco_send_text_submit 01 v:.0 continuemos >/dev/null 2>&1 || rc=$?
  printf '%s:%s:%s' "$rc" "$(grep -c ' -l --' "$TMP_TEST/calls")" "$(grep -c ' C-m' "$TMP_TEST/calls")"
)
ok 'empujón vacío envía una vez con eco propio' "$(_nudge empty)" 0:1:1
ok 'eco tardío envía una vez sin reteclear' "$(_nudge delayed)" 0:1:1
for state in foreign wrapped busy modal duplicate no-anchor; do
  ok "empujón $state no teclea ni envía" "$(_nudge "$state")" 2:0:0
done
for state in changed anomaly-after capture-failed; do
  ok "eco $state no envía ni reteclea" "$(_nudge "$state")" 2:1:0
done
ok 'submit sin propiedad no envía' "$(
  incus() { printf 'TECLA'; }
  rc_of tco_send_submit 01 v:.0
)" 2
for kind in survey survey-rating; do
  ok "curación $kind obsoleta no teclea" "$(
    incus() { printf 'TECLA'; }
    tco_cap_pane() { cat "$REAL/idle.txt"; }
    rc_of tco_pane_heal 01 v:.0 "$kind"
  )" 2
done
for kind in model confirm trust; do
  ok "confirmación $kind sin diálogo acreditado no envía teclas" "$(
    incus() { printf 'TECLA'; }
    rc_of tco_send_dialog_choice 01 v:.0 "$kind" 1 yes
  )" 2
done
ok 'sesión ocupada prevalece sobre captura quieta' "$(
  _tco_carril_session() { printf 'sid busy 1'; }
  tco_pane_busy() { return 0; }
  tco_cap_pane_e() { cat "$REAL/idle.txt"; }
  rc_of tco_send_ready 01 v:.0
)" 2
ok 'estado desconocido prevalece sobre captura quieta' "$(
  tco_pane_busy() { return 2; }
  tco_cap_pane_e() { cat "$REAL/idle.txt"; }
  rc_of tco_send_ready 01 v:.0
)" 2
for sender in tco_send_dev tco_relay_file tco_queue_dev_file; do
  ok "envoltorio $sender preserva texto ajeno sin envío" "$(
    incus() { printf '%s\n' "$*" >> "$TMP_TEST/wrapper-calls"; }
    sleep() { :; }
    tco_wait_idle() { return 0; }
    tco_pane_busy() { return 1; }
    tco_cap_pane() { cat "$FX/wrapped-two.txt"; }
    tco_cap_pane_e() { cat "$FX/wrapped-two.txt"; }
    : > "$TMP_TEST/wrapper-calls"
    rc=0
    if [ "$sender" = tco_send_dev ]; then "$sender" 01 v:.0 continuemos >/dev/null 2>&1 || rc=$?
    else "$sender" 01 v:.0 "$REAL/idle.txt" brief >/dev/null 2>&1 || rc=$?; fi
    printf '%s:%s' "$rc" "$(grep -c send-keys "$TMP_TEST/wrapper-calls")"
  )" 2:0
done
for input in '/home/persona/repo' '/Users/persona/repo'; do
  ok 'capturador rechaza ruta personal original sin escribir' "$(
    rc=0
    printf '%s\n' "$input" | TCO_FIXTURE_DIR="$TMP_TEST/rejected" bash "$SC/capture-pane-fixtures.sh" --from-stdin --cli-version synthetic:1.0 idle >/dev/null 2>&1 || rc=$?
    printf '%s:%s' "$rc" "$([ -e "$TMP_TEST/rejected/synthetic_1.0/idle.txt" ] && echo escrito || echo ausente)"
  )" 3:ausente
done
printf 'PASS=%s FAIL=%s TOTAL=%s\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] && [ "$((PASS+FAIL))" -eq 120 ]
