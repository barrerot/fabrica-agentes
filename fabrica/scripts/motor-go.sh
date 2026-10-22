#!/usr/bin/env bash
# motor-go.sh — ÚNICA vía de autorización de push directo a main del MOTOR (TAL-2288).
#
# El repo del motor (talent-factory) se opera con commits directos a main (no tiene cola de
# Mergeador), pero su hook githooks/pre-push exige un sentinel atado a (SHA, refs/heads/main)
# que SOLO emite este script, tras correr los gates del motor sobre el diff a empujar:
#   - `bash -n` de TODO shell ejecutable modificado (scripts/**/*.sh, githooks/*, shell
#     dentro de skills/ espejados) — M4-rev6: el propio hook que autoriza main entra en scope.
#   - shellcheck de los mismos archivos (si el binario existe; sin él, el push exige el escape
#     consciente MOTOR_GO_NO_SHELLCHECK=1 — degradación DECLARADA, nunca silenciosa).
#   - smoke de los entry-points conocidos (invocación sin args ⇒ exit 2 de uso, no crash).
#
# La ruta manual (correr estos comandos a mano) NO emite sentinel: sirve de diagnóstico,
# jamás de autorización. Bootstrap sin excepción: el hook que corre en un push es el del
# working tree local, así que tras commitear hook+script se corre ESTE script sobre ese HEAD
# y el primer push ya sale con sentinel.
#
# Salida: 0 = gates verdes + sentinel emitido · 1 = algún gate rojo · 2 = precondición.
set -euo pipefail

