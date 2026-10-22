# 05 — Fuentes, consultas y contrato de credenciales

> Fuente: TAL-5157 §B2 (las 4 fuentes con IDs reales) + el contrato del
> `sentry_doctor.sh` GO'd. Leer antes de tocar una fuente nueva o al levantar
> la torre. **Ningún token aparece nunca en argv, logs, sellos ni en el repo.**

## Doctrina de acceso (transversal)

- Credenciales por **header-file 0600** (`curl -H @<hdr>`), nunca en la línea
  de comando. El token JAMÁS se imprime, ni un fragmento.
- El doctor lee la **identidad del tenant por variable de entorno** (`SENTRY_
  DOCTOR_*`), sin ningún default de marca (gotcha #12 del SKILL, invariantes
  25b/c/e). Config ausente ⇒ PUERTA CERRADA con "config ausente", nunca asume
  una marca.
- El doctor construye la URL de cada fuente con un **literal de origen
  hardcodeado** (`https://sentry.io`, `https://api.supabase.com`, …) + la
  identidad declarada; NO acepta override de URL/host por entorno (cerró la
  clase de bypass de las rondas 1-6 de TAL-5157). El único inyectable es el
  cliente HTTP (`SENTRY_DOCTOR_HTTP_CLIENT`, solo para tests) y `main` ABORTA
  con exit 3 si detecta cualquier seam en producción. Ver la cabecera del
  propio `sentry_doctor.sh`.

## 1. Sentry issues API

- Org **`SENTRY_ORG`**, proyecto **`SENTRY_PROJECT`** (variables obligatorias del ciclo;
  el doctor exige `SENTRY_DOCTOR_SENTRY_ORG` y `SENTRY_DOCTOR_SENTRY_PROJECT` para la misma instancia).
- Ciclo (`sentry_triage.py`, PROJECT-scoped — NO el endpoint de organización,
  que puede mezclar grupos de otra superficie si la org tiene más de un
  proyecto Sentry, NO-GO #MAYOR-1 TAL-5157 r11):
  `GET /projects/<SENTRY_ORG>/<SENTRY_PROJECT>/issues/?query=is:unresolved&sort=date&statsPeriod=24h`,
  seguido de un 2º pase con `sort=freq`. `SENTRY_PROJECT` (env, sin default de
  marca) fija el slug del proyecto.
- Identidad exacta (el doctor la exige, no basta un 200):
  `GET /organizations/<SENTRY_ORG>/` → `slug == SENTRY_ORG`;
  `GET /projects/<SENTRY_ORG>/<SENTRY_PROJECT>/` → `slug == SENTRY_PROJECT`;
  issues **project-scoped**, shape SIEMPRE lista.
- Auth por header-file 0600. Regla de alerta existente en Sentry:
  `17042308` («Errors > 10/min in production»).
- Scopes del token: `org:read` + `project:read` + `event:read`.

## 2. Releases / deploys de Railway

- Release Sentry = `<SENTRY_RELEASE_PREFIX>@<sha-8>` (`src/lib/sentry-release.ts`,
  resuelto UNA vez en build time por `next.config.ts`; `SENTRY_RELEASE_PREFIX`
  es obligatorio por instancia y falla antes de consultar la red si falta).
- Correlación de deploy: **`railway status --json`** →
  `latestDeployment.{status,id}`. El doctor valida `.name` == el proyecto
  esperado (`SENTRY_DOCTOR_RAILWAY_EXPECTED`, obligatorio por instancia y sin default).
- **`NEEDS_APPROVAL` es un estado real y frecuente** que retiene el fix; el
  CEO lo destraba con `railway-approve.sh`. El Vigía lo **REPORTA, no lo
  aprueba** (límite duro B9).
- NUNCA la API GraphQL cruda: responde HTTP 200 con el error dentro del body
  (gotcha #10 del SKILL). Siempre el CLI, y validar exit code **Y** que el
  stdout parsea como JSON.

## 3. Better Stack Uptime

- Monitor **`4392730`** apuntando a **`/api/health/deep`** (ADR-0014
  amendment TAL-2505).
- El shallow `/api/health` es gate de deploy de Railway y **NO prueba
  Supabase**: **nunca** usarlo como señal de salud.
- API JSON:API (`{"data":{"id":…}}`); el doctor exige `data.id` == el monitor
  esperado. Token team-scoped.

## 4. Money-path SQL read-only (Supabase Management API)

- **`POST https://api.supabase.com/v1/projects/<SUPABASE_PROJECT_REF>/database/query`**
  (la ref viene de `SENTRY_DOCTOR_SUPABASE_PROJECT_REF`, nunca literal — hallazgo
  del texto CR-CLI corrida 3, medido: la ref del tenant estaba hardcodeada en
  este doc, invariante tenant-ready 25b), SOLO `select`/`with`.
- **Toda petición con `User-Agent` explícito** (gotcha #6 del SKILL:
  `error code: 1010` HTTP 400 = bloqueo Cloudflare por falta de User-Agent,
  NO error de Postgres — puede llegar tras un commit exitoso).
- Éxito = **HTTP 201** (no 200), body lista de filas-objeto (medido en vivo
  por C3 en TAL-5157: `select 1 as ok` → `201` + `[{"ok":1}]`).
- La ref del proyecto se valida con formato estricto `^[a-z0-9]{20}$` antes de
  construir la URL (corta traversal `ref/../otra`, bloqueante r7 de TAL-5157).
- Proxies ya rodados por C3: ventas stuck, `failed_1h`, sobre-crédito
  (`credited>total`), mismo importe completado 2+ veces por el mismo comprador.

## Linear (5ª superficie, de escritura — ver `04-contrato-de-issue.md`)

- `POST https://api.linear.app/graphql`, API key personal **sin** `Bearer`.
- El doctor pinga `viewer{id}` (string) como acreditación mínima.

## Sonda antes de tocar nada

`bash scripts/sentry_doctor.sh` (o `--solo-fuentes` para validación por un
tercero desde otra máquina; `--completo` —default— solo desde la torre real,
ver gotchas #13/#14 del SKILL). PUERTA CERRADA ⇒ no se opera ninguna fuente.
