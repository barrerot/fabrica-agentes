#!/usr/bin/env bash
# No imprime respuesta ni secretos; admite login o token privado del usuario efectivo.
set -euo pipefail
set +x
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../skills/talent-channel-operation/scripts/lib-respuesta-cli.sh
. "$HERE/../../skills/talent-channel-operation/scripts/lib-respuesta-cli.sh"
unset GITHUB_TOKEN GH_TOKEN LINEAR_API_KEY CODERABBIT_API_KEY
token_file="$HOME/.claude_token.env"
login_file="$HOME/.claude/.credentials.json"
falla() { printf '%s\n' "$1" >&2; exit 1; }
if [ -e "$token_file" ] || [ -L "$token_file" ]; then
  [ -f "$token_file" ] && [ ! -L "$token_file" ] && [ "$(stat -c '%a:%u' "$token_file")" = "600:$(id -u)" ] || falla 'sin acreditar'
  token_line=$(<"$token_file")
  [[ "$token_line" =~ ^export\ CLAUDE_CODE_OAUTH_TOKEN=([A-Za-z0-9_.-]+)$ ]] || falla 'sin acreditar'
  export CLAUDE_CODE_OAUTH_TOKEN="${BASH_REMATCH[1]}"
  unset token_line
elif [ -f "$login_file" ] && [ ! -L "$login_file" ] && [ "$(stat -c '%a:%u' "$login_file")" = "600:$(id -u)" ]; then
  unset CLAUDE_CODE_OAUTH_TOKEN
else
  falla 'sin acreditar'
fi
rc=0
json=$(timeout 90 claude -p 'Responde solo: OK' --output-format json </dev/null 2>/dev/null) || rc=$?
[ "$rc" != 124 ] || falla 'sin respuesta en 90 s'
# Un único objeto; ni JSON concatenado ni un éxito seguido de error acreditan.
cli_respuesta_objeto <<< "$json" || falla 'otro error (subtype=desconocido; JSON inválido o vacío)'
if jq -e '.is_error == true' <<< "$json" >/dev/null; then
  clase=$(jq -r '(.result // "") | if type == "string" then ascii_downcase else "" end' <<< "$json")
  case "$clase" in
    *authentication*|*unauthorized*|*invalid*token*|*invalid*api*key*|*oauth*expired*|*please*login*|*not*logged*in*) falla 'credencial rechazada' ;;
    *usage*limit*|*session*limit*|*rate*limit*|*hit*limit*|*out*of*usage*|*quota*) falla 'sin cupo ahora' ;;
  esac
fi
if [ "$rc" = 0 ] && cli_respuesta_exito <<< "$json"; then
  exit 0
fi
subtype=$(jq -r '.subtype | if type == "string" then if test("^[a-zA-Z0-9_-]{1,64}$") then . else "desconocido" end else "desconocido" end' <<< "$json")
falla "otro error (subtype=$subtype; rc=$rc)"
