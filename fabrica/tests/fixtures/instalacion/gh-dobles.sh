#!/usr/bin/env bash
# Contrato único para los dobles shell del paquete.
GH_CONTRATO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh_contrato.py"
export GH_CONTRATO
cerrar_doble_gh() {
  python3 "$GH_CONTRATO" --envolver "$1" || return $?
}
