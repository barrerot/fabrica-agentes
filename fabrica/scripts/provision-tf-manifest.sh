#!/usr/bin/env bash
# provision-tf-manifest.sh — materializa .claude/tf-manifest.conf en un clon (de la fábrica o de un
# repo de producto) copiando el manifiesto de la instancia, cuya ruta se pasa EXPLÍCITA: --manifest
# <ruta> o la variable TCO_TF_MANIFEST (config de la fábrica). SIN default: el paquete no incluye
# ningún manifiesto de casa, y adivinarlo sería inventar una fuente (fail-closed). (TAL-5563 cierra el
# hueco de provisioning en el motor; TAL-8040 generaliza la fuente para la distribución.)
#
# scripts/verify-handoff.sh es fail-closed sin .claude/tf-manifest.conf resoluble (env
# TF_MANIFEST o esta copia local) — este script rellena esa copia, para cualquier clon (host o
# canal), SIN tocar la lógica fail-closed del gate.
#
# No depende del $PWD del invocador: resuelve su propia ubicación física y opera SOBRE LA
# RAÍZ GIT DEL CLON QUE LO CONTIENE (o --root <ruta>, explícito), nunca sobre el cwd ambiente.
#
# Fail-closed: manifiesto ausente, no absoluto, inexistente o sin TF_SENSITIVE_SURFACES con tokens
# (misma extracción canónica que verify-handoff) ⇒ rc 1, no se escribe nada.
# Idempotente: si el destino ya existe y es BYTE-IDÉNTICO al manifiesto, no toca nada (exit 0).
# Si existe y DIFIERE, para con exit 1 salvo --force (que sobreescribe DECLARÁNDOLO) — nunca
# pisa en silencio.
#
# Contrato de canales (code-gate TAL-5563 r1, hallazgo MAYOR): fail() — TODA condición fatal,
# incluida la rama de drift sin --force — escribe SIEMPRE a stderr y termina en rc=1, mismo
# patrón que draft-handoff.sh/verify-handoff.sh. Los mensajes informativos/de éxito (idempotente
# sin cambios, --force sobreescribiendo, provisionado) van SIEMPRE a stdout (echo sin redirigir).
set -euo pipefail

fail() { echo "[provision-tf-manifest] $1" >&2; exit 1; }

USO="uso: provision-tf-manifest.sh [--manifest <ruta-absoluta> | TCO_TF_MANIFEST=<ruta-absoluta>] [--force] [--root <ruta>]"
FORCE=0
ROOT_OVERRIDE=""
MANIFEST_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --root) ROOT_OVERRIDE="${2:-}"; shift 2 ;;
    --manifest) MANIFEST_ARG="${2:-}"; shift 2 ;;
    -h|--help)
      echo "$USO"
      exit 0
      ;;
    *) fail "argumento desconocido: $1 ($USO)" ;;
  esac
done

# Resolución de la ubicación FÍSICA del propio script (sigue symlinks) — independiente de
# desde dónde se invoque. La raíz por defecto es la del clon que CONTIENE este script, no la
# del cwd del invocador (gotcha real, TAL-5509/draft-handoff: una ruta derivada del $PWD
# ambiente apunta al árbol equivocado en cuanto se invoca desde fuera del clon).
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_SOURCE" ]; do
  SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
  SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
  case "$SCRIPT_SOURCE" in /*) ;; *) SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"

if [ -n "$ROOT_OVERRIDE" ]; then
  [ -d "$ROOT_OVERRIDE" ] || fail "--root '$ROOT_OVERRIDE' no existe."
  ROOT="$(cd "$ROOT_OVERRIDE" && git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$ROOT" ] || fail "--root '$ROOT_OVERRIDE' no es (ni está dentro de) un repo git."
else
  ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$ROOT" ] || fail "no puedo resolver la raíz git del clon que contiene este script ($SCRIPT_DIR)."
fi

# Fuente del manifiesto: --manifest tiene prioridad sobre TCO_TF_MANIFEST; sin ninguna ⇒ fail-closed.
CANON="${MANIFEST_ARG:-${TCO_TF_MANIFEST:-}}"
[ -n "$CANON" ] || fail "sin fuente de manifiesto: pasa --manifest <ruta-absoluta> o define TCO_TF_MANIFEST (fail-closed, sin default). $USO"
case "$CANON" in /*) ;; *) fail "manifiesto '$CANON' no es ruta absoluta (fail-closed)." ;; esac
[ -f "$CANON" ] || fail "manifiesto '$CANON' no existe (fail-closed)."
# Misma extracción canónica que verify-handoff (sed a la ÚLTIMA ocurrencia + tokens no vacíos).
surfaces="$(sed -n 's/^TF_SENSITIVE_SURFACES="\([^"]*\)".*$/\1/p' "$CANON" | tail -1)"
tokens=0
for _t in $surfaces; do tokens=$((tokens+1)); done
[ "$tokens" -gt 0 ] || fail "manifiesto '$CANON' sin TF_SENSITIVE_SURFACES con tokens (extracción canónica de verify-handoff) — fail-closed."

DEST_DIR="$ROOT/.claude"
DEST="$DEST_DIR/tf-manifest.conf"

canon_sha="$(sha256sum "$CANON" | cut -d' ' -f1)"

if [ -f "$DEST" ]; then
  dest_sha="$(sha256sum "$DEST" | cut -d' ' -f1)"
  if [ "$dest_sha" = "$canon_sha" ]; then
    echo "[provision-tf-manifest] ya provisionado y al día: $DEST == $CANON (sha256 ${canon_sha:0:12}…). Nada que hacer."
    exit 0
  fi
  if [ "$FORCE" -ne 1 ]; then
    fail "'$DEST' EXISTE y DIFIERE del manifiesto '$CANON' (sha256 destino ${dest_sha:0:12}… vs manifiesto ${canon_sha:0:12}…). No se sobreescribe en silencio — revisa la diferencia o re-ejecuta con --force para sobreescribir DECLARÁNDOLO."
  fi
  echo "[provision-tf-manifest] --force: sobreescribiendo '$DEST' (sha256 previo ${dest_sha:0:12}…) con el manifiesto (${canon_sha:0:12}…)."
fi

mkdir -p "$DEST_DIR"
install -m 0600 "$CANON" "$DEST"
echo "[provision-tf-manifest] provisionado: $DEST ← $CANON (sha256 ${canon_sha:0:12}…)."
