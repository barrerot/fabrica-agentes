#!/usr/bin/env bash
# pozo-sync.sh — ciclo COMPLETO de recarga de un pozo con UN comando.
# Uso:  pozo-sync.sh p3 [p5 ...]   |   pozo-sync.sh all
#
# Qué hace por cada pozo (doctrina sellada 22-ago, ver docs/pozos.md):
#   1. Cosecha l1 del contenedor local (la ÚNICA línea donde el lead hace login).
#   2. Valida: JSON con accessToken real (>50 chars) — un stub de logout (243 bytes,
#      tokLen 0) se RECHAZA y se pide re-login; jamás se replica un stub.
#   3. Verifica VIVA con lector_cuotas (endpoint usage, no gasta inferencia).
#   4. Clona l1 → l2 (misma cuenta; propagación Claude por copia = canónica).
#   5. Replica AMBAS líneas a los satélites (SAT_HOSTS): si el contenedor no existe
#      lo crea por copia CoW de PLANTILLA_POZO; chown por NOMBRE (uid difiere entre
#      hosts); chmod 600; verifica fp md5 == local. Sin canary remoto (no gasta).
#   6. Asegura el lanzador ~/.local/bin/<pozo> en la máquina de mando.
# REGLA DURA: el token JAMÁS se imprime. Fail-closed por pozo (un pozo malo no
# detiene a los demás). La máquina de mando es donde corre este script (los logins
# del lead se hacen SIEMPRE aquí; los satélites son réplicas pasivas).
set -u
SAT_HOSTS=(omega.tailnet.example alpha.tailnet.example delta.tailnet.example)   # omega · alpha · delta (ssh root@ — ACL tailnet)
PLANTILLA_POZO=p8                                        # base CoW si el contenedor falta en un satélite
ESC="${SECRET_DIR:-$HOME/.config/talent-channels}"
LECTOR="$(dirname "$0")/lector_cuotas.py"
FALLOS=0

