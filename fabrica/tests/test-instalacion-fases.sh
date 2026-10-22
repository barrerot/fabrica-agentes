#!/usr/bin/env bash
# Integración con consumidores íntegros y contratos unitarios; infraestructura externa aislada.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
rc=0
python3 "$HERE/positivos-fases-reales.py" || rc=1
python3 "$HERE/test-instalacion-fases.py" || rc=1
python3 "$HERE/test-instalacion-homes.py" || rc=1
exit "$rc"
