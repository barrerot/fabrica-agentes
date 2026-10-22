#!/usr/bin/env bash
# compose-bootstrap.sh — registro TSV de trenes para el compositor (TAL-5383 · A2).
#
# Seccion critica UNICA: toda mutacion publica (init/upsert/marcar_stale) pasa por
# `_bootstrap_con_lock`, que toma `flock` sobre `${path}.lock` antes de leer/transformar/
# escribir. Sin esto, dos procesos que leen la MISMA preimagen y escriben `mv` distintos
# pierden en silencio una de las dos actualizaciones (r1 MAYOR 1). Ningun helper interno
# vuelve a tomar el lock por su cuenta.
#
# Todas las funciones publicas resuelven el path via `bootstrap_path()` (override por
# `BOOTSTRAP_TSV` para tests, mismo patron `DRG_GH_BIN`/`DRG_GIT_BIN` de A1) — NINGUNA
# recibe el path como argumento posicional (contrato sellado en el plan-gate r1-r5).
set -uo pipefail

_BOOTSTRAP_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_BOOTSTRAP_MOTOR="$(dirname "$(dirname "$_BOOTSTRAP_HERE")")"

# bootstrap_path() -> ruta del registro TSV. Override por `BOOTSTRAP_TSV` (tests/canarios).
bootstrap_path() {
  printf '%s' "${BOOTSTRAP_TSV:-$_BOOTSTRAP_MOTOR/registro/bootstrap-trenes.tsv}"
}

# Cabecera canonica, EXACTA (byte a byte) — 6 columnas, orden sellado en el plan.
BOOTSTRAP_CABECERA=$'tren_id\tslug\tpiezas\thead_shas\tarmado_en\tstale'

# ---------------------------------------------------------------------------------------
# Seccion critica
# ---------------------------------------------------------------------------------------

# _bootstrap_con_lock <path> <timeout_seg> <body_fn> [args...]
# Unico punto de entrada al lock. Ejecuta body_fn EN UN SUBSHELL: los traps que instale
# (o el `trap` del propio `flock`) quedan aislados y nunca pisan los del llamador — un
# subshell tiene su propia tabla de traps, no hace falta guardar/restaurar nada a mano.
# RC: 90 no se pudo abrir el fd del lock · 91 falta el binario `flock` · 75 timeout de
# adquisicion (mismo codigo que usa el canario de contencion, por consistencia) · el rc de
# `body_fn` en cualquier otro caso.
_bootstrap_con_lock() {
  local path="$1" timeout="$2" body_fn="$3"
  shift 3
  command -v flock >/dev/null 2>&1 || return 91
  local lockfile="${path}.lock"
  (
    exec 9>"$lockfile" || exit 90
    flock -w "$timeout" -E 75 9 || exit "$?"
    "$body_fn" "$@"
  )
}

# ---------------------------------------------------------------------------------------
# Gramatica cerrada de las 6 columnas
# ---------------------------------------------------------------------------------------

_bootstrap_valida_tren_id() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; }
# slug: identificador humano corto, estilo URL — minusculas, digitos y guiones.
_bootstrap_valida_slug() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,99}$ ]]; }
_bootstrap_valida_piezas_csv() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}(,[A-Za-z0-9][A-Za-z0-9._/-]{0,127})*$ ]]
}
_bootstrap_valida_head_shas_csv() {
  [[ "$1" =~ ^[0-9a-f]{40}(,[0-9a-f]{40})*$ ]]
}
_bootstrap_valida_stale() { [ "$1" = "0" ] || [ "$1" = "1" ]; }
_bootstrap_valida_armado_en() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

# _bootstrap_cuenta_csv <csv> — numero de elementos separados por coma.
_bootstrap_cuenta_csv() {
  local -a arr
  IFS=',' read -ra arr <<<"$1"
  printf '%d' "${#arr[@]}"
}

