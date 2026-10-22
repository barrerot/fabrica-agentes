#!/usr/bin/env bash
# lib/runner-identity.sh — identidad canónica de runners + filtro RUNNING exacto (TAL-5196 E1).
#
# Cierra el sobre-despacho INTRA-invocación (rg2118: N gates al mismo runner físico desde UNA
# invocación de seal-suite.sh): una lista de runners con duplicados/alias del mismo físico, o
# con runners caídos contados como capacidad, hace que el round-robin trate slots distintos
# como si fueran runners distintos. Este módulo NO toca coordinación CROSS-invocación (dos
# suites concurrentes al mismo runner) — eso queda fuera de alcance, ver follow-on TAL-5249.
#
# Contrato del mapa (manifiestos/runner-identity.map, o TF_RUNNER_IDENTITY_MAP): líneas
# `alias=host_canonico`, gramática CERRADA — ambos tokens deben matchear
# `^[A-Za-z0-9._-]+$` (charset típico de hostname/IP; rechaza espacios internos, `=`
# adicionales, etc. — cierra la gramática laxa detectada en auditoría), sin `source`,
# fail-closed ante malformado o alias duplicado con host DISTINTO. El centinela
# `RI_PENDING_ROLLOUT` es una identidad EXPLÍCITAMENTE NO-REAL: `ri_load_map` la rechaza
# siempre (cierra la aceptación de un placeholder sembrado sin editar, detectada en
# auditoría) — el operador del rollout DEBE reemplazarla por el host real antes de que
# cualquier alias que la use resuelva. FASE 1 admite EXCLUSIVAMENTE proyecto Incus "default".
set -uo pipefail

RI_PENDING_ROLLOUT="RI_PENDING_ROLLOUT"
ri_die() { echo "[runner-identity] ERROR: $*" >&2; exit 2; }
ri_token_ok() { case "$1" in *[!A-Za-z0-9._-]*|'') return 1;; *) return 0;; esac; }

# Resuelve la ruta del mapa: override explícito, o colocado junto al manifiesto en uso.
ri_map_path() { # <manifest_path>
  if [ -n "${TF_RUNNER_IDENTITY_MAP:-}" ]; then
    printf '%s\n' "$TF_RUNNER_IDENTITY_MAP"
  else
    printf '%s\n' "$(dirname "$1")/runner-identity.map"
  fi
}

# Carga el mapa en el array asociativo global RI_ALIAS_TO_HOST. Fail-closed: no legible,
# vacío, línea malformada o alias contradictorio (mismo alias, host distinto) → die.
ri_load_map() { # <manifest_path>
  local map; map="$(ri_map_path "$1")"
  [ -r "$map" ] || ri_die "mapa de identidad no legible: $map (rollout pendiente — ver runner-identity.map)"
  declare -gA RI_ALIAS_TO_HOST=()
  local line lineno=0 body alias host
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    body="${line%%#*}"
    body="$(printf '%s' "$body" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$body" ] || continue
    case "$body" in
      *=*) alias="${body%%=*}"; host="${body#*=}" ;;
      *) ri_die "$map:$lineno: línea malformada (esperado alias=host_canonico): $line" ;;
    esac
    # Gramática CERRADA (cierra MAYOR 1 de auditoría): ambos tokens deben ser EXACTAMENTE
    # un identificador de charset hostname/IP — un segundo "=" (alias=host=extra), espacios
    # internos, o cualquier otro carácter fuera de [A-Za-z0-9._-] mueren aquí, en vez de
    # colarse como "resuelto" y fallar más tarde como un SSH roto indistinguible de un
    # host caído de verdad.
    ri_token_ok "$alias" || ri_die "$map:$lineno: alias con caracteres inválidos (charset hostname/IP: [A-Za-z0-9._-]): $line"
    ri_token_ok "$host" || ri_die "$map:$lineno: host_canonico con caracteres inválidos o vacío/multi-'=' (charset hostname/IP: [A-Za-z0-9._-]): $line"
    if [ -n "${RI_ALIAS_TO_HOST[$alias]:-}" ] && [ "${RI_ALIAS_TO_HOST[$alias]}" != "$host" ]; then
      ri_die "$map:$lineno: alias '$alias' CONTRADICTORIO (ya='${RI_ALIAS_TO_HOST[$alias]}', nuevo='$host') — fail-closed"
    fi
    RI_ALIAS_TO_HOST[$alias]="$host"
  done < "$map"
  [ "${#RI_ALIAS_TO_HOST[@]}" -gt 0 ] || ri_die "$map: mapa vacío tras parsear"
}

# Fail-closed ante el centinela de rollout pendiente (cierra BLOQUEANTE 2 de auditoría: el
# preflight aceptaba un placeholder sembrado sin editar como si fuera identidad real). Un
# alias resuelto al centinela NUNCA cuenta como resoluble, aunque el mapa lo tenga declarado
# y la sintaxis sea válida — la sintaxis válida no es lo mismo que una identidad real.
ri_require_real_host() { # <alias> <host_canonico>
  [ "$2" != "$RI_PENDING_ROLLOUT" ] || ri_die "identidad PENDIENTE DE ROLLOUT: el alias '$1' apunta al centinela $RI_PENDING_ROLLOUT — sustitúyelo por el host físico real en runner-identity.map (o TF_RUNNER_IDENTITY_MAP) antes de activar esto en producción"
}

