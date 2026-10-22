#!/usr/bin/env bash
# compose-identity.sh — identidad de piezas para el compositor de trenes (TAL-5383 · A2).
#
# Dos responsabilidades, ambas sin tocar git/gh/red: extraer que issues cierra un PR (para
# saber que <CLAVE>-N acredita cada pieza) y decidir si dos issues pertenecen al MISMO dominio
# (proyecto Linear) para poder agruparlas en un tren. `compose-trains.sh` (pieza B) consume
# estas funciones; este fichero no decide particion ni exclusiones — eso es de B.
set -uo pipefail

# identity_linear_key — clave del team Linear de la INSTANCIA (TAL-8037): jamás un default de casa. Resolución
# FAIL-CLOSED: env TF_LINEAR_TEAM_KEY → línea TF_LINEAR_TEAM_KEY= del manifiesto TF_MANIFEST (ruta absoluta, leída
# como DATO) → rc 2 nombrando la variable. Formato ^[A-Z][A-Z0-9]{0,9}$ (también el del env). Imprime la clave.
identity_linear_key() {
  local key="${TF_LINEAR_TEAM_KEY:-}" mf="${TF_MANIFEST:-}"
  if [ -z "$key" ] && [ -n "$mf" ] && [ -f "$mf" ]; then
    key="$(sed -n -E 's/^TF_LINEAR_TEAM_KEY=("([^"]*)"|([^[:space:]"#]*)).*$/\2\3/p' "$mf" | tail -1)"
  fi
  [ -n "$key" ] || { echo "compose-identity: TF_LINEAR_TEAM_KEY sin resolver (ni env ni línea del manifiesto TF_MANIFEST) — fail-closed" >&2; return 2; }
  [[ $key =~ ^[A-Z][A-Z0-9]{0,9}$ ]] || { echo "compose-identity: TF_LINEAR_TEAM_KEY inválida ('$key'): se espera ^[A-Z][A-Z0-9]{0,9}$" >&2; return 2; }
  printf '%s' "$key"
}

# identity_issues_de_body <body>
# Extrae los <CLAVE>-N que un cuerpo de PR cierra via closes/fixes/resolves (case-insensitive),
# normalizados a mayusculas y deduplicados. Cero cierres es un resultado VALIDO: salida
# vacia, rc=0 — no es un error. Cualquier fallo real del extractor (rc distinto de "no
# matches") se propaga tal cual, nunca se convierte en exito silencioso.
identity_issues_de_body() {
  local body="${1:-}" primeros rc key
  key="$(identity_linear_key)" || return $?   # sin clave del team no hay qué extraer: fail-closed (rc 2)
  # OJO: la condicion NO lleva `!`. Dentro de `if ! comando; then`, `$?` es el resultado de
  # la NEGACION, no el de `comando` — asi es como un `grep` con rc=2 (regex invalida real)
  # se colaba como rc=0. Con `if comando; then :; else rc=$?; ...; fi` el `$?` del `else` es
  # el rc REAL del comando que fallo.
  if primeros=$(grep -Eio "\\b(closes|fixes|resolves)[[:space:]]+#?${key}-[0-9]+\\b" <<<"$body"); then
    :
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then
      return 0 # cero cierres: salida vacia, exito real, NO un fallo del pipeline.
    fi
    return "$rc" # rc real de grep (2 = uso invalido, u otro): se propaga, nunca se oculta.
  fi
  grep -Eio "${key}-[0-9]+" <<<"$primeros" | tr '[:lower:]' '[:upper:]' | sort -u
}

# identity_dominio_de_issue_json <issue_json>
# Imprime `.project.name` si es un string no vacio; rc!=0 en cualquier otro caso (JSON
# invalido, `.project` ausente/null, `.project.name` ausente/null/vacio/no-string). `-r`
# evita que el dominio salga entre comillas; `-e` hace que "no hay valor" sea rc!=0, no una
# cadena vacia interpretada como exito.
identity_dominio_de_issue_json() {
  local issue_json="${1:-}"
  jq -er '(.project.name? // empty) | select(type=="string" and length>0)' <<<"$issue_json"
}

# identity_mismo_dominio <a> <b>
# rc=0 (verdadero) UNICAMENTE si ambos son strings no vacios e identicos. Dos dominios
# vacios NUNCA son "el mismo dominio" — sin esta guarda, dos issues sin proyecto Linear se
# tratarian como si compartieran dominio, agrupando piezas sin acreditar juntas (fail-open).
identity_mismo_dominio() {
  local a="${1:-}" b="${2:-}"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" = "$b" ]
}
