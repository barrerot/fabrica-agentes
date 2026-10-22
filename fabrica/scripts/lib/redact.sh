#!/usr/bin/env bash
# lib/redact.sh — Redacción de secretos en logs del motor (TAL-2288).
#
# ESPEJO del redactor canónico `tco_redact` de
# talent-channel-operation/scripts/lib.sh — mantener AMBOS sincronizados: si se añade
# una familia de tokens allí, se añade aquí en el mismo cambio. No reinventar filtros
# más pobres (doctrina del audit de TAL-2288: la redacción es defensa SECUNDARIA;
# la primaria es no imprimir logs de gates — solo rutas protegidas).
#
# Cubre: gh[psour]_ (TODOS los formatos de token GitHub: ghp_ ghs_ gho_ ghu_ ghr_),
# github_pat_ (fine-grained), sbp_/sb_secret_/sb_publishable_ (Supabase),
# tskey-* (Tailscale), lin_api_ (Linear), cr-... {20,} (CodeRabbit; el umbral evita
# redactar el label corto `cr-review`), y cualquier VAR= con sufijo de credencial.

lg_redact() {
  sed -E 's/(sbp_|sb_secret_|sb_publishable_|tskey-[a-z]+-|gh[psour]_|github_pat_|lin_api_)[A-Za-z0-9_-]{6,}/\1REDACTED/g;
          s/cr-[A-Za-z0-9_-]{20,}/cr-REDACTED/g;
          s/(([A-Z0-9_]*(SECRET_ACCESS_KEY|ACCESS_KEY_ID|API_KEY|SECRET|TOKEN|KEY))=)[^[:space:]]+/\1REDACTED/g'
}
