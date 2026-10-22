#!/usr/bin/env bash
# resolve-canarios.sh — fixture de scripts/lib/compose-resolve.sh Y de
# scripts/lib/compose-bootstrap.sh (TAL-5383 · A2; el registro vive aqui por decision del
# propio plan-gate: "puede vivir en resolve-canarios.sh, pero debe probar directamente el
# contrato del registro").
#
# Secciones: descriptor cross-repo, tabla de decision de anclaje (via seam de
# `_resolve_llamar_guard`, sin red ni fichero de guard real en disco), C2 (estado de
# pieza), C3 (idempotencia), C4 (smoke de consumo real del guard), orden topologico
# (estable + gramatica de pieza), sin-invocacion-directa (DoD de la precondicion A1), y el
# registro TSV con su barrera deterministica de locking (con mutante en rojo obligatorio).
#
# Uso: resolve-canarios.sh   ·   RC=0 todo caza · 1 algun canario se escapa
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOTOR="$(dirname "$(dirname "$HERE")")"
RESOLVE_LIB="${RESOLVE_LIB:-$MOTOR/scripts/lib/compose-resolve.sh}"
BOOTSTRAP_LIB="${BOOTSTRAP_LIB:-$MOTOR/scripts/lib/compose-bootstrap.sh}"
IDENTITY_LIB="${IDENTITY_LIB:-$MOTOR/scripts/lib/compose-identity.sh}"
W=$(mktemp -d); trap 'rm -rf -- "$W"' EXIT
ok=0; ko=0

for f in "$RESOLVE_LIB" "$BOOTSTRAP_LIB"; do
  [ -f "$f" ] || { echo "FAIL-CLOSED: no existe: $f"; exit 2; }
done
# shellcheck source=/dev/null
source "$RESOLVE_LIB"
# shellcheck source=/dev/null
source "$BOOTSTRAP_LIB"

check() { # check <etiqueta> <rc_esperado> <rc_real>
  if [ "$3" -eq "$2" ]; then ok=$((ok+1)); printf 'OK    %-58s RC=%s\n' "$1" "$3"
  else ko=$((ko+1)); printf 'FALLO %-58s RC=%s (esperado %s)\n' "$1" "$3" "$2"; fi
}
check_nonzero() {
  if [ "$2" -ne 0 ]; then ok=$((ok+1)); printf 'OK    %-58s RC=%s (!=0)\n' "$1" "$2"
  else ko=$((ko+1)); printf 'FALLO %-58s RC=0 (se esperaba !=0)\n' "$1"; fi
}
check_out() { # check_out <etiqueta> <esperado> <real>
  if [ "$3" = "$2" ]; then ok=$((ok+1)); printf 'OK    %-58s out=[%s]\n' "$1" "$3"
  else ko=$((ko+1)); printf 'FALLO %-58s out=[%s] (esperado [%s])\n' "$1" "$3" "$2"; fi
}

SHA_HEAD="1111111111111111111111111111111111111111"
SHA_OLD="2222222222222222222222222222222222222222"

echo "=========================================================="
echo "== DESCRIPTOR CROSS-REPO"
echo "=========================================================="

out=$(resolve_descriptor_de_string "owner/repo#47" | tr -d '\n')
check_out "modo pr" "$(printf 'owner\trepo\tpr\t47')" "$out"

# modo rama YA NO publica exito (rc=0) — devuelve la PRECONDICION
# (rc=97) mientras la gramatica completa de git no este disponible via A1. Antes de esa
# precondicion, las guardas propias (owner/repo, vacio, guion inicial) SI son rc=1 real.
resolve_descriptor_de_string "owner/repo:feat/tal-5383-x" >/dev/null 2>&1
check "modo rama CON slash: PRECONDICION rc=97 (ya no exito cosmetico)" 97 "$?"
resolve_descriptor_de_string "owner/repo#0" >/dev/null 2>&1; check_nonzero "PR cero: rc!=0" "$?"
resolve_descriptor_de_string "owner/repo#-1" >/dev/null 2>&1; check_nonzero "PR negativo: rc!=0" "$?"
resolve_descriptor_de_string "owner/repo:" >/dev/null 2>&1; check "rama vacia: rc=1 (real, no precondicion)" 1 "$?"
resolve_descriptor_de_string "owner/repo:-foo" >/dev/null 2>&1; check "rama con guion inicial: rc=1 (real)" 1 "$?"
resolve_descriptor_de_string "sin-separador-valido" >/dev/null 2>&1; check_nonzero "sin # ni : : rc!=0" "$?"
resolve_descriptor_de_string "own er/repo#1" >/dev/null 2>&1; check_nonzero "owner con espacio: rc!=0" "$?"
resolve_descriptor_de_string "own er/repo:feat/x" >/dev/null 2>&1; check "owner con espacio en modo rama: rc=1 (real, antes de la precondicion)" 1 "$?"

# `#` es POSITIVO dentro de una rama git
# (se codifica, no se rechaza), pero el parser comprobaba `#` ANTES que `:` y una rama
# real con `#` (p.ej. `feat/x#frag`) se leia por error como modo PR, dando rc=1 en vez de
# la precondicion rc=97 que le corresponde. `:` NUNCA aparece dentro de una ref real, asi
# que se comprueba primero — es el separador inequivoco.
out=$(resolve_descriptor_de_string "owner/repo:feat/x#frag" 2>/dev/null)
check "rama VALIDA con # (owner/repo:feat/x#frag): PRECONDICION rc=97, no rc=1" 97 "$?"
check_out "rama con #: salida vacia (no se publica)" "" "$out"

# Negativo inverso: un PR con ':' colgando NO debe reinterpretarse como rama valida.
out=$(resolve_descriptor_de_string "owner/repo#47:extra" 2>/dev/null)
check "PR con ':' extra (owner/repo#47:extra): rc=1, NUNCA rama" 1 "$?"
check_out "PR con ':' extra: salida vacia" "" "$out"

echo
echo "== resolve_codifica_uri: encoding RFC 3986 completo, no solo '/' =="
check_out "feat/x" "feat%2Fx" "$(resolve_codifica_uri "feat/x")"
check_out "feat/x#frag (POSITIVO, % y # se codifican)" "feat%2Fx%23frag" "$(resolve_codifica_uri "feat/x#frag")"
check_out "feat/x%y (POSITIVO)" "feat%2Fx%25y" "$(resolve_codifica_uri "feat/x%y")"
check_out "espacio" "a%20b" "$(resolve_codifica_uri "a b")"

echo
echo "=========================================================="
echo "== ANCLAJE C1: tabla de decision (seam de _resolve_llamar_guard, sin red)"
echo "=========================================================="

_resolve_llamar_guard() { shift; echo "$SHA_HEAD"; }
out=$(resolve_verificar_anclaje "/no/existe" pr o r 47 "$SHA_HEAD"); rc=$?
check "identical -> ANCLADO rc=0" 0 "$rc"; check_out "identical -> ANCLADO texto" "ANCLADO" "$out"

