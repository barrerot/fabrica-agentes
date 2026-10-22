#!/usr/bin/env bash
# compose-resolve.sh — anclaje de veredictos, descriptor cross-repo y orden topologico para
# el compositor de trenes (TAL-5383 · A2).
#
# Cierra el contrato C1-C4 de TAL-5301 para el consumidor A2: un veredicto (acta de
# auditoria) solo autoriza un head si su SHA es EXACTAMENTE el tip actual (igualdad, no solo
# ancestro) — `ahead` (el veredicto es un ancestro antiguo) NUNCA se acepta como ANCLADO,
# porque eso autorizaria codigo anadido DESPUES de la auditoria.
#
# Todo acceso a `gh`/`git` pasa por `_resolve_llamar_guard`, que reenvia a
# `dry-run-guard.sh` (A1/TAL-5382) — NUNCA se invoca `git`/`gh` directo desde este fichero.
# El DoD de esta pieza exige comprobar que no existe ninguna invocacion directa; ver
# tests/scripts/resolve-canarios.sh, seccion "sin invocacion directa".
set -uo pipefail

# ---------------------------------------------------------------------------------------
# Indireccion UNICA hacia el guard. Los canarios REDEFINEN esta funcion para inyectar
# respuestas deterministas sin red y sin necesitar el guard real en disco — no es una
# reimplementacion de su logica de permisos, es el unico punto de paso hacia gh/git.
# ---------------------------------------------------------------------------------------
_resolve_llamar_guard() {
  local guard_path="$1"
  shift
  "$guard_path" "$@"
}

# _resolve_gh_json <errfile> <guard_path> <args...>
# Imprime stdout por stdout y propaga el rc real; el stderr se redirige al FICHERO que pasa
# el llamador (creado por el llamador con `mktemp` ANTES de esta llamada). Una variable
# global NO sirve aqui: esta funcion se invoca casi siempre como `x=$(_resolve_gh_json ...)`,
# y cualquier asignacion hecha DENTRO de un subshell de `$( )` desaparece en cuanto ese
# subshell termina — el fichero es la unica via que sobrevive al cruce de subshell.
_resolve_gh_json() {
  local errfile="$1" guard_path="$2"
  shift 2
  _resolve_llamar_guard "$guard_path" "$@" 2>"$errfile"
}

# ---------------------------------------------------------------------------------------
# Gramatica: owner/repo, PR, rama (parcial — ver PRECONDICION en resolve_valida_rama_basica)
# ---------------------------------------------------------------------------------------

resolve_valida_owner_repo() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$ ]]; }
resolve_valida_pr() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

# resolve_valida_rama_basica <rama>
# Las DOS guardas que `git check-ref-format` en modo ref-completa NO cubre (medido y
# confirmado por el auditor en r4): una rama vacia, y una rama que empieza por `-` se
# aceptarian como ref completa aunque `--branch` las rechazaria. Estas dos SI son
# responsabilidad de A2, sin necesitar ninguna autoridad externa.
resolve_valida_rama_basica() {
  local rama="${1:-}"
  [ -n "$rama" ] || return 1
  case "$rama" in
    -*) return 1 ;;
  esac
  return 0
}

# resolve_codifica_uri <valor> — encoding porcentual RFC 3986 COMPLETO (no solo `/`).
resolve_codifica_uri() {
  jq -rn --arg v "$1" '$v|@uri'
}

