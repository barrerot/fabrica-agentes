#!/usr/bin/env bash
# Parser y predicados reales de lib-package, sin destino ni ejecución de los datos.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/../skills/skill-creator/scripts/lib-package.sh"
pkg_parse_authority "$1"
pkg_parse_identity_conf "$2" || exit 3
[ "$PKGID_PKG_IDENTITY_PROJECT" = "$AUTH_PROJECT" ] || exit 3
for clave in TCO_REPO_STACK TCO_ANEXO_FILE TCO_LINEAR_INPROGRESS_STATE TCO_LINEAR_INREVIEW_STATE TCO_POSTMERGE_CMD TCO_HOST_ENV_REL TORC_HOST_ENV_REL; do
  nombre="PKGID_$clave"
  [ -n "${!nombre}" ] || { printf 'ADJUDICACION RECHAZADA: falta %s; complete el fragmento\n' "$clave" >&2; exit 3; }
  pkg_es_placeholder "${!nombre}" && exit 3
done
pkg_validate_identidad_formatos "$PKGID_TCO_REPO_STACK" "$PKGID_TCO_SUPABASE_REF" "$PKGID_TCO_LINEAR_INPROGRESS_STATE" "$PKGID_TCO_LINEAR_INREVIEW_STATE" fragmento || exit 3
pkg_validate_env_rel "$PKGID_TCO_HOST_ENV_REL" fragmento
pkg_validate_env_rel "$PKGID_TORC_HOST_ENV_REL" fragmento
case "$PKGID_TCO_ANEXO_FILE" in references/anexo-*.md) : ;; *) exit 3 ;; esac
pkg_validate_overlay_path "$PKGID_TCO_ANEXO_FILE" fragmento
printf 'fragmento: VALIDO\n'
