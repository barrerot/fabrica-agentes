#!/usr/bin/env bash
# Compositor con sugerencias: capturas reales y transporte sustituido, solo en el arnés.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$TEST_DIR/../scripts"
# shellcheck source=/dev/null
. "$TEST_DIR/capturas-codificadas.sh"
export TF_LINEAR_TEAM_KEY=ABC TCO_REPO_DIR=Repo-Neutro TCO_REPO_SLUG=org-neutra/Repo-Neutro TCO_REPO_STACK=ninguno
export TCO_ANEXO_FILE=references/anexo-neutro.md TCO_HOST_ENV_REL=Repo-Neutro/.env.local
export TCO_LINEAR_INPROGRESS_STATE=00000000-0000-4000-8000-000000000007
export TCO_LINEAR_INREVIEW_STATE=00000000-0000-4000-8000-000000000008
# shellcheck source=/dev/null
. "$SC/00-config.sh"
# shellcheck source=/dev/null
. "${TCO_SLASH_LIB:-$SC/lib.sh}"
REAL="$TEST_DIR/fixtures/pane/claude_2.1.289"
TMP_TEST="$(mktemp -d)"
trap 'rm -rf "$TMP_TEST"' EXIT
PASS=0; FAIL=0
ok() {
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'PASS %s\n' "$1";
  else FAIL=$((FAIL+1)); printf 'FAIL %s: actual [%s], esperado [%s]\n' "$1" "$2" "$3"; fi
}
rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
# La secuencia depende de las teclas, nunca de un contador de capturas.
# shellcheck disable=SC2329
send_sequence() (
  local initial="$1" suffix="$2" rc=0
  : > "$TMP_TEST/calls"; printf '%s' "$initial" > "$TMP_TEST/state"
  incus() {
    printf '%s\n' "$*" >> "$TMP_TEST/calls"
    case "$*" in
      *' -l -- '*) printf typed > "$TMP_TEST/state";;
      *' C-m') printf modal > "$TMP_TEST/state";;
      *) return 1;;
    esac
  }
  sleep() { :; }
  _tco_carril_session() { return 1; }
  _tco_pane_cli_version() { printf 'claude:2.1.289'; }
  tco_cap_pane_e() {
    case "$(cat "$TMP_TEST/state")" in
      idle) tco_fixture_decode "$REAL/slash/s-reposo$suffix.txt";;
      typed) tco_fixture_decode "$REAL/slash/s-slash-model$suffix.txt";;
      modal) cat "$REAL/modal.txt";;
    esac
  }
  tco_cap_pane() { tco_cap_pane_e | tco_strip_ansi_from; }
  TCO_PANE_CALIBRATED=claude:2.1.289 TCO_IDLE_STABILITY_GAP=0 TCO_RELAY_SUBMIT_GAP=0 TCO_RELAY_ECHO_GAP=0 \
    _tco_send_text_submit 01 v:.0 /model >/dev/null 2>&1 || rc=$?
  printf '%s:%s:%s:%s' "$rc" "$(grep -c ' -l -- ' "$TMP_TEST/calls")" \
    "$(grep -c ' C-m' "$TMP_TEST/calls")" "$(cat "$TMP_TEST/state")"
)
AWK_BIN="${TCO_TEST_AWK:-awk}"
command -v "$AWK_BIN" >/dev/null || { printf 'FAIL falta %s\n' "$AWK_BIN"; exit 1; }
# Todas las funciones puras usan la variante elegida.
awk() { command "$AWK_BIN" "$@"; }
for locale in C C.UTF-8; do
  export LC_ALL="$locale"
  for kind in model effort parcial; do
    case "$kind" in model) text=/model;; effort) text=/effort;; parcial) text=/mod;; esac
    for suffix in '' .ansi; do
      cap="$(tco_fixture_decode "$REAL/slash/s-slash-$kind$suffix.txt")"
      label="$kind$suffix $AWK_BIN $locale"
      ok "captura limpia $label" "$(printf '%s' "$cap" | rc_of tco_fixture_secret_scan)" 0
      ok "ancla real $label" "$(printf '%s' "$cap" | tco_tui_anchor_from)" '22 24'
      ok "compositor exacto $label" "$(printf '%s' "$cap" | tco_tui_regions_from composer | tco_strip_dim_from | sed 's/^[[:space:]]*❯//; s/ //g' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" "$text"
      ok "eco verificado $label" "$(printf '%s' "$cap" | tco_tui_regions_from composer | rc_of tco_composer_echo_from "$text")" 0
      ok "sugerencias sin diálogo $label" "$(printf '%s' "$cap" | rc_of tco_pane_anomaly)" 1
      ok "reposo $label" "$(printf '%s' "$cap" | rc_of tco_pane_busy_from)" 1
    done
  done
  for suffix in '' .ansi; do
    for kind in s-reposo s-texto-normal; do
      cap="$(tco_fixture_decode "$REAL/slash/$kind$suffix.txt")"
      ok "forma normal conserva ancla $kind$suffix $AWK_BIN $locale" "$(printf '%s' "$cap" | rc_of tco_tui_anchor_from)" 0
    done
    ok "envío real un tecleo un Enter $suffix $AWK_BIN $locale" "$(send_sequence idle "$suffix")" '0:1:1:modal'
    ok "diálogo real bloquea sin tecleo $suffix $AWK_BIN $locale" "$(send_sequence modal "$suffix")" '2:0:0:modal'
  done
  cap="$(tco_fixture_decode "$REAL/slash/s-slash-model.txt")"
  fake="$(printf '%s\n' "$cap" | sed 's/❯ \/model/❯ texto normal/')"
  ok "texto normal exige pie $AWK_BIN $locale" "$(printf '%s' "$fake" | rc_of tco_tui_anchor_from)" 2
  for extra in 'prosa fuera de sugerencias' '  /' '   /model falso' '  /modelXYZ! falso'; do
    ok "fila ajena rechaza ancla $extra $AWK_BIN $locale" "$(printf '%s\n%s\n' "$cap" "$extra" | rc_of tco_tui_anchor_from)" 2
  done
  no_rows="$(printf '%s\n' "$cap" | sed -n '1,24p')"
  ok "barra sin sugerencias exige pie $AWK_BIN $locale" "$(printf '%s' "$no_rows" | rc_of tco_tui_anchor_from)" 2
  ok "continuación sin sugerencia rechazada $AWK_BIN $locale" "$(printf '%s\n                                    continuación\n' "$no_rows" | rc_of tco_tui_anchor_from)" 2
  dialog="$(printf '%s\n' "$cap"; cat "$REAL/modal.txt")"
  ok "barra con diálogo real activo $AWK_BIN $locale" "$(printf '%s' "$dialog" | tco_pane_anomaly)" modal
  ok "barra con diálogo impide envío $AWK_BIN $locale" "$(printf '%s' "$dialog" | rc_of tco_send_ready_from)" 2
done
printf 'PASS=%s FAIL=%s TOTAL=%s\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] && [ "$((PASS+FAIL))" -eq 106 ]
