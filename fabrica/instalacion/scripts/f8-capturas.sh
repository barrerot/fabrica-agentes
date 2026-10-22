#!/usr/bin/env bash
# Capturar un estado real y clasificar antes de publicar el fichero.
set -euo pipefail
umask 077
fail() { printf 'falla captura %s: %s\n' "${estado:-sin estado}" "$*" >&2; exit 1; }
[ $# -ge 4 ] && [ $# -le 5 ] || { echo 'uso f8-capturas CLON CARRIL PANE ESTADO [--repetir]' >&2; exit 2; }
clon=$1; carril=$2; pane=$3; estado=$4; repetir=${5:-}
case "$estado" in idle|busy|done|modal|redraw) ;; *) fail 'estado inválido' ;; esac
[ -z "$repetir" ] || [ "$repetir" = --repetir ] || fail 'opción inválida'
case "$clon" in /*) ;; *) fail 'CLON debe ser absoluto' ;; esac
scripts="$clon/.claude/skills/talent-channel-operation/scripts"
for file in 00-config.sh lib.sh capture-pane-fixtures.sh; do
  [ -f "$scripts/$file" ] && [ ! -L "$scripts/$file" ] || fail "falta $scripts/$file"
done
# shellcheck source=/dev/null
. "$scripts/00-config.sh" || fail 'no se pudo cargar configuración'
# shellcheck source=/dev/null
. "$scripts/lib.sh" || fail 'no se pudo cargar parser'
[ -n "${TCO_PANE_CLI_VERSION_CMD:-}" ] || fail 'define TCO_PANE_CLI_VERSION_CMD con la versión real del CLI'
[ -n "${TCO_FIXTURE_DIR:-}" ] || fail 'define TCO_FIXTURE_DIR con ruta absoluta'
case "$TCO_FIXTURE_DIR" in /*) ;; *) fail 'TCO_FIXTURE_DIR debe ser absoluto' ;; esac
version="$(_tco_pane_cli_version "$carril" "$pane")" || fail 'no se pudo consultar CLI/versión; revisa TCO_PANE_CLI_VERSION_CMD'
[[ $version =~ ^(claude|codex):[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'CLI/versión inválidos'
destination="$TCO_FIXTURE_DIR/${version/:/_}/$estado.txt"
parent=${destination%/*}
probe=$parent
while [ "$probe" != / ]; do
  [ ! -L "$probe" ] || fail "directorio enlazado: $probe"
  probe=${probe%/*}; [ -n "$probe" ] || probe=/
done
[ ! -L "$destination" ] || fail "destino enlazado: $destination"
if [ -e "$destination" ]; then
  [ -f "$destination" ] || fail "destino no regular: $destination"
  [ "$repetir" = --repetir ] || fail "destino existente: $destination; usa --repetir"
fi
work="$(mktemp -d)" || fail 'no se pudo crear área temporal'
trap 'rm -rf "$work"' EXIT
tco_cap_pane "$carril" "$pane" > "$work/pane" || fail 'no se pudo leer el panel'
capture_state=$estado; [ "$estado" != 'done' ] || capture_state=idle
if ! TCO_FIXTURE_DIR="$work" bash "$scripts/capture-pane-fixtures.sh" --from-stdin \
  --cli-version "$version" "$capture_state" < "$work/pane" > "$work/capturador.log" 2>&1; then
  fail 'capturador rechazó la pantalla (secreto/cuenta, vacío o compositor ausente); limpia la pantalla y repite'
fi
capture="$work/${version/:/_}/$capture_state.txt"
[ -s "$capture" ] || fail 'fichero temporal vacío'
rc=0; tco_pane_busy_from < "$capture" >/dev/null 2>&1 || rc=$?
case "$estado" in idle|done) esperado=1 ;; busy) esperado=0 ;; *) esperado=2 ;; esac
[ "$rc" = "$esperado" ] || fail "clasificación rc=$rc esperado=$esperado; descartada, vuelve a provocar el estado"
mkdir -p "$parent" || fail "no se pudo crear $parent"
if [ -e "$destination" ]; then
  backup="$(mktemp "$parent/$estado.rechazada.XXXXXX")" || fail 'no se pudo conservar captura anterior'
  cp -- "$destination" "$backup" || fail 'no se pudo conservar captura anterior'
fi
install -m 600 "$capture" "$destination" || fail "no se pudo guardar $destination"
printf 'captura %s clasificada rc=%s: %s\n' "$estado" "$rc" "$destination"
