#!/usr/bin/env bash
# Regresiones del ZIP: estados explícitos, anexos adjudicados y runner fail-closed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d)" || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  PASS $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1: esperado=$2 real=$3"; fi; }
cp -a "$ROOT/." "$T/pkg" || exit 2
R="$T/pkg"; V="$R/skills/skill-creator/scripts/validate-package.sh"
run_v() { bash "$V" --root "$R/skills" --estado "$1" > "$T/$2.log" 2>&1; }
run_v distribucion distribucion; check 'distribución verde' 0 $?
check 'diez invariantes overlay separadas' 10 "$(grep -c '^SKIP-OVERLAY ' "$T/distribucion.log")"
cp "$R/skills/talent-merger/invariants.tsv" "$T/invariants.tsv"
sed -i -E '/^INV-ME-(081|270)\t/s/\t[^\t]+\tMUST\t/\tCHANGELOG.md\tMUST\t/' "$R/skills/talent-merger/invariants.tsv"
run_v distribucion doctrina-rojo; check 'mutación CHANGELOG falla' 1 $?
cp "$T/invariants.tsv" "$R/skills/talent-merger/invariants.tsv"
run_v distribucion doctrina-verde; check 'doctrina restaurada verde' 0 $?
for sk in talent-channel-operation talent-merger talent-ceo; do
  printf 'Anexo propio de ejemplo\n' > "$R/skills/$sk/references/anexo-neutral.md"
