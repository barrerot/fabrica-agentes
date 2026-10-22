#!/usr/bin/env bash
# lib/preflight.sh — sonda LG-PREFLIGHT del contenedor runner (TAL-2288/TAL-2293 B1).
#
# La ejecuta la ESTACIÓN como root DENTRO del contenedor (código del motor, no del PR)
# ANTES de cada gate. El límite de aislamiento es el CONTENEDOR entero: el usuario de
# gates necesita docker (stacks efímeros) ⇒ es root-equivalente dentro, así que se barre
# TODO el contenedor, no solo su home. Fail-closed: cualquier hallazgo ⇒ SUCIO / rc 3.
#
# PF_HOME_ROOTS es overridable ÚNICAMENTE para el arnés de tests (fixtures locales que
# ejecutan esta MISMA lógica); en producción se usa el default /root /home/*.
lg_preflight() { # <usuario-de-gates> <ruta-repo>
  local U="$1" R="$2" bad="" H d p e ch ch2 ch3
  H="$(getent passwd "$U" | cut -d: -f6)"
  [ -n "$H" ] || { echo "usuario $U inexistente"; return 3; }
  local roots="${PF_HOME_ROOTS:-/root /home/*}"
  # 1) Credenciales y env no versionado en CUALQUIER home del contenedor.
  for d in $roots; do
    [ -d "$d" ] || continue
    for p in "$d/.config/gh" "$d/.codex/auth.json" "$d/.claude/.credentials.json" \
             "$d/.claude_token.env" "$d/.coderabbit/auth.json" "$d/.netrc" "$d/.git-credentials"; do
      [ ! -e "$p" ] || bad="$bad $p"
    done
    while IFS= read -r e; do bad="$bad $e"; done \
      < <(find "$d" -maxdepth 5 -name ".env.local" 2>/dev/null)
  done
  # 2) .env.local en el clon de gates (puede vivir fuera de los homes barridos).
  [ ! -e "$R/.env.local" ] || bad="$bad $R/.env.local"
  # 3) credential.helper: del usuario de gates, del repo y del sistema.
  ch="$(sudo -u "$U" git config --global --get credential.helper 2>/dev/null || true)"
  ch2="$(sudo -u "$U" git -C "$R" config --get credential.helper 2>/dev/null || true)"
  ch3="$(git config --system --get credential.helper 2>/dev/null || true)"
  [ -z "$ch$ch2$ch3" ] || bad="$bad credential.helper(${ch:-}${ch2:+ repo:$ch2}${ch3:+ system:$ch3})"
  # 4) Privilegios del usuario de gates: sudo PROHIBIDO (docker permitido por diseño).
  if id -nG "$U" 2>/dev/null | tr ' ' '\n' | grep -qx "sudo"; then bad="$bad grupo:sudo"; fi
  if sudo -l -U "$U" 2>/dev/null | grep -qE "\(ALL\)|may run the following"; then bad="$bad sudoers:$U"; fi
  [ -z "$bad" ] || { echo "SUCIO:$bad"; return 3; }
  echo "LIMPIO"
}