# resolve_descriptor_de_string <descriptor>
# Parsea `owner/repo#N` (modo pr) o `owner/repo:rama` (modo rama). Imprime
# `owner<TAB>repo<TAB>modo<TAB>valor`; rc=1 si cualquier componente falla su gramatica.
# Owner/repo se mantienen como campos SEPARADOS en todo momento — nunca se recomponen a un
# string para volver a parsearlo.
#
# MAYOR 2 (code-gate r1): modo `rama` NO puede publicarse como descriptor VALIDO (rc=0)
# mientras `resolve_valida_rama_basica` sea solo una validacion PARCIAL (vacio/guion
# inicial) — un consumidor que solo mira "rc=0 => descriptor bueno" persistiria identidad
# invalida antes de que `resolve_verificar_anclaje` la rechace. Por eso, para modo `rama`,
# esta funcion devuelve la MISMA precondicion (rc=97) que `resolve_verificar_anclaje`,
# DESPUES de aplicar las validaciones propias (owner/repo, vacio/guion) — un descriptor
# rama que falla esas SI es rc=1 (basura real); uno que las pasa pero no tiene gramatica de
# git completa es rc=97 (pendiente, no publicado como valido).
#
# MAYOR 1 (code-gate r6, segunda pasada CERO×2): `#` es un caracter VALIDO dentro de una
# ref de git (contrato sellado: se codifica `%23`, no se rechaza — ver resolve_codifica_uri
# y la matriz de r4/r5), pero `:` NUNCA es valido dentro de una ref. El orden de deteccion
# IMPORTA: comprobar `#` antes que `:` hacia que `owner/repo:feat/x#frag` (rama valida con
# `#`) se leyera como modo PR (`repo:feat/x` como "repo", `frag` como "numero"), rechazado
# con rc=1 en vez de la precondicion rc=97 que le corresponde. Corregido: `:` se comprueba
# PRIMERO — es un separador inequivoco (nunca aparece dentro de una rama real) — y `#` solo
# se considera si NO hay `:` en absoluto. Esto tambien resuelve el negativo inverso
# (`owner/repo#47:extra`): al haber `:`, se interpreta como candidato a rama con
# repo="repo#47", que falla su propia gramatica (rc=1) sin reinterpretarse como PR.
resolve_descriptor_de_string() {
  local descriptor="${1:-}" owner repo resto modo valor
  case "$descriptor" in
    */*'#'*) : ;;
    */*':'*) : ;;
    *) return 1 ;;
  esac
  owner="${descriptor%%/*}"
  resto="${descriptor#*/}"
  case "$resto" in
    *':'*)
      repo="${resto%%:*}"
      valor="${resto#*:}"
      modo="rama"
      resolve_valida_rama_basica "$valor" || return 1
      resolve_valida_owner_repo "$owner" || return 1
      resolve_valida_owner_repo "$repo" || return 1
      return 97 # PRECONDICION: gramatica de git completa pendiente de A1, no se publica.
      ;;
    *'#'*)
      repo="${resto%%#*}"
      valor="${resto#*#}"
      modo="pr"
      resolve_valida_pr "$valor" || return 1
      resolve_valida_owner_repo "$owner" || return 1
      resolve_valida_owner_repo "$repo" || return 1
      printf '%s\t%s\t%s\t%s\n' "$owner" "$repo" "$modo" "$valor"
      return 0
      ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------------------
# Anclaje C1-C4: tabla de decision con igualdad EXACTA, no solo ancestro.
# ---------------------------------------------------------------------------------------