done
cat > "$R/skills/talent-channel-operation/scripts/repo-identity.conf" <<'EOF'
PKG_IDENTITY_PROJECT=ejemplo
TCO_REPO_DIR=Repo-Ejemplo
TCO_REPO_SLUG=example/Repo-Ejemplo
TCO_REPO_STACK=supabase
TCO_ANEXO_FILE=references/anexo-neutral.md
TCO_LINEAR_INPROGRESS_STATE=00000000-0000-4000-8000-000000000007
TCO_LINEAR_INREVIEW_STATE=00000000-0000-4000-8000-000000000008
TCO_POSTMERGE_CMD=true
TCO_HOST_ENV_REL=Repo-Ejemplo/entorno.conf
TCO_TF_MANIFEST=/tmp/instancia-neutral/manifiestos/ejemplo.conf
EOF
printf 'PKG_IDENTITY_PROJECT=ejemplo\n' > "$R/skills/talent-orchestrator/scripts/repo-identity.conf"
cat > "$R/skills/talent-merger/references/anexo-neutral.md" <<'EOF'
repinear
lock table supabase_migrations.schema_migrations in exclusive mode;
class() { printf
: "${PROC_M13_CLASS_FILE:=/dev/null}"
if exists (select 1 from supabase_migrations.schema_migrations where version
GUARDA DE FORMA
no se interpola en SQL
TM_FLOCK_CANONICO_TRUSTED
PROCEDENCIA INDEPENDIENTE: NO MEDIDA, NO GARANTIZABLE DESDE ESTE ARTEFACTO
Se declara NO MEDIDO, no cerrado, y así se mantiene
preflight-issue.sh
EOF
run_v instancia instancia-verde; check 'instancia adjudicada verde' 0 $?
check 'instancia evalúa diez invariantes en anexo adjudicado' 10 "$(grep -c '^PASS talent-merger INV-ME-.*MUST match en references/anexo-neutral.md' "$T/instancia-verde.log")"
bash "$R/skills/talent-channel-operation/tests/test-proc13-pointer-integrity.sh" --estado instancia > "$T/pointer-instancia-verde.log" 2>&1
check 'punteros evalúan el anexo adjudicado de la instancia' 0 $?
sed -i '/^preflight-issue\.sh$/d' "$R/skills/talent-merger/references/anexo-neutral.md"
bash "$R/skills/talent-channel-operation/tests/test-proc13-pointer-integrity.sh" --estado instancia > "$T/pointer-instancia-rojo.log" 2>&1
check 'anexo adjudicado sin referencia sigue rojo' 1 $?
printf 'preflight-issue.sh\n' >> "$R/skills/talent-merger/references/anexo-neutral.md"
# Misma forma y confinamiento que el validador, también por symlinks.
mkdir -p "$R/skills/talent-merger/references/anexo-ruta" "$T/exterior"
printf 'preflight-issue.sh\n' > "$R/skills/talent-merger/anexo-exterior.md"
printf 'preflight-issue.sh\n' > "$R/skills/talent-merger/references/anexo-ruta/anexo-neutral.md"
printf 'preflight-issue.sh\n' > "$T/exterior/anexo-neutral.md"
ln -s "$T/exterior" "$R/skills/talent-merger/references/anexo-enlace"
for ruta in references/anexo-ruta/../../anexo-exterior.md references/anexo-ruta/../anexo-neutral.md references/anexo-ruta/./anexo-neutral.md references/anexo-enlace/anexo-neutral.md; do
  sed -i "s|^TCO_ANEXO_FILE=.*|TCO_ANEXO_FILE=$ruta|" "$R/skills/talent-channel-operation/scripts/repo-identity.conf"
  bash "$R/skills/talent-channel-operation/tests/test-proc13-pointer-integrity.sh" --estado instancia > "$T/pointer-${ruta//\//_}.log" 2>&1
  check "punteros rechazan $ruta" 2 $?
done
sed -i 's|^TCO_ANEXO_FILE=.*|TCO_ANEXO_FILE=references/anexo-neutral.md|' "$R/skills/talent-channel-operation/scripts/repo-identity.conf"
bash "$R/skills/talent-channel-operation/tests/test-proc13-pointer-integrity.sh" --estado instancia > "$T/pointer-ruta-restaurada.log" 2>&1
check 'punteros restaurados verdes' 0 $?
bash "$R/skills/talent-merger/references/proc-m13.selftest.sh" --estado instancia > "$T/proc-supabase-sin-ejecutable.log" 2>&1
check 'proc-m13 supabase sin bloque ejecutable rechaza en el hijo congelado' 2 $?
check 'proc-m13 supabase no declara una omisión de distribución en el hijo' 0 "$(grep -c '^SKIP' "$T/proc-supabase-sin-ejecutable.log")"
sed -i '/^repinear$/d' "$R/skills/talent-merger/references/anexo-neutral.md"
run_v instancia instancia-rojo; check 'anexo adjudicado sin doctrina sigue rojo' 1 $?
for stack in ninguno convex; do
  sed -i "s/^TCO_REPO_STACK=.*/TCO_REPO_STACK=$stack/" "$R/skills/talent-channel-operation/scripts/repo-identity.conf"
  run_v instancia "instancia-$stack"; check "instancia $stack sin doctrina no aplica" 0 $?
  check "diez omisiones declaradas para $stack" 10 "$(grep -c "^SKIP talent-merger INV-ME-.*PROC-M13 no aplica al stack $stack$" "$T/instancia-$stack.log")"
  if [ "$stack" = ninguno ]; then
    cp "$V" "$T/validator-verde.sh"
    sed -i '/if \[ "\$stack_adjudicado" != supabase \]; then/s/!=/=/' "$V"
    run_v instancia criterio-rojo; check 'mutación del criterio evalúa doctrina ajena y falla' 1 $?
    cp "$T/validator-verde.sh" "$V"
    run_v instancia criterio-verde; check 'criterio restaurado omite con rc cero' 0 $?
  fi
  for suite in "$R/skills/talent-channel-operation/tests/test-proc13-pointer-integrity.sh" "$R/skills/talent-merger/references/proc-m13.selftest.sh"; do
    bash "$suite" --estado instancia > "$T/$(basename "$suite")-$stack.log" 2>&1; rc=$?
    good=0; [ "$rc" = 0 ] && grep -q "SKIP.*PROC-M13 no aplica al stack $stack" "$T/$(basename "$suite")-$stack.log" && good=1
    check "$(basename "$suite") omite con motivo $stack" 1 "$good"
  done
done
sed -i 's/^TCO_REPO_STACK=.*/TCO_REPO_STACK=invalido/' "$R/skills/talent-channel-operation/scripts/repo-identity.conf"
for suite in "$V" "$R/skills/talent-channel-operation/tests/test-proc13-pointer-integrity.sh" "$R/skills/talent-merger/references/proc-m13.selftest.sh"; do
  if [ "$suite" = "$V" ]; then run_v instancia stack-invalido; else bash "$suite" --estado instancia > "$T/$(basename "$suite")-invalido.log" 2>&1; fi
  rc=$?
  check "$(basename "$suite") rechaza stack inválido" 2 "$rc"
done
run_v distribucion fuga-rojo; check 'distribución con overlays falla' 1 $?

# El runner de la copia ejecuta la misma fila con asserts sintéticos rojo/verde.
check 'inventario incluye 58 suites' 58 "$(bash "$R/scripts/run-all-suites.sh" --listar | wc -l)"
cp "$R/tests/test-instalacion-fases.sh" "$T/fases-original.sh"
for fallos in 0 1; do
  printf '#!/usr/bin/env bash\necho "PASS=1 FAIL=%s esperados=1"\n' "$fallos" > "$R/tests/test-instalacion-fases.sh"
  TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo instalacion-fases > "$T/runner-fases-$fallos.log" 2>&1
  check "resumen fases con FAIL=$fallos conserva fail-closed" "$fallos" $?
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$R/tests/test-instalacion-fases.sh"
TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo instalacion-fases > "$T/runner-fases-sin-resumen.log" 2>&1
check 'fases sin resumen bloquea' 1 $?
# Registro cerrado de las omisiones soportadas del montaje íntegro de F2 creado.
for variante in env11 env12 tail11 tail12 canal-ajeno destino-ajeno sin-positivos sin-creado sin-restaurado fallo; do
  cat > "$R/tests/test-instalacion-fases.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'CONSUMIDOR F2 verify real creado rc=0' 'CONSUMIDOR F2 verify restaurado rc=0' 'positivos-reales: PASS=41 FAIL=0'
EOF
  omision='  SKIP  vibe-channel-11 .env.local (sin vibe-channel-11.env en el escrow — ruta soportada)'
  esperado=0; fallos=0
  case "$variante" in
    env12) omision='  SKIP  vibe-channel-12 .env.local (sin vibe-channel-12.env en el escrow — ruta soportada)' ;;
    tail11) omision='  SKIP  vibe-channel-11 en tailnet (TC_LOCAL_ONLY=yes — acceso local vía incus exec)' ;;
    tail12) omision='  SKIP  vibe-channel-12 en tailnet (TC_LOCAL_ONLY=yes — acceso local vía incus exec)' ;;
    canal-ajeno) omision='  SKIP  vibe-channel-13 .env.local (sin vibe-channel-13.env en el escrow — ruta soportada)'; esperado=1 ;;
    destino-ajeno) omision='  SKIP  vibe-channel-11 otro.env (sin vibe-channel-11.env en el escrow — ruta soportada)'; esperado=1 ;;
    sin-positivos) sed -i 's/positivos-reales: PASS=41 FAIL=0/positivos-reales: PASS=40 FAIL=0/' "$R/tests/test-instalacion-fases.sh"; esperado=1 ;;
    sin-creado) sed -i 's/F2 verify real creado rc=0/F2 verify real creado rc=1/' "$R/tests/test-instalacion-fases.sh"; esperado=1 ;;
    sin-restaurado) sed -i 's/F2 verify restaurado rc=0/F2 verify restaurado rc=1/' "$R/tests/test-instalacion-fases.sh"; esperado=1 ;;
    fallo) fallos=1; esperado=1 ;;
  esac
  printf 'echo "%s"\n' "$omision" >> "$R/tests/test-instalacion-fases.sh"
  printf 'echo "PASS=1 FAIL=%s esperados=1"\n' "$fallos" >> "$R/tests/test-instalacion-fases.sh"
  TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo instalacion-fases > "$T/f2-omision-$variante.log" 2>&1
  check "F2 omisión soportada $variante conserva el contrato" "$esperado" $?
  if [ "$esperado" = 0 ]; then
    check "F2 omisión $variante se cuenta aparte de PASS" 1 "$(grep -c '^RESULTADO: PASS=0 FAIL=0 SKIP=1 TOTAL=1$' "$T/f2-omision-$variante.log")"
  fi
