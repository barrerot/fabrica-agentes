#!/usr/bin/env bash
# Ejecuta el bloque real de identidad con uid efectivo simulado, sin tocar usuarios.
set -euo pipefail
conf=$1; uid_fixture=$2
snippet=$(sed -n '/^if .*id -u.*-eq 0.*then$/,/^fi$/p' "$conf")
[ -n "$snippet" ] || exit 1
unset HOST_USER
export SUDO_USER=instalador USER=instalador
id() { if [ "${1:-}" = -u ]; then printf '%s\n' "$uid_fixture"; else printf '%s\n' rol-efectivo; fi; }
eval "$snippet"
printf '%s\n' "$HOST_USER"
