---
title: "Runbook — Gobierno de gates: cómo un gate nuevo entra en `local-gates`"
created: 2026-07-17
updated: 2026-07-17
author: raulmartin
status: active
---

# Runbook · Gobierno de gates del proyecto Go to Producción

Cómo aterriza un gate de calidad nuevo (ejemplos vigentes: `a11y-smoke`, `bundle-budget`) y
cómo pasa de **advisory** (no bloquea) a **requerido** (bloquea merges) bajo el modelo
**`local-gates`** vigente. Este doc gobierna el ciclo de vida de un gate; la mecánica del
propio commit-status vive en `docs/runbooks/local-gates.md` (léelo primero si no conoces el
motor).

## Por qué existe este doc

El proyecto Go to Producción introduce gates de calidad nuevos (accesibilidad, presupuesto de
bundle, …) que no pueden aterrizar como bloqueantes desde el día uno: el baseline de `main`
aún no está limpio para ellos. Necesitan una fase de aterrizaje sin bloquear merges, y un
criterio explícito para pasar a bloqueantes. Ese es el problema que resuelve este doc — pero
**bajo el contrato real del motor vigente**, no bajo el modelo antiguo de GitHub Actions.

**GitHub Actions está OFF** (TAL-2286, 2026-07-09): `.github/workflows/pr-gate.yml` no se
ejecuta. El único required check de branch protection en `main` es el commit-status
**`local-gates`** (`scripts/setup-branch-protection.sh`). Mecánica completa en
[`local-gates.md`](local-gates.md) — este doc no la duplica.

## El modelo Actions-era está superseded

Antes de TAL-2286, "soft" significaba "el job de `pr-gate.yml` corre pero no está en
`REQUIRED_CHECKS`" y "promover" significaba editar `REQUIRED_CHECKS` + re-ejecutar
`scripts/setup-branch-protection.sh`. Ese modelo **ya no aplica**: hoy
`scripts/setup-branch-protection.sh` gestiona un único context (`local-gates`) y
**re-ejecutarlo no añade ni promueve gates individuales**.

## Gobierno de gates HOY (`local-gates`)

El motor obtiene el **conjunto esperado de gates exclusivamente del manifiesto**
(`talent-factory/manifiestos/academy.conf`) leído en runtime — ningún gate participa del
pipeline sellado si no está declarado ahí. Esto define dos, y solo dos, estados posibles:

| Estado | Dónde vive | Efecto |
|---|---|---|
| **Advisory** | Fuera del manifiesto | No participa del pipeline sellado — **no puede** usar la vía sellada canónica (el runner necesita una entrada del manifiesto para saber cómo invocarlo) y por tanto no produce evidencia/receipt. Solo puede correrse como **diagnóstico manual en la máquina del propio dev** (`npm run <script>` local) — **nunca por la estación**: la estación posee credenciales y el contrato prohíbe que ejecute código de head_sha bajo cualquier forma, incluida una corrida "informativa" (ver [`local-gates.md`](local-gates.md) §Arquitectura: "quien tiene credenciales jamás ejecuta código de head_sha"). **No bloquea nada.** |
| **Requerido** | Dentro del manifiesto | Participa del pipeline sellado. Receipt `FAIL` o ausente ⇒ el agregador no postea `local-gates=success` ⇒ merge bloqueado (fail-closed). |

**No existe un estado intermedio ("soft" dentro del pipeline, corriendo pero sin bloquear).**
Añadir un gate al manifiesto lo vuelve requerido de inmediato — es una propiedad del diseño
fail-closed del agregador (ver [`local-gates.md`](local-gates.md) §Arquitectura), no una
limitación de este doc.

## Criterios para incluir un gate candidato en el manifiesto

Antes de que un gate advisory pase a vivir en el manifiesto:

1. **Baseline limpio** — cero violaciones preexistentes contra `main` en su head actual. Un
   gate que arranca requerido con deuda existente bloquea PRs no relacionados con esa deuda.
2. **Determinismo** — el gate no debe producir falsos positivos/negativos intermitentes
   (flaky). Es una precondición cualitativa: el umbral operativo concreto (cuántas corridas
   observar, ventana de tiempo, tolerancia) lo fija el lead caso por caso al ratificar la
   inclusión — este doc no fija un número fijo de corridas como si fuera un contrato universal.
3. **Ratificación explícita del lead ANTES de fusionar el cambio de manifiesto** — la
   persistencia de esa ratificación es el propio historial de commit/PR que añade el gate a
   `talent-factory/manifiestos/academy.conf` (mensaje de commit + aprobación explícita del
   lead antes del merge). Esto es **distinto** de `manifiestos/RATIFICACIONES.log` /
   `scripts/ci/REGISTRY-RATIFICACIONES.log`, que son mecanismos de anti-reducción exclusivos
   para **retiros/reducciones** del conjunto de gates (ver [`local-gates.md`](local-gates.md)
   §Arquitectura) — una inclusión nueva no escribe ahí.

## Mecanismo real de inclusión (no es un dial gradual)

**Orden crítico**: añadir el gate al manifiesto lo vuelve requerido de inmediato en el
**siguiente** post de `local-gates` (§Gobierno de gates HOY arriba) — por eso la validación
completa debe ocurrir **ANTES** de que ese cambio de manifiesto sea el que gobierna `main`,
nunca después:

1. Preparar el cambio de manifiesto como **candidato, todavía sin fusionar**: el gate nuevo en
   `talent-factory/manifiestos/academy.conf`, su wrapper (`scripts/ci/run-*-local.sh`) y, si
   posee stack de shards, la entrada correspondiente en `scripts/ci/e2e-shards.json`. Mientras
   el candidato no se fusiona, `local-gates` (el status real que gobierna `main`) sigue
   produciéndose sin él.
2. Con ese manifiesto candidato (vía `--manifest` apuntando al candidato, no al vigente),
   correr la suite **completa** (todos los gates + shards del registro, incluido el nuevo)
   contra un SHA real y publicarla como contexto de rollout **`local-gates-test`** — nunca
   como `local-gates` — hasta confirmar una corrida verde de punta a punta (ver
   [`local-gates.md`](local-gates.md) §Rollout). Es la validación del **motor completo** con
   el candidato, no un modo "soft" del gate individual.
3. **Solo entonces** fusionar el cambio de manifiesto candidato (con la ratificación del punto
   anterior ya obtenida). A partir de ese commit, el **siguiente** post de `local-gates` ya
   incluye el gate nuevo como requerido — no hay paso de "promoción" adicional después de
   fusionar.
4. `scripts/setup-branch-protection.sh` **no cambia** en este proceso: sigue gestionando el
   único context `local-gates`; no se edita para "añadir" el gate nuevo como lo hacía la era
   Actions.

Los **retiros o reducciones** del conjunto de gates (no las adiciones) exigen ratificación
durable append-only en `manifiestos/RATIFICACIONES.log` / `scripts/ci/REGISTRY-RATIFICACIONES.log`
con `ref=` de la aprobación — ver [`local-gates.md`](local-gates.md) §Arquitectura.

## Gates candidatos pendientes (estado a 2026-07-18)

Ninguno de los tres gates siguientes está en el manifiesto real del motor, así que ninguno
bloquea merge todavía. `functions`/`deno` y `bundle-budget` ya existen en el repo (TAL-2030
y TAL-1904 respectivamente); `a11y-smoke` aún no existe en el repo:

- **`functions` / `deno`** ([TAL-2030](https://linear.app/talent-engine/issue/TAL-2030),
  advisory): `npm run functions:check` (`scripts/check-functions.sh`) — `deno fmt --check` +
  `deno lint` + `deno check` sobre `supabase/functions/**` (Edge Functions Deno, excluidas del
  toolchain Node). A diferencia de los otros dos, YA existe en el repo (script + npm + `run_gate`
  en `scripts/draft-handoff.sh`) con baseline limpio y corre en el flujo de canales; solo falta
  cablearlo al manifiesto para volverlo requerido. Detalle en
  [`local-gates.md`](local-gates.md) §Candidato de gate NUEVO: `functions` / `deno`.
- **`a11y-smoke`** ([TAL-1838](https://linear.app/talent-engine/issue/TAL-1838), estado
  `Todo`): no existe todavía en el repo ni en el manifiesto. Spec de humo con `axe` sobre
  rutas clave del portal/admin. Baseline limpio previsto en M5.
- **`bundle-budget`** ([TAL-1839](https://linear.app/talent-engine/issue/TAL-1839) /
  [TAL-1904](https://linear.app/talent-engine/issue/TAL-1904)): **tooling advisory
  aterrizado** (script de medición `scripts/perf/bundle-budget.mjs`, registro de
  presupuestos por ruta `scripts/perf/bundle-budgets.json`, wrapper
  `scripts/ci/run-bundle-budget-local.sh`) — corre hoy solo como diagnóstico local, fuera
  del manifiesto. Detalle completo en [`bundle-budget.md`](bundle-budget.md). Pendiente
  para inclusión en el manifiesto: baseline limpio ⇐
  [TAL-1900](https://linear.app/talent-engine/issue/TAL-1900) (code-splitting, in
  progress — los `budget_bytes` actuales son provisionales contra `main` pre-splitting) +
  ratificación del lead sobre el fragmento de manifiesto (paquete listo en
  `bundle-budget.md` §Paquete de promoción). Desviación de herramienta: mide con un
  parser propio de manifiestos Turbopack en vez de `size-limit` (motivo documentado en
  `bundle-budget.md` — `size-limit` no expresa first-load JS por ruta App Router bajo
  Turbopack, y el repo no usa webpack en producción).

Cuando `a11y-smoke` se implemente seguirá el mismo ciclo: nace advisory (fuera del
manifiesto), corre como diagnóstico hasta cumplir los criterios de la sección anterior, y
solo entonces se incluye en el manifiesto — momento en el que pasa a requerido de
inmediato. La inclusión de cada gate es un paso posterior y ratificado por separado.

## Referencias

- Mecánica del commit-status y el motor: [`local-gates.md`](local-gates.md).
- Script de branch protection: `scripts/setup-branch-protection.sh` (gestiona el único
  context `local-gates`; su cabecera documenta TAL-2286/TAL-2288).
- Linear: TAL-2286 (gates 100 % locales) · TAL-2288 (motor v2) · TAL-1837 (parent, "gates
  a11y-smoke/bundle-budget modo soft inicial") · TAL-1838 (`a11y-smoke`) · TAL-1839
  (`bundle-budget`).