done
cp "$T/fases-original.sh" "$R/tests/test-instalacion-fases.sh"
cp "$R/instalacion/tests/run-tests.sh" "$T/instalacion-original.sh"
for fallos in 0 1; do
  printf '#!/usr/bin/env bash\necho "== 1 ok, %s FAIL (esperados: 1 casos) =="\n' "$fallos" > "$R/instalacion/tests/run-tests.sh"
  TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo instalacion > "$T/runner-instalacion-$fallos.log" 2>&1
  check "resumen instalacion con FAIL=$fallos conserva fail-closed" "$fallos" $?
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$R/instalacion/tests/run-tests.sh"
TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo instalacion > "$T/runner-instalacion-sin-resumen.log" 2>&1
check 'instalacion sin resumen bloquea' 1 $?
cp "$T/instalacion-original.sh" "$R/instalacion/tests/run-tests.sh"
cp "$R/skills/talent-context/tests/run-tests.sh" "$T/context-original.sh"
# Assert real roto con exit 0 conserva el rechazo.
sed -i 's/"ctx simple 42%"        "42"/"ctx simple 42%"        "41"/; s/\[ "$FAIL" -eq 0 \]/exit 0/' "$R/skills/talent-context/tests/run-tests.sh"
TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo talent-context > "$T/m02-fail-rc-cero.log" 2>&1
check 'resumen con FAIL positivo y rc cero bloquea' 1 $?
cp "$T/runner-logs/talent-context.log" "$T/m02-context.log"
check 'm02 ejercita el fallo real de context' 1 "$(grep -c '^== RESULTADO: 80 ok, 1 FAIL ==' "$T/runner-logs/talent-context.log")"
cp "$T/context-original.sh" "$R/skills/talent-context/tests/run-tests.sh"
TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo talent-context > "$T/m02-restaurado.log" 2>&1
check 'context real restaurado verde aunque descripciones citen FAIL' 0 $?
printf '#!/usr/bin/env bash\n[ 1 = 2 ]\n' > "$R/skills/talent-context/tests/run-tests.sh"
TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo talent-context > "$T/runner-rojo.log" 2>&1
check 'runner propaga assert roto' 1 $?
printf '#!/usr/bin/env bash\n[ 1 = 1 ]\necho "== RESULTADO: 1 ok, 0 FAIL =="\n' > "$R/skills/talent-context/tests/run-tests.sh"
TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo talent-context > "$T/runner-verde.log" 2>&1
check 'runner restaurado verde' 0 $?
printf '#!/usr/bin/env bash\necho "SKIP caso inventado sin contrato"\n' > "$R/skills/talent-context/tests/run-tests.sh"
TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo talent-context > "$T/runner-skip-rojo.log" 2>&1
check 'SKIP no declarado bloquea' 1 $?
printf '#!/usr/bin/env bash\necho "RESULTADO: PASS=0 FAIL=0 SKIP=1"\n' > "$R/skills/talent-context/tests/run-tests.sh"
TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo talent-context > "$T/runner-skip-resumen-rojo.log" 2>&1
check 'SKIP solo en resumen también bloquea' 1 $?
for omision in 'SKIP-STACK desconocido' 'probar-patches: SKIP (no declarado)' 'OMIT caso sin contrato'; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$omision" > "$R/skills/talent-context/tests/run-tests.sh"
  TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo talent-context > "$T/runner-omision-${omision// /_}.log" 2>&1
  check "omisión no declarada bloquea: $omision" 1 $?