# resolve_verificar_anclaje <guard_path> <modo:pr|rama> <owner> <repo> <valor> <veredicto_sha>
# Salida (rc=0 en los TRES casos — la etiqueta ES el resultado correcto de una consulta que
# SI funciono): ANCLADO | VEREDICTO-AJENO | VEREDICTO-CADUCO.
# rc!=0 (ERROR OPERACIONAL o uso invalido) en cualquier otro caso — NUNCA se convierte un
# fallo de red/auth/rate-limit/JSON/PRECONDICION en una de las tres etiquetas.
#
# PRECONDICION NO SATISFECHA (modo rama): construir la URL de `branches/<rama>` exige
# validar la rama con la autoridad real de git (`check-ref-format`, que cubre `~ ^ : ? * [
# \ @{ // .lock` entre otros — ver r3/r4 del plan-gate), invocada EXCLUSIVAMENTE a traves
# de `dry-run-guard.sh` una vez A1 (TAL-5382/#47) incorpore ese par a su lista blanca.
# Dueño: A1/ch41. Como se obtiene: fusion acreditada de A1 + firma exacta del coordinador.
# Caducidad: al recibir esa firma, se sustituye este bloque por la llamada real — NUNCA se
# inventa la sintaxis mientras tanto. Por eso el modo `rama` falla aqui con rc=97, ANTES de
# tocar el guard, en vez de fabricar una URL sin la validacion de gramatica completa.
resolve_verificar_anclaje() {
  local guard_path="$1" modo="$2" owner="$3" repo="$4" valor="$5" veredicto_sha="$6"

  case "$modo" in pr | rama) : ;; *) return 2 ;; esac
  resolve_valida_owner_repo "$owner" || return 2
  resolve_valida_owner_repo "$repo" || return 2
  [[ "$veredicto_sha" =~ ^[0-9a-f]{40}$ ]] || return 2

  local sha_head=""
  case "$modo" in
    pr)
      resolve_valida_pr "$valor" || return 2
      local out rc errfile
      errfile="$(mktemp)" || return 99
      out="$(_resolve_gh_json "$errfile" "$guard_path" gh api "repos/$owner/$repo/pulls/$valor" --jq '.head.sha')"
      rc=$?
      rm -f "$errfile"
      [ "$rc" -eq 0 ] || return 3 # ERROR OPERACIONAL: red/auth/rate-limit/404-del-PR-mismo/JSON invalido
      [[ "$out" =~ ^[0-9a-f]{40}$ ]] || return 3 # JSON valido pero campo inesperado: no se adivina
      sha_head="$out"
      ;;
    rama)
      resolve_valida_rama_basica "$valor" || return 2
      return 97 # PRECONDICION NO SATISFECHA — ver comentario de arriba, no se inventa la llamada.
      ;;
  esac

  if [ "$veredicto_sha" = "$sha_head" ]; then
    printf 'ANCLADO\n'
    return 0
  fi

  local estado crc errfile2 errcontenido
  errfile2="$(mktemp)" || return 99
  estado="$(_resolve_gh_json "$errfile2" "$guard_path" gh api "repos/$owner/$repo/compare/$veredicto_sha...$sha_head" --jq '.status')"
  crc=$?
  errcontenido="$(cat "$errfile2" 2>/dev/null)"
  rm -f "$errfile2"
  if [ "$crc" -ne 0 ]; then
    # Forma especifica "HTTP 404" (la que `gh api` imprime de verdad), no un grep amplio de
    # '404': un error operacional cuya URL/mensaje contenga esos digitos por casualidad NO
    # debe clasificarse como AJENO (sugerencia del code-gate r1).
    if grep -q 'HTTP 404' <<<"$errcontenido"; then
      printf 'VEREDICTO-AJENO\n' # 404 del commit del veredicto en el compare: no pertenece a este repo/head.
      return 0
    fi
    return 3 # cualquier otro fallo del compare: ERROR OPERACIONAL, nunca una etiqueta.
  fi

  case "$estado" in
    ahead)
      printf 'VEREDICTO-AJENO\n'
      return 0
      ;;
    behind | diverged)
      printf 'VEREDICTO-CADUCO\n'
      return 0
      ;;
    *) return 3 ;; # status desconocido/JSON inesperado: no se adivina, ERROR OPERACIONAL.
  esac
}

# ---------------------------------------------------------------------------------------
# Orden topologico (Kahn estable) sobre el grafo simple added->modified.
# ---------------------------------------------------------------------------------------

# _resolve_valida_pieza_id <pieza>
# MAYOR 3 (code-gate r1): las aristas se guardan como string separado por espacios e se
# iteran con `for dep in $edges` — sin gramatica, una pieza con whitespace o con
# metacaracteres de glob (`*`, `?`, `[`) se particiona o se expande contra el filesystem al
# iterar, corrompiendo nodos/indegrees silenciosamente. Misma familia de caracteres que se
# excluyen en owner/repo/tren_id — mantiene la representacion string-con-espacios SEGURA
# sin reescribirla a un array anidado.
_resolve_valida_pieza_id() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$ ]]; }

# _resolve_lee_filas_grafo <tsv_path> — imprime `pieza<TAB>status<TAB>path` validadas, una
# por linea, o no imprime nada y devuelve rc!=0 si CUALQUIER fila es invalida (fail-closed:
# cero salida parcial ante input malformado).
_resolve_lee_filas_grafo() {
  local tsv="$1" nf pieza status path
  local -a filas=()
  while IFS= read -r linea || [ -n "$linea" ]; do
    [ -n "$linea" ] || continue
    nf="$(awk -F'\t' '{print NF; exit}' <<<"$linea")"
    [ "$nf" -eq 3 ] || return 1
    pieza="$(awk -F'\t' '{print $1}' <<<"$linea")"
    status="$(awk -F'\t' '{print $2}' <<<"$linea")"
    path="$(awk -F'\t' '{print $3}' <<<"$linea")"
    _resolve_valida_pieza_id "$pieza" || return 1
    [ -n "$path" ] || return 1
    case "$status" in added | modified) : ;; *) return 1 ;; esac
    filas+=("$pieza"$'\t'"$status"$'\t'"$path")
  done <"$tsv"
  [ "${#filas[@]}" -ge 1 ] || return 1
  printf '%s\n' "${filas[@]}"
}