SENTINEL=".claude/.motor-go"
die() { echo "[motor-go] ERROR: $*" >&2; exit 2; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || die "no estás en un repo git"
cd "$ROOT"

branch="$(git branch --show-current 2>/dev/null || true)"
[ "$branch" = "main" ] || die "el motor se empuja desde main (rama actual: ${branch:-detached})"

git fetch --no-tags --quiet origin main 2>/dev/null || true
base="$(git rev-parse --verify --quiet origin/main || true)"
[ -n "$base" ] || die "sin origin/main para diffear"

head_sha="$(git rev-parse HEAD)"
dirty="$(git status --porcelain)"
[ -z "$dirty" ] || die "working tree sucio — el sentinel autoriza EXACTAMENTE lo committeado:
$dirty"

# Lista de cambios del rango a empujar, capturada UNA vez con rc VERIFICADO (review PR #13):
# `mapfile < <(git diff … || true)` es ciego a fallos de git (mapfile jamás ve el rc del
# proceso sustituido) — un `git diff` roto producía lista vacía, saltaba los gates y emitía
# sentinel. Fail-closed: sin lista fiable de cambios no hay gates ni sentinel.
diff_all="$(git diff --name-only "$base"..HEAD --)" \
  || die "git diff $base..HEAD FALLÓ — sin lista fiable de cambios no hay gates ni sentinel"

# [Review PR #13, NO-GO-3] Los TRES filtros (shell M4-rev6 · skills/ · manifiestos) se
# derivan de diff_all en UN solo bucle Bash puro (while/case sobre herestring): sin procesos
# sustituidos, sin grep y sin `|| true` — un grep roto (rc>=2 por shim/entorno) dejaba los
# filtros vacíos y el sentinel salía con los gates saltados.
changed=(); skills_changed=(); conf_changed=()
while IFS= read -r _p; do
  [ -n "$_p" ] || continue
  case "$_p" in *.sh|githooks/*) changed+=("$_p") ;; esac
  case "$_p" in skills/*) skills_changed+=("$_p") ;; esac
  case "$_p" in manifiestos/*.conf) conf_changed+=("$_p") ;; esac
done <<< "$diff_all"
if [ "${#changed[@]}" -eq 0 ]; then
  echo "[motor-go] el diff $base..HEAD no toca shell ejecutable — gates de shell N/A"
fi

# [Paquete v1, D10] Si el diff toca skills/**: PRIMERO los self-tests de la maquinaria del
# paquete (un bug del validador/sincronizador se propagaría a TODOS los repos al sincronizar
# — R4) y DESPUÉS el validador estricto (completitud de los 9 miembros + doctrina-como-test).
# rc≠0 en cualquiera ⇒ NO hay sentinel. Adición pura (ratchet): no debilita ningún gate previo.
if [ "${#skills_changed[@]}" -gt 0 ]; then
  echo "[motor-go] el diff toca skills/ (${#skills_changed[@]} archivos) — gates del paquete:"
  bash skills/skill-creator/scripts/validate-package.sh --self-test >/dev/null \
    || die "self-test de validate-package FALLÓ — un validador roto no se propaga"
  bash skills/skill-creator/scripts/sync-package.sh --self-test >/dev/null \
    || die "self-test de sync-package FALLÓ — un sincronizador roto no se propaga"
  bash skills/skill-creator/scripts/validate-package.sh --root skills --strict-set \
    || die "validate-package --strict-set FALLÓ — el paquete no está completo/conforme"
  echo "[motor-go] paquete: self-tests + strict-set VERDES"
fi

# Los MANIFIESTOS también entran al scope (mayor del audit TAL-2293): se SOURCEAN en el motor,
# así que un .conf roto/duplicado/apócrifo que llegue a main rompe o desvía los gates de toda
# la fábrica. Gates: bash -n (sourceable), claves TF_* duplicadas ⇒ rojo, TF_PROJECT presente,
# y ANTI-REDUCCIÓN SEMÁNTICA contra origin/main: quitar un gate de TF_GATE_IDS, una familia
# de TF_E2E_FAMILIES o DEBILITAR TF_DB_GATE (always→auto→never) reduce el conjunto que deriva
# el agregador ⇒ falso verde del required check. Ratificación trazable del lead = entrada
# append-only en manifiestos/RATIFICACIONES.log (versionada, viaja en el MISMO push).
mfail=0; mreduced=0; reduced_confs=""
conf_key() { sed -n "s/^$2=\"\([^\"]*\)\".*\$/\1/p" <<<"$1" | tail -1; }
db_rank() { case "$1" in always) echo 3;; auto) echo 2;; never) echo 1;; "") echo 0;; *) echo 0;; esac; }
# Claves de ENFORCEMENT: cambiar el COMANDO de un gate (p.ej. TF_GATE_CMD_unit="true"),
# el wrapper E2E, el install, el validador de rama, el registro o los heavy-gates conserva
# el ID pero vacía el gate ⇒ falso verde. CUALQUIER cambio en estas claves exige la misma
# ratificación trazable que una reducción (audit r4 TAL-2293).
ENFORCEMENT_RE='^TF_(GATE_CMD_[A-Za-z0-9_]+|E2E_WRAPPER|INSTALL|BRANCH_VALIDATOR|SHARDS_REGISTRY|HEAVY_GATES|CARVEOUT_INERT_DIGEST|CARVEOUT_INERT_DIGEST_SHA)='
for m in "${conf_changed[@]:-}"; do
  [ -n "$m" ] || continue
  if [ ! -f "$m" ]; then
    # Manifiesto ELIMINADO: desaparece el inventario entero de esa fábrica — reducción máxima.
    echo "──── manifiesto: $m (ELIMINADO) ────"
    echo "  ✗ eliminación de manifiesto = reducción total del inventario" >&2
    mreduced=1; reduced_confs="$reduced_confs $m"
    continue
  fi
  echo "──── manifiesto: $m ────"
  if bash -n "$m"; then echo "  ✓ bash -n"; else echo "  ✗ bash -n" >&2; mfail=1; fi
  # Gramática CERRADA (B2 r5): los manifiestos son DATOS — valores sin $, backtick ni backslash
  # (la estación los parsea sin ejecutar; código embebido en un valor jamás llega a main).
  gram_bad="$(grep -vnE '^([[:space:]]*(#.*)?|TF_[A-Za-z0-9_]+="[^"$\\`]*"([[:space:]]+#.*)?[[:space:]]*)$' "$m" || true)"
  if [ -z "$gram_bad" ]; then echo "  ✓ gramática cerrada"; else echo "  ✗ fuera de la gramática cerrada: $(echo "$gram_bad" | head -2 | tr '\n' ' ')" >&2; mfail=1; fi
  dups="$(grep -E '^TF_[A-Za-z0-9_]+=' "$m" | cut -d= -f1 | sort | uniq -d)"
  if [ -z "$dups" ]; then echo "  ✓ sin claves duplicadas"; else echo "  ✗ claves TF_* duplicadas: $(echo "$dups" | tr '\n' ' ')" >&2; mfail=1; fi
  if grep -qE '^TF_PROJECT="[^"]+"' "$m"; then echo "  ✓ TF_PROJECT presente"; else echo "  ✗ falta TF_PROJECT" >&2; mfail=1; fi
  old="$(git show "$base:$m" 2>/dev/null || true)"
  if [ -n "$old" ]; then
    new="$(cat "$m")"
    for key in TF_GATE_IDS TF_E2E_FAMILIES; do
      old_v="$(conf_key "$old" "$key")"; new_v="$(conf_key "$new" "$key")"
      removed="$(comm -23 <(printf '%s' "$old_v" | tr ' ' '\n' | grep . | sort -u) \
                          <(printf '%s' "$new_v" | tr ' ' '\n' | grep . | sort -u) | grep . || true)"
      if [ -n "$removed" ]; then
        echo "  ✗ $key REDUCE respecto a origin/main: $(echo "$removed" | tr '\n' ' ')" >&2
        mreduced=1; case " $reduced_confs " in *" $m "*) ;; *) reduced_confs="$reduced_confs $m";; esac
      else
        echo "  ✓ $key sin reducción"
      fi
    done
    old_db="$(conf_key "$old" TF_DB_GATE)"; new_db="$(conf_key "$new" TF_DB_GATE)"
    if [ -n "$old_db" ] && [ "$(db_rank "$new_db")" -lt "$(db_rank "$old_db")" ]; then
      echo "  ✗ TF_DB_GATE se DEBILITA ($old_db → ${new_db:-ausente})" >&2
      mreduced=1; case " $reduced_confs " in *" $m "*) ;; *) reduced_confs="$reduced_confs $m";; esac
    else
      echo "  ✓ TF_DB_GATE sin debilitamiento (${old_db:-n/a} → ${new_db:-n/a})"
    fi
    # Cambios en claves de enforcement (comandos/rutas): diff línea a línea de esas claves.
    enf_diff="$(diff <(grep -E "$ENFORCEMENT_RE" <<<"$old" | sort) \
                     <(grep -E "$ENFORCEMENT_RE" <<<"$new" | sort) || true)"
    if [ -n "$enf_diff" ]; then
      echo "  ✗ claves de ENFORCEMENT modificadas (comando/wrapper/install/validador/registro):" >&2
      echo "$enf_diff" | sed 's/^/      /' >&2
      mreduced=1; case " $reduced_confs " in *" $m "*) ;; *) reduced_confs="$reduced_confs $m";; esac
    else
      echo "  ✓ claves de enforcement sin cambios"
    fi
    # Carve-out docs-only (TAL-2749): HABILITAR el fast-path (TF_CARVEOUT_DOCS_ONLY 0→1), ENCOGER
    # los survivors (TF_CARVEOUT_KEEP_GATES) o AMPLIAR los prefijos inertes (TF_CARVEOUT_PATHS)
    # reduce la cobertura efectiva (más gates omitidos / más superficie califica como docs-only).
    # El alcance de "qué es docs-only" es ENFORCEMENT que vive en el manifiesto ⇒ misma ratificación
    # durable que quitar un gate (H4a/H4b): que no escape por ser una clave nueva o de código.
    co_reduced=0
    old_co="$(conf_key "$old" TF_CARVEOUT_DOCS_ONLY)"; new_co="$(conf_key "$new" TF_CARVEOUT_DOCS_ONLY)"
    if [ "$new_co" = "1" ]; then
      if [ "$old_co" != "1" ]; then
        echo "  ✗ TF_CARVEOUT_DOCS_ONLY habilitado (${old_co:-ausente} → 1): activa el fast-path que OMITE la suite pesada" >&2
        co_reduced=1
      else
        old_keep="$(conf_key "$old" TF_CARVEOUT_KEEP_GATES)"; new_keep="$(conf_key "$new" TF_CARVEOUT_KEEP_GATES)"
        keep_removed="$(comm -23 <(printf '%s' "$old_keep" | tr ' ' '\n' | grep . | sort -u) \
                                 <(printf '%s' "$new_keep" | tr ' ' '\n' | grep . | sort -u) | grep . || true)"
        [ -z "$keep_removed" ] || { echo "  ✗ TF_CARVEOUT_KEEP_GATES ENCOGE (survivors retirados: $(echo "$keep_removed" | tr '\n' ' ')): más gates omitidos en fast-path" >&2; co_reduced=1; }
        old_paths="$(conf_key "$old" TF_CARVEOUT_PATHS)"; new_paths="$(conf_key "$new" TF_CARVEOUT_PATHS)"
        paths_added="$(comm -13 <(printf '%s' "$old_paths" | tr ' ' '\n' | grep . | sort -u) \
                                <(printf '%s' "$new_paths" | tr ' ' '\n' | grep . | sort -u) | grep . || true)"
        [ -z "$paths_added" ] || { echo "  ✗ TF_CARVEOUT_PATHS AMPLÍA (prefijos nuevos: $(echo "$paths_added" | tr '\n' ' ')): más superficie califica como docs-only" >&2; co_reduced=1; }
      fi
      # r7: con el carve-out habilitado, el gate de inercia (prueba POSITIVA de que docs/skills no
      # son build-inputs) DEBE estar cableado como survivor always-on; si no, el fast-path omitiría
      # la suite sin esa prueba corriendo → config INVÁLIDA (rojo, sin sentinel).
      new_inert="$(conf_key "$new" TF_CARVEOUT_INERT_GATE)"
      new_ids="$(conf_key "$new" TF_GATE_IDS)"; new_keep_g="$(conf_key "$new" TF_CARVEOUT_KEEP_GATES)"
      if [ -z "$new_inert" ]; then
        echo "  ✗ TF_CARVEOUT_DOCS_ONLY=1 sin TF_CARVEOUT_INERT_GATE — el carve-out exige un gate de inercia (r7)" >&2; mfail=1
      else
        case " $new_ids " in *" $new_inert "*) : ;; *) echo "  ✗ TF_CARVEOUT_INERT_GATE '$new_inert' ∉ TF_GATE_IDS (no correría ni se esperaría)" >&2; mfail=1;; esac
        case " $new_keep_g " in *" $new_inert "*) : ;; *) echo "  ✗ TF_CARVEOUT_INERT_GATE '$new_inert' ∉ TF_CARVEOUT_KEEP_GATES (sería SKIPeado en el fast-path)" >&2; mfail=1;; esac
      fi
      # Autoridad conservadora (ruling del lead, scope ampliado tras r3-r8): el carve-out EXIGE un
      # digest ratificado del árbol no-carveout — sin él, el agregador no tiene autoridad y el
      # fast-path quedaría fail-closed en la práctica (no config-inválida, pero sí una config
      # incompleta que motor-go debe negarse a sellar: el checker heurístico por sí solo YA NO
      # basta, según el ruling).
      new_digest="$(conf_key "$new" TF_CARVEOUT_INERT_DIGEST)"
      new_digest_sha="$(conf_key "$new" TF_CARVEOUT_INERT_DIGEST_SHA)"
      if [ -z "$new_digest" ] || [ -z "$new_digest_sha" ]; then
        echo "  ✗ TF_CARVEOUT_DOCS_ONLY=1 sin TF_CARVEOUT_INERT_DIGEST(_SHA) — el carve-out exige la autoridad conservadora ratificada" >&2; mfail=1
      elif ! printf '%s' "$new_digest" | grep -qE '^[0-9a-f]{64}$'; then
        echo "  ✗ TF_CARVEOUT_INERT_DIGEST no es un sha256 hexadecimal de 64 caracteres válido" >&2; mfail=1
      fi
    fi
    if [ "$co_reduced" = 1 ]; then
      mreduced=1; case " $reduced_confs " in *" $m "*) ;; *) reduced_confs="$reduced_confs $m";; esac
    else
      echo "  ✓ TF_CARVEOUT_* sin reducción de cobertura"
    fi
  fi
done
RATLOG="manifiestos/RATIFICACIONES.log"
# El log de ratificaciones es APPEND-ONLY en TODO push (M3 r6): un commit posterior que
# reescriba o borre líneas previas (aunque no reduzca nada) destruiría la trazabilidad de
# las degradaciones ya aprobadas. Se verifica siempre, haya o no reducción en este diff.
rat_old="$(git show "$base:$RATLOG" 2>/dev/null || true)"
rat_new="$(cat "$RATLOG" 2>/dev/null || true)"
if [ -n "$rat_old" ]; then
  if [ ! -f "$RATLOG" ]; then
    echo "[motor-go] ✗ $RATLOG fue ELIMINADO — el registro de ratificaciones es append-only" >&2; mfail=1
  elif [ "${rat_new:0:${#rat_old}}" != "$rat_old" ]; then
    echo "[motor-go] ✗ $RATLOG reescrito (no append-only) respecto a origin/main" >&2; mfail=1
  else
    echo "[motor-go] ✓ $RATLOG append-only"
  fi
fi
if [ "$mreduced" = "1" ]; then
  # M7 r5: la ratificación debe ser DURABLE y viajar EN EL MISMO PUSH — una entrada nueva
  # append-only en $RATLOG (versionado) que nombre cada manifiesto reducido y lleve un
  # identificador de aprobación (`ref=` → issue/comentario/quién). Un env var no deja rastro:
  # el sentinel es one-shot y gitignored.
  rat_ok=1; rat_refs=""
  old_log="$rat_old"; new_log="$rat_new"
  if [ -z "$new_log" ]; then
    rat_ok=0
  elif [ "${new_log:0:${#old_log}}" != "$old_log" ]; then
    echo "[motor-go] ✗ $RATLOG NO es append-only respecto a origin/main (reescritura de historial de ratificaciones)" >&2
    rat_ok=0
  else
    added="${new_log:${#old_log}}"
    [ -n "$added" ] || rat_ok=0
    # Formato CERRADO (M3 r7): cada manifiesto reducido debe aparecer como TOKEN COMPLETO en
    # el campo items= de una entrada añadida que lleve ref= en ESA MISMA LÍNEA (grep -qF del
    # basename permitiría que 'tt.conf' cubriera 't.conf').
    mgo_line_covers() { # <item>
      local ln its
      while IFS= read -r ln; do
        grep -q 'ref=[^|[:space:]]' <<<"$ln" || continue
        its="$(sed -n 's/.*items=\([^|]*\).*/\1/p' <<<"$ln" | tr -d '[:space:]')"
        [ -n "$its" ] || continue
        printf '%s' "$its" | tr ',' '\n' | grep -qxF "$1" && return 0
      done <<<"$added"
      return 1
    }
    for rm in $reduced_confs; do
      mgo_line_covers "$(basename "$rm")" \
        || { echo "[motor-go] ✗ $RATLOG no ratifica '$(basename "$rm")' con una entrada '| ref=... | items=$(basename "$rm")[,...] |' (token exacto)" >&2; rat_ok=0; }
    done
    rat_refs="$(grep -o 'ref=[^|[:space:]]*' <<<"$added" | tr '\n' ' ' || true)"
  fi
  if [ "$rat_ok" = "1" ]; then
    echo "[motor-go] ⚠ reducción de manifiesto RATIFICADA vía $RATLOG ($rat_refs) — trazada en git y en el sentinel" >&2
  else
    echo "[motor-go] ✗ reducción semántica de manifiesto SIN ratificación durable — añade en el MISMO commit una entrada append-only a $RATLOG:" >&2
    echo "[motor-go]     $(date -u +%F) | ref=<TAL-n/URL/quién> | items=<manifiesto.conf[,...]> | <motivo>" >&2
    mfail=1
  fi