done
cp "$T/context-original.sh" "$R/skills/talent-context/tests/run-tests.sh"
# Resumen obligatorio con omisiones parciales; solo PROC-M13 omite todo.
cp "$R/skills/talent-channel-operation/scripts/preflight-issue.sh" "$T/preflight-original.sh"
cp "$R/skills/talent-channel-operation/tests/test-proc13-pointer-integrity.sh" "$T/pointer-original.sh"
printf '\n# anexo PROC-13 §5\n' >> "$R/skills/talent-channel-operation/scripts/preflight-issue.sh"
TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo proc13-pointers > "$T/r2-puntero-resumen-presente.log" 2>&1
check 'puntero real roto con resumen falla' 1 $?
sed -i '/echo "\[test-proc13-pointer-integrity\] \$fails caso(s) FALLARON"/d; s/^exit 1$/exit 0/' "$R/skills/talent-channel-operation/tests/test-proc13-pointer-integrity.sh"
TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo proc13-pointers > "$T/r2-puntero-resumen-ausente.log" 2>&1
check 'fallo real sin resumen y con omisión parcial bloquea' 1 $?
check 'conserva el fallo ejecutado de punteros' 1 "$(grep -c 'FAIL.*(1)' "$T/runner-logs/proc13-pointers.log")"
check 'conserva la omisión parcial de punteros' 1 "$(grep -c 'SKIP-OVERLAY.*(4)' "$T/runner-logs/proc13-pointers.log")"
cp "$T/pointer-original.sh" "$R/skills/talent-channel-operation/tests/test-proc13-pointer-integrity.sh"
TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo proc13-pointers > "$T/r2-puntero-resumen-restaurado.log" 2>&1
check 'resumen restaurado conserva rechazo' 1 $?
cp "$T/preflight-original.sh" "$R/skills/talent-channel-operation/scripts/preflight-issue.sh"
TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo proc13-pointers > "$T/r2-puntero-restaurado.log" 2>&1
check 'puntero restaurado verde' 0 $?
TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo proc-m13 > "$T/r2-proc-omision-completa.log" 2>&1
check 'PROC-M13 omisión completa explícita sin resumen aceptada' 0 $?
check 'PROC-M13 ejecutó cero asserts' 1 "$(grep -c '^SKIP-OVERLAY:.*0 asserts ejecutados;' "$T/runner-logs/proc-m13.log")"
# La omisión completa es UNA línea exacta; una línea vacía añadida ya no la acredita.
cp "$R/skills/talent-merger/references/proc-m13.selftest.sh" "$T/proc-r3-original.sh"
omision_proc="$(cat "$T/runner-logs/proc-m13.log")"
printf '#!/usr/bin/env bash\nprintf "%%s\\n\\n" '\''%s'\'' >&2\n' "$omision_proc" > "$R/skills/talent-merger/references/proc-m13.selftest.sh"
TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo proc-m13 > "$T/r3-proc-linea-vacia.log" 2>&1
check 'R3 PROC-M13 omisión con línea vacía añadida bloquea' 1 $?
cp "$T/proc-r3-original.sh" "$R/skills/talent-merger/references/proc-m13.selftest.sh"
# Variante sin comentario y formato real declarado, con el clasificador original.
cp "$R/skills/talent-channel-operation/tests/run-tests.sh" "$T/channel-original.sh"
omision_real="$(sed -n 's/^.*echo "\(== .*tooling raíz.*OMITIDOS.*\)"$/\1/p' "$T/channel-original.sh")"
for omision in "$omision_real" "${omision_real%% OMITIDOS*} OMITIDOS =="; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" '\''%s'\''\necho "== RESULTADO: 80 ok, 0 FAIL =="\n' "$omision" > "$R/skills/talent-context/tests/run-tests.sh"
  TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo talent-context > "$T/r2-omitidos-${#omision}.log" 2>&1
  check "OMITIDOS no declarado bloquea (${#omision})" 1 $?