# _bootstrap_valida_fila_campos <tren_id> <slug> <piezas> <head_shas> <armado_en> <stale>
# Valida los 6 campos de UNA fila (nueva o ya existente en el fichero). No conoce el
# fichero; solo la gramatica de valores. Orden IDENTICO al de BOOTSTRAP_CABECERA.
_bootstrap_valida_fila_campos() {
  local tren_id="$1" slug="$2" piezas="$3" head_shas="$4" armado_en="$5" stale="$6"
  _bootstrap_valida_tren_id "$tren_id" || return 1
  _bootstrap_valida_slug "$slug" || return 1
  _bootstrap_valida_piezas_csv "$piezas" || return 1
  _bootstrap_valida_head_shas_csv "$head_shas" || return 1
  [ "$(_bootstrap_cuenta_csv "$piezas")" -eq "$(_bootstrap_cuenta_csv "$head_shas")" ] || return 1
  _bootstrap_valida_armado_en "$armado_en" || return 1
  _bootstrap_valida_stale "$stale" || return 1
  return 0
}

# _bootstrap_parsea_fila <linea> -> deja los 6 campos en variables globales _F1.._F6.
# rc!=0 si la linea no tiene EXACTAMENTE 6 campos (columna de mas o de menos = fichero
# corrupto, no se adivina).
#
# OJO — gotcha de Bash real, encontrado por el propio smoke test antes de llegar al
# auditor: `IFS=$'\t' read -r ...` NO sirve para TSV con campos vacios. Bash trata tab
# (junto con espacio y newline) como "IFS whitespace" SIEMPRE, sin importar que IFS se
# fije a un unico caracter — eso colapsa tabs consecutivos en un solo delimitador y
# desplaza todos los campos siguientes una posicion, perdiendo en silencio campos vacios
# intermedios. `awk -F'\t'` no tiene ese problema: para cualquier FS distinto del default
# (" "), no colapsa ni recorta — cada tab es un delimitador literal independiente.
_bootstrap_parsea_fila() {
  local linea="$1" nf
  nf="$(awk -F'\t' '{print NF; exit}' <<<"$linea")"
  [ "$nf" -eq 6 ] || return 1
  local -a campos
  mapfile -t campos < <(awk -F'\t' '{for (i=1;i<=6;i++) print $i}' <<<"$linea")
  [ "${#campos[@]}" -eq 6 ] || return 1
  _F1="${campos[0]}"; _F2="${campos[1]}"; _F3="${campos[2]}"
  _F4="${campos[3]}"; _F5="${campos[4]}"; _F6="${campos[5]}"
  return 0
}

# _bootstrap_valida_preimagen <path> -> rc=0 si el fichero NO EXISTE (estado vacio valido)
# o si existe con cabecera EXACTA en la linea 1, TODAS las filas siguientes validas, y
# CERO tren_id duplicados (la unicidad por clave es parte del contrato del registro, no
# solo del upsert: dos filas validas con la misma clave no son un fichero sano). Fail-closed
# sobre el fichero COMPLETO, no solo sobre los argumentos nuevos.
_bootstrap_valida_preimagen() {
  local path="$1"
  [ -f "$path" ] || return 0
  local n=0 linea
  local -A vistos=()
  while IFS= read -r linea || [ -n "$linea" ]; do
    n=$((n + 1))
    if [ "$n" -eq 1 ]; then
      [ "$linea" = "$BOOTSTRAP_CABECERA" ] || return 1
      continue
    fi
    [ "$linea" = "$BOOTSTRAP_CABECERA" ] && return 1 # cabecera duplicada
    _bootstrap_parsea_fila "$linea" || return 1
    _bootstrap_valida_fila_campos "$_F1" "$_F2" "$_F3" "$_F4" "$_F5" "$_F6" || return 1
    [ -n "${vistos[$_F1]+x}" ] && return 1 # tren_id duplicado: fichero no sano
    vistos[$_F1]=1
  done <"$path"
  [ "$n" -ge 1 ] || return 1 # fichero existe pero esta vacio: truncado, no es un estado valido
  return 0
}

# ---------------------------------------------------------------------------------------
# Escritura atomica (temporal en el MISMO directorio + mv)
# ---------------------------------------------------------------------------------------