fi

fail=0
# MOTOR_GO_SHELLCHECK_BIN permite un binario alternativo (p.ej. "npx --yes shellcheck" en
# hosts sin paquete); debe responder a --version o se ignora (fail-closed más abajo).
sc_bin=""
if [ -n "${MOTOR_GO_SHELLCHECK_BIN:-}" ] && $MOTOR_GO_SHELLCHECK_BIN --version >/dev/null 2>&1; then
  sc_bin="$MOTOR_GO_SHELLCHECK_BIN"
elif command -v shellcheck >/dev/null 2>&1; then
  sc_bin="shellcheck"
fi

for f in "${changed[@]:-}"; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  echo "──── $f ────"
  if bash -n "$f"; then echo "  ✓ bash -n"; else echo "  ✗ bash -n" >&2; fail=1; fi
  if [ -n "$sc_bin" ]; then
    # SC1090/SC1091: sources dinámicos (manifiestos/redactor) — rutas resueltas en runtime.
    # -S warning: los info (estilo) no bloquean el push del motor; warnings y errores SÍ.
    if $sc_bin -S warning -x -e SC1090,SC1091 "$f"; then echo "  ✓ shellcheck"; else echo "  ✗ shellcheck" >&2; fail=1; fi
  fi
done

if [ -z "$sc_bin" ] && [ "${#changed[@]}" -gt 0 ]; then
  if [ "${MOTOR_GO_NO_SHELLCHECK:-0}" = "1" ]; then
    echo "[motor-go] ⚠ shellcheck NO disponible — degradación DECLARADA por MOTOR_GO_NO_SHELLCHECK=1 (solo bash -n)" >&2
  else
    die "shellcheck no disponible en este host. Instálalo, o degrada CONSCIENTEMENTE con MOTOR_GO_NO_SHELLCHECK=1 (quedará trazado en el sentinel)."
  fi