done
printf '#!/usr/bin/env bash\nprintf "%%s\\n" '\''%s'\''\necho "RESULTADO: PASS=1 FAIL=0 SKIP=0 TOTAL=1"\n' "$omision_real" > "$R/skills/talent-channel-operation/tests/run-tests.sh"
TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo talent-channel-operation > "$T/r2-omitidos-declarado.log" 2>&1
check 'formato real OMITIDOS declarado aceptado' 0 $?
cp "$T/channel-original.sh" "$R/skills/talent-channel-operation/tests/run-tests.sh"
cp "$T/context-original.sh" "$R/skills/talent-context/tests/run-tests.sh"
# Antifugas real: historia neutra propia y binario vetado, sin transportar nada.
cp "$R/skills/talent-buzz/tests/probar-antifugas.sh" "$T/antifugas-original.sh"
git init -q -b main "$R"
git -C "$R" add .
git -C "$R" -c user.name=Prueba -c user.email=prueba@example.invalid commit -qm base
git -C "$R" checkout -qb prueba-resumen
printf 'Documento neutro\n' > "$R/fixture.md"
git -C "$R" add fixture.md
git -C "$R" -c user.name=Prueba -c user.email=prueba@example.invalid commit -qm documento
TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo talent-buzz/probar-antifugas.sh > "$T/r2-antifugas-limpio.log" 2>&1
check 'antifugas real LIMPIO aceptado' 0 $?
printf 'ABC\0DEF\n' > "$R/fixture.bin"
git -C "$R" add fixture.bin
git -C "$R" -c user.name=Prueba -c user.email=prueba@example.invalid commit -qm binario
TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo talent-buzz/probar-antifugas.sh > "$T/r2-antifugas-original-rojo.log" 2>&1
check 'antifugas real con binario falla' 1 $?
sed -i 's/^  exit 1$/  exit 0/' "$R/skills/talent-buzz/tests/probar-antifugas.sh"
TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo talent-buzz/probar-antifugas.sh > "$T/r2-antifugas-rc-cero.log" 2>&1
check 'antifugas real con hallazgo y rc cero bloquea' 1 $?
check 'reproduce contador real de antifugas' 1 "$(grep -c '^probar-antifugas: 1 hallazgo(s)' "$T/runner-logs/talent-buzz_probar-antifugas.sh.log")"
cp "$T/antifugas-original.sh" "$R/skills/talent-buzz/tests/probar-antifugas.sh"
TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo talent-buzz/probar-antifugas.sh > "$T/r2-antifugas-restaurado-rojo.log" 2>&1
check 'antifugas restaurado conserva rechazo' 1 $?
for hallazgos in 0 1; do
  printf '#!/usr/bin/env bash\necho "probar-antifugas: %s hallazgo(s)"\n' "$hallazgos" > "$R/skills/talent-buzz/tests/probar-antifugas.sh"
  TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo talent-buzz/probar-antifugas.sh > "$T/r2-antifugas-contador-$hallazgos.log" 2>&1
  check "antifugas contador $hallazgos con rc cero" "$hallazgos" $?
done
cp "$T/antifugas-original.sh" "$R/skills/talent-buzz/tests/probar-antifugas.sh"
# Worktree válido, pin sintético y transporte privado bloqueado.
cp "$R/skills/talent-orchestrator/tests/run-tests.sh" "$T/orchestrator-original.sh"
for fallos in 0 1; do
  printf '#!/usr/bin/env bash\necho "RESULTADO: PASS=240 FAIL=%s"\n' "$fallos" > "$R/skills/talent-orchestrator/tests/run-tests.sh"
  TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo talent-orchestrator > "$T/runner-contadores-$fallos.log" 2>&1
  check "resumen PASS=240 FAIL=$fallos conserva su resultado" "$fallos" $?