# _bootstrap_escribe_atomico <path> <contenido-completo>
#
# MAYOR 1 (code-gate r8+r9): la version de r8 solo atrapaba INT/TERM, no EXIT — el
# auditor senalo correctamente que una terminacion por otra via (HUP, `exit` temprano,
# etc.) seguia sin cubrirse, y que desactivar la trampa (`trap - INT TERM`) ANTES de la
# limpieza sincrona abria una ventana propia. Corregido con una UNICA seccion critica: el
# CUERPO ENTERO corre en su propio subshell, con UN SOLO punto de limpieza (el trap EXIT,
# que se dispara SIEMPRE — salida normal, `exit` explicito, o el `exit` que instalan a su
# vez INT/TERM) que borra "tmp" SOLO SI sigue apuntando a un fichero pendiente; tras un
# `mv` exitoso se vacia "tmp" antes de salir, asi que la limpieza de EXIT se vuelve un
# no-op correcto (el fichero ya se movio, no hay nada que borrar). Ni un solo intento de
# JAMAS desactiva las trampas antes de limpiar: hay una limpieza, siempre la misma.
#
# GOTCHA REAL DE BASH que exige el subshell (no es cosmetico): un `trap ... EXIT` fijado
# DENTRO de una funcion SIN subshell propio se dispara cuando la SHELL QUE LA CONTIENE
# termina (aqui, el subshell de `_bootstrap_con_lock`) — NO cuando esta funcion retorna;
# para entonces "tmp" (local a la funcion) ya fue destruida y `rm -f -- "$tmp"` revienta
# con "unbound variable" bajo `set -u` (verificado con el error real antes de este fix).
# Envolviendo el CUERPO en su propio `( ... )`, el trap vive y se dispara DENTRO de esa
# misma vida, con "tmp" siempre en alcance.
#
# LIMITE DOCUMENTADO (no defecto): Bash difiere la ejecucion de cualquier trap mientras
# esta bloqueado esperando a un hijo en primer plano (el propio `mv` externo) — una señal
# que llega mientras `mv` esta en marcha no lo interrumpe, el trap corre justo cuando `mv`
# termina por su cuenta. Si `mv` completa pese a la señal, el rename es atomico (nunca dej
# a el registro a medias) y no hay temporal residual (se movio); si `mv` muere el mismo,
# el propio `mv -f` devuelve rc!=0 y esta MISMA limpieza de EXIT se encarga igual.
_bootstrap_escribe_atomico() {
  local path="$1" contenido="$2"
  (
    local tmp="" rc
    # UNICO punto de limpieza: se dispara siempre, borra "tmp" solo si sigue pendiente.
    trap 'rc=$?; [ -n "$tmp" ] && rm -f -- "$tmp"; exit "$rc"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    tmp="$(mktemp "$(dirname -- "$path")/.bootstrap-trenes.XXXXXXXX")" || exit 94
    printf '%s' "$contenido" >"$tmp"
    rc=$?
    [ "$rc" -eq 0 ] || exit 95
    mv -f -- "$tmp" "$path"
    rc=$?
    [ "$rc" -eq 0 ] && tmp="" # exito: ya no hay temporal pendiente que limpiar.
    exit "$rc"
  )
}

# ---------------------------------------------------------------------------------------
# Cuerpos de las mutaciones publicas (se invocan SIEMPRE via _bootstrap_con_lock)
# ---------------------------------------------------------------------------------------

# _bootstrap_init_body <path>
# MAYOR 1 (code-gate r1): validar SOLO la cabecera con `head -n 1` da "exito" sobre una
# preimagen con cabecera correcta pero filas corruptas — el contrato exige validar la
# preimagen COMPLETA en TODA mutacion publica, init incluido.
_bootstrap_init_body() {
  local path="$1"
  if [ -f "$path" ]; then
    _bootstrap_valida_preimagen "$path" || return 93 # existe pero corrupto/cabecera ajena: no se toca
    return 0 # idempotente: ya inicializado y sano
  fi
  _bootstrap_escribe_atomico "$path" "$BOOTSTRAP_CABECERA"$'\n'
}

