#!/usr/bin/env bash
# lib/carveout.sh — clasificador fail-closed docs-only/skills-only (TAL-2749).
#
# Lo sourean DOS piezas:
#   - el MOTOR (run-local-gates.sh), transportado al runner sellado, para PROPONER un SKIP de
#     carve-out cuando el diff base..head es 100% documentación/skills inerte; y
#   - el AGREGADOR (post-local-gates.sh) para RECOMPUTARLO de forma independiente y AUTORITATIVA
#     (fail-closed) antes de aceptar ese SKIP.
# Mismo patrón de doble cómputo que db-guards (el runner propone por `git diff`, el agregador
# recomputa con `mig_diff_empty`). La copia transportada al contenedor está ATESTADA: su sha256 se
# sella en la asignación/journal y el runner la verifica ANTES de sourcearla (r4), y el agregador
# re-deriva la clasificación con SU propia lib aprobada. El arnés (tests/run-tests.sh) ejercita
# ESTAS funciones contra fixtures git reales (M4 r7).
#
# NUNCA ejecuta código del head: usa solo `git diff --raw --no-textconv` (metadatos, no
# contenido; un `.gitattributes` con textconv no corre), es NUL-safe (no depende de
# core.quotePath), y ante CUALQUIER duda devuelve "suite completa".

# carveout_docs_only <repo_dir> <base_sha> <head_sha>
#   exit 0  → el diff base..head es 100% .md bajo un prefijo permitido (TF_CARVEOUT_PATHS) → fast-path
#   exit 1  → cualquier otra cosa O DUDA → suite completa (fail-closed)
# Requiere TF_CARVEOUT_PATHS en el entorno (prefijos permitidos, separados por espacios).
carveout_docs_only() {
  local repo="$1" base="$2" head="$3"
  local paths="${TF_CARVEOUT_PATHS:-}"
  [ -n "$repo" ] && [ -n "$base" ] && [ -n "$head" ] && [ -n "$paths" ] || return 1
  git -C "$repo" cat-file -e "${base}^{commit}" 2>/dev/null || return 1
  git -C "$repo" cat-file -e "${head}^{commit}" 2>/dev/null || return 1

  # `git diff --raw -z` emite, por fichero, un registro NUL-delimitado:
  #   :<srcmode> <dstmode> <srcsha> <dstsha> <status>\0<path>[\0<path2 si R/C>]
  # Fail-closed EXTREMO A EXTREMO (r5): el diff se VUELCA a un temporal para poder comprobar el
  # EXIT CODE de git. $(...) elimina los NUL, y una process substitution `< <(git…)` NO expone el
  # rc de git: si git falla a mitad de stream con salida PARCIAL 100% docs, parsearla daría
  # "docs-only" sobre un diff que en realidad falló de leer (fail-OPEN). Por eso: dump → comprobar
  # rc → solo entonces parsear (NUL-safe leyendo del fichero; el while queda en el shell actual).
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/carveout-XXXXXX")" || return 1
  git -C "$repo" diff --raw -z --no-textconv -M -C "$base" "$head" > "$tmp" 2>/dev/null
  local git_rc=$?
  if [ "$git_rc" -ne 0 ]; then rm -f "$tmp"; return 1; fi   # git diff falló → suite completa
  if [ ! -s "$tmp" ]; then rm -f "$tmp"; return 1; fi        # diff REALMENTE vacío → suite completa

  local ok=1 any=0 meta srcmode dstmode status path
  while IFS= read -r -d '' meta; do
    any=1
    case "$meta" in :*) : ;; *) ok=0; break ;; esac   # forma inesperada ⇒ DUDA
    meta="${meta#:}"
    srcmode="${meta%% *}"; meta="${meta#* }"
    dstmode="${meta%% *}"; meta="${meta#* }"
    meta="${meta#* }"; meta="${meta#* }"              # descartar srcsha y dstsha
    status="$meta"
    # Blob no-regular ⇒ DUDA: solo 100644/100755 (o 000000 en add/delete). Rechaza 120000
    # (symlink) y 160000 (submódulo/gitlink), que podrían transportar código/estado ejecutable.
    case "$srcmode" in 100644|100755|000000) : ;; *) ok=0; break ;; esac
    case "$dstmode" in 100644|100755|000000) : ;; *) ok=0; break ;; esac
    case "$status" in
      A|M|D)
        IFS= read -r -d '' path || { ok=0; break; }
        _carveout_path_ok "$path" "$paths" || { ok=0; break; }
        ;;
      R*|C*)                                          # rename/copy → suite completa (mandato del brief)
        IFS= read -r -d '' path; IFS= read -r -d '' path   # consumir src+dst
        ok=0; break
        ;;
      *) ok=0; break ;;                                # T (typechange), U (unmerged), X, …
    esac
  done < "$tmp"
  rm -f "$tmp"
  [ "$ok" = 1 ] && [ "$any" = 1 ] || return 1         # error de parseo / diff vacío ⇒ DUDA
  return 0
}