done
cp "$T/orchestrator-original.sh" "$R/skills/talent-orchestrator/tests/run-tests.sh"
cp "$R/skills/talent-merger/references/proc-m13.selftest.sh" "$T/proc-original.sh"
for nomedido in 0 1; do
  printf '#!/usr/bin/env bash\necho "RESULTADO: 341 PASS / 0 FAIL / %s NO-MEDIDO · huella de entradas fixture"\n' "$nomedido" > "$R/skills/talent-merger/references/proc-m13.selftest.sh"
  TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo proc-m13 > "$T/runner-nomedido-$nomedido.log" 2>&1
  check "resultado PROC-M13 con NO-MEDIDO=$nomedido conserva fail-closed" "$nomedido" $?
done
cp "$T/proc-original.sh" "$R/skills/talent-merger/references/proc-m13.selftest.sh"
# CEO usa N SKIP, sin signo igual: concordancia positiva y negativa sin raíz git.
cp "$R/skills/talent-ceo/tests/run-tests.sh" "$T/ceo-original.sh"
git_reservado=0
if [ -e "$R/.git" ]; then mv "$R/.git" "$T/git-reservado"; git_reservado=1; fi
for omisiones in 1 2; do
  cat > "$R/skills/talent-ceo/tests/run-tests.sh" <<'EOF'
#!/usr/bin/env bash
echo '  SKIP sin raiz de repo; el Quick Start desde la raiz del repo no es evaluable'
echo "== 256 ok, 0 FAIL, $PRUEBA_OMISIONES SKIP (esperados: 257 casos) =="
EOF
  PRUEBA_OMISIONES="$omisiones" TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo talent-ceo > "$T/runner-ceo-skip-$omisiones.log" 2>&1
  check "resumen CEO con $omisiones SKIP concuerda solo con una omisión" "$((omisiones-1))" $?
done
cp "$T/ceo-original.sh" "$R/skills/talent-ceo/tests/run-tests.sh"
if [ "$git_reservado" = 1 ]; then mv "$T/git-reservado" "$R/.git"; fi
# El proveedor neutro carece del contenido de los patches: la suite real debe fallar.
git init -q -b main "$T/proveedor"
printf 'Proveedor neutro\n' > "$T/proveedor/README.md"
git -C "$T/proveedor" add README.md
git -C "$T/proveedor" -c user.name=Prueba -c user.email=prueba@example.invalid commit -qm base
pin="$(git -C "$T/proveedor" rev-parse HEAD)"
git -C "$T/proveedor" worktree add -q --detach "$T/proveedor-wt" "$pin"
mkdir -p "$T/bin"
git_real="$(command -v git)"
cat > "$T/bin/git" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in ls-remote|fetch|clone|push) echo TRANSPORTE_BLOQUEADO >> "$PRUEBA_TRANSPORTE"; exit 1 ;; esac
done
if [ "${PRUEBA_PERDER_PROVEEDOR:-0}" = 1 ] && [ "${3:-}" = cat-file ]; then
  "$PRUEBA_GIT_REAL" "$@"; rc=$?
  [ "$rc" != 0 ] || rm -f "$2/.git"
  exit "$rc"
