#!/usr/bin/env bash
# Perfil mínimo en el contenedor ya creado; sin sesiones ni credenciales.
set -euo pipefail
channel_user=$1
motor=$2
origin=$3
[[ "$origin" =~ ^https://github.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || exit 1
id runner >/dev/null 2>&1 || useradd -m -s /bin/bash runner
usermod -aG docker runner
for user in "$channel_user" runner; do
  if id -nG "$user" | tr ' ' '\n' | grep -qx sudo; then
    gpasswd -d "$user" sudo >/dev/null
  fi
done
# Única regla heredada conocida de la plantilla; no borrar reglas ajenas.
rule="/etc/sudoers.d/90-$channel_user"
if [ -e "$rule" ]; then
  [ ! -L "$rule" ] && [ "$(cat "$rule")" = "$channel_user ALL=(ALL) NOPASSWD:ALL" ] || exit 1
  rm "$rule"
fi
[ ! -L /home/runner/repo ] || exit 1
if [ ! -d /home/runner/repo ]; then
  sudo -H -u runner git init -q -b main /home/runner/repo
fi
sudo -H -u runner git -C /home/runner/repo rev-parse --git-dir >/dev/null
sudo -H -u runner git -C /home/runner/repo fsck --no-reflogs >/dev/null
remotes="$(sudo -H -u runner git -C /home/runner/repo remote)"
[ -z "$remotes" ] || [ "$remotes" = origin ] || exit 1
if sudo -H -u runner git -C /home/runner/repo remote get-url origin >/dev/null 2>&1; then
  [ "$(sudo -H -u runner git -C /home/runner/repo remote get-url origin)" = "$origin" ] || exit 1
else
  sudo -H -u runner git -C /home/runner/repo remote add origin "$origin"
fi
# El mismo preflight usado por run-gate-sealed.sh, con todo el contenedor como límite.
# shellcheck source=/dev/null
. "$motor/scripts/lib/preflight.sh"
lg_preflight runner /home/runner/repo
