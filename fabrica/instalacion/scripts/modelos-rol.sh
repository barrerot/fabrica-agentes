#!/usr/bin/env bash
# Consumir la interfaz rodante solo bajo el usuario acreditado, sin compartir registros.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TF_ROOT="$(cd "$HERE/../.." && pwd -P)"; export TF_ROOT
if [ -f "$HOME/.claude_token.env" ]; then
  [ ! -L "$HOME/.claude_token.env" ] && [ "$(stat -c '%a' "$HOME/.claude_token.env")" = 600 ] || exit 1
  # shellcheck source=/dev/null
  . "$HOME/.claude_token.env"
fi
case "${1:-}" in
  --resolver) bash "$TF_ROOT/skills/talent-channel-operation/scripts/resolver-modelos.sh" ;;
  --modelo|--verificar)
    # shellcheck source=/dev/null
    . "$TF_ROOT/skills/talent-channel-operation/scripts/lib-modelos.sh"
    case "${2:-}" in
      CEO) rol=ceo ;;
      C1) rol=coordinador ;;
      M1) rol=merge ;;
      *) exit 2 ;;
    esac
    model="$(tco_modelo_read "$rol")" && [ -n "$model" ] || exit 1
    if [ "$1" = --modelo ]; then
      printf '%s\n' "$model"
    else
      [ $# -eq 3 ] || exit 2
      capture="$(tmux capture-pane -p -t "$3")" || exit 1
      label="$(printf '%s\n' "$capture" | grep -oiE '\[(Opus|Sonnet)[^][]*\]' | tail -1)" || exit 1
      printf '%s\n' "$label" | tco_modelo_etiqueta_is "$model" || {
        printf 'ERROR modelo de torre pendiente: %s; vigente=%s\n' "$2" "$model" >&2
        exit 1
      }
    fi ;;
  *) exit 2 ;;
esac