fi
exec "$PRUEBA_GIT_REAL" "$@"
EOF
chmod +x "$T/bin/git"
export PRUEBA_GIT_REAL="$git_real" PRUEBA_TRANSPORTE="$T/transporte.log"
PATH="$T/bin:$PATH" TB_BUZZ_GIT="$T/proveedor-wt" TB_BUZZ_COMMIT="$pin" TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo talent-buzz/probar-patches.sh > "$T/m09-proveedor-worktree.log" 2>&1
check 'worktree ejercita patches reales incompatibles y falla' 1 $?
check 'worktree no cae en SKIP' 0 "$(grep -c 'SKIP' "$T/runner-logs/talent-buzz_probar-patches.sh.log")"
check 'worktree no intenta transporte' 0 "$([ -e "$T/transporte.log" ] && echo 1 || echo 0)"
PATH="$T/bin:$PATH" PRUEBA_PERDER_PROVEEDOR=1 TB_BUZZ_GIT="$T/proveedor-wt" TB_BUZZ_COMMIT="$pin" TF_SUITES_LOG_DIR="$T/runner-logs" bash "$R/scripts/run-all-suites.sh" --solo talent-buzz/probar-patches.sh > "$T/proveedor-desaparecido.log" 2>&1
check 'proveedor desaparecido tras prerrequisito sigue FAIL' 1 $?
check 'proveedor desaparecido no intenta transporte' 0 "$([ -e "$T/transporte.log" ] && echo 1 || echo 0)"
# Proceso propio con comm real codex: la guarda se prueba sin pgrep simulado.
python3 - "$R/scripts/run-all-suites.sh" > "$T/runner-guarda.log" 2>&1 <<'PY'
import ctypes, subprocess, sys
ctypes.CDLL(None).prctl(15, b"codex", 0, 0, 0)
r = subprocess.run(["bash", sys.argv[1], "--solo", "talent-channels"])
sys.exit(0 if r.returncode == 2 else 1)
PY
check 'guarda rc 2 con proceso propio codex' 0 $?
check 'guarda no ejecuta channels' 1 "$(grep -c '^ABORT: procesos' "$T/runner-guarda.log")"
python3 - "$R" "$T" > "$T/runner-seleccion.log" 2>&1 <<'PY'
import ctypes, os, pathlib, subprocess, sys
ctypes.CDLL(None).prctl(15, b"codex", 0, 0, 0)
root, out = map(pathlib.Path, sys.argv[1:])
runner = root / "scripts/run-all-suites.sh"
# Para la batería excluida, comandos inocuos conservando inventario y selección reales.
original = runner.read_text()
stub = original.replace('TF_FASES_EN_BATERIA="$fases_cubiertas" TB_BUZZ_SIN_RED=1 timeout "$SUITE_TIMEOUT" bash -c "${CMDS[$i]}"',
                        'TF_FASES_EN_BATERIA="$fases_cubiertas" timeout "$SUITE_TIMEOUT" bash -c \'echo LIMITE=$1; echo SUITE_EJECUTADA; echo FASES_CUBIERTAS=$TF_FASES_EN_BATERIA\' _ "$SUITE_TIMEOUT"')
if stub == original:
    sys.exit('no se pudo construir el doble de selección')
# Solo la prueba de selección usa resúmenes vacíos: el clasificador se prueba arriba.
stub = stub.replace('RESUMENES+=("$patron")', 'RESUMENES+=("")')
runner.write_text(stub)
cases = [("completa", [], 2), ("otra", ["--solo", "talent-context"], 0),
         ("excluida", ["--sin", "talent-channels", "--sin", "validate"], 0),
         ("motor", ["--solo", "motor"], 0),
         ("sin-fases", ["--sin", "talent-channels", "--sin", "instalacion-fases"], 0)]
ok = True
for name, args, expected in cases:
    # Cada selección tiene logs propios; los dobles nunca pisan los del padre.
    env = os.environ.copy()
    env["TF_SUITES_LOG_DIR"] = str(out / ("seleccion-" + name + "-suites"))
    result = subprocess.run(["bash", str(runner), *args], capture_output=True, text=True, env=env)
    (out / ("seleccion-" + name + ".log")).write_text(result.stdout + result.stderr)
    ok &= result.returncode == expected
    if name == "completa":
        ok &= "log=" not in result.stdout
    if name == "excluida":
        ok &= "SKIP talent-channels: excluida por el operador" in result.stdout
        ok &= "PASS talent-channels:" not in result.stdout
        ok &= "FASES_CUBIERTAS=1" in (pathlib.Path(env["TF_SUITES_LOG_DIR"]) / "motor.log").read_text()
    if name in ("motor", "sin-fases"):
        ok &= "FASES_CUBIERTAS=0" in (pathlib.Path(env["TF_SUITES_LOG_DIR"]) / "motor.log").read_text()
runner.write_text(original)
sys.exit(0 if ok else 1)
PY
check 'centinela: batería aborta, otra suite y exclusión ejecutan' 0 $?
# El presupuesto por defecto se lee del propio run-all-suites.sh: aquí no hay un segundo literal que pueda divergir.
# 3060 s = mayor medida por suite (2025 s en Ubuntu 26.04) x 1,5, redondeado hacia arriba al minuto (issue 9010).
DEFECTO="$(grep -E '^SUITE_TIMEOUT=' "$ROOT/scripts/run-all-suites.sh" | grep -oE ':-[0-9]+' | tr -d ':-')"
check 'run-all-suites declara un único presupuesto por defecto numérico' 1 "$(printf '%s\n' "$DEFECTO" | grep -c '^[0-9][0-9]*$')"
check 'el presupuesto por defecto de run-all-suites es 3060 s' 3060 "$DEFECTO"
check 'motor usa el presupuesto configurable por defecto' 1 "$(grep -c "^LIMITE=$DEFECTO\$" "$T/seleccion-motor-suites/motor.log")"
check 'resto de suites usa el presupuesto configurable por defecto' 1 "$(grep -c "^LIMITE=$DEFECTO\$" "$T/seleccion-otra-suites/talent-context.log")"

