#!/usr/bin/env bash
# Sonda de instalación del runner, ejecutada como operador Incus.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
container=$1
origin=$2
mode=$3
manifest=$4
[[ "$container" =~ ^runner-[a-z0-9-]+$ ]] || exit 2
[[ "$origin" =~ ^https://github.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || exit 2
case "$mode" in F2|F5) ;; *) exit 2 ;; esac
script="$(cat "$HERE/../../scripts/lib/preflight.sh")"
script+=$'\nlg_preflight runner /home/runner/repo\n'
incus exec "$container" -- bash -c "$script"
incus exec "$container" -- sudo -H -u runner git -C /home/runner/repo rev-parse --git-dir >/dev/null
incus exec "$container" -- sudo -H -u runner git -C /home/runner/repo fsck --no-reflogs >/dev/null
observed="$(incus exec "$container" -- sudo -H -u runner git -C /home/runner/repo remote get-url origin)"
[ "${observed%.git}" = "${origin%.git}" ] || { echo 'runner origin distinto' >&2; exit 1; }
[ "$(incus exec "$container" -- sudo -H -u runner git -C /home/runner/repo remote)" = origin ] || exit 1
# Nombres solamente: ningún valor de entorno sale del contenedor.
environment_probe='
for name in $(compgen -e); do
  case "$name" in GH_TOKEN|GITHUB_TOKEN|*_TOKEN|*_API_KEY|*_SECRET|*_PASSWORD|AWS_*|GOOGLE_APPLICATION_CREDENTIALS)
    echo "runner entorno con credencial: $name" >&2; exit 1 ;;
  esac
done'
incus exec "$container" -- bash -c "$environment_probe"
incus exec "$container" -- sudo -H -u runner bash -c "$environment_probe"
[ "$mode" = F5 ] || exit 0
# Copiar los ficheros exactos evita convertir sus datos en un programa shell.
d=$(incus exec "$container" -- mktemp -d /tmp/tmp.XXXXXXXXXX)
[[ "$d" =~ ^/tmp/tmp\.[A-Za-z0-9]+$ ]] || { echo 'runner temporal inválido' >&2; exit 1; }
trap 'incus exec "$container" -- rm -rf -- "$d"' EXIT
incus file push "$HERE/../../scripts/run-local-gates.sh" "$container$d/motor.sh"
incus file push "$manifest" "$container$d/manifest.conf"
incus exec "$container" -- chmod 755 "$d"
incus exec "$container" -- chmod 644 "$d/motor.sh" "$d/manifest.conf"
incus exec "$container" -- sudo -H -u runner env TF_CHECK_REPO_ONLY=1 bash "$d/motor.sh" /home/runner/repo --gate docs --manifest "$d/manifest.conf"