fi

# Smoke de entry-points conocidos: sin args deben fallar con exit 2 (uso), no crashear.
# [NO-GO-3] Pertenencia por comparación Bash pura (sin grep): inmune a un grep roto.
for entry in scripts/run-local-gates.sh scripts/post-local-gates.sh; do
  entry_changed=0
  for _f in "${changed[@]:-}"; do
    if [ "$_f" = "$entry" ]; then entry_changed=1; break; fi
  done
  [ "$entry_changed" -eq 1 ] || continue
  echo "──── smoke: $entry (sin args ⇒ exit 2) ────"
  set +e; bash "$entry" >/dev/null 2>&1; rc=$?; set -e
  if [ "$rc" -eq 2 ] || [ "$rc" -eq 1 ]; then echo "  ✓ smoke (rc=$rc)"; else echo "  ✗ smoke: rc=$rc (esperado 1|2)" >&2; fail=1; fi
done

[ "$fail" -eq 0 ] && [ "$mfail" -eq 0 ] || { echo "[motor-go] gates ROJOS — sin sentinel." >&2; exit 1; }

mkdir -p .claude
# TAL-2614: nota de shellcheck para el sentinel. Antes: sustitución `$([ … ] && echo …)` dentro de la
# expansión ${sc_bin:-…} — cuando sc_bin está vacío (shellcheck ausente) Y el diff NO trae shell
# (changed vacío, así que el die de arriba no aplica), el `[ 0 = 1 ]` retorna 1 y, bajo `set -e`, la
# ASIGNACIÓN adopta ese rc y mata el script ANTES de escribir el sentinel (fallo silencioso del gate).
# Reemplazado por un condicional explícito, sin sustitución que pueda fallar.
if [ -n "${sc_bin:-}" ]; then
  sc_note="$sc_bin"
elif [ "${MOTOR_GO_NO_SHELLCHECK:-0}" = "1" ]; then
  sc_note="AUSENTE (escape consciente)"
else
  sc_note="AUSENTE"
fi
red_note=""
[ "$mreduced" = "1" ] && red_note=" reduccion-manifiesto=RATIFICADA(${rat_refs:-})"
cat > "$SENTINEL" <<EOF
$head_sha
refs/heads/main
$(date -u +"%Y-%m-%dT%H:%M:%SZ")
gates: bash-n(${#changed[@]} archivos) shellcheck=$sc_note manifiestos(${#conf_changed[@]})$red_note
EOF
echo "[motor-go] ✓ sentinel emitido para (${head_sha:0:12}, refs/heads/main) — one-shot, lo consume githooks/pre-push."