# _carveout_path_ok <path> <prefijos>  (interno) — path bajo un prefijo permitido y con sufijo .md.
_carveout_path_ok() {
  local path="$1" paths="$2" p
  case "$path" in *.md) : ;; *) return 1 ;; esac      # case-sensitive: .MD/.mdx caen fuera
  for p in $paths; do
    [ -n "$p" ] || continue
    case "$path" in "$p"*) return 0 ;; esac
  done
  return 1
}

# carveout_gate_skippable <gate> <keep_list>
#   exit 0 → el gate NO está en la keep-list ⇒ elegible para SKIP en fast-path
#   exit 1 → está en la keep-list (survivor: corre siempre)
carveout_gate_skippable() {
  local gate="$1" keep="${2:-}" k
  for k in $keep; do
    [ "$k" = "$gate" ] && return 1
  done
  return 0
}

# carveout_noncarveout_digest <repo_dir> <sha>
#   Imprime en stdout el digest sha256 del ÁRBOL en <sha> EXCLUYENDO TF_CARVEOUT_PATHS, y retorna 0.
#   Retorna 1 (sin imprimir nada) ante cualquier duda — commit inexistente, `ls-tree` fallido, etc.
#
# AUTORIDAD CONSERVADORA (ruling del lead, ~/.tco-relay/ruling-49-tal2749.txt): el checker heurístico
# (carveout-check en Academy) es defensa en profundidad, NO la autoridad fail-closed. La autoridad es
# este digest: cualquier fichero que se convierta en consumidor de docs/**/.claude/skills/** —por
# CUALQUIER vía sintáctica, import, alias, indirección, tooling nuevo, lo que sea— es, por definición,
# un cambio en un fichero FUERA de esas rutas (el consumidor no puede vivir bajo `docs/` o
# `.claude/skills/` y a la vez ser código de build/test). Por tanto: si el árbol NO-carveout no ha
# cambiado un byte desde el commit en que la inercia fue ratificada, ningún consumidor nuevo pudo
# haberse introducido — sin importar la sintaxis. Esto subsume TODA la clase de evasión (r3–r8 y lo
# que venga) sin analizar una sola línea de código consumidor: es una comparación de hashes, decidible.
#
# `git ls-tree -r --full-tree <sha>` emite, por blob: "<mode> blob <sha>\t<path>" — el <sha> del blob
# YA es un hash de su contenido, así que no hace falta leer ningún fichero (ni ejecutar nada del
# árbol). Se excluye una línea SOLO si su <path> es EXACTAMENTE lo que `_carveout_path_ok` permitiría
# cambiar sin correr la suite pesada: termina en `.md` (case-sensitive) Y empieza por un prefijo de
# TF_CARVEOUT_PATHS — el MISMO predicado que usa el clasificador (replicado aquí, awk no puede llamar
# a una función de shell). Gate-1 auditoría de código (r8, hallazgo BLOQUEANTE, verificado): excluir
# el prefijo COMPLETO (cualquier extensión) es demasiado ancho — Academy tiene .sh/.py/.ts/.mjs reales
# bajo `.claude/skills/`, y el clasificador NUNCA permite que esos cambien en un fast-path (solo .md).
# Si el digest los excluyera igual, un cambio en uno de esos scripts (p.ej. uno que empiece a leer un
# `.md` vecino, el patrón exacto de r3–r7) no invalidaría el digest, y un PR .md posterior pasaría el
# fast-path sobre un árbol cuya inercia ya se rompió. Al exigir AMBAS condiciones para excluir, el
# conjunto hasheado es EXACTAMENTE "todo lo que el clasificador no permite tocar en fast-path" — el
# resto —ordenado de forma estable por `ls-tree` (lexicográfico, sin depender de locale)— se hashea.
carveout_noncarveout_digest() {
  local repo="$1" sha="$2"
  local paths="${TF_CARVEOUT_PATHS:-}"
  [ -n "$repo" ] && [ -n "$sha" ] && [ -n "$paths" ] || return 1
  git -C "$repo" cat-file -e "${sha}^{commit}" 2>/dev/null || return 1
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/carveout-digest-XXXXXX")" || return 1
  git -C "$repo" ls-tree -r --full-tree "$sha" > "$tmp" 2>/dev/null
  local rc=$?
  if [ "$rc" -ne 0 ]; then rm -f "$tmp"; return 1; fi
  if [ ! -s "$tmp" ]; then rm -f "$tmp"; return 1; fi   # árbol vacío ⇒ DUDA, no autoridad
  local filtered digest
  filtered="$(awk -F'\t' -v paths="$paths" '
    function is_md(s,    n) { n = length(s); return n >= 3 && substr(s, n-2) == ".md" }
    BEGIN { n = split(paths, arr, " ") }
    {
      path = $2
      skip = 0
      if (is_md(path)) {
        for (i = 1; i <= n; i++) {
          p = arr[i]
          if (p == "") continue
          if (index(path, p) == 1) { skip = 1; break }
        }
      }
      if (!skip) print $0
    }
  ' "$tmp")"
  local awk_rc=$?
  rm -f "$tmp"
  [ "$awk_rc" -eq 0 ] || return 1
  digest="$(printf '%s\n' "$filtered" | sha256sum | cut -d' ' -f1)" || return 1
  [ -n "$digest" ] || return 1
  printf '%s\n' "$digest"
  return 0
}
