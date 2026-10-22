#!/usr/bin/env bash
# Aislamiento del candado: entorno, exclusión real y manifiestos sin autoridad sobre él.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RLG="$ROOT/scripts/run-local-gates.sh"
T="$(mktemp -d)" || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  PASS $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1: esperado=$2 real=$3"; fi; }
git init -q -b main "$T/repo"
git -C "$T/repo" -c user.name=pruebas -c user.email=pruebas@example.invalid commit -qm base --allow-empty
SHA="$(git -C "$T/repo" rev-parse HEAD)"
cat > "$T/espera.sh" <<'EOF'
#!/usr/bin/env bash
: > "$1/$2.dentro"
for _ in $(seq 300); do [ -e "$1/$2.suelta" ] && exit 0; sleep 0.1; done
exit 1
EOF
man() {
  printf 'TF_PROJECT="ejemplo"\nTF_GATE_IDS="db-guards"\nTF_GATE_CMD_db_guards="bash %s/espera.sh %s %s"\nTF_INSTALL="true"\nTF_DB_GATE="always"\nTF_MIGRATIONS_DIR="migrations"\n' "$T" "$T" "$2" > "$1"
}
run() { TMPDIR="$T" TF_RUNNER_LOCK="$1" bash "$RLG" "$T/repo" --gate db-guards --manifest "$2" --sha "$SHA" --base "$SHA" --receipt "$3"; }
man "$T/a.conf" a; man "$T/b.conf" b
good=0
# shellcheck disable=SC2016
grep -qFx 'RUNNER_LOCK="${TF_RUNNER_LOCK:-/tmp/local-gates-runner.lock}"' "$RLG" && [ "$(grep -c '^readonly RUNNER_LOCK$' "$RLG")" = 1 ] && good=1
check 'default original y una asignación readonly del lock' 1 "$good"
run "$T/lock" "$T/a.conf" "$T/a.json" > "$T/a.log" 2>&1 & pa=$!
for _ in $(seq 300); do [ -e "$T/a.dentro" ] && break; sleep 0.1; done
flock -n "$T/lock" true; check 'el primer pesado posee el candado del entorno' 1 $?
run "$T/lock" "$T/b.conf" "$T/b.json" > "$T/b.log" 2>&1; rb=$?
good=0; [ "$rb" -ne 0 ] && grep -q 'otro run pesado' "$T/b.log" && [ ! -e "$T/b.dentro" ] && good=1
check 'segundo pesado bloqueado sin entrar al gate' 1 "$good"
: > "$T/a.suelta"; wait "$pa"; ra=$?
good=0; [ "$ra" = 0 ] && jq -e '.result=="PASS"' "$T/a.json" >/dev/null 2>&1 && good=1
check 'primero termina con receipt PASS al soltar' 1 "$good"
# El mismo lock sigue ocupado durante las tres inyecciones del manifiesto.
(exec 9>"$T/lock"; flock -x 9; : > "$T/holder"; exec sleep 30) & ph=$!
for _ in $(seq 300); do [ -e "$T/holder" ] && break; sleep 0.1; done
for forma in env primero ultimo; do
  case "$forma" in
    env) { printf 'TF_RUNNER_LOCK="%s"\n' "$T/otro"; cat "$T/b.conf"; } > "$T/m.conf" ;;
    primero) { printf 'RUNNER_LOCK="%s"\n' "$T/otro"; cat "$T/b.conf"; } > "$T/m.conf" ;;
    ultimo) { cat "$T/b.conf"; printf 'RUNNER_LOCK="%s"\n' "$T/otro"; } > "$T/m.conf" ;;
  esac
  run "$T/lock" "$T/m.conf" "$T/m.json" > "$T/$forma.log" 2>&1; rm_rc=$?
  good=0
  if [ ! -e "$T/otro" ] && [ ! -e "$T/b.dentro" ]; then
    case "$forma" in
      env|primero) [ "$rm_rc" -ne 0 ] && grep -q 'otro run pesado' "$T/$forma.log" && good=1 ;;
      ultimo) [ "$rm_rc" = 2 ] && grep -q 'el manifiesto no se pudo cargar' "$T/$forma.log" && good=1 ;;
    esac
  fi
  check "manifiesto no mueve el candado ($forma)" 1 "$good"
done
kill "$ph"; wait "$ph" 2>/dev/null || true
echo "RESULTADO: PASS=$PASS FAIL=$FAIL SKIP=0 TOTAL=$((PASS+FAIL))"
[ "$((PASS+FAIL))" = 7 ] && [ "$FAIL" = 0 ]
