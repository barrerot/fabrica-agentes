#!/usr/bin/env bash
# Interfaz compartida: las respuestas se procesan como datos, nunca como código.
instalacion_main() {
  local directorio
  directorio="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  python3 "$directorio/instalacion.py" "$@"
}
