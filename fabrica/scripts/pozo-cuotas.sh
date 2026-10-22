#!/usr/bin/env bash
# pozo-cuotas.sh — tabla de cuotas por línea de pozo (5h / 7d / Fable-7d / resets).
# POLÍTICA DEL LEAD (22-ago, refinada): se quema PRIMERO la línea cuyo reset 7d está MÁS CERCA
# (lo gastado se perdona pronto = gasto barato). Una línea RECIÉN RENOVADA (reset lejano ~7d)
# pasa AL FINAL de la cola (su semana fresca es el colchón, no se toca primero). El orden
# ascendente por resets_at implementa ambas cosas; la etiqueta lo hace explícito:
#   USAR-YA   = reset <48h y con margen → primera munición
#   NORMAL    = reset intermedio
#   COLCHÓN   = renovada hace poco (reset >5d) → última en usar
# REGLA DURA: el token jamás se imprime — se usa solo en la cabecera Authorization del curl raw.
set -u
# [TAL-8037] El lector vive junto a este script (sin ruta de casa); LECTOR_CUOTAS lo sobrescribe.
LECTOR="${LECTOR_CUOTAS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lector_cuotas.py}"
TMP=$(mktemp -d /tmp/pozo-cuotas.XXXXXX); chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/rows.tsv"; : > "$OUT"
for P in p1 p2 p3 p4 p5 p6 p7 p8 p9; do
  incus info "$P" >/dev/null 2>&1 || continue
  for L in l1 l2; do
    DIR=$([ "$L" = l1 ] && echo ".claude" || echo ".claude-l2")
    CRED="$TMP/c.json"
    incus file pull "$P/home/vivecoder/$DIR/.credentials.json" "$CRED" 2>/dev/null || { printf '%s\t%s\t%s\n' "999999999" "$P-$L" "SIN-CRED (login pendiente)" >> "$OUT"; continue; }
    J=$(python3 "$LECTOR" read claude --cred "$CRED" 2>/dev/null)
    ALIVE=$(echo "$J" | jq -r '.alive')
    if [ "$ALIVE" != "true" ]; then
      RZN=$(echo "$J" | jq -r '.reason // "?"' | head -c 40)
      printf '%s\t%s\t%s\n' "999999998" "$P-$L" "MUERTA/$RZN" >> "$OUT"; rm -f "$CRED"; continue
    fi
    S5=$(echo "$J" | jq -r '.session.used_pct // "?"'); R5=$(echo "$J" | jq -r '.session.resets_at // "?"')
    S7=$(echo "$J" | jq -r '.weekly.used_pct // "?"'); R7=$(echo "$J" | jq -r '.weekly.resets_at // "?"')
    TIER=$(echo "$J" | jq -r '.tier // "?"')
    # Bucket Fable/Opus 7d: raw read-only (solo utilization/resets, jamás el token)
    TK=$(jq -r '.claudeAiOauth.accessToken' "$CRED")
    RAW=$(curl -s --max-time 15 "https://api.anthropic.com/api/oauth/usage" -H "Authorization: Bearer $TK" -H "Accept: application/json" -H "anthropic-beta: oauth-2025-04-20" -H "User-Agent: claude-code/2.1.0" 2>/dev/null)
    unset TK
    FAB=$(echo "$RAW" | jq -r '[to_entries[] | select(.key|test("fable|opus";"i")) | .key+"="+(.value.utilization|tostring)+"%"] | join(" ") // empty' 2>/dev/null)
    [ -z "$FAB" ] && FAB="(sin bucket fable/opus)"
    EPOCH=$(date -d "$R7" +%s 2>/dev/null || echo 999999997)
    NOW=$(date +%s); DT=$(( EPOCH - NOW ))
    if [ "$S7" != "?" ] && [ "${S7%.*}" -ge 95 ] 2>/dev/null; then TAG="AGOTADA(espera reset)"
    elif [ $DT -lt 172800 ]; then TAG="USAR-YA"
    elif [ $DT -gt 432000 ]; then TAG="COLCHÓN(renovada→última)"
    else TAG="NORMAL"; fi
    printf '%s\t%s\t%s VIVA %s | 5h:%s%% (rst %s) | 7d:%s%% (rst %s) | fable7d: %s\n' "$EPOCH" "$P-$L" "$TAG" "$TIER" "$S5" "${R5:11:5}Z" "$S7" "${R7:0:16}Z" "$FAB" >> "$OUT"
    rm -f "$CRED"
  done
done
echo "═══ CUOTAS POR LÍNEA DE POZO — orden: reset 7d más cercano primero ($(date -u +%H:%M:%SZ)) ═══"
sort -n "$OUT" | cut -f2-3 | column -t -s$'\t'