# Resuelve UN spec de runner a "canonical_tuple<TAB>executable_spec". El executable_spec es
# el spec ORIGINAL (sin tocar) — es el único alcanzable por slate_exec/run_one; la tupla
# canónica es SOLO para identidad/dedup, nunca se usa para transporte (cierra M2 r7).
ri_resolve_spec() { # <spec> <station_alias>
  local spec="$1" station="$2" host_alias contenedor host_canon slashes
  case "$spec" in
    */*)
      slashes="$(printf '%s' "$spec" | tr -cd '/' | wc -c)"
      [ "$slashes" -eq 1 ] || ri_die "spec con formato inválido (más de un '/'): $spec"
      host_alias="${spec%%/*}"; contenedor="${spec#*/}"
      ;;
    *) host_alias="$station"; contenedor="$spec" ;;
  esac
  [ -n "$contenedor" ] || ri_die "spec sin nombre de contenedor: $spec"
  host_canon="${RI_ALIAS_TO_HOST[$host_alias]:-}"
  [ -n "$host_canon" ] || ri_die "alias de host no resoluble contra el mapa de identidad: '$host_alias' (spec: $spec) — añadirlo en runner-identity.map"
  ri_require_real_host "$host_alias" "$host_canon"
  # FASE 1: proyecto Incus fijo "default" (restricción declarada; multi-proyecto = follow-up).
  printf '%s:default:%s\t%s\n' "$host_canon" "$contenedor" "$spec"
}

# Consulta EXACTA de estado (cierra M1 r7): exige UNA sola fila cuyo nombre == contenedor Y
# estado == RUNNING. Un match por prefijo (p.ej. "incus list nombre-parcial") NO basta: puede
# aceptar otro contenedor o devolver varias filas. rc=0 ⟺ RUNNING confirmado; rc!=0 en
# cualquier otro caso (ausente, parado, múltiples filas, error de inspección/transporte).
#
# TRANSPORTE = el ALIAS LITERAL del spec, NUNCA el host_canónico (cierra BLOQUEANTE 1 de
# auditoría): la identidad canónica es SOLO para dedup, nunca sustituye el transporte real.
# Dos aliases que colapsan a la MISMA tupla física pueden tener alcanzabilidad DISTINTA
# (uno con la ruta de red/DNS rota, el otro viva) — sondear por el canónico compartido haría
# que un candidato inalcanzable pase el probe "prestado" de otro alias sano, y luego la
# ejecución real fallaría con el spec conservado. El probe debe reflejar el transporte
# CONCRETO de ESTE candidato, no el de "algún" alias que apunte al mismo físico.
ri_check_running() { # <spec> <station_alias>
  local spec="$1" station="$2" host_alias contenedor out n name status is_remote
  case "$spec" in
    */*) host_alias="${spec%%/*}"; contenedor="${spec#*/}"; is_remote=1 ;;
    *) host_alias="$station"; contenedor="$spec"; is_remote=0 ;;
  esac
  # Local/remoto se decide por la SINTAXIS del spec (presencia de '/'), EXACTAMENTE igual
  # que slate_exec en seal-suite.sh — NUNCA comparando el alias resultante con la estación
  # (cierra un segundo caso del mismo BLOQUEANTE de auditoría: un spec CON '/' cuyo alias
  # literal coincide con TF_STATION_HOST, p.ej. "station/vibe-r9", se sondearía por Incus
  # local aunque la ejecución real de ESE spec vaya siempre por SSH porque tiene '/').
  if [ "$is_remote" -eq 0 ]; then
    out="$(incus list --format csv -c ns "^${contenedor}\$" 2>/dev/null)" || return 1
  else
    out="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$host_alias" \
      "incus list --format csv -c ns $(printf '%q' "^${contenedor}\$")" 2>/dev/null)" || return 1
  fi
  n="$(printf '%s\n' "$out" | grep -c .)"
  [ "$n" -eq 1 ] || return 1
  IFS=',' read -r name status <<<"$out"
  [ "$name" = "$contenedor" ] && [ "$status" = "RUNNING" ]
}

# Normaliza un array de specs: identidad -> (opcional) filtro RUNNING -> dedup por tupla
# física, preservando orden y conservando DETERMINISTA el primer executable_spec vivo de
# cada tupla (cierra C1/C2/C1b/M1/M2). Con SKIP_LIVE=1 (modo --plan) NO toca red: asume
# vivos todos los que resuelven identidad (dry-run puro). Escribe el resultado deduplicado
# en el array global RI_RESULT (uso: declare -a RI_RESULT=(); ri_normalize_runners ...).
ri_normalize_runners() { # <station_alias> <skip_live:0|1> <spec...>
  local station="$1" skip_live="$2"; shift 2
  local -A seen_tuples=()
  RI_RESULT=()
  local spec pair tuple
  for spec in "$@"; do
    pair="$(ri_resolve_spec "$spec" "$station")" || exit 2
    tuple="${pair%%$'\t'*}"
    if [ "$skip_live" != "1" ]; then
      if ! ri_check_running "$spec" "$station"; then
        echo "[runner-identity] runner NO-RUNNING (descartado): $spec" >&2
        continue
      fi
    fi
    if [ -n "${seen_tuples[$tuple]:-}" ]; then
      echo "[runner-identity] runner duplicado (misma identidad física que ${seen_tuples[$tuple]}, descartado): $spec" >&2
      continue
    fi
    seen_tuples[$tuple]="$spec"
    RI_RESULT+=("$spec")
  done
}
