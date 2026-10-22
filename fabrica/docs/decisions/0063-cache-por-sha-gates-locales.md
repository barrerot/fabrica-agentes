---
title: "ADR-0063: Caché por-SHA de build + reuso verificado del stack Supabase para los gates locales (opt-in, fail-toward-correct)"
created: 2026-07-17
updated: 2026-07-17
author: raulmartin
status: accepted
---

# ADR-0063: Caché por-SHA de build + reuso verificado del stack Supabase para los gates locales (opt-in, fail-toward-correct)

## Status

**Aceptado · 2026-07-17.** Documenta la decisión de [TAL-2728](https://linear.app/talent-engine/issue/TAL-2728) (acelerar los gates locales Fase 1) sobre cómo reutilizar el artefacto `.next` y el estado post-reset de Supabase entre shards SIN erosionar el modelo sellado anti-false-green de [ADR-0043](0043-fabrica-v2-mergeador-posture-cr.md) / TAL-2288 / TAL-2286. No supersede ningún ADR — extiende el contrato de los gates locales.

## Context

Los gates locales sellados (TAL-2288/TAL-2286) corren cada gate en un **árbol desechable** dentro de un runner **sin credenciales**, con **`supabase db reset --local` obligatorio desde cero**. Ese reset from-scratch es el aislamiento anti-false-green: hay un false-green documentado (volumen persistido atascado en la migración `20270836` mientras el árbol tenía hasta `20270842` → `phase_league_config` ausente → el gate corría contra un esquema stale y pasaba verde). Por eso los wrappers `scripts/ci/run-{db-guards,integration,e2e-shard}-local.sh` re-aplican TODAS las migraciones + seed desde cero antes de cada gate.

El coste: repetir `npm run build` (14 shards e2e) + `db reset` (db-guards, integration y los 14 e2e) gasta ~9-11 min por shard. TAL-2728 pide acelerar eso **probando equivalencia**, no asumiéndola: un artefacto cacheado solo se reutiliza si se puede DEMOSTRAR que corresponde al SHA/migration-set gateado, el reuso de Supabase debe preservar el reset from-scratch o probar equivalencia, y sin canales de exfiltración nuevos (el runner sigue sin credenciales; `TF_ENV_COPY` sigue prohibido).

**Frontera de repo.** El motor sellado (`talent-factory`: `run-local-gates.sh`, `seal-suite.sh`, `post-local-gates.sh`) NO vive en el repo del canal — solo los wrappers de producto. El coste de build+reset se gasta en los wrappers. Por eso esta decisión entrega el **mecanismo de caché verificado en los wrappers + una lib compartida**; el cableado/provisión del cache dir en los runners sellados es un follow-up de `talent-factory`.

## Decision drivers

- **Reutilizar solo si se prueba equivalencia por SHA + configuración efectiva** — contrato central del encargo. Un hit que restaure un artefacto no equivalente rompe la integridad del caché (peor que no cachear: un false-green silencioso).
- **Anti-false-green intacto** — el snapshot de Supabase SOLO puede existir porque un `db reset` real from-scratch lo produjo; nunca se fabrica un estado sin haber corrido el reset al menos una vez para esa clave.
- **La env efectiva del build debe modelarse por CONSTRUCCIÓN, no por enumeración** — dos rondas de plan-gate adversarial demostraron que enumerar a mano las vars que afectan `.next` NUNCA converge (aparece siempre otra heredada: `TA_COMMERCE_HOSTS` leída en carga de módulo por `src/proxy.ts`, y `SENTRY_ORG/PROJECT/AUTH_TOKEN`/`CI` leídas en build-time por `next.config.ts`). La única forma fail-closed es CERRAR el entorno del build a una allowlist explícita.
- **Regresión cero por defecto** — el mecanismo es opt-in: apagado salvo que un runner setee `TA_GATES_CACHE_DIR`. Con caché OFF, los wrappers ejecutan EXACTAMENTE las líneas de hoy.
- **No-exfiltración** — el caché guarda solo artefactos derivados del propio head + migraciones/seed públicas + datos del stack local (demo, sin secrets). El runner sigue sin credenciales.

## Decisión

Se adopta un mecanismo de **caché verificado, opt-in y fail-toward-correct**, implementado en la lib compartida `scripts/ci/lib/gate-cache.sh` (sourceada por los tres wrappers, sin efectos secundarios al sourcear) con dos artefactos, cada uno reutilizable SOLO ante coincidencia de un digest de contenido completo (la "clave"). Cualquier miss/duda/corrupción cae al camino from-scratch de hoy.

### Habilitación (opt-in, default OFF)

`ta_cache_enabled` devuelve verdadero solo si `TA_GATES_CACHE_DIR` está seteado a un directorio escribible y `TA_GATES_CACHE_DISABLE` no está puesto (kill-switch). Con caché OFF, `ta_db_reset` ejecuta el `supabase db reset --local` real y `ta_build` ejecuta `npm run build` con la env heredada — **idéntico a hoy, regresión cero**.

### A) Caché de build (`.next`) — build SANEADO + allowlist explícita

En el camino de caché, `npm run build` se invoca bajo un **entorno CERRADO** (`env -i` + base fija inerte: `PATH` mínimo derivado del dir de `node`, `HOME`, `NODE_ENV=production`, `TMPDIR`, `LANG`) + **solo la allowlist de app EN EFECTO**:

- todos los `NEXT_PUBLIC_*` seteados (se inlinean en el bundle),
- `CI` (consumida por `next.config.ts`),
- las vars no-públicas de `ta_build_env_allowlist_names()` que estén seteadas — hoy **solo `TA_COMMERCE_HOSTS`** (leída en carga de módulo por `src/proxy.ts` vía `parseCommerceHosts()`).

Todo lo demás (`SENTRY_*`, `STRIPE_*`, creds de foro…) se ELIMINA del entorno del build. Como el build **solo ve** la allowlist, la clave modela la env efectiva COMPLETA por construcción:

```text
build_key = sha256( HEAD^{tree} + node --version + versión de next + sha(package-lock.json)
                    + digest ordenado de la allowlist de app EN EFECTO )
```

`env -i` acota SOLO el subproceso del build; el paso e2e posterior conserva la env normal del shard (sus vars runtime `STRIPE_*`, etc.). El default-OFF NO sanea (build con env heredada como hoy), así que ambos modos nunca comparten artefactos.

**Ratchet de cobertura fail-closed** (`scripts/ci/check-build-env-coverage.sh`): escanea el árbol por lecturas scope-módulo de `process.env.<NAME>` no-públicas (declaraciones top-level + defaults de parámetro de firmas como `parseCommerceHosts()` + todo `next.config.ts`) y FALLA en rojo si aparece un NAME que NO esté (a) en `ta_build_env_allowlist_names()` (entra en la clave), o (b) en la lista documentada `INERT_IN_BUILD` (con el porqué: p.ej. `SENTRY_*` solo controlan la subida de source-maps, no los bytes del artefacto; `BETTER_STACK_*`/`EMAIL_*` son transporte runtime del servidor). Añadir una var de build nueva OBLIGA a clasificarla → o entra en la clave, o se declara inerte con justificación. Sin clasificación ⇒ rojo.

### B) Reuso de Supabase (snapshot post-reset)

```text
db_key = sha256( sha ordenado de supabase/migrations/*.sql + sha(seed.sql)
                 + bloque [db]/[db.*] de config.toml + versión de la CLI supabase )
```

Es el conjunto COMPLETO que `db reset` consume → misma clave ⇒ estado post-reset equivalente. **Miss**: corre el `db reset --local` REAL from-scratch (anti-false-green intacto) y luego **snapshotea el estado pristino** (pre-advisors/pre-pgtap/pre-fixtures; db-guards es el consumidor más sensible). **Hit**: **recrea la base `postgres` desde `template0` (vacía) y luego aplica el dump** — así el resultado es idéntico a un reset from-scratch; re-verifica el manifiesto (clave + integridad sha del artefacto); cualquier duda → reset real.

**Mecanismo primario**: dump/restore lógico (`pg_dump --clean --if-exists --no-owner --quote-all-identifiers` de todos los schemas, vía `docker exec supabase_db`), por ser el menos invasivo al flujo start/stop de los wrappers. Dos invariantes anti-false-green del restore, ambas exigidas por el code-gate adversarial y blindadas por tests: **(a) partir de estado LIMPIO real** — recrear la base desde `template0` ANTES de aplicar el dump; `--clean` sobre el stack vivo sólo emite `DROP` para objetos presentes en el snapshot, así que un objeto de un volumen STALE ausente del snapshot SOBREVIVIRÍA (reintroduce el false-green del volumen atascado); **(b) INCLUIR privilegios** — sin `--no-privileges`, para que GRANT/REVOKE/ACLs entren en el snapshot Y en la comparación de equivalencia (db-guards audita grants; estriparlos daría un restore divergente en authz invisible a la prueba). **Fallback** si el harness revela brechas de fidelidad: snapshot del volumen PGDATA (byte-idéntico).

**Prueba de equivalencia obligatoria** (`scripts/ci/test-gate-cache-equivalence.sh`, requiere docker+supabase): demuestra `dump(reset from-scratch) == dump(restore snapshot)` para la misma clave (mutando la DB entremedias para probar que el restore reescribe), y que una migración nueva ⇒ clave distinta ⇒ miss. Ejerce además las dos invariantes anti-false-green del restore: **(a)** un objeto stale (schema `tal2728_probe`) creado antes del restore NO sobrevive a la restauración (prueba que parte de estado limpio real); **(b)** un cambio de GRANT/REVOKE altera el dump normalizado (prueba que la equivalencia es sensible a ACLs). Este harness ARBITRA dump-lógico vs volumen-PGDATA y debe pasar en verde antes de habilitar el caché en cualquier runner. El self-test barato `scripts/ci/test-gate-cache.sh` (sin docker) añade guardas estáticas de ambos vectores: el restore de la lib recrea desde `template0` y ningún `pg_dump` usa `--no-privileges`.

### Verificación de integridad (fail-toward-correct)

Cada artefacto lleva un manifiesto sidecar con `key=` y `artifact_sha256=`. El restore re-verifica ambos: si la clave recomputada no coincide o el sha del artefacto no cuadra → miss (rebuild/reset real). Un manifiesto corrupto o incoherente NUNCA sirve un artefacto no verificado.

## Consecuencias

### Positivas

- Reuso de build y de estado Supabase entre shards con **equivalencia probable por construcción**, no best-effort.
- Anti-false-green preservado: el snapshot solo existe tras un reset real; con caché OFF el comportamiento es idéntico a hoy.
- El ratchet de env hace EXPLÍCITA y auditable la superficie de build: una var nueva que afecte `.next` no puede colarse sin entrar en la clave o declararse inerte.
- Sin canal de exfiltración nuevo; el runner sigue sin credenciales.

### Negativas / Riesgo aceptado

- **Mantenimiento del ratchet**: cada lectura scope-módulo de env no-pública nueva exige clasificarla (allowlist o `INERT_IN_BUILD`). Es el precio del fail-closed; sin él la clave divergiría en silencio.
- **Fidelidad del dump lógico**: el mecanismo primario asume que el dump/restore reproduce el estado post-reset; si el harness de equivalencia falla, hay que caer al fallback PGDATA (documentado, no implementado hasta que el harness lo exija).
- **Frontera wrapper↔motor**: los wrappers traen el mecanismo pero el caché no actúa hasta que un runner sellado de `talent-factory` provisione `TA_GATES_CACHE_DIR` (follow-up fuera de este repo). Hasta entonces, coste idéntico a hoy.

## Alternatives considered

- **Enumerar a mano las vars que afectan el build y meterlas en la clave.** Descartada: dos rondas de plan-gate probaron que nunca converge (siempre aparece otra heredada). Cerrar la env con `env -i` + allowlist es fail-closed por construcción.
- **Cachear `.next` sin sanear el entorno del build.** Descartada: `npm run build` hereda el entorno del proceso; un `.next` cacheado bajo otra env efectiva (p.ej. con `TA_COMMERCE_HOSTS` distinto o `SENTRY_*` activando subida de source-maps) no sería equivalente → false-green.
- **Reutilizar el snapshot de Supabase sin prueba de equivalencia.** Descartada: rompe el contrato central ("reutilizar solo si se prueba equivalencia") y el aislamiento anti-false-green. El harness de equivalencia es la condición de habilitación.
- **Caché siempre-ON.** Descartada: viola regresión-cero y adelanta el rollout antes de que el motor sellado provisione el cache dir. Opt-in default-OFF permite shadow/rollout controlado.

## Trazabilidad

- **Issue**: [TAL-2728](https://linear.app/talent-engine/issue/TAL-2728) — Acelerar gates locales Fase 1: caché por-SHA de build + reuso verificado de Supabase.
- **Código**: `scripts/ci/lib/gate-cache.sh` (lib), `scripts/ci/check-build-env-coverage.sh` (ratchet), `scripts/ci/test-gate-cache.sh` (self-test sin docker), `scripts/ci/test-gate-cache-equivalence.sh` (harness con docker), wrappers `scripts/ci/run-{db-guards,integration,e2e-shard}-local.sh`.
- **Contrato de gates**: [ADR-0043](0043-fabrica-v2-mergeador-posture-cr.md), TAL-2288/TAL-2286, `docs/runbooks/local-gates.md`.

## References

- [Next.js — Environment Variables](https://nextjs.org/docs/app/building-your-application/configuring/environment-variables)
- [Supabase CLI — Local Development](https://supabase.com/docs/guides/cli/local-development)
- `docs/runbooks/local-gates.md` — operación de los gates locales y del caché opt-in.
