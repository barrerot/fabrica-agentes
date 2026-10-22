#!/usr/bin/env bash
# draft-handoff.sh — Autoriza el push de una ENTREGA DRAFT (Fábrica v2, ADR-0043 / TAL-2193).
#
# El canal de producción entrega PR DRAFT + comentario HANDOFF y NO corre CodeRabbit
# (el gate CR se muda al Mergeador). Este script valida los gates locales del canal y,
# solo si TODOS pasan, emite el sentinel `.claude/.draft-handoff` que `.githooks/pre-push`
# acepta como exención del gate CR-CLI (Gate 2) para el SHA de HEAD.
#
# NO exime del Gate 1 de auditoría (`.claude/.audit-go`, hook check-push-audit.sh):
# una entrega draft sigue exigiendo código auditado (GO del auditor).
#
# El sentinel es one-shot: el hook pre-push lo consume tras validar el push completo.
# Commits nuevos post-emisión exigen re-ejecutar este script (validez atada al SHA).
#
# La entrega NO está hecha con el push: tras `gh pr create --draft` + comentario HANDOFF
# (docs/templates/handoff-pr-draft.md), correr `bash scripts/verify-handoff.sh <pr>`.
set -euo pipefail

SENTINEL=".claude/.draft-handoff"

fail() { echo "[draft-handoff] $1" >&2; exit 1; }

# Manifiesto (opcional pero recomendado): define los gates del proyecto. Se resuelve a ruta
# ABSOLUTA antes de cualquier `cd` — una ruta relativa se resolvería contra el destino
# equivocado y el manifiesto se ignoraría en silencio, cayendo a los defaults de npm.
MANIFEST="${TF_MANIFEST:-}"
_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="${2:-}"; shift 2;;
    *) _args+=("$1"); shift;;
  esac
done
[ ${#_args[@]} -gt 0 ] && set -- "${_args[@]}" || set --

if [ -n "$MANIFEST" ]; then
  [ -f "$MANIFEST" ] || fail "manifiesto no encontrado: $MANIFEST (¿ruta relativa?). Usa ruta absoluta."
  MANIFEST="$(cd "$(dirname "$MANIFEST")" && pwd -P)/$(basename "$MANIFEST")"
  # shellcheck disable=SC1090
  . "$MANIFEST" || fail "el manifiesto no se pudo cargar: $MANIFEST"
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || fail "no estás en un repo git."
cd "$ROOT"

branch="$(git branch --show-current 2>/dev/null || true)"
[ -n "$branch" ] || fail "HEAD detached (sin rama). La entrega draft se hace desde una rama de trabajo."
# Fuente ÚNICA de la convención de rama: el propio validador del repo (rechaza main/master,
# prefijos inválidos, mayúsculas y '/' extra en el slug). Fail-closed.
BRANCH_CHECK="scripts/github/validar-rama-pr.sh"
[ -f "$BRANCH_CHECK" ] || fail "no encuentro $BRANCH_CHECK — no puedo validar la rama (fail-closed)."
bash "$BRANCH_CHECK" "$branch" >/dev/null \
  || fail "rama '$branch' RECHAZADA por validar-rama-pr.sh — corrígela ANTES de entregar."

# Working tree limpio: el sentinel autoriza EXACTAMENTE lo committeado.
dirty="$(git status --porcelain)"
[ -z "$dirty" ] || fail "working tree sucio — commitea o descarta antes de emitir la entrega:
$dirty"

# Gates locales del canal (fail-closed; la entrega draft NO espera CI de GitHub,
# por eso los gates locales son obligatorios ANTES del push).
run_gate() { # <nombre> <comando en una cadena>
  local name="$1" cmd="$2"
  echo "[draft-handoff] gate: $name …"
  bash -c "$cmd" || fail "gate '$name' en ROJO — la entrega draft exige gates locales verdes."
  echo "[draft-handoff] gate: $name OK"
}

# Los gates salen del manifiesto, con la MISMA convención que run-local-gates.sh:
# TF_HANDOFF_GATES lista los ids y TF_GATE_CMD_<id> da el comando. Sin manifiesto se
# conserva el comportamiento npm de siempre.
HANDOFF_GATES="${TF_HANDOFF_GATES:-}"
if [ -n "$HANDOFF_GATES" ]; then
  for id in $HANDOFF_GATES; do
    case "$id" in
      *[!a-z0-9_-]*) fail "gate-id inválido en TF_HANDOFF_GATES: '$id'" ;;
    esac
    id_var="${id//-/_}"
    cmd="$(eval "printf '%s' \"\${TF_GATE_CMD_${id_var}:-}\"")"
    [ -n "$cmd" ] || fail "el manifiesto declara el gate '$id' pero no define TF_GATE_CMD_${id_var}"
    run_gate "$id" "$cmd"
  done
else
  run_gate "typecheck" "npm run typecheck"
  run_gate "lint"      "npm run lint"
  run_gate "build"     "npm run build"
fi

head_sha="$(git rev-parse HEAD)"
timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

mkdir -p .claude
cat > "$SENTINEL" <<EOF
$head_sha
$branch
$timestamp
EOF

echo "✓ Entrega draft autorizada (gates locales verdes):"
echo "  SHA:       $head_sha"
echo "  Branch:    $branch"
echo "  Timestamp: $timestamp"
echo ""
echo "Sentinel: $SENTINEL (one-shot — lo consume .githooks/pre-push al validar el push)."
echo "Siguiente: git push → gh pr create --draft (\"closes TAL-N…\") → comentario HANDOFF"
echo "(docs/templates/handoff-pr-draft.md) → bash scripts/verify-handoff.sh <pr>."
echo "Commits nuevos antes del push ⇒ re-ejecutar este script."
