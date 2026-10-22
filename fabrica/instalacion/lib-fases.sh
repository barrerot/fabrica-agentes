#!/usr/bin/env bash
# Biblioteca de entrada: rutas absolutas, sin cargar configuración como código.
FASES_RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export FASES_RAIZ
fases_ejecutar() {
  python3 "$FASES_RAIZ/instalacion/scripts/fases.py" "$@"
}