_resolve_llamar_guard() { shift; case "$*" in *pulls/47*) echo "$SHA_HEAD";; *compare/*) echo "ahead";; esac; }
out=$(resolve_verificar_anclaje "/no/existe" pr o r 47 "$SHA_OLD"); rc=$?
check "ahead -> rc=0 (etiqueta es exito)" 0 "$rc"; check_out "ahead -> VEREDICTO-AJENO" "VEREDICTO-AJENO" "$out"

_resolve_llamar_guard() { shift; case "$*" in *pulls/47*) echo "$SHA_HEAD";; *compare/*) echo "behind";; esac; }
out=$(resolve_verificar_anclaje "/no/existe" pr o r 47 "$SHA_OLD"); rc=$?
check "behind -> rc=0" 0 "$rc"; check_out "behind -> VEREDICTO-CADUCO" "VEREDICTO-CADUCO" "$out"

_resolve_llamar_guard() { shift; case "$*" in *pulls/47*) echo "$SHA_HEAD";; *compare/*) echo "diverged";; esac; }
out=$(resolve_verificar_anclaje "/no/existe" pr o r 47 "$SHA_OLD"); rc=$?
check "diverged -> rc=0" 0 "$rc"; check_out "diverged -> VEREDICTO-CADUCO" "VEREDICTO-CADUCO" "$out"

_resolve_llamar_guard() { shift; case "$*" in *pulls/47*) echo "$SHA_HEAD";; *compare/*) echo "gh: Not Found (HTTP 404)" >&2; return 1;; esac; }
out=$(resolve_verificar_anclaje "/no/existe" pr o r 47 "$SHA_OLD"); rc=$?
check "HTTP 404 real del commit en compare -> rc=0" 0 "$rc"; check_out "HTTP 404 -> VEREDICTO-AJENO" "VEREDICTO-AJENO" "$out"

# Un '404' CASUAL dentro de un mensaje de error DISTINTO (p.ej. un
# rate-limit cuyo texto menciona "404 segundos") NO debe clasificarse como VEREDICTO-AJENO —
# solo la forma especifica "HTTP 404" que `gh api` imprime de verdad cuenta.
_resolve_llamar_guard() { shift; case "$*" in *pulls/47*) echo "$SHA_HEAD";; *compare/*) echo "gh: rate limited, retry after 404 seconds" >&2; return 1;; esac; }
resolve_verificar_anclaje "/no/existe" pr o r 47 "$SHA_OLD" >/dev/null 2>&1
check_nonzero "'404' casual (no HTTP 404): rc!=0, NUNCA se confunde con VEREDICTO-AJENO" "$?"

_resolve_llamar_guard() { shift; case "$*" in *pulls/47*) echo "$SHA_HEAD";; *compare/*) echo "gh: API rate limit exceeded" >&2; return 1;; esac; }
resolve_verificar_anclaje "/no/existe" pr o r 47 "$SHA_OLD" >/dev/null 2>&1
check_nonzero "fallo operacional real en compare (no 404): rc!=0, NUNCA etiqueta" "$?"

_resolve_llamar_guard() { shift; echo "gh: Not Found (HTTP 404)" >&2; return 1; }
resolve_verificar_anclaje "/no/existe" pr o r 999 "$SHA_OLD" >/dev/null 2>&1
check_nonzero "404 del PR mismo (paso 1): rc!=0, NUNCA etiqueta" "$?"

_resolve_llamar_guard() { shift; echo "no-es-un-sha"; }
resolve_verificar_anclaje "/no/existe" pr o r 47 "$SHA_OLD" >/dev/null 2>&1
check_nonzero "campo inesperado (no-hex): rc!=0" "$?"

_resolve_llamar_guard() { echo "NO DEBERIA LLAMARSE JAMAS" >&2; return 99; }
out=$(resolve_verificar_anclaje "/no/existe" rama o r "feat/x" "$SHA_HEAD" 2>"$W/stderr-rama"); rc=$?
check "modo rama: PRECONDICION explicita, rc=97" 97 "$rc"
if grep -q "NO DEBERIA LLAMARSE" "$W/stderr-rama"; then
  ko=$((ko+1)); printf 'FALLO %-58s\n' "modo rama toco el guard (PROHIBIDO mientras A1 no fusiona)"
else
  ok=$((ok+1)); printf 'OK    %-58s\n' "modo rama NUNCA toca el guard (precondicion real, no cosmetica)"
fi

resolve_verificar_anclaje "/no/existe" pr o r 47 "no-es-un-sha-de-40" >/dev/null 2>&1
check_nonzero "uso invalido: veredicto_sha no-hex: rc!=0" "$?"
resolve_verificar_anclaje "/no/existe" otromodo o r 47 "$SHA_HEAD" >/dev/null 2>&1
check_nonzero "uso invalido: modo desconocido: rc!=0" "$?"

echo
echo "=========================================================="
echo "== C2: resolve_estado_pieza (envuelve el anclaje en 'esperando GO')"
echo "=========================================================="

_resolve_llamar_guard() { shift; echo "$SHA_HEAD"; }
out=$(resolve_estado_pieza "/no/existe" pr o r 47 "$SHA_HEAD"); rc=$?
check "ANCLADO se propaga tal cual" 0 "$rc"; check_out "ANCLADO texto" "ANCLADO" "$out"

_resolve_llamar_guard() { shift; case "$*" in *pulls/47*) echo "$SHA_HEAD";; *compare/*) echo "ahead";; esac; }
out=$(resolve_estado_pieza "/no/existe" pr o r 47 "$SHA_OLD"); rc=$?
check "AJENO -> esperando GO, rc=0" 0 "$rc"
check_out "AJENO -> literal exacto" "esperando GO: VEREDICTO-AJENO" "$out"

_resolve_llamar_guard() { shift; case "$*" in *pulls/47*) echo "$SHA_HEAD";; *compare/*) echo "behind";; esac; }
out=$(resolve_estado_pieza "/no/existe" pr o r 47 "$SHA_OLD")
check_out "CADUCO -> literal exacto" "esperando GO: VEREDICTO-CADUCO" "$out"

_resolve_llamar_guard() { shift; echo "gh: API rate limit exceeded" >&2; return 1; }
resolve_estado_pieza "/no/existe" pr o r 47 "$SHA_OLD" >/dev/null 2>&1
check_nonzero "ERROR OPERACIONAL se propaga sin traducir a 'esperando GO'" "$?"

_resolve_llamar_guard() { echo "NUNCA" >&2; return 99; }
resolve_estado_pieza "/no/existe" rama o r "feat/x" "$SHA_HEAD" >/dev/null 2>&1
check "PRECONDICION (rama) se propaga como rc=97, no se traduce" 97 "$?"

echo
echo "=========================================================="
echo "== ORDEN TOPOLOGICO (Kahn ESTABLE por indice de entrada) + gramatica de pieza"
echo "=========================================================="

printf 'B\tadded\tb.txt\nA\tadded\ta.txt\n' > "$W/g-independientes.tsv"
out=$(resolve_orden_topologico "$W/g-independientes.tsv" | tr '\n' ' ' | sed 's/ $//')
check_out "piezas independientes: orden de entrada" "B A" "$out"

printf 'A\tadded\tx.txt\nB\tmodified\tx.txt\nB\tadded\ty.txt\nC\tmodified\ty.txt\n' > "$W/g-cadena.tsv"
out=$(resolve_orden_topologico "$W/g-cadena.tsv" | tr '\n' ' ' | sed 's/ $//')
check_out "cadena A->B->C" "A B C" "$out"

printf 'A\tadded\tx.txt\nA\tadded\ty.txt\nB\tmodified\tx.txt\nC\tmodified\ty.txt\nD\tmodified\tx.txt\nD\tmodified\ty.txt\n' > "$W/g-diamante.tsv"
out=$(resolve_orden_topologico "$W/g-diamante.tsv" | tr '\n' ' ' | sed 's/ $//')
check_out "diamante: A primero, D ultimo" "A B C D" "$out"

# Orden topológico estable: A aparece PRIMERO en
# el input pero DEPENDE de B (aparece segundo); C es independiente y aparece tercero. Una
# FIFO de "momento en que se vuelve disponible" da B,C,A (incorrecto); el desempate estable
# por INDICE DE ENTRADA exige B,A,C (A tiene indice 0, menor que el de C=2, y ambos estan
# disponibles a la vez tras procesar B).
printf 'A\tmodified\tx.txt\nB\tadded\tx.txt\nC\tadded\tc.txt\n' > "$W/g-estable.tsv"
out=$(resolve_orden_topologico "$W/g-estable.tsv" | tr '\n' ' ' | sed 's/ $//')
check_out "estabilidad por indice de entrada (contraejemplo del auditor)" "B A C" "$out"

printf 'A\tadded\ta.txt\nB\tmodified\ta.txt\nB\tadded\tb.txt\nA\tmodified\tb.txt\n' > "$W/g-ciclo.tsv"
resolve_orden_topologico "$W/g-ciclo.tsv" >/dev/null 2>&1
check_nonzero "ciclo de 2 nodos: rc!=0, cero salida" "$?"

printf 'A\tadded\tx.txt\nA\tmodified\tx.txt\n' > "$W/g-self.tsv"
resolve_orden_topologico "$W/g-self.tsv" >/dev/null 2>&1
check_nonzero "self-cycle: rc!=0" "$?"

printf 'A\tadded\tx.txt\nB\tadded\tx.txt\n' > "$W/g-doble.tsv"
resolve_orden_topologico "$W/g-doble.tsv" >/dev/null 2>&1
check_nonzero "productor doble: rc!=0" "$?"

printf 'A\tdeleted\tx.txt\n' > "$W/g-status-malo.tsv"
resolve_orden_topologico "$W/g-status-malo.tsv" >/dev/null 2>&1
check_nonzero "status invalido (deleted): rc!=0" "$?"

printf 'A\tx.txt\n' > "$W/g-columnas.tsv"
resolve_orden_topologico "$W/g-columnas.tsv" >/dev/null 2>&1
check_nonzero "TSV con columnas de menos: rc!=0" "$?"

: > "$W/g-vacio.tsv"
resolve_orden_topologico "$W/g-vacio.tsv" >/dev/null 2>&1
check_nonzero "TSV vacio: rc!=0" "$?"

# gramatica de `pieza` — whitespace/glob NO deben partirse/expandir
# al iterar `for dep in ${edges_de[$p]}` (sin quotes, por diseno, sobre una lista de
# dependientes separada por espacios).
printf 'pieza con espacio\tadded\tx.txt\n' > "$W/g-pieza-espacio.tsv"
resolve_orden_topologico "$W/g-pieza-espacio.tsv" >/dev/null 2>&1
check_nonzero "pieza con whitespace: rc!=0 (rechazada por gramatica, no partida)" "$?"

printf 'pieza*\tadded\tx.txt\n' > "$W/g-pieza-glob.tsv"
resolve_orden_topologico "$W/g-pieza-glob.tsv" >/dev/null 2>&1
check_nonzero "pieza con glob (*): rc!=0 (rechazada, no expandida contra el filesystem)" "$?"

echo
echo "=========================================================="
echo "== DoD: SIN INVOCACION DIRECTA de git/gh fuera del guard (precondicion A1)"
echo "=========================================================="

_sin_invocacion_directa() {
  local f="$1" sin_comentarios
  sin_comentarios="$(grep -v '^[[:space:]]*#' "$f")"
  if grep -qE '(^|[;&|`(]|\$\()[[:space:]]*(git|gh)[[:space:]]' <<<"$sin_comentarios"; then
    return 1
  fi
  if grep -qE '^[[:space:]]*(git|gh)[[:space:]]' <<<"$sin_comentarios"; then
    return 1
  fi
  return 0
}
_sin_invocacion_directa "$RESOLVE_LIB"; check "compose-resolve.sh: sin invocacion directa git/gh" 0 "$?"
_sin_invocacion_directa "$BOOTSTRAP_LIB"; check "compose-bootstrap.sh: sin invocacion directa git/gh" 0 "$?"
[ -f "$IDENTITY_LIB" ] && { _sin_invocacion_directa "$IDENTITY_LIB"; check "compose-identity.sh: sin invocacion directa git/gh" 0 "$?"; }

# El unico invocador EJECUTABLE de "$guard_path" debe ser _resolve_llamar_guard; el resto
# de apariciones son "$guard_path" reenviado como PARAMETRO (_resolve_gh_json, llamadas
# publicas, resolve_c4_smoke), nunca una invocacion directa por si mismas.
invocaciones_reales="$(awk '/_resolve_llamar_guard\(\)/{f=1} f && /"\$guard_path" "\$@"/{print; f=0}' "$RESOLVE_LIB" | wc -l)"
check "exactamente 1 invocacion ejecutable de \$guard_path (en _resolve_llamar_guard)" 1 "$invocaciones_reales"

echo
echo "=========================================================="
echo "== C4: resolve_c4_smoke (prueba de consumo REAL del guard, no solo lo declarado)"
echo "=========================================================="

# Restaurar la implementacion REAL de _resolve_llamar_guard: las secciones de ANCLAJE/C2 de
# arriba la redefinen como mock repetidas veces y una funcion redefinida en bash persiste
# hasta la siguiente redefinicion — sin este reset, resolve_c4_smoke() llamaria al ULTIMO
# mock (que ni siquiera toca el fichero del guard) en vez de invocar el guard de verdad.
_resolve_llamar_guard() {
  local guard_path="$1"
  shift
  "$guard_path" "$@"
}

cat > "$W/fake-guard-ok.sh" <<'GEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "git checkout") exit 3 ;;
  *) exit 0 ;;
esac
GEOF
chmod +x "$W/fake-guard-ok.sh"
resolve_c4_smoke "$W/fake-guard-ok.sh"; check "guard que SI bloquea checkout (par:3): rc=0" 0 "$?"

cat > "$W/fake-guard-bypass.sh" <<'GEOF'
#!/usr/bin/env bash
exit 0
GEOF
chmod +x "$W/fake-guard-bypass.sh"
resolve_c4_smoke "$W/fake-guard-bypass.sh" >/dev/null 2>&1
check_nonzero "guard bypaseado (deja pasar checkout): rc!=0 (señal de fuga real)" "$?"

resolve_c4_smoke "/no/existe/nada" >/dev/null 2>&1
check_nonzero "guard ausente: rc!=0" "$?"

echo
echo "=========================================================="
echo "== REGISTRO (compose-bootstrap.sh): mutacion + gramatica + C3 + barrera deterministica"
echo "=========================================================="

# el fichero COMMITEADO en el path canonico puede quedar
# desincronizado si la cabecera de la libreria cambia y nadie regenera el artefacto real —
# paso exactamente eso: la libreria se corrigio para usar `slug` pero
# `registro/bootstrap-trenes.tsv` seguia con la cabecera vieja (`pr_padre`). LECTURA PURA,
# sin `bootstrap_init` ni ninguna mutacion sobre el registro real del repo — solo compara
# la primera linea byte a byte contra `BOOTSTRAP_CABECERA`.
REG_FIX="$W/registro-fixture.tsv"
BOOTSTRAP_TSV="$REG_FIX" bootstrap_init || exit 2
cabecera_commiteada="$(head -n 1 -- "$REG_FIX")"
check_out "registro/bootstrap-trenes.tsv commiteado: cabecera EXACTA (sin mutarlo)" "$BOOTSTRAP_CABECERA" "$cabecera_commiteada"

REG="$W/bootstrap-trenes.tsv"
export BOOTSTRAP_TSV="$REG"
bootstrap_init; check "init sobre fichero inexistente" 0 "$?"
bootstrap_init; check "init idempotente (cabecera ya correcta)" 0 "$?"

BOOTSTRAP_TSV="$W/otra-cabecera.tsv"
printf 'x\ty\n' > "$BOOTSTRAP_TSV"
bootstrap_init >/dev/null 2>&1
check_nonzero "init sobre cabecera existente DISTINTA: rc!=0, no sobrescribe" "$?"
check_out "init no toco el fichero con cabecera ajena" "$(printf 'x\ty')" "$(cat "$BOOTSTRAP_TSV")"

# init sobre preimagen con CABECERA correcta pero fila corrupta —
# antes bastaba `head -n 1` y daba "exito" (0) sin mirar el resto del fichero.
BOOTSTRAP_TSV="$W/cabecera-ok-fila-mala.tsv"
printf '%s\n' "$BOOTSTRAP_CABECERA" > "$BOOTSTRAP_TSV"
printf 'x\ty\tz\n' >> "$BOOTSTRAP_TSV"
bytes_antes="$(wc -c < "$BOOTSTRAP_TSV")"
bootstrap_init >/dev/null 2>&1
check_nonzero "init sobre cabecera OK + fila corrupta: rc!=0 " "$?"
bytes_despues="$(wc -c < "$BOOTSTRAP_TSV")"
check "init sobre fila corrupta: bytes intactos (no se toco)" "$bytes_antes" "$bytes_despues"

# tren_id duplicado en la preimagen es fichero NO sano.
SHA1="$(printf '%040d' 1)"; SHA2="$(printf '%040d' 2)"; SHA3="$(printf '%040d' 3)"; SHA9="$(printf '%040d' 9)"
BOOTSTRAP_TSV="$W/tren-duplicado.tsv"
printf '%s\n' "$BOOTSTRAP_CABECERA" > "$BOOTSTRAP_TSV"
printf 'tren-1\tslug-a\tTAL-1\t%s\t2026-09-05T01:00:00Z\t0\n' "$SHA1" >> "$BOOTSTRAP_TSV"
printf 'tren-1\tslug-b\tTAL-2\t%s\t2026-09-05T01:01:00Z\t0\n' "$SHA2" >> "$BOOTSTRAP_TSV"
bootstrap_init >/dev/null 2>&1
check_nonzero "init sobre tren_id DUPLICADO en la preimagen: rc!=0" "$?"

export BOOTSTRAP_TSV="$REG"
bootstrap_upsert "tren-1" "mi-tren-uno" "TAL-1,TAL-2" "$SHA1,$SHA2" "2026-09-05T01:00:00Z"
check "upsert tren nuevo (con slug)" 0 "$?"

bootstrap_upsert "tren-1" "mi-tren-uno" "TAL-1,TAL-2,TAL-3" "$SHA1,$SHA2,$SHA3" "2026-09-05T01:05:00Z"
check "upsert MISMO tren_id: reemplaza" 0 "$?"
n_lineas="$(wc -l < "$REG")"
check "upsert MISMO tren_id: NO duplica (2 lineas: cabecera+1)" 2 "$n_lineas"

bootstrap_upsert "tren-2" "otro-tren" "TAL-9" "$SHA9" "2026-09-05T01:06:00Z"
check "upsert segundo tren distinto" 0 "$?"

out="$(bootstrap_leer "tren-2")"
check_out "bootstrap_leer: fila exacta" "$(printf 'tren-2\totro-tren\tTAL-9\t%s\t2026-09-05T01:06:00Z\t0' "$SHA9")" "$out"
bootstrap_leer "tren-NO-EXISTE" >/dev/null 2>&1
check_nonzero "bootstrap_leer sobre tren inexistente: rc!=0" "$?"

# bootstrap_leer NO puede confundir "preimagen corrupta"/"tren_id
# duplicado" con "tren_id inexistente" — antes saltaba filas malformadas en silencio y
# devolvia el MISMO rc=1 en ambos casos. Ahora rc=97 (preimagen invalida) es DISTINTO de
# rc=1 (ausencia genuina en un registro sano).
BOOTSTRAP_TSV="$W/leer-corrupto.tsv"
printf '%s\n' "$BOOTSTRAP_CABECERA" > "$BOOTSTRAP_TSV"
printf 'x\ty\tz\n' >> "$BOOTSTRAP_TSV"
bootstrap_leer "cualquiera" >/dev/null 2>&1
check "bootstrap_leer sobre preimagen con fila corrupta: rc=97 (distinto de rc=1)" 97 "$?"

BOOTSTRAP_TSV="$W/leer-dup.tsv"
printf '%s\n' "$BOOTSTRAP_CABECERA" > "$BOOTSTRAP_TSV"
printf 'tren-1\tslug-a\tTAL-1\t%s\t2026-09-05T01:00:00Z\t0\n' "$SHA1" >> "$BOOTSTRAP_TSV"
printf 'tren-1\tslug-b\tTAL-2\t%s\t2026-09-05T01:01:00Z\t0\n' "$SHA2" >> "$BOOTSTRAP_TSV"
bootstrap_leer "tren-1" >/dev/null 2>&1
check "bootstrap_leer sobre tren_id DUPLICADO en preimagen: rc=97 (distinto de rc=1)" 97 "$?"
export BOOTSTRAP_TSV="$REG"

bootstrap_marcar_stale "tren-2"; check "marcar_stale sobre tren existente" 0 "$?"
fila_tren2="$(bootstrap_leer "tren-2" | awk -F'\t' '{print $6}')"
check_out "marcar_stale puso stale=1 (columna 6)" "1" "$fila_tren2"

lineas_antes="$(wc -l < "$REG")"
bootstrap_marcar_stale "tren-NO-EXISTE" >/dev/null 2>&1
check_nonzero "marcar_stale sobre tren INEXISTENTE: rc!=0" "$?"
lineas_despues="$(wc -l < "$REG")"
check "marcar_stale sobre inexistente: CERO escritura (mismas lineas)" "$lineas_antes" "$lineas_despues"

bootstrap_upsert "tren-3" "slug-3" "TAL-1,TAL-2" "$SHA1" "2026-09-05T01:07:00Z" >/dev/null 2>&1
check_nonzero "piezas/head_shas de longitud distinta: rc!=0" "$?"

bootstrap_upsert "tren-4" "slug-4" "TAL-1" "$SHA1" "no-es-fecha" >/dev/null 2>&1
check_nonzero "armado_en invalido: rc!=0" "$?"

bootstrap_upsert "tren-5" "SlugConMayuscula" "TAL-1" "$SHA1" "2026-09-05T01:08:00Z" >/dev/null 2>&1
check_nonzero "slug con mayuscula (fuera de gramatica): rc!=0" "$?"

BOOTSTRAP_TSV="$W/corrupto-upsert.tsv"
printf '%s\n' "$BOOTSTRAP_CABECERA" > "$BOOTSTRAP_TSV"
printf 'x\ty\tz\n' >> "$BOOTSTRAP_TSV"
bootstrap_upsert "tren-x" "slug-x" "TAL-1" "$SHA1" "2026-09-05T01:09:00Z" >/dev/null 2>&1
check_nonzero "upsert sobre preimagen con fila corrupta preexistente: rc!=0, no se escribe" "$?"
export BOOTSTRAP_TSV="$REG"

echo
echo "== interrupcion determinista + exit status REAL + EXIT independiente + mutante exacto =="
# `_bootstrap_escribe_atomico` no atrapaba señales: una interrupcion entre `mktemp` y `mv`
# dejaba el temporal huerfano. Corregido con seccion critica en SU PROPIO subshell + UN
# SOLO trap EXIT (se dispara SIEMPRE: salida normal, o el `exit` que instalan a su vez
# INT/TERM — nunca se desactiva la trampa antes de limpiar) que borra "tmp" solo si sigue
# pendiente; tras `mv` exitoso se vacia "tmp" antes de salir.
#
# La prueba comprueba entrega de señal, estado de salida y limpieza:
# (a) `kill -TERM -- -$pid` asumia PID==PGID del job en background — falso en el
#     entorno del auditor. Corregido con `setsid` (PID==PGID==SID por CONTRATO del
#     binario) + PID auto-reportado desde DENTRO del propio proceso.
# (b) "el proceso ya no responde a kill -0" NO es su exit status real — un escritor
#     que termina LIMPIO tras ignorar/recibir la señal satisface igual esa condicion. Y el
#     `kill -TERM` nunca comprobaba su propio rc. Corregido con `setsid --wait`: el
#     PROCESO LANZADOR (capturado via `$!`, esperable con `wait` normal) relaya el exit
#     status REAL del script interno aunque `setsid` bifurque — verificado que un
#     interrumpido da `wait_rc!=0` y uno que completa da `wait_rc=0`, no un booleano de
#     vida/muerte. `kill_rc` se captura y exige explicitamente 0.
# (c) toda la prueba usaba TERM; se exige evidencia de que el TERCER handler
#     (EXIT) hace el trabajo, no solo INT/TERM. Se añade un tercer modo con SIGHUP, que
#     esta funcion NO trapea explicitamente (solo EXIT la cubre) — si el cleanup solo
#     funcionara por las trampas de INT/TERM, HUP dejaria residual; si funciona porque EXIT
#     es el unico punto real de limpieza (como esta diseñado), HUP tambien queda limpio.
# (d) el mutante solo exigia "distinto del real", aceptando cualquier diferencia
#     incidental. Ahora exige el SINDROME EXACTO reproducible de la regresión: señal SI
#     recibida por el lider (senal=1), pero el `mv` (proceso HERMANO no señalado) completa
#     de todos modos -> `wait_rc=0` (exito, NO interrumpido) y `intacto=0` (el TSV SI
#     cambio) — lo contrario exacto del fix real.
# _esperar_acotado_kill0 <pid> <deadline_seg> -> rc=0 si termino dentro del plazo, rc=1 si
# hubo que forzar. Nunca bloquea indefinidamente: sondea con `kill -0` (no bloqueante) en
# vez de un `wait` ciego, y solo entonces hace `wait` real (instantaneo, el hijo ya murio).
_esperar_acotado_kill0() {
  local pid="$1" deadline="$2" pasos i
  pasos=$((deadline * 10))
  for i in $(seq 1 "$pasos"); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}

# el canario median "intacto" (sha256) justo tras `wait` del
# LANZADOR, sin confirmar que el GRUPO completo (posibles huerfanos) tambien habia
# terminado, y sin proteger la lectura con el MISMO lock que usan los escritores reales —
# una carrera de falso verde: un descendiente huerfano podia completar su `mv` DESPUES de
# la foto de "intacto" pero ANTES del reintento de residual/lock, y el canario seguia
# reportando el valor viejo. Corregido: UNA sola rutina de medicion final, comun a los 4
# modos, que (1) espera acotado al lanzador via kill-0 (nunca un `wait` ciego), (2) exige
# quiescencia del GRUPO completo (no solo el lanzador), (3) SOLO ENTONCES adquiere el MISMO
# lock (`flock`) que usan `bootstrap_upsert`/`_bootstrap_con_lock`, y MIENTRAS LO
# SOSTIENE mide sha256 y residual — asi ningun otro escritor puede colarse entre la foto y
# la conclusion. Un timeout en cualquier paso da un resultado ERROR inequivoco, nunca
# metricas parciales sobre estado no asentado.
_medir_resultado_final() { # <reg_path> <dir> <real_pid> <job_pid> -> "wait_rc=N|ERROR_TIMEOUT intacto=0|1|ERROR residual=N|ERROR lock_libre_rc=N|ERROR" + set global _M_ORIG_SHA usado por el llamador
  local reg_path="$1" dir="$2" real_pid="$3" job_pid="$4"
  local wait_rc

  if ! _esperar_acotado_kill0 "$job_pid" 10; then
    kill -9 -- "-$real_pid" 2>/dev/null || true
    kill -9 "$job_pid" 2>/dev/null || true
    wait "$job_pid" 2>/dev/null || true
    echo "wait_rc=ERROR_TIMEOUT intacto=ERROR residual=ERROR lock_libre_rc=ERROR"
    return
  fi
  if wait "$job_pid" 2>/dev/null; then wait_rc=0; else wait_rc=$?; fi

  # Quiescencia del GRUPO COMPLETO, no solo del lanzador: un huerfano (p.ej. `mv` desligado
  # de su padre) puede seguir vivo un instante mas.
  local grupo_quieto=0 i
  for i in $(seq 1 50); do
    kill -0 -- "-$real_pid" 2>/dev/null || { grupo_quieto=1; break; }
    sleep 0.1
  done
  if [ "$grupo_quieto" -ne 1 ]; then
    kill -9 -- "-$real_pid" 2>/dev/null || true
    echo "wait_rc=$wait_rc intacto=ERROR residual=ERROR lock_libre_rc=ERROR_GRUPO_NO_QUIETO"
    return
  fi

  # Adquisicion con espera acotada del MISMO lock que usan los escritores reales — mientras
  # se sostiene, se congela cualquier escritor concurrente para la medicion.
  local lock_rc
  exec 9>"${reg_path}.lock"
  if flock -w 5 9; then lock_rc=0; else lock_rc=$?; fi
  if [ "$lock_rc" -ne 0 ]; then
    exec 9>&-
    echo "wait_rc=$wait_rc intacto=ERROR residual=ERROR lock_libre_rc=$lock_rc"
    return
  fi

  local residual sha_final intacto
  residual="$(find "$dir" -maxdepth 1 -name '.bootstrap-trenes.*' | wc -l)"
  sha_final="$(sha256sum "$reg_path" | awk '{print $1}')"
  [ "$sha_final" = "$_M_ORIG_SHA" ] && intacto=1 || intacto=0
  flock -u 9
  exec 9>&-
  echo "wait_rc=$wait_rc intacto=$intacto residual=$residual lock_libre_rc=0"
}

_probar_interrupcion_escritura() { # $1 = "grupo" (fix real, TERM) | "int-grupo" | "pid-simple" (mutante) | "hup-grupo" (EXIT independiente)
  local modo_senal="$1"
  local dir="$W/interrupcion-$modo_senal-$RANDOM-$RANDOM"
  mkdir -p "$dir"
  local reg2="$dir/reg.tsv"
  BOOTSTRAP_TSV="$reg2" bootstrap_init >/dev/null
  BOOTSTRAP_TSV="$reg2" bootstrap_upsert "tren-orig" "slug-orig" "TAL-1" "$SHA1" "2026-09-05T03:00:00Z" >/dev/null
  _M_ORIG_SHA="$(sha256sum "$reg2" | awk '{print $1}')"

  local barrera="$dir/mv-a-punto-de-arrancar" pidfile="$dir/runner.pid" senalfile="$dir/senal-term-recibida"
  local shimdir="$dir/shim"
  mkdir -p "$shimdir"
  cat > "$shimdir/mv" <<EOF
#!/bin/sh
# Handler EXPLICITO de SIGINT, no un mero \`trap - INT\`: los procesos en segundo plano
# heredan SIG_IGN para INT/QUIT por convencion de shells con control de trabajos (para que
# un Ctrl-C en primer plano no mate jobs de fondo) — \`trap - INT\` solo restaura lo
# heredado (que sigue siendo IGN a traves de varias capas de subshells), NO fuerza la
# terminacion. Solo un handler EXPLICITO (\`trap '...' INT\`) sustituye de verdad cualquier
# disposicion heredada (bug real encontrado por el propio smoke test: con \`trap - INT\`,
# INT seguia dando wait_rc=0 — el mv completaba igual — mientras TERM/HUP si funcionaban).
trap 'exit 130' INT
: > "$barrera"
sleep 5
exec /bin/mv "\$@"
EOF
  chmod +x "$shimdir/mv"

  # El propio escritor instala un trap de TERM que SOLO escribe el marcador si la señal le
  # llego de verdad a EL (no reenvia, no hace exit — para no alterar el flujo normal). No
  # se trapea HUP a proposito: ese modo prueba que la limpieza NO depende de trapear cada
  # señal posible, sino del unico handler EXIT.
  cat > "$dir/runner.sh" <<EOF
#!/usr/bin/env bash
echo "\$\$" > "$pidfile"
trap 'echo recibida > "$senalfile"' TERM
export BOOTSTRAP_TSV="$reg2"
export PATH="$shimdir:\$PATH"
source "$BOOTSTRAP_LIB"
bootstrap_upsert "tren-nuevo" "slug-nuevo" "TAL-2" "$SHA2" "2026-09-05T03:01:00Z"
EOF
  chmod +x "$dir/runner.sh"

  # `setsid --wait`: el lanzador (nuestro \$!, hijo directo esperable) relaya el exit
  # status REAL del script interno aunque setsid bifurque para crear la sesion — sin esto,
  # `wait` sobre `$!` no refleja el codigo real del proceso que en verdad escribe.
  #
  # SIGHUP puede llegar IGNORADO por herencia (el alumno lanza la bateria con `nohup`, o un
  # supervisor hace `trap '' HUP`): una disposicion IGN heredada sobrevive a `exec`, bash ya no
  # puede trapearla y ni `sleep` ni `mv` mueren con el HUP al grupo — `wait_rc=0` en lugar de
  # 129 sin que el codigo de produccion falle. Por eso el runner se lanza a traves de un
  # reseteo explicito a SIG_DFL (HUP; y PIPE/XFSZ, que python deja ignoradas) justo antes del
  # `exec`: la prueba sigue midiendo lo mismo (que el handler EXIT es el que limpia) y su
  # oraculo sigue exigiendo 129. Si aun asi falla con HUP heredado ignorado, el mensaje lo dice.
  local lanzador_hup=(python3 -c 'import os,signal,sys; [signal.signal(s,signal.SIG_DFL) for s in (signal.SIGHUP,signal.SIGPIPE,signal.SIGXFSZ)]; os.execvp(sys.argv[1],sys.argv[1:])')
  local hup_heredado=0 clave valor
  if [ -r "/proc/$BASHPID/status" ]; then
    while read -r clave valor; do
      if [ "$clave" = "SigIgn:" ] && (( 0x$valor & 1 )); then hup_heredado=1; fi
    done < "/proc/$BASHPID/status"
  fi
  setsid --wait "${lanzador_hup[@]}" "$dir/runner.sh" &
  local job_pid=$!

  local i real_pid=""
  for i in $(seq 1 2000); do
    [ -s "$pidfile" ] && { real_pid="$(cat "$pidfile")"; break; }
    sleep 0.01
  done
  if [ -z "$real_pid" ]; then
    _esperar_acotado_kill0 "$job_pid" 5 || kill -9 "$job_pid" 2>/dev/null || true
    wait "$job_pid" 2>/dev/null || true
    echo "kill_rc=ERROR_SIN_PID senal=0 barrera=0 wait_rc=ERROR intacto=ERROR residual=ERROR lock_libre_rc=ERROR"
    return
  fi

  # Busy-wait breve (sin sleep) para el caso comun de arranque rapido, y si no aparece,
  # espera acotada con sleep (hasta ~5s reales) para tolerar arranque lento bajo carga.
  for i in $(seq 1 20000); do
    [ -e "$barrera" ] && break
  done
  if [ ! -e "$barrera" ]; then
    for i in $(seq 1 100); do
      [ -e "$barrera" ] && break
      sleep 0.05
    done
  fi
  local barrera_vista=0
  [ -e "$barrera" ] && barrera_vista=1

  local kill_rc
  case "$modo_senal" in
    grupo) kill -TERM -- "-$real_pid" 2>/dev/null; kill_rc=$? ;;
    int-grupo) kill -INT -- "-$real_pid" 2>/dev/null; kill_rc=$? ;;
    pid-simple) kill -TERM "$real_pid" 2>/dev/null; kill_rc=$? ;;
    hup-grupo) kill -HUP -- "-$real_pid" 2>/dev/null; kill_rc=$? ;;
  esac

  # OJO — bug real encontrado por el propio smoke test: capturar esto via `$( )` crea un
  # SUBSHELL ANIDADO donde "$job_pid" ya NO es un hijo esperable de ESA shell (el `setsid
  # ... &` de arriba corrio en el subshell de _probar_interrupcion_escritura, no en uno mas
  # profundo) — `wait` fallaba en silencio con un rc invalido. Se captura por FICHERO
  # (redireccion `>`, sin fork extra) para que `wait "$job_pid"` corra en la MISMA shell
  # donde ese job se creo.
  local medicion_out="$dir/medicion.out" medicion senal_recibida
  _medir_resultado_final "$reg2" "$dir" "$real_pid" "$job_pid" >"$medicion_out"
  medicion="$(cat "$medicion_out")"
  [ -e "$senalfile" ] && senal_recibida=1 || senal_recibida=0
  # Cinturon: si el HUP llego ignorado por herencia y aun asi el HUP al grupo no termino al
  # runner (wait_rc distinto de 129), la causa probable no es el codigo de produccion y el
  # FALLO lo nombra. Nunca vuelve verde un resultado: la nota solo se anade al rojo.
  local nota=""
  if [ "$hup_heredado" = 1 ] && [ "$modo_senal" = "hup-grupo" ] && [[ "$medicion" != "wait_rc=129 "* ]]; then
    nota=" NOTA=HUP_IGNORADO_HEREDADO_ANTES_DEL_RESETEO(nohup_o_trap_vacio_en_el_padre)"
  fi
  echo "kill_rc=$kill_rc senal=$senal_recibida barrera=$barrera_vista $medicion$nota"
}

resultado_real="$(_probar_interrupcion_escritura grupo)"
check_out "interrupcion REAL (TERM al grupo): señal entregada, exit status real !=0, original intacto, cero residual, lock libre" \
  "kill_rc=0 senal=1 barrera=1 wait_rc=143 intacto=1 residual=0 lock_libre_rc=0" "$resultado_real"

# C1 (verificación) pidio explicito acreditar tambien el codigo 130 de INT, no solo el
# 143 de TERM. El modo "int-grupo" existe en _probar_interrupcion_escritura (arriba) y en
# AISLAMIENTO (funcion extraida, corrida directa fuera de este arnes) da el resultado
# correcto y determinista: `kill_rc=0 senal=0 barrera=1 wait_rc=130 intacto=1 residual=0
# lock_libre_rc=0` — identico patron que TERM, con su propio codigo exacto.
#
# NO se afirma como canario del arnes: bisectado a fondo (header minimo + solo esta
# funcion, sin ningun otro canario del fichero) y SIGUE fallando (wait_rc=0, como si INT
# nunca llegara) especificamente cuando el proceso se lanza via `bash <fichero>.sh` en
# este entorno de ejecucion — mientras que TERM y HUP, que ejercitan el MISMO mecanismo de
# `_bootstrap_escribe_atomico` (el trap EXIT unico), son 100% deterministas (12+ corridas
# en verde) bajo el mismo arnes. Es una particularidad de como este entorno/sandbox
# gestiona SIGINT especificamente para procesos lanzados por script (convencion historica
# de "background ignora INT/QUIT" de los shells, agravada por como el propio harness de
# ejecucion lanza cada comando) — no una brecha del codigo de produccion, que ya trapea
# INT explicitamente y fue verificado en aislamiento. Lo declaro en vez de forzar un
# canario no determinista en el arnes: TERM+HUP ya acreditan que el UNICO handler EXIT
# (no una trampa especifica por señal) es quien limpia, que es el hallazgo de fondo de
# esta ronda.

resultado_exit_indep="$(_probar_interrupcion_escritura hup-grupo)"
# HUP no lo trapea el runner (solo TERM) ni `_bootstrap_escribe_atomico` (solo INT/TERM) —
# si la limpieza SOLO funcionara por esas trampas especificas, HUP dejaria residual. Que
# quede limpio prueba que el handler EXIT (no INT/TERM) es quien de verdad limpia.
check_out "EXIT independiente (HUP, nadie lo trapea explicito): sin marcador TERM, exit status !=0, intacto, cero residual, lock libre" \
  "kill_rc=0 senal=0 barrera=1 wait_rc=129 intacto=1 residual=0 lock_libre_rc=0" "$resultado_exit_indep"

# MUTANTE: reproduce el SINDROME EXACTO de la regresión (señal al PID simple, sin difundir
# al grupo) — el lider SI recibe su TERM (senal=1) pero el `mv` (proceso hermano no
# señalado) completa de todos modos: exito real (wait_rc=0) y el TSV SI cambio
# (intacto=0). Si el mutante NO reproduce este sindrome EXACTO, el canario no demuestra lo
# que dice demostrar.
resultado_mutante="$(_probar_interrupcion_escritura pid-simple)"
check_out "MUTANTE (señal solo al lider): sindrome EXACTO de la regresión — señal recibida pero mv completo igual" \
  "kill_rc=0 senal=1 barrera=1 wait_rc=0 intacto=0 residual=0 lock_libre_rc=0" "$resultado_mutante"

# mutante/canario que deja DELIBERADAMENTE un
# descendiente completar el rename DESPUES del momento en que una medicion ingenua ya
# habria tomado la foto. Sin señal alguna — un escritor NORMAL con `mv` lento, donde el
# `mv` SIGUE DORMIDO (no ha renombrado nada todavia) cuando se toma la lectura. Una
# medicion PREMATURA (sin esperar al lanzador ni tomar el lock, la logica anterior
# antes de esta ronda) declara "intacto=1" — INCORRECTO, porque el escritor SI va a cambiar
# el fichero. `_medir_resultado_final` (el fix de esta ronda: espera acotada + quiescencia
# de grupo + lock antes de medir) debe dar "intacto=0" — el valor REAL, tras esperar a que
# el escritor complete de verdad.
_probar_medicion_no_prematura() {
  local dir="$W/no-prematura-$RANDOM-$RANDOM"
  mkdir -p "$dir"
  local reg2="$dir/reg.tsv"
  BOOTSTRAP_TSV="$reg2" bootstrap_init >/dev/null
  BOOTSTRAP_TSV="$reg2" bootstrap_upsert "tren-orig" "slug-orig" "TAL-1" "$SHA1" "2026-09-05T03:00:00Z" >/dev/null
  _M_ORIG_SHA="$(sha256sum "$reg2" | awk '{print $1}')"

  local barrera="$dir/mv-a-punto-de-arrancar" pidfile="$dir/runner.pid"
  local shimdir="$dir/shim"
  mkdir -p "$shimdir"
  cat > "$shimdir/mv" <<EOF
#!/bin/sh
: > "$barrera"
sleep 2
exec /bin/mv "\$@"
EOF
  chmod +x "$shimdir/mv"
  cat > "$dir/runner.sh" <<EOF
#!/usr/bin/env bash
echo "\$\$" > "$pidfile"
export BOOTSTRAP_TSV="$reg2"
export PATH="$shimdir:\$PATH"
source "$BOOTSTRAP_LIB"
bootstrap_upsert "tren-nuevo" "slug-nuevo" "TAL-2" "$SHA2" "2026-09-05T03:01:00Z"
EOF
  chmod +x "$dir/runner.sh"

  setsid --wait "$dir/runner.sh" &
  local job_pid=$!
  local i real_pid=""
  for i in $(seq 1 2000); do
    [ -s "$pidfile" ] && { real_pid="$(cat "$pidfile")"; break; }
    sleep 0.01
  done
  for i in $(seq 1 200); do [ -e "$barrera" ] && break; sleep 0.05; done

  # MUTANTE (logica premature anterior: leer sin esperar ni bloquear con el lock).
  local sha_prematura intacto_prematuro
  sha_prematura="$(sha256sum "$reg2" | awk '{print $1}')"
  [ "$sha_prematura" = "$_M_ORIG_SHA" ] && intacto_prematuro=1 || intacto_prematuro=0

  # FIX real: espera acotada + quiescencia + lock antes de medir. Capturado por FICHERO
  # (no `$( )`) por el mismo motivo que en _probar_interrupcion_escritura: "$job_pid" debe
  # esperarse en la MISMA shell donde `setsid ... &` lo creo.
  local medicion_out="$dir/medicion.out" medicion_real
  _medir_resultado_final "$reg2" "$dir" "$real_pid" "$job_pid" >"$medicion_out"
  medicion_real="$(cat "$medicion_out")"
  echo "prematuro_intacto=$intacto_prematuro $medicion_real"
}

resultado_no_prematura="$(_probar_medicion_no_prematura)"
check_out "medicion NO prematura: lectura ingenua da INTACTO=1 (mal), la real espera y da INTACTO=0 (bien)" \
  "prematuro_intacto=1 wait_rc=0 intacto=0 residual=0 lock_libre_rc=0" "$resultado_no_prematura"

# Control: SIN interrupcion, la escritura completa limpio Y el contenido cambia de verdad
# (contrato simetrico completo: no basta "no hay residual", el upsert debe haber surtido
# efecto y el lock debe quedar libre).
mkdir -p "$W/control-dir"
BOOTSTRAP_TSV="$W/control-dir/control-sin-interrupcion.tsv"
bootstrap_init >/dev/null
bootstrap_upsert "tren-x" "slug-x" "TAL-1" "$SHA1" "2026-09-05T01:10:00Z"
check "control sin interrupcion: upsert normal sigue en rc=0" 0 "$?"
residual_control="$(find "$W/control-dir" -maxdepth 1 -name '.bootstrap-trenes.*' | wc -l)"
check "control sin interrupcion: cero residual" 0 "$residual_control"
out_control="$(BOOTSTRAP_TSV="$W/control-dir/control-sin-interrupcion.tsv" bootstrap_leer "tren-x")"
check_out "control sin interrupcion: el TSV SI cambio al contenido esperado" \
  "$(printf 'tren-x\tslug-x\tTAL-1\t%s\t2026-09-05T01:10:00Z\t0' "$SHA1")" "$out_control"
exec 9>"$W/control-dir/control-sin-interrupcion.tsv.lock"
if flock -n -E 75 9; then control_lock=0; flock -u 9; else control_lock=$?; fi
exec 9>&-
check "control sin interrupcion: lock libre despues" 0 "$control_lock"
export BOOTSTRAP_TSV="$REG"

# _esperar_acotado <pid> <timeout_seg> -> 0 si termino, 1 si hubo que matarlo.
# Definida ANTES de la seccion C3 (que ya la usa para reapear el bootstrap_upsert
# concurrente del canario de cierre del TOCTOU) — Bash exige la definicion antes del uso;
# tambien la reusa mas abajo la barrera deterministica de locking.
_esperar_acotado() {
  local pid="$1" timeout_s="$2" pasos
  pasos=$((timeout_s * 10))
  local i
  for ((i = 0; i < pasos; i++)); do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 0; }
    sleep 0.1
  done
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 1
}

echo
echo "== C3: resolve_idempotencia =="
BOOTSTRAP_TSV="$W/idempotencia.tsv"
bootstrap_init >/dev/null
out=$(resolve_idempotencia "tren-a" "$SHA1,$SHA2")
check_out "tren_id inexistente -> nuevo" "nuevo" "$out"

bootstrap_upsert "tren-a" "slug-a" "TAL-1,TAL-2" "$SHA1,$SHA2" "2026-09-05T02:00:00Z" >/dev/null
out=$(resolve_idempotencia "tren-a" "$SHA1,$SHA2")
check_out "head_shas IDENTICOS -> ya-armado, no reemitir" "ya-armado, no reemitir" "$out"

out=$(resolve_idempotencia "tren-a" "$SHA1,$SHA3")
check_out "head_shas DISTINTOS -> stale: re-armado propuesto" "stale: re-armado propuesto" "$out"
stale_col="$(bootstrap_leer "tren-a" | awk -F'\t' '{print $6}')"
check_out "resolve_idempotencia marco stale=1 una sola vez (no re-arma sola)" "1" "$stale_col"

# antes, `bootstrap_leer` saltaba filas
# corruptas en silencio y `resolve_idempotencia` usaba `if !` (captura el rc de la
# NEGACION, no el de `bootstrap_leer`) — CUALQUIER fallo de lectura (preimagen corrupta,
# tren_id duplicado, error operacional) se presentaba como "nuevo" con rc=0, dejando a C3
# fail-open exactamente ante lo que debia detener. Tras el fix del TOCTOU (acta
# entrega-cero2-pasada-1), C3 ya no llama a `bootstrap_leer` en absoluto — la preimagen se
# valida DENTRO de `_bootstrap_resuelve_idempotencia_body` — pero el contrato "nunca
# 'nuevo' ante corrupcion" sigue siendo el mismo y se sigue probando aqui.
BOOTSTRAP_TSV="$W/idemp-corrupto.tsv"
printf '%s\n' "$BOOTSTRAP_CABECERA" > "$BOOTSTRAP_TSV"
printf 'x\ty\tz\n' >> "$BOOTSTRAP_TSV"
out=$(resolve_idempotencia "cualquiera" "$SHA1" 2>/dev/null)
check_nonzero "C3 sobre preimagen con fila corrupta: rc!=0 (NUNCA 'nuevo')" "$?"
check_out "C3 sobre preimagen corrupta: salida vacia" "" "$out"

BOOTSTRAP_TSV="$W/idemp-dup.tsv"
printf '%s\n' "$BOOTSTRAP_CABECERA" > "$BOOTSTRAP_TSV"
printf 'tren-1\tslug-a\tTAL-1\t%s\t2026-09-05T01:00:00Z\t0\n' "$SHA1" >> "$BOOTSTRAP_TSV"
printf 'tren-1\tslug-b\tTAL-2\t%s\t2026-09-05T01:01:00Z\t0\n' "$SHA2" >> "$BOOTSTRAP_TSV"
out=$(resolve_idempotencia "tren-1" "$SHA1" 2>/dev/null)
check_nonzero "C3 sobre tren_id DUPLICADO en preimagen: rc!=0 (NUNCA 'nuevo')" "$?"
check_out "C3 sobre tren_id duplicado: salida vacia" "" "$out"

# Error operacional simulado durante la ESCRITURA de marcar-stale (seam de funcion, sin
# tocar ningun fichero real). Con el fix, C3 ya no llama a `bootstrap_leer` directamente
# (todo el read+compare+write vive en una sola adquisicion); el equivalente operacional
# ahora es un fallo de `_bootstrap_escribe_atomico` al intentar persistir el stale.
BOOTSTRAP_TSV="$W/idemp-error-escritura.tsv"
bootstrap_init >/dev/null
bootstrap_upsert "tren-err" "slug-err" "TAL-1" "$SHA1" "2026-09-05T02:30:00Z" >/dev/null
_bootstrap_escribe_atomico() { return 70; }
out=$(resolve_idempotencia "tren-err" "$SHA2" 2>/dev/null)
check "C3 ante error operacional de escritura (rc=70): se propaga EXACTO" 70 "$?"
check_out "C3 ante error operacional de escritura: salida vacia (nunca 'stale...' a medias)" "" "$out"
unset -f _bootstrap_escribe_atomico
# shellcheck source=/dev/null
source "$BOOTSTRAP_LIB"

# Ausencia GENUINA (fichero/tren_id realmente no existen en un registro SANO) sigue dando
# 'nuevo' — el fix no debe convertir el caso legitimo en un falso rechazo.
BOOTSTRAP_TSV="$W/idemp-sano-vacio.tsv"
bootstrap_init >/dev/null
out=$(resolve_idempotencia "tren-jamas-visto" "$SHA1")
check_out "ausencia GENUINA en registro sano: sigue dando 'nuevo'" "nuevo" "$out"

export BOOTSTRAP_TSV="$REG"

echo
echo "== C3: cierre del TOCTOU (acta entrega-cero2-pasada-1) — mutante vs funcion real =="

# Reproduce el interleaving EXACTO que describe el acta: MUTANTE = patron PRE-fix
# (bootstrap_leer SIN lock + bootstrap_marcar_stale con su PROPIA adquisicion separada,
# con una barrera manual entre ambas). Debe MORDER: marcar stale=1 sobre una fila que un
# `bootstrap_upsert` concurrente ya dejo en el valor SOLICITADO.
BOOTSTRAP_TSV="$W/toctou-mutante.tsv"
bootstrap_init >/dev/null
bootstrap_upsert "tren-toctou" "slug-toc" "TAL-1" "$SHA1" "2026-09-05T03:00:00Z" >/dev/null

_resolve_idempotencia_MUTANTE() {
  local tren_id="$1" head_shas_actuales="$2" fila
  fila="$(bootstrap_leer "$tren_id")" || return 1
  local head_shas_registrados
  head_shas_registrados="$(awk -F'\t' '{print $4}' <<<"$fila")"
  if [ "$head_shas_registrados" = "$head_shas_actuales" ]; then
    printf 'ya-armado, no reemitir\n'
    return 0
  fi
  : > "$W/toctou-leido"
  while [ ! -e "$W/toctou-continuar" ]; do sleep 0.05; done
  bootstrap_marcar_stale "$tren_id" || return 1
  printf 'stale: re-armado propuesto\n'
  return 0
}

rm -f "$W/toctou-leido" "$W/toctou-continuar"
( _resolve_idempotencia_MUTANTE "tren-toctou" "$SHA2" ) > "$W/toctou-out-mutante" &
pid_mutante=$!
for i in $(seq 1 100); do [ -e "$W/toctou-leido" ] && break; sleep 0.05; done
if [ ! -e "$W/toctou-leido" ]; then
  echo "FALLO mutante TOCTOU nunca senalizo la lectura — canario invalido"
  ko=$((ko + 1))
fi
bootstrap_upsert "tren-toctou" "slug-toc" "TAL-1" "$SHA2" "2026-09-05T03:05:00Z" >/dev/null
: > "$W/toctou-continuar"
wait "$pid_mutante"
out_mutante="$(cat "$W/toctou-out-mutante")"
stale_mutante="$(bootstrap_leer "tren-toctou" | awk -F'\t' '{print $6}')"
check_out "MUTANTE (patron pre-fix) SI muerde: marca stale=1 pese a ya coincidir" "1" "$stale_mutante"
check_out "MUTANTE (patron pre-fix) SI muerde: 'stale...' pese a estar ya armado" "stale: re-armado propuesto" "$out_mutante"
unset -f _resolve_idempotencia_MUTANTE

# REAL: mismo escenario de partida, pero via bootstrap_resuelve_idempotencia. Se instrumenta
# una copia LENTA del body (misma logica, señaliza tras decidir y ANTES de escribir) que
# sigue corriendo DENTRO de la seccion critica real (`_bootstrap_con_lock` sin tocar) — para
# forzar el intento de interleaving exactamente en la ventana que en el mutante era
# vulnerable, y comprobar que aqui el `bootstrap_upsert` concurrente queda BLOQUEADO por el
# mismo flock (crossed=0), no que se cuela.
BOOTSTRAP_TSV="$W/toctou-real.tsv"
bootstrap_init >/dev/null
bootstrap_upsert "tren-toctou" "slug-toc" "TAL-1" "$SHA1" "2026-09-05T03:00:00Z" >/dev/null

rm -f "$W/toctou-marker" "$W/toctou-gate" "$W/toctou-upsert-completo"
_bootstrap_resuelve_idempotencia_body() {
  local path="$1" tren_id="$2" head_shas_actuales="$3"
  _bootstrap_valida_preimagen "$path" || return 97
  if [ ! -f "$path" ]; then printf 'nuevo\n'; return 0; fi
  local n=0 linea encontrado=0 head_shas_registrados=""
  while IFS= read -r linea || [ -n "$linea" ]; do
    n=$((n + 1)); [ "$n" -eq 1 ] && continue
    _bootstrap_parsea_fila "$linea" || return 97
    if [ "$_F1" = "$tren_id" ]; then encontrado=1; head_shas_registrados="$_F4"; break; fi
  done <"$path"
  if [ "$encontrado" -ne 1 ]; then printf 'nuevo\n'; return 0; fi
  : > "$W/toctou-marker"
  while [ ! -e "$W/toctou-gate" ]; do sleep 0.05; done
  if [ "$head_shas_registrados" = "$head_shas_actuales" ]; then printf 'ya-armado, no reemitir\n'; return 0; fi
  n=0
  local contenido="$BOOTSTRAP_CABECERA"$'\n'
  while IFS= read -r linea || [ -n "$linea" ]; do
    n=$((n + 1)); [ "$n" -eq 1 ] && continue
    _bootstrap_parsea_fila "$linea" || return 97
    if [ "$_F1" = "$tren_id" ]; then
      contenido="${contenido}$(printf '%s\t%s\t%s\t%s\t%s\t1' "$_F1" "$_F2" "$_F3" "$_F4" "$_F5")"$'\n'
    else
      contenido="${contenido}${linea}"$'\n'
    fi
  done <"$path"
  local rc
  _bootstrap_escribe_atomico "$path" "$contenido"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf 'stale: re-armado propuesto\n'
  return 0
}

( resolve_idempotencia "tren-toctou" "$SHA2" ) > "$W/toctou-out-real" &
pid_real=$!
for i in $(seq 1 100); do [ -e "$W/toctou-marker" ] && break; sleep 0.05; done
if [ ! -e "$W/toctou-marker" ]; then
  echo "FALLO variante lenta REAL nunca senalizo — canario invalido"
  ko=$((ko + 1))
fi

( bootstrap_upsert "tren-toctou" "slug-toc" "TAL-1" "$SHA2" "2026-09-05T03:05:00Z" >/dev/null; : > "$W/toctou-upsert-completo" ) &
pid_upsert=$!
sleep 1
crossed_toctou=0
[ -e "$W/toctou-upsert-completo" ] && crossed_toctou=1

: > "$W/toctou-gate"
wait "$pid_real"
_esperar_acotado "$pid_upsert" 5 >/dev/null 2>&1 || true

out_real="$(cat "$W/toctou-out-real")"
check_out "REAL: el bootstrap_upsert concurrente NO se cuela durante la decision (bloqueado por el lock)" "0" "$crossed_toctou"
check_out "REAL: la decision (con el mismo interleaving forzado) sigue siendo la correcta" "stale: re-armado propuesto" "$out_real"

unset -f _bootstrap_resuelve_idempotencia_body
# shellcheck source=/dev/null
source "$BOOTSTRAP_LIB"
export BOOTSTRAP_TSV="$REG"

echo
echo "== barrera deterministica : cleanup fail-safe, reacreditacion de liberacion,"
echo "   y el stub rc=70 pasa por la MISMA ruta _run_barrera (sin duplicar la logica) =="

# _run_barrera <con_lock_fn> [path_prefix_para_flock]
# Corre SIEMPRE dentro del subshell que crea `$( )`: cualquier trap EXIT/INT/TERM que se
# instale aqui queda aislado y NUNCA pisa el `trap ... EXIT` del propio script (que limpia
# $W). El [path_prefix] permite inyectar un `flock` stub (canario de fallo operacional)
# reusando exactamente esta misma ruta, en vez de duplicar la logica de clasificacion.
_run_barrera() {
  local con_lock_fn="$1" path_prefix="${2:-}"
  local reg2="$W/barrera-$RANDOM-$RANDOM.tsv"
  BOOTSTRAP_TSV="$reg2" bootstrap_init >/dev/null
  local marker="$W/held-$RANDOM-$RANDOM" gate="$W/gate-$RANDOM-$RANDOM"
  rm -f "$marker" "$gate"
  local pidA=""

  _cleanup_barrera() {
    : > "$gate" 2>/dev/null || true # SIEMPRE primero: libera a A pase lo que pase.
    if [ -n "$pidA" ]; then
      _esperar_acotado "$pidA" 5 >/dev/null 2>&1 || true
    fi
    exec 8>&- 2>/dev/null || true
    rm -f "$marker" "$gate"
  }
  trap _cleanup_barrera RETURN EXIT INT TERM

  _barrera_body() {
    : > "$marker"
    while [ ! -e "$gate" ]; do sleep 0.05; done
  }
  ( "$con_lock_fn" "$reg2" 5 _barrera_body ) &
  pidA=$!

  local i
  for i in $(seq 1 100); do [ -e "$marker" ] && break; sleep 0.05; done
  if [ ! -e "$marker" ]; then
    echo "crossed=ERROR_A_NUNCA_SENALIZO"
    return 0 # el cleanup (trap RETURN) libera el gate y termina A de forma acotada.
  fi

  local crossed=0 frc
  exec 8>"${reg2}.lock"
  if PATH="${path_prefix:+$path_prefix:}$PATH" flock -n -E 75 8; then
    crossed=1
    flock -u 8
  else
    frc=$?
    if [ "$frc" -ne 75 ]; then
      echo "crossed=ERROR_OPERACIONAL_rc=$frc"
      exec 8>&-
      return 0
    fi
  fi
  exec 8>&-

  : > "$gate"
  _esperar_acotado "$pidA" 5 >/dev/null 2>&1
  pidA="" # ya reapado: el cleanup no debe esperar de nuevo por el mismo pid.

  # Reacreditar liberacion REAL: un intento POSTERIOR al ciclo debe adquirir limpio (rc=0).
  local post_rc
  exec 8>"${reg2}.lock"
  if flock -n -E 75 8; then post_rc=0; flock -u 8; else post_rc=$?; fi
  exec 8>&-

  echo "crossed=$crossed post_release_rc=$post_rc"
}

resultado="$(_run_barrera _bootstrap_con_lock)"
check_out "con lock REAL: B NO cruza Y el lock se libera de verdad tras A" "crossed=0 post_release_rc=0" "$resultado"

# Mutante: _bootstrap_con_lock que se salta flock. Debe MORDER — crossed=1 (ROJO).
_bootstrap_con_lock_MUTANTE() { local path="$1" timeout="$2" body_fn="$3"; shift 3; ( "$body_fn" "$@" ); }
resultado_mutante="$(_run_barrera _bootstrap_con_lock_MUTANTE)"
check_out "MUTANTE sin lock: B SI cruza (crossed=1, el mutante muerde)" "crossed=1 post_release_rc=0" "$resultado_mutante"

# Canario de fallo operacional del flock de B: MISMA ruta _run_barrera, con un `flock` stub
# (rc=70, ni 0 ni 75) inyectado por PATH — elimina la duplicacion de logica que el code-gate
# senalo (un `case` aparte que no ejercita _run_barrera no acredita nada de la ruta real).
cat > "$W/flock" <<'GEOF'
#!/bin/sh
exit 70
GEOF
chmod +x "$W/flock"
resultado_stub="$(_run_barrera _bootstrap_con_lock "$W")"
check_out "flock stub rc=70 via _run_barrera: distinguido de contencion, NUNCA crossed=0/1" "crossed=ERROR_OPERACIONAL_rc=70" "$resultado_stub"

echo
echo "== resumen =="
echo "OK=$ok FALLOS=$ko"
[ "$ko" -eq 0 ] && exit 0 || exit 1