# resolve_orden_topologico <tsv_path>
# Imprime una pieza por linea, en orden topologico ESTABLE (desempate por orden de primera
# aparicion en el input). rc!=0 y CERO salida ante: productor doble (mismo path anadido por
# mas de una fila), ciclo (incluido self-cycle: una pieza que anade Y modifica el mismo
# path), o TSV malformado.
resolve_orden_topologico() {
  local tsv="$1"
  local filas
  filas="$(_resolve_lee_filas_grafo "$tsv")" || return 1

  local -A productor_de=()
  local -a orden_piezas=()
  local -A vista_pieza=()
  local -A edges_de=() # edges_de[P] = lista de dependientes de P, separada por espacios
  local -A indegree=()

  local fila pieza status path
  while IFS= read -r fila; do
    [ -n "$fila" ] || continue
    pieza="$(awk -F'\t' '{print $1}' <<<"$fila")"
    status="$(awk -F'\t' '{print $2}' <<<"$fila")"
    path="$(awk -F'\t' '{print $3}' <<<"$fila")"
    if [ -z "${vista_pieza[$pieza]+x}" ]; then
      vista_pieza[$pieza]=1
      orden_piezas+=("$pieza")
      indegree[$pieza]=0
      edges_de[$pieza]=""
    fi
    if [ "$status" = "added" ]; then
      if [ -n "${productor_de[$path]+x}" ]; then
        return 1 # productor doble: este path ya tiene productor (misma pieza u otra).
      fi
      productor_de[$path]="$pieza"
    fi
  done <<<"$filas"

  while IFS= read -r fila; do
    [ -n "$fila" ] || continue
    pieza="$(awk -F'\t' '{print $1}' <<<"$fila")"
    status="$(awk -F'\t' '{print $2}' <<<"$fila")"
    path="$(awk -F'\t' '{print $3}' <<<"$fila")"
    if [ "$status" = "modified" ] && [ -n "${productor_de[$path]+x}" ]; then
      local prod="${productor_de[$path]}"
      edges_de[$prod]="${edges_de[$prod]} $pieza"
      indegree[$pieza]=$((indegree[$pieza] + 1))
    fi
  done <<<"$filas"

  # Kahn ESTABLE por prioridad de indice de entrada (MAYOR 3, code-gate r1): una FIFO
  # simple de "momento en que se vuelve disponible" NO es estable — un nodo que aparece
  # PRIMERO en el input pero se libera DESPUES (porque dependia de otro) debe salir antes
  # que un nodo independiente que aparecio despues, si ambos estan disponibles a la vez.
  # Por eso en CADA paso se re-escanea el conjunto de disponibles (indegree=0, no emitido
  # aun) y se elige SIEMPRE el de menor indice original — no el primero en entrar a una
  # cola. Con pocas piezas por tren, el escaneo O(n^2) es irrelevante en coste.
  local -a salida=()
  local -A emitido=()
  local i n_piezas=${#orden_piezas[@]} paso p elegido_idx elegido dep
  for ((paso = 0; paso < n_piezas; paso++)); do
    elegido_idx=-1
    elegido=""
    for ((i = 0; i < n_piezas; i++)); do
      p="${orden_piezas[$i]}"
      [ -n "${emitido[$p]+x}" ] && continue
      if [ "${indegree[$p]}" -eq 0 ]; then
        elegido_idx="$i"
        elegido="$p"
        break # primer disponible en orden de indice == el de menor indice, por construccion.
      fi
    done
    [ "$elegido_idx" -ge 0 ] || break # ningun disponible: ciclo — se sale del bucle, salida queda incompleta.
    emitido[$elegido]=1
    salida+=("$elegido")
    for dep in ${edges_de[$elegido]}; do
      indegree[$dep]=$((indegree[$dep] - 1))
    done
  done

  [ "${#salida[@]}" -eq "${#orden_piezas[@]}" ] || return 1 # ciclo (incluye self-cycle): cero salida parcial.
  printf '%s\n' "${salida[@]}"
}

# ---------------------------------------------------------------------------------------
# C2 — estado de pieza: envuelve el anclaje en la etiqueta de trazabilidad "esperando GO".
# ---------------------------------------------------------------------------------------

# resolve_estado_pieza <guard_path> <modo> <owner> <repo> <valor> <veredicto_sha>
# Envuelve `resolve_verificar_anclaje`: ANCLADO se propaga tal cual; VEREDICTO-AJENO y
# VEREDICTO-CADUCO se traducen a la etiqueta literal exacta `esperando GO: <razon>` (C2),
# para que un consumidor (compose-trains.sh, pieza B) trate ambos casos como "no anclado
# todavia, no autorizado" sin tener que conocer la distincion AJENO/CADUCO el mismo. rc!=0
# (uso invalido/ERROR OPERACIONAL/PRECONDICION) se propaga sin traducir — nunca se convierte
# un fallo de la consulta en un estado de trazabilidad.
resolve_estado_pieza() {
  local resultado rc
  resultado="$(resolve_verificar_anclaje "$@")"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  case "$resultado" in
    ANCLADO)
      printf 'ANCLADO\n'
      return 0
      ;;
    VEREDICTO-AJENO | VEREDICTO-CADUCO)
      printf 'esperando GO: %s\n' "$resultado"
      return 0
      ;;
    *) return 3 ;; # etiqueta desconocida — defensivo, no deberia ocurrir tras resolve_verificar_anclaje.
  esac
}