_bootstrap_upsert_body() {
  local path="$1" tren_id="$2" slug="$3" piezas="$4" head_shas="$5" armado_en="$6"
  local stale="0" # todo upsert arma el tren: nunca se inserta ya-stale.
  _bootstrap_valida_fila_campos "$tren_id" "$slug" "$piezas" "$head_shas" "$armado_en" "$stale" ||
    return 96
  _bootstrap_valida_preimagen "$path" || return 97

  local nueva_fila
  nueva_fila="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$tren_id" "$slug" "$piezas" "$head_shas" "$armado_en" "$stale")"

  local contenido="$BOOTSTRAP_CABECERA"$'\n'
  if [ -f "$path" ]; then
    local n=0 linea
    while IFS= read -r linea || [ -n "$linea" ]; do
      n=$((n + 1))
      [ "$n" -eq 1 ] && continue # cabecera, ya puesta arriba
      _bootstrap_parsea_fila "$linea"
      [ "$_F1" = "$tren_id" ] && continue # se sustituye por la nueva_fila, mas abajo
      contenido="${contenido}${linea}"$'\n'
    done <"$path"
  fi
  contenido="${contenido}${nueva_fila}"$'\n'
  _bootstrap_escribe_atomico "$path" "$contenido"
}

_bootstrap_marcar_stale_body() {
  local path="$1" tren_id="$2"
  _bootstrap_valida_preimagen "$path" || return 97
  [ -f "$path" ] || return 98 # sin fichero no hay tren que marcar

  local n=0 linea encontrado=0 contenido="$BOOTSTRAP_CABECERA"$'\n'
  while IFS= read -r linea || [ -n "$linea" ]; do
    n=$((n + 1))
    if [ "$n" -eq 1 ]; then continue; fi
    _bootstrap_parsea_fila "$linea"
    if [ "$_F1" = "$tren_id" ]; then
      encontrado=1
      contenido="${contenido}$(printf '%s\t%s\t%s\t%s\t%s\t1' "$_F1" "$_F2" "$_F3" "$_F4" "$_F5")"$'\n'
    else
      contenido="${contenido}${linea}"$'\n'
    fi
  done <"$path"
  [ "$encontrado" -eq 1 ] || return 98 # tren inexistente: rc!=0, CERO escritura de fila incompleta
  _bootstrap_escribe_atomico "$path" "$contenido"
}

# ---------------------------------------------------------------------------------------
# API publica — TODA pasa por _bootstrap_con_lock (mutaciones) o lee directo (bootstrap_leer,
# seguro sin lock porque `mv` es atomico: un lector siempre ve el fichero ENTERO viejo o
# ENTERO nuevo, nunca a medio escribir). Ninguna recibe el path como argumento — todas
# resuelven via `bootstrap_path()`.
# ---------------------------------------------------------------------------------------

bootstrap_init() {
  local path
  path="$(bootstrap_path)"
  _bootstrap_con_lock "$path" "${BOOTSTRAP_LOCK_TIMEOUT:-10}" _bootstrap_init_body "$path"
}

bootstrap_upsert() {
  local tren_id="$1" slug="$2" piezas="$3" head_shas="$4" armado_en="$5" path
  path="$(bootstrap_path)"
  _bootstrap_con_lock "$path" "${BOOTSTRAP_LOCK_TIMEOUT:-10}" _bootstrap_upsert_body \
    "$path" "$tren_id" "$slug" "$piezas" "$head_shas" "$armado_en"
}

bootstrap_marcar_stale() {
  local tren_id="$1" path
  path="$(bootstrap_path)"
  _bootstrap_con_lock "$path" "${BOOTSTRAP_LOCK_TIMEOUT:-10}" _bootstrap_marcar_stale_body \
    "$path" "$tren_id"
}