sync_pozo() {
  local P="$1"
  incus info "$P" >/dev/null 2>&1 || { echo "✗ $P: sin contenedor local"; return 1; }
  # 1-2) cosecha + validación anti-stub
  incus file pull "$P/home/vivecoder/.claude/.credentials.json" "$ESC/creds-$P-l1.json" 2>/dev/null \
    || { echo "✗ $P: sin credencial l1 (login pendiente: teclea $P → claude → /login)"; return 1; }
  chmod 600 "$ESC/creds-$P-l1.json"
  if ! jq -e '.claudeAiOauth.accessToken|length>50' "$ESC/creds-$P-l1.json" >/dev/null 2>&1; then
    echo "✗ $P: STUB de logout (token vacío) — re-login necesario (teclea $P → claude → /login)"
    rm -f "$ESC/creds-$P-l1.json"; return 1
  fi
  # 3) viva + cuotas (informativo; AGOTADA sigue siendo replicable — renueva sola)
  local Q; Q=$(python3 "$LECTOR" read claude --cred "$ESC/creds-$P-l1.json" 2>/dev/null)
  local ALIVE; ALIVE=$(echo "$Q" | jq -r '.alive // false')
  local INFO; INFO=$(echo "$Q" | jq -r '"\(.tier // "?") 7d:\(.weekly.used_pct // "?")% rst:\(.weekly.resets_at // "?" | .[0:16])Z"')
  [ "$ALIVE" != "true" ] && { echo "✗ $P: credencial NO viva ($(echo "$Q" | jq -r '.reason // "?"')) — re-login"; rm -f "$ESC/creds-$P-l1.json"; return 1; }
  local FP; FP=$(md5sum "$ESC/creds-$P-l1.json" | cut -c1-8)
  # 4) clon l2 local
  cp "$ESC/creds-$P-l1.json" "$ESC/creds-$P-l2.json"; chmod 600 "$ESC/creds-$P-l2.json"
  incus exec "$P" -- mkdir -p /home/vivecoder/.claude-l2
  incus file push -q "$ESC/creds-$P-l2.json" "$P/home/vivecoder/.claude-l2/.credentials.json"
  incus exec "$P" -- chown vivecoder:vivecoder /home/vivecoder/.claude-l2 /home/vivecoder/.claude-l2/.credentials.json
  incus exec "$P" -- chmod 600 /home/vivecoder/.claude-l2/.credentials.json
  # 5) réplica a satélites
  local OK=1 H
  for H in "${SAT_HOSTS[@]}"; do
    scp -q -o BatchMode=yes -o ConnectTimeout=8 "$ESC/creds-$P-l1.json" "$ESC/creds-$P-l2.json" "root@$H:/root/" </dev/null \
      || { echo "  ✗ $H: scp falló"; OK=0; continue; }
    local R; R=$(ssh -o BatchMode=yes "root@$H" "P=$P; T=$PLANTILLA_POZO; "'
      incus info "$P" >/dev/null 2>&1 || incus copy "$T" "$P" >/dev/null 2>&1
      ST=$(incus list "$P" -c s --format csv 2>/dev/null)
      [ -z "$ST" ] && { echo "SIN-CONTENEDOR"; exit 0; }
      [ "$ST" != "RUNNING" ] && { incus start "$P"; sleep 4; }
      incus exec "$P" -- hostnamectl set-hostname "$P" 2>/dev/null || true
      for L in l1 l2; do
        DIR=$([ "$L" = l1 ] && echo .claude || echo .claude-l2)
        incus exec "$P" -- mkdir -p "/home/vivecoder/$DIR"
        incus file push -q "/root/creds-$P-$L.json" "$P/home/vivecoder/$DIR/.credentials.json"
        incus exec "$P" -- chown vivecoder:vivecoder "/home/vivecoder/$DIR" "/home/vivecoder/$DIR/.credentials.json"
        incus exec "$P" -- chmod 600 "/home/vivecoder/$DIR/.credentials.json"
        printf "%s " "$(incus exec "$P" -- md5sum "/home/vivecoder/$DIR/.credentials.json" | cut -c1-8)"
      done
      shred -u "/root/creds-$P-l1.json" "/root/creds-$P-l2.json"' </dev/null)
    if [ "$R" = "SIN-CONTENEDOR" ]; then echo "  ✗ $H: no pude crear $P (¿plantilla $PLANTILLA_POZO ausente?)"; OK=0
    elif [ "$R" != "$FP $FP " ]; then echo "  ✗ $H: fp mismatch ($R vs $FP)"; OK=0; fi
  done
  # 6) lanzador
  if [ ! -x "$HOME/.local/bin/$P" ]; then
    printf '#!/usr/bin/env bash\n# Pozo %s — dentro: claude → /login → URL en navegador → autenticar → exit\nexec incus exec %s -- su - vivecoder -c "tmux new -As pozo"\n' "$P" "$P" > "$HOME/.local/bin/$P"
    chmod +x "$HOME/.local/bin/$P"
  fi
  [ $OK -eq 1 ] && echo "✓ $P: VIVA $INFO · fp $FP · l1+l2 en mando+${#SAT_HOSTS[@]} satélites" || { echo "△ $P: local OK, réplica INCOMPLETA (ver arriba)"; return 1; }
}

[ $# -eq 0 ] && { echo "uso: pozo-sync.sh <p1..p9|all> [más pozos]"; exit 2; }
LISTA=("$@"); [ "$1" = "all" ] && LISTA=(p1 p2 p3 p4 p5 p6 p7 p8 p9)
for P in "${LISTA[@]}"; do sync_pozo "$P" || FALLOS=$((FALLOS+1)); done
echo "── pozo-sync: $((${#LISTA[@]}-FALLOS))/${#LISTA[@]} OK · tabla de quema: pozo-cuotas.sh ──"
[ "$FALLOS" -eq 0 ] && exit 0 || exit 1
