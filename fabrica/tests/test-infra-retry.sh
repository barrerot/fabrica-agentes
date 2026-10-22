#!/usr/bin/env bash
# tests/test-infra-retry.sh — self-test de TAL-6759: el clasificador de firma de infra
# (infra_signature_patterns / infra_signature_which / infra_signature_match) del motor de
# gates. Uso:
#   bash tests/test-infra-retry.sh scripts/run-local-gates.sh
# Lo EJECUTA tests/run-tests.sh: un test que nadie corre no es una prueba, es un fichero.
#
# Extrae el bloque REAL (marcadores BEGIN/END infra_signature_match) del script bajo prueba y lo
# evalúa en este proceso — ejercita la LÓGICA REAL, no una copia. Casos GREEN (firma de infra →
# match) y RED (defecto de producto → NUNCA match, aunque el log diga "fail"/"error"/"Killed" en
# otro contexto) verifican el núcleo de seguridad de la tarea: un clasificador laxo reintentaría
# un test flaky de producto y un 2º PASS daría FALSO VERDE — catastrófico.
set -uo pipefail

SCRIPT_UNDER_TEST="${1:?uso: bash tests/test-infra-retry.sh <ruta a run-local-gates.sh>}"
[ -f "$SCRIPT_UNDER_TEST" ] || { echo "FAIL: no existe $SCRIPT_UNDER_TEST" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-infra-retry-XXXXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
ok() { echo "  ✓ $1"; }
ko() { echo "  ✗ $1" >&2; FAIL=1; }

# extract: el bloque completo (patrones + which + match) delimitado por los marcadores del
# script real. Igual patrón que tests/test-db-reset-marker.sh con su bloque de TAL-5352.
extract() { sed -n '/── BEGIN infra_signature_match (TAL-6759)/,/── END infra_signature_match (TAL-6759)/p' "$SCRIPT_UNDER_TEST"; }

extracted="$(extract)"
[ -n "$extracted" ] || { echo "FAIL: no encontré el bloque BEGIN/END infra_signature_match en $SCRIPT_UNDER_TEST" >&2; exit 2; }

# Carga las tres funciones EN ESTE proceso (no en un subshell nuevo por caso: así cada caso
# ejercita exactamente la misma definición, y una fuga de estado sería visible entre casos).
# shellcheck disable=SC1090
eval "$extracted" || { echo "FAIL: el bloque extraído no evalúa (sintaxis)" >&2; exit 2; }
for f in infra_signature_patterns infra_signature_which infra_signature_match; do
  declare -F "$f" >/dev/null 2>&1 || { echo "FAIL: falta la función $f tras extraer/evaluar" >&2; exit 2; }
done

mk_log() { # <nombre> <contenido> → ruta del log-fixture
  local name="$1" content="$2" path
  path="$TMP/$name.log"
  printf '%s\n' "$content" > "$path"
  printf '%s' "$path"
}

# run_case <desc> <logpath-o-__EMPTY__> [env=val ...] -- exp=green|red
run_green() { # <desc> <contenido>
  local desc="$1" content="$2" log
  log="$(mk_log "green-$desc" "$content")"
  if infra_signature_match "$log"; then ok "GREEN: $desc (match)"; else ko "GREEN: $desc → NO casó (esperaba match)"; fi
}
run_red() { # <desc> <contenido>
  local desc="$1" content="$2" log
  log="$(mk_log "red-$desc" "$content")"
  if infra_signature_match "$log"; then ko "RED: $desc → CASÓ (esperaba NO match — falso positivo peligroso)"; else ok "RED: $desc (no match)"; fi
}

echo "== GREEN: firmas de infra ESTRICTAS → deben casar =="
run_green "docker-daemon"     "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"
run_green "sin-espacio-disco" "write /var/lib/docker/tmp/x: no space left on device"
run_green "conn-refused"      "Error: connect ECONNREFUSED 127.0.0.1:54322"
run_green "supabase-unhealthy" "supabase_db_talent-factory container is unhealthy after 60s: Timed out waiting for database to become ready"
run_green "oom-killed"        "npm ERR! signal SIGKILL / dmesg: Out of memory: Killed process 4821 (node) OOMKilled"
run_green "puerto-en-uso"     "Error: listen EADDRINUSE: address already in use :::54321"
run_green "dns"               "getaddrinfo ENOTFOUND registry.npmjs.org"
run_green "tls-timeout"       "npm ERR! network TLS handshake timeout"
run_green "pg-conn-refused"   "psql: error: could not connect to server: Connection refused (host 127.0.0.1, port 5432)"

echo "== RED: defecto de PRODUCTO → NUNCA deben casar (aunque digan fail/error/Killed) =="
run_red "typecheck"      "src/lib/foo.ts(12,7): error TS2322: Type 'string' is not assignable to type 'number'."
run_red "assertion"      "AssertionError: expected 3 to equal 4
  at Object.<anonymous> (tests/unit/foo.test.ts:22:10)"
run_red "tests-failed"   "Tests:       2 failed, 118 passed, 120 total
✗ 2 tests failed"
run_red "lint"           "error  'x' is defined but never used  no-unused-vars
✖ 3 problems (3 errors, 0 warnings)"
run_red "generic-fail-word" "Build failed because of webpack errors
FAIL src/components/Foo.test.tsx"
run_red "generic-killed-sin-oom" "test worker was Killed by the test runner after exceeding the per-test timeout"
run_red "log-vacio"      ""

echo "== RED: ERROR DE RED contra ENDPOINT DE PRODUCTO (sin dependencia controlada) → NUNCA casa =="
# El discriminador de dependencia controlada (TAL-6759) impide reintentar un DEFECTO de producto
# que falla contra un endpoint propio con el mismo texto de red — el riesgo exacto del hallazgo CR.
run_red "prod-econnrefused-endpoint" "Error: connect ECONNREFUSED 10.20.30.40:443 (api.mi-producto.example)"
run_red "prod-connrefused-app"       "checkout flow failed: Connection refused connecting to app server localhost:3000"
run_red "prod-getaddrinfo-host"      "FetchError: getaddrinfo ENOTFOUND api.mi-producto.example"
run_red "prod-etimedout-endpoint"    "AssertionError: request to https://api.mi-producto.example timed out (ETIMEDOUT) after 5000ms"

echo "== RED: genéricos de estado transitorio SIN dependencia controlada → NUNCA casan =="
# «Timed out waiting for», «is not ready», «healthcheck …fail», «container …unhealthy» son texto
# que un e2e/integración de producto emite contra SU propio stack — sin discriminador no reintenta.
run_red "prod-timeout-selector" "Test timeout of 30000ms exceeded: Timed out waiting for selector '.checkout-btn' to be visible"
run_red "prod-not-ready-comp"   "Error: the payment component is not ready"
run_red "prod-healthcheck-api"  "healthcheck for /api/status failed with HTTP 500"
run_red "prod-unhealthy-app"    "the app service container is unhealthy (assertion failed)"
run_red "prod-port-collision"   "Error: listen EADDRINUSE: address already in use :::3000"

echo "== GREEN: genéricos de estado CON dependencia controlada → casan =="
run_green "timeout-postgres"    "waiting for stack: Timed out waiting for the postgres container to accept connections"
run_green "healthcheck-docker"  "docker compose: dependency healthcheck failed for service supabase_db"
run_green "oom-container"       "docker: the supabase_db container was killed: Out of memory (cgroup limit exceeded)"
run_green "oomkilled-solo"      "container state: OOMKilled (exit 137)"

echo "== RED: OOM/puerto de PRODUCTO sin dependencia controlada → NUNCA casan =="
run_red "prod-oom-heap"         "FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory"
run_red "prod-port-15432"       "Error: connect ECONNREFUSED 127.0.0.1:15432 (mi-servicio de producto)"
run_red "prod-port-54320"       "Error: connect ECONNREFUSED 127.0.0.1:54320"

echo "== log ausente → NO match (fail-closed, no revienta) =="
if infra_signature_match "$TMP/no-existe.log"; then
  ko "log ausente → CASÓ (esperaba NO match)"
else
  ok "log ausente → no match"
fi

echo "== EXTENSIÓN por manifiesto (TF_INFRA_RETRY_EXTRA_PATTERNS, SOLO-SUMA) =="
extra_log="$(mk_log "extra-sin-env" "esto trae mi-firma-custom en el tail")"
if infra_signature_match "$extra_log"; then
  ko "sin TF_INFRA_RETRY_EXTRA_PATTERNS → CASÓ 'mi-firma-custom' (no debería estar en la lista base)"
else
  ok "sin TF_INFRA_RETRY_EXTRA_PATTERNS → 'mi-firma-custom' no casa (no es parte de la lista estricta base)"
fi
extra_log2="$(mk_log "extra-con-env" "esto trae mi-firma-custom en el tail")"
if TF_INFRA_RETRY_EXTRA_PATTERNS='mi-firma-custom' infra_signature_match "$extra_log2"; then
  ok "con TF_INFRA_RETRY_EXTRA_PATTERNS='mi-firma-custom' → casa (extensión solo-suma)"
else
  ko "con TF_INFRA_RETRY_EXTRA_PATTERNS='mi-firma-custom' → NO casó (la extensión debería sumar)"
fi
# La extensión SUMA, no reemplaza: una firma de la lista base debe seguir casando con la env puesta.
base_still_log="$(mk_log "extra-no-pisa-base" "Cannot connect to the Docker daemon")"
if TF_INFRA_RETRY_EXTRA_PATTERNS='mi-firma-custom' infra_signature_match "$base_still_log"; then
  ok "con la extensión puesta, una firma BASE sigue casando (solo-suma, no reemplazo)"
else
  ko "con la extensión puesta, una firma BASE dejó de casar (la extensión NO debe reemplazar la base)"
fi

echo "== infra_signature_which: reporta el patrón casado (para el journal del receipt) =="
which_log="$(mk_log "which" "boom: Cannot connect to the Docker daemon at unix:///var/run/docker.sock")"
which_out="$(infra_signature_which "$which_log")"
if [ -n "$which_out" ]; then
  ok "infra_signature_which devuelve un patrón no vacío ('$which_out')"
else
  ko "infra_signature_which no devolvió patrón sobre un log GREEN"
fi

# ── VETO DE PRODUCTO (product_defect_match) ────────────────────────────────────────────────
prod_yes() { # <desc> <contenido> → product_defect_match DEBE casar (defecto de producto)
  local desc="$1" content="$2" log; log="$(mk_log "prod-yes-$desc" "$content")"
  if product_defect_match "$log"; then ok "PROD-DEFECT: $desc (casa → veta reintento)"; else ko "PROD-DEFECT: $desc → NO casó (esperaba veto)"; fi
}
prod_no() { # <desc> <contenido> → product_defect_match NO debe casar (infra pura, no veta)
  local desc="$1" content="$2" log; log="$(mk_log "prod-no-$desc" "$content")"
  if product_defect_match "$log"; then ko "PROD-DEFECT: $desc → CASÓ (vetaría un reintento de infra legítimo)"; else ok "PROD-DEFECT: $desc (no casa → no veta)"; fi
}
echo "== product_defect_match: firmas INEQUÍVOCAS de defecto de producto → vetan el reintento =="
prod_yes "typecheck"   "src/lib/foo.ts(12,7): error TS2322: Type 'string' is not assignable to type 'number'."
prod_yes "assertion"   "AssertionError: expected 3 to equal 4"
prod_yes "vitest-sum"  "Tests:       2 failed, 118 passed, 120 total"
prod_yes "vitest-bar"  "Test Files  1 failed | 5 passed (6)"
prod_yes "lint"        "✖ 3 problems (3 errors, 0 warnings)"
echo "== product_defect_match: infra PURA → NO veta (no debe casar) =="
prod_no "docker"       "Cannot connect to the Docker daemon at unix:///var/run/docker.sock"
prod_no "supabase"     "supabase_db container is unhealthy: Timed out waiting for database"
prod_no "oom"          "Out of memory: Killed process 4821 (node) OOMKilled"
prod_no "passing-sum"  "Tests: 0 failed, 120 passed, 120 total"

echo "== SECUENCIA blip-infra-histórico + fallo TERMINAL de producto → product veta el reintento =="
seq_log="$(mk_log "seq-docker-then-ts" "$(printf '%s\n' \
  "[step 1] Cannot connect to the Docker daemon — retrying container boot..." \
  "[step 1] docker recovered, containers up" \
  "[step 2] running typecheck" \
  "src/lib/pay.ts(88,3): error TS2322: Type mismatch en el importe")")"
if infra_signature_match "$seq_log" && product_defect_match "$seq_log"; then
  ok "secuencia: infra casa (blip histórico) PERO product también → la lógica de retry VETA (no reintenta)"
else
  ko "secuencia: se esperaba infra-match ∧ product-match (para que el veto impida el reintento)"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "TEST-INFRA-RETRY: TODO OK"
  exit 0
else
  echo "TEST-INFRA-RETRY: FALLOS" >&2
  exit 1
fi