# _bootstrap_resuelve_idempotencia_body <path> <tren_id> <head_shas_actuales>
#
# MAYOR 1 (acta entrega-cero2-pasada-1, ronda posterior a code-gate r12): la version
# anterior de C3 (`resolve_idempotencia` en compose-resolve.sh) hacia `bootstrap_leer`
# (SIN lock) y, si los head_shas diferian, llamaba despues a `bootstrap_marcar_stale` (con
# su PROPIA adquisicion, distinta de la lectura). Entre esas dos llamadas, otro compositor
# podia hacer `bootstrap_upsert` y dejar la fila YA en el valor solicitado — el primer
# proceso marcaba entonces stale=1 sobre un tren que en realidad ya coincidia (reproducido
# de forma determinista por el auditor). Corregido haciendo TODA la decision — leer,
# comparar contra head_shas_actuales y, solo si siguen siendo distintos, escribir stale=1 —
# dentro de UNA SOLA adquisicion de `_bootstrap_con_lock`. No se llama a
# `bootstrap_marcar_stale` desde aqui (esa API vuelve a adquirir el mismo flock; anidar la
# adquisicion es la ruta que el propio auditor descarto explicitamente): esta funcion
# reimplementa el mismo escaneo+reescritura que `_bootstrap_marcar_stale_body`, pero como
# parte de una unica seccion critica que ya incluye la lectura y la comparacion.
_bootstrap_resuelve_idempotencia_body() {
  local path="$1" tren_id="$2" head_shas_actuales="$3"
  _bootstrap_valida_preimagen "$path" || return 97
  if [ ! -f "$path" ]; then
    printf 'nuevo\n'
    return 0
  fi

  local n=0 linea encontrado=0 head_shas_registrados=""
  while IFS= read -r linea || [ -n "$linea" ]; do
    n=$((n + 1))
    [ "$n" -eq 1 ] && continue
    _bootstrap_parsea_fila "$linea" || return 97
    if [ "$_F1" = "$tren_id" ]; then
      encontrado=1
      head_shas_registrados="$_F4"
      break
    fi
  done <"$path"

  if [ "$encontrado" -ne 1 ]; then
    printf 'nuevo\n'
    return 0
  fi
  if [ "$head_shas_registrados" = "$head_shas_actuales" ]; then
    printf 'ya-armado, no reemitir\n'
    return 0
  fi

  n=0
  local contenido="$BOOTSTRAP_CABECERA"$'\n'
  while IFS= read -r linea || [ -n "$linea" ]; do
    n=$((n + 1))
    [ "$n" -eq 1 ] && continue
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

# bootstrap_resuelve_idempotencia <tren_id> <head_shas_actuales>
# API atomica de C3: unico punto de entrada que un compositor debe usar para decidir si un
# tren es nuevo, ya esta armado al valor deseado, o quedo obsoleto. Imprime EXACTAMENTE una
# de `nuevo` | `ya-armado, no reemitir` | `stale: re-armado propuesto`; rc=0 en los tres
# casos. rc!=0 (con salida vacia, nunca un mensaje a medias) solo por fallo estructural:
# preimagen corrupta (97), fallo de `_bootstrap_con_lock` (90/91/75) o fallo de
# `_bootstrap_escribe_atomico` al marcar stale.
bootstrap_resuelve_idempotencia() {
  local tren_id="$1" head_shas_actuales="$2" path
  path="$(bootstrap_path)"
  _bootstrap_con_lock "$path" "${BOOTSTRAP_LOCK_TIMEOUT:-10}" _bootstrap_resuelve_idempotencia_body \
    "$path" "$tren_id" "$head_shas_actuales"
}

# bootstrap_leer <tren_id> -> imprime la fila (tab-separated) o rc=1 SI Y SOLO SI el
# fichero/tren_id genuinamente no existe en un registro SANO. Sin lock: lectura pura,
# segura por atomicidad de `mv` en la escritura.
#
# MAYOR 1 (code-gate r4, segunda pasada CERO×2): version anterior saltaba filas corruptas
# en silencio (`_bootstrap_parsea_fila || continue`) y devolvia el MISMO rc=1 tanto para
# "tren_id inexistente" como para "preimagen corrupta" — un registro truncado/con
# duplicados/con filas malformadas se leia como si el tren nunca hubiera existido.
# Corregido: se valida la preimagen COMPLETA antes de buscar, con un rc DISTINTO (97,
# mismo codigo de "preimagen invalida" que usan upsert/marcar_stale) para corrupcion —
# rc=1 queda reservado EXCLUSIVAMENTE para fichero/tren_id realmente ausentes.
bootstrap_leer() {
  local tren_id="$1" path linea
  path="$(bootstrap_path)"
  [ -f "$path" ] || return 1
  _bootstrap_valida_preimagen "$path" || return 97
  local n=0
  while IFS= read -r linea || [ -n "$linea" ]; do
    n=$((n + 1))
    [ "$n" -eq 1 ] && continue
    _bootstrap_parsea_fila "$linea" || return 97 # no deberia ocurrir tras la validacion; fail-closed de todos modos.
    if [ "$_F1" = "$tren_id" ]; then
      printf '%s\n' "$linea"
      return 0
    fi
  done <"$path"
  return 1
}