# ---------------------------------------------------------------------------------------
# C3 — idempotencia: no reemitir un tren ya armado con las mismas piezas.
# ---------------------------------------------------------------------------------------

# resolve_idempotencia <tren_id> <piezas_head_shas_actuales>
# Requiere que el LLAMADOR haya cargado `compose-bootstrap.sh`
# (`bootstrap_resuelve_idempotencia`) — este fichero no se auto-source a si mismo otra
# libreria, cada lib se compone desde fuera (mismo patron que el resto de A2). Fail-closed
# si falta. Salida: `nuevo` (el tren_id no existe todavia en el registro) | `ya-armado, no
# reemitir` (existe y los head_shas coinciden byte a byte) | `stale: re-armado propuesto`
# (existe y difieren — NUNCA re-arma ella sola: solo propone).
#
# MAYOR 1 (acta entrega-cero2-pasada-1): esta funcion solia hacer `bootstrap_leer` (sin
# lock) y, si diferia, `bootstrap_marcar_stale` (con su PROPIA adquisicion) — dos
# secciones criticas separadas con una ventana de interleaving real entre ambas (ver el
# comentario extenso en `compose-bootstrap.sh` junto a `_bootstrap_resuelve_idempotencia_body`).
# Ahora es un passthrough puro a `bootstrap_resuelve_idempotencia`, que hace todo el
# read+compare+write bajo UNA sola adquisicion del lock — cierra el TOCTOU de raiz en vez
# de enumerar casos. Como efecto secundario, esto tambien retira el patron `if !` que aqui
# habia reincidido dos veces en esta misma libreria (code-gate r4 en `identity_issues_de_body`
# y en esta funcion): ya no hay una condicion negada que capturar mal, porque no queda
# ninguna.
resolve_idempotencia() {
  local tren_id="$1" head_shas_actuales="$2"
  command -v bootstrap_resuelve_idempotencia >/dev/null 2>&1 || return 90 # compose-bootstrap.sh no cargado.
  bootstrap_resuelve_idempotencia "$tren_id" "$head_shas_actuales"
}

# ---------------------------------------------------------------------------------------
# C4 — smoke de consumo real del guard: prueba que A2 CONSUME dry-run-guard.sh, no que lo
# reimplementa ni que lo bordea.
# ---------------------------------------------------------------------------------------

# resolve_c4_smoke <guard_path>
# Invoca UN subcomando mutante CONOCIDO (`git checkout`, que NO esta en la lista blanca de
# A1 — par:3 "no permitido") a traves del guard y exige rc=3 exacto. Si el guard esta
# ausente, no es ejecutable, o de alguna forma permite `checkout` (bifurcado/bypaseado),
# esta funcion falla — es la señal en tiempo de ejecucion de que alguien rompio el contrato
# C4 (A2 consume el guard real, nunca una copia ni un atajo).
resolve_c4_smoke() {
  local guard_path="$1" rc
  [ -n "$guard_path" ] || return 2
  [ -x "$guard_path" ] || return 90 # guard ausente/no ejecutable: no se puede probar el consumo.
  _resolve_llamar_guard "$guard_path" git checkout >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 3 ] || return 1 # se esperaba par:3 (no permitido); cualquier otra cosa es la señal de bypass.
  return 0
}