# Timeout real y validación del valor: conservar el rojo aunque falte resumen.
cp "$R/skills/talent-context/tests/run-tests.sh" "$T/context-timeout.sh"
printf '#!/usr/bin/env bash\nsleep 3\necho "== RESULTADO: 1 ok, 0 FAIL =="\n' > "$R/skills/talent-context/tests/run-tests.sh"
TF_SUITE_TIMEOUT=1 TF_SUITES_LOG_DIR="$T/timeout" bash "$R/scripts/run-all-suites.sh" --solo talent-context > "$T/timeout.log" 2>&1
check 'tiempo agotado conserva rojo' 1 $?
check 'tiempo agotado explica segundos y rc' 1 "$(grep -c 'tiempo agotado tras 1 s.*rc=124' "$T/timeout.log")"
for limite in 0 -1 abc 1.5; do
  TF_SUITE_TIMEOUT="$limite" bash "$R/scripts/run-all-suites.sh" --solo talent-context > "$T/timeout-invalido.log" 2>&1
  check "límite inválido rechazado $limite" 2 $?
done
cp "$T/context-timeout.sh" "$R/skills/talent-context/tests/run-tests.sh"

# Ambos gates detectan un futuro instalacion/ incluso en copia sin git.
mkdir -p "$R/instalacion"
printf '#!/usr/bin/env bash\nif\n' > "$R/instalacion/ejemplo.sh"
(cd "$R" && bash scripts/check-bash-syntax.sh) > "$T/syntax-rojo.log" 2>&1
check 'syntax incluye instalacion' 1 $?
printf '#!/usr/bin/env bash\nif\n' > "$R/instalacion/ejemplo.sh"
(cd "$R" && bash scripts/check-shellcheck.sh) > "$T/shellcheck-rojo.log" 2>&1
check 'shellcheck incluye instalacion' 1 $?
TF_PAQUETE_ESTADO=inventado bash "$ROOT/skills/talent-channel-operation/tests/test-proc13-pointer-integrity.sh" > "$T/estado-pointer.log" 2>&1
check 'pointer fija distribución independientemente del entorno' 0 $?
TF_PAQUETE_ESTADO=inventado bash "$ROOT/skills/talent-merger/references/proc-m13.selftest.sh" > "$T/estado-proc.log" 2>&1
check 'proc-m13 fija distribución independientemente del entorno' 0 $?

# La limpieza es del FS del runner, con el contrato fijo de run-gate-sealed.
# Se ejecutan las funciones reales con transporte falso; TMPDIR/receipts locales
# no deben alterar los destinos remotos ni dejar restos de un gate previo.
export TMPDIR="$T/local-temp"; mkdir -p "$TMPDIR"
sed -n '/^run_one() {/,/^}/p; /^run_lane() {/,/^}/p' "$ROOT/scripts/seal-suite.sh" > "$T/slate-funciones.sh"
# shellcheck source=/dev/null
. "$T/slate-funciones.sh"
slate_exec() { printf '%s\n' "$@" >> "$T/slate.log"; }
STAMP() { printf prueba; }
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/sealed.sh"
SEALED="$T/sealed.sh"; RG=rgNeutral; PR=1; GATE_TIMEOUT=10
CLONE="$T"; SHA=fixture; BASE=fixture; MAN="$T/man"; SLUG=example/repo
REC="$T/rec"; FAILDIR="$T/fail"; mkdir -p "$REC" "$FAILDIR"
run_lane runner-neutral gate-neutral > "$T/slate-ejecucion.log" 2>&1
check 'limpieza remota y gate conservan rc observado' 0 $?
good=0
grep -qFx 'rm -f /tmp/lg-rgNeutral* 2>/dev/null' "$T/slate.log" &&
  [ "$(grep -c '^/tmp/lg-rgNeutral' "$T/slate.log")" = 5 ] &&
  grep -qFx '/tmp/lg-rgNeutral-gate-neutral.receipt.json' "$T/slate.log" &&
  ! grep -qF "$TMPDIR" "$T/slate.log" && ! grep -qF "$REC" "$T/slate.log" && good=1
check 'destinos remotos lg fijos independientes de TMPDIR y receipts locales' 1 "$good"

if [ -n "${TF_SUITES_EVIDENCIA:-}" ]; then
  mkdir -p "$TF_SUITES_EVIDENCIA" || exit 2
  cp "$T"/*.log "$TF_SUITES_EVIDENCIA/" || exit 2
fi
echo "RESULTADO: PASS=$PASS FAIL=$FAIL SKIP=0 TOTAL=$((PASS+FAIL))"
[ "$((PASS+FAIL))" = 110 ] || exit 1
[ "$FAIL" = 0 ]
