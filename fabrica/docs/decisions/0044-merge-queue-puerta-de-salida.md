---
title: "ADR-0044: Merge queue de GitHub como puerta de salida — spike GO/NO-GO"
created: 2026-07-08
updated: 2026-07-08
author: raulmartin
status: proposed
---

# ADR-0044: Merge queue de GitHub como puerta de salida — spike GO/NO-GO

## Status

**Propuesto · 2026-07-08 · spike.** Este ADR es el **entregable de un spike** (TAL-2244,
"Puerta de Salida 2.0 · E4"): documenta la evaluación y **propone una recomendación GO/NO-GO
con la configuración**, pero **no aplica nada** — no toca branch protection, no crea la merge queue,
no modifica `scripts/setup-branch-protection.sh` ni `.github/workflows/*`. **La decisión final es
del lead**; al sellar se moverá a `accepted` (registrando el veredicto) o a `deprecated` si se
descarta. La disponibilidad de la feature está fechada a 2026-07-08 y debe re-verificarse contra
las docs de GitHub si el lead retoma el GO más adelante (regla 20).

## Terminología

- **Puerta de salida** — el gate final por el que un PR entra a `main`: hoy, el squash-merge que
  ejecuta el Mergeador tras verificar los gates AND contra un head fijo.
- **Merge queue (modo batch)** — cola nativa de GitHub que agrupa N PRs, valida el grupo contra el
  `main` fusionado **especulativo** en una construcción, y mergea el grupo si pasa.
- **`merge_group`** — el evento de GitHub Actions que dispara los checks sobre las ramas temporales
  especulativas creadas por la cola (base + PRs precedentes + el PR en cuestión).
- **Ledger** — `supabase_migrations.schema_migrations` en producción; la verdad del estado de
  migraciones (no `main`, no el working tree).
- **Invariantes head-pinned** — las garantías del Mergeador que dependen de un head **fijo y
  conocido**: `--match-head-commit`, el sentinel de CodeRabbit-CLI con `head_sha == HEAD`, y los
  gates AND corridos "inmediatamente antes del merge".
- **Bypass actor** — actor autorizado en un ruleset para saltarse una regla (p. ej. "Require merge
  queue") en PRs concretos.

## Context

La protección de `main` corre hoy con `strict=false` (verificado en vivo el 2026-07-08:
`gh api repos/org-ejemplo/Academia-Ejemplo-2.0/branches/main/protection` →
`{"strict": false, "contexts": ["validar-flujo-pr","validar-build","db-guards","e2e-ola3"], "required_linear_history": true, "required_conversation_resolution": true}`).
Esto es un **hack operativo**: el script versionado declara `strict: true`
(`scripts/setup-branch-protection.sh:135`), de modo que hay **drift script↔vivo**. El motivo del
hack está en el registro del repo: con `strict=true` ("require branches up to date") cada avance de
`main` deja a los demás PRs abiertos en `BEHIND` y los bloquea hasta rebase, generando churn de
re-runs (`.claude/memory/gotchas.md` TAL-855, 2026-06-05; runbook
[`security-deps-upgrades.md`](../runbooks/security-deps-upgrades.md) §"strict"). La tesis del
encargo: **GitHub merge queue en modo batch recuperaría la garantía de `strict` sin re-runs
manuales**, validando N PRs contra el `main` fusionado en una sola construcción.

El repo opera bajo **Fábrica v2** ([ADR-0043](0043-fabrica-v2-mergeador-posture-cr.md)): los canales
de producción entregan **PR draft + HANDOFF** y **no mergean**; una **estación de merge**
(`talent-merger`) es el **único serializador**: mantiene **1 PR en el slot de merge**, lo rebasa,
corre los gates AND contra ese head exacto y ejecuta
`gh pr merge <pr> --squash --delete-branch --match-head-commit <head>`. El estado de migraciones es
el **ledger** de prod, y el Mergeador es su serializador: renumera `migration_slots` contra
`ledger ∪ main ∪ drafts en vuelo` y **aplica una migración por turno** post-merge como gate de Done
(regla 24 de `CLAUDE.md`; `talent-merger/references/06-migraciones-y-slots.md`).

El pipeline de CI relevante: `.github/workflows/pr-gate.yml` (nombre "Puerta PR") dispara **solo en
`pull_request`** (líneas 3-6) y aloja los checks requeridos; `ci.yml` corre post-merge en `push` a
`main`; `deploy.yml` es `workflow_dispatch` (el día a día es auto-deploy nativo de Railway desde
`main`). **`merge_group` no está manejado en ningún workflow, script ni doc del repo.**

## Gate de viabilidad — tier y visibilidad (decisivo)

**El repositorio es privado y la organización está en plan GitHub Team** (verificado por API el
2026-07-08: `gh api repos/{owner}/{repo}` → `"private": true`, owner type `Organization`;
`gh api orgs/te-talentacademy` → `"plan": "team"`). **GitHub no ofrece merge queue para repos
privados fuera de GitHub Enterprise Cloud.** Según GitHub, la cola está disponible para
repositorios **públicos** en cualquier plan de organización y para repositorios **privados/internos
solo en organizaciones con GitHub Enterprise Cloud**; la respuesta de GitHub en la discusión de
comunidad sobre este punto es explícita:

> "Currently, merge queues are only available for GitHub Enterprise Cloud users and aren't supported
> on the GitHub Team plan."
> — GitHub Community, discusión #131130 ("Merge queues availability for Github Team private
> repositories?").

El propio `setup-branch-protection.sh` (líneas 107-129) ya documenta la restricción de tier para la
API de branch protection y rulesets en repos privados: sin Team/Enterprise devuelve 403. La feature
va un paso más allá: **merge queue exige Enterprise Cloud** para repos privados.

**Consecuencia:** en el tier actual (Team, privado) **la merge queue no se puede habilitar**. La
configuración propuesta en este ADR **no es accionable** sin un **upgrade a GitHub Enterprise Cloud**.
Este gate es el que hace pivotar la recomendación: **cualquier GO queda condicionado a ese upgrade**,
que es una decisión de coste/contrato del lead, no un cambio de repo.

## Decision drivers

- **Disponibilidad en el tier actual** (gate duro: privado + Team ⇒ no disponible).
- Recuperar la garantía "rama al día con `main`" sin el churn de re-runs de `strict=true`.
- **Preservar los invariantes head-pinned** del Mergeador (`--match-head-commit`, sentinel CR-CLI,
  gates AND contra head fijo).
- **Correctitud de migraciones**: serialización contra el ledger, una por turno (regla 24).
- Preservar el flujo **draft + HANDOFF** y la autoría del flip draft→ready.
- **Coste de CI** (los checks pesados: `db-guards` con Supabase efímero, `e2e-ola3` 9 shards,
  `e2e-pagos` 4 shards).
- Simplicidad operativa dado que la estación **ya es un serializador** (mergea ~1 PR por turno).

## Decision

Recomendación del spike (a ratificar por el lead), estructurada por las preguntas del encargo.

### Q1 — Convivencia con la serialización de migraciones

El prior del Orquestador ("queue solo para no-mig; migraciones fuera del batch") es **correcto en el
objetivo** pero **no tiene un mecanismo nativo de exclusión selectiva**. La merge queue se **exige a
nivel de rama base** (ajuste "Require merge queue" en branch protection / ruleset): una vez activa
sobre `main`, **aplica a todos los PRs que la apuntan**; GitHub **no ofrece un selector por-PR** ni
por HANDOFF/etiqueta para eximir PRs concretos. Las únicas separaciones **nativas** son:

- **(a) Bypass actor** en el ruleset para que el Mergeador mergee los PRs de migración **fuera de la
  cola**. Es un *bypass*, no una exclusión diseñada: las migraciones se saltan la puerta de salida y
  se apoyan en que la estación ya las serializa por el ledger. Funciona, pero convierte "la superficie
  más crítica" en la que rutinariamente salta el gate.
- **(b) Base branch de integración separada** para migraciones (sin merge queue), fundida a `main` por
  el Mergeador. Es un cambio arquitectónico mayor (dos ramas base, doble CI, reglas duplicadas).

Por qué las migraciones **no pueden ir en el batch**: la cola valida contra un `main` fusionado
**especulativo** y **no conoce el ledger de prod**; no renumera slots ni aplica migraciones. El
Mergeador elige slots contra `ledger ∪ main ∪ drafts en vuelo` y aplica **una por turno** post-merge
(gate de Done, regla 24). Dos PRs de migración en un mismo grupo mantendrían timestamps válidos contra
`main` pero **colisionarían contra el ledger** (colisión invisible con applies en vuelo). Conclusión:
**separar migraciones es obligatorio y correcto; la merge queue nativa no lo hace por selección, solo
por bypass o rama aparte.**

### Q2 — Configuración propuesta de la merge queue (NO aplicar)

Si el lead diera GO (post-Enterprise), la configuración mínima viable sería:

1. **`pr-gate.yml` — añadir el trigger `merge_group`** y blindar los jobs que hoy asumen un
   `pull_request`:
   - `on:` pasa a incluir `merge_group:` además de `pull_request` (hoy solo `pull_request`, líneas 3-6).
   - `concurrency.group` usa `github.event.pull_request.number`, **null en `merge_group`** (líneas
     11-13) → usar un fallback (`github.event.merge_group.head_sha || github.event.pull_request.number`).
   - `validar-flujo-pr` lee `github.event.pull_request.user.login` y `github.head_ref` (líneas 29-33),
     **null/empty en `merge_group`** → guardar el step para no fallar en eventos de cola (el nombre de
     rama ya se validó en el PR; en `merge_group` el step debe hacer *skip* con SUCCESS).
2. **Checks requeridos en la cola — separar el set vivo del canónico.** Enforced en vivo hoy = **4**:
   `validar-flujo-pr`, `validar-build`, `db-guards`, `e2e-ola3` (API). El script/ADR-0043 declara **6**
   (`scripts/setup-branch-protection.sh:91-98` añade `integration` y `e2e-pagos`, "visibles pero no
   enforced" hasta re-ejecutar con token admin). **La cola debe correr en `merge_group` exactamente el
   set que esté enforced** — y `db-guards` **no se retira nunca** (invariante del runbook
   `github-branch-protection.md`). Cualquier check requerido que **no** dispare en `merge_group` deja
   la cola colgada (la construcción especulativa nunca reporta) → los 4/6 deben añadir `merge_group` a
   su trigger.
3. **Ruleset "Require merge queue"** sobre `main`, con: merge method = **squash** (preserva
   `required_linear_history: true`), *build concurrency* acotado, *maximum PRs to merge* y *minimum*
   conservadores (batch pequeño), y *check timeout* holgado para los E2E. La merge queue **se
   configura por ruleset / toggle de branch protection**, no por la API clásica de
   `branches/{branch}/protection` que usa hoy el script → sería un mecanismo nuevo.
4. **`strict` — recomendación operativa, no mandato de GitHub.** GitHub presenta la cola como
   *alternativa* a "require up to date":

   > "The merge queue provides the same benefits as the **Require branches to be up to date before
   > merging** branch protection, but does not require a pull request author to update their pull
   > request branch." — GitHub Docs, *Managing a merge queue*.

   `required_status_checks.strict` sigue siendo una **regla separada** en la API de rulesets: con la
   cola activa, mantener `strict=false` es **redundante/operativo** (la cola aporta la garantía), **no
   algo que GitHub exija poner en `false`**. De adoptarse, reconciliar el drift dejando el script
   coherente con lo vivo.

### Q3 — Coste, riesgos y rollback

**Coste (corrige la premisa del encargo).** La idea "N PRs en UNA run" es **incorrecta**: la cola no
colapsa N ejecuciones de checks en una; corre los checks sobre **grupos especulativos** (posibles
ramas `merge_group` solapadas) y los *merge limits* gobiernan el **merge final**, no la combinación de
construcciones:

> "Merge limits do not combine `merge_group` builds. Merge limits only affect merges to the base
> branch once one or more `merge_group` has satisfied build checks." — GitHub Docs, *Managing a merge
> queue*.

Con la estación **single-serializer** (mergea ~1 PR por turno, no lotes de N), el tamaño de grupo es
≈ 1 la mayor parte del tiempo → **no hay amortización real** y la cola **añade overhead** (una
construcción `merge_group` extra por PR sobre los checks pesados: `db-guards` Supabase efímero,
`e2e-ola3` 9 shards, `e2e-pagos` 4 shards).

**Riesgos (rompen invariantes de Fábrica v2).** La cola valida y mergea sobre un **SHA especulativo
del `merge_group`** (rama/commit temporal que combina base + PRs precedentes + el PR), un SHA
**distinto del head auditado** del PR. GitHub **no muta el `headRefOid` del PR** — pero lo que se
integra a `main` **no es el head auditado**, sino ese SHA especulativo, que ninguna de las
atestaciones del Mergeador cubrió:

- El **head verificado deja de ser el que se integra**: el guard `--match-head-commit <head>` del
  Mergeador queda fuera de juego porque **la cola —no el Mergeador— ejecuta la integración**, y la
  hace sobre el SHA especulativo del `merge_group`, no sobre el head auditado.
- El sentinel de **CodeRabbit-CLI** (`.claude/.cr-review-result.json` exige `head_sha == HEAD`) y el
  HANDOFF están anclados al **head auditado**; el SHA especulativo que realmente se integra **no fue
  atestado** por CR-CLI ni por el HANDOFF.
- Los **gates AND "inmediatamente antes del merge"** se verifican contra el head auditado fijo, no
  contra el SHA especulativo que la cola construye y mergea después.
- **Desacopla el apply de migración same-turn**: la cola mergea de forma asíncrona; el gate de Done
  (regla 24: apply + advisors + ledger confirmados en el mismo turno) exige que el Mergeador controle
  el momento del merge.
- El **flip draft→ready** lo hace hoy el Mergeador (`verify-handoff.sh` exige entrega en DRAFT); la
  cola consume PRs *ready-no-draft*, así que la autoría del ready y sus precondiciones (CR limpio /
  App APPROVED, higiene de labels) siguen **aguas arriba** de la cola.

**Rollback.** Trivial y sin estado: deshabilitar "Require merge queue" en el ruleset y (si se tocó)
devolver `strict` a su valor previo. No hay datos que migrar ni esquema que revertir.

### Interacción con el flujo draft + HANDOFF

La cola solo reemplazaría el `gh pr merge` final + el churn de re-rebase de `strict=true`; **no**
sustituye la intake del Mergeador (validar HANDOFF, rebasar, renumerar slots, correr CR-CLI,
refactorizar findings). Como además rompe los invariantes head-pinned de esa intake, su adopción
**exigiría re-arquitectar** el head-pinning del Mergeador (CR-CLI y `--match-head-commit` asumen que
lo que se integra es el head auditado, pero la cola mergea el **SHA especulativo del `merge_group`**,
distinto de ese head) — coste alto y no cubierto por este spike.

### Recomendación GO/NO-GO

**NO-GO operativo hoy.** Dos razones independientes, cualquiera de ellas suficiente:

1. **Viabilidad**: merge queue no está disponible para repos privados en GitHub Team (gate duro).
2. **Arquitectura**: aun con Enterprise Cloud, la estación de merge **ya provee** la garantía "rama al
   día" (rebase por-PR + gates AND contra head fijo) siendo un serializador único; la cola
   **duplicaría** eso mientras **rompe** invariantes head-pinned y **no** amortiza coste con grupo ≈ 1,
   y **no** ofrece exclusión selectiva de migraciones (solo bypass o rama aparte).

**GO condicionado** (documentado para el futuro, decisión del lead): (1) upgrade a **Enterprise
Cloud**; (2) resolver la exclusión de migraciones (bypass actor del Mergeador **o** base branch de
integración); (3) re-arquitectar el head-pinning del Mergeador (CR-CLI, `--match-head-commit`,
apply same-turn); (4) aceptar que no hay amortización de coste con el station single-serializer.
Mientras tanto, **mantener `strict=false` + el Mergeador como serializador** (statu quo), que ya
cubre el objetivo del encargo.

## Consequences

### Positivas

- Deja **decidible** el GO/NO-GO con evidencia verificada (tier real + docs de GitHub a fecha) en vez
  de asumir que la cola "recupera strict".
- Documenta por qué el statu quo (`strict=false` + estación serializadora) **ya cumple** la garantía
  que motivaba el encargo, evitando trabajo de adopción innecesario.
- Deja lista la **config propuesta** (trigger `merge_group`, guardas de jobs, ruleset) por si el lead
  ejecuta el GO condicionado tras un upgrade.

### Negativas / residuales

- No se resuelve el drift `strict` script↔vivo (queda como nota; su reconciliación es trabajo aparte,
  no de este spike docs-only).
- Si GitHub habilitara merge queue en Team (posible en el futuro), este ADR debe re-evaluarse: la
  disponibilidad está fechada a 2026-07-08.

### Neutrales

- No cambia nada operativo hoy (docs-only). La puerta de salida sigue siendo el Mergeador.

## Alternatives considered

- **(a) Statu quo — `strict=false` + estación serializadora (recomendada).** La garantía "rama al día"
  la da el rebase por-PR del Mergeador; coste cero, sin romper invariantes. Es lo que se recomienda
  mantener.
- **(b) `strict=true` permanente.** Recupera la garantía pero reintroduce el churn de re-runs
  (TAL-855) que motivó el hack; con la estación serializadora el churn está acotado a "el siguiente en
  el slot", pero sigue siendo fricción sin beneficio neto sobre (a).
- **(c) Merge queue para todos los PRs.** Requiere Enterprise Cloud y rompe el head-pinning del
  Mergeador y la serialización de migraciones. Descartada.
- **(d) Merge queue solo no-mig, migraciones vía bypass actor.** La única forma nativa de "separar";
  hace que la superficie más crítica salte rutinariamente la puerta. Solo viable post-Enterprise y con
  el head-pinning re-arquitecturado.
- **(e) Base branch de integración para migraciones.** Aísla migraciones de la cola a costa de doble
  rama base / doble CI. Sobre-ingeniería para el volumen actual.
- **(f) Bot de auto-rebase (p. ej. dependabot-style) en vez de cola.** Mitiga el churn de `strict=true`
  sin cola ni Enterprise, pero re-dispara CI por rebase; inferior a (a) dado que la estación ya rebasa.

## Sealing checklist

- [ ] El lead ratifica el veredicto: **NO-GO operativo** (mantener statu quo) **o** **GO condicionado**
      (con upgrade a Enterprise Cloud + las 4 condiciones de §Recomendación).
- [ ] Si GO: crear issue(s) de seguimiento para (1) upgrade de plan, (2) mecanismo de exclusión de
      migraciones, (3) re-arquitectura del head-pinning del Mergeador, (4) config `merge_group` en
      `pr-gate.yml` + ruleset.
- [ ] Si NO-GO: registrar la decisión y, aparte de este spike, abrir el fix del **drift `strict`
      script↔vivo** (`setup-branch-protection.sh` declara `true`, vivo `false`).
- [ ] Re-verificar la disponibilidad de merge queue en el tier vigente contra las docs de GitHub a la
      fecha del sello (regla 20).
- [ ] Mover `status: proposed → accepted` (o `deprecated`) + `updated:` con la fecha; cross-ref en el
      índice de `README.md`.

## Trazabilidad

- **Linear**: [TAL-2244](https://linear.app/talent-engine/issue/TAL-2244) (este spike;
  "Puerta de Salida 2.0 · E4").
- **Fábrica v2 / estación de merge**: [ADR-0043](0043-fabrica-v2-mergeador-posture-cr.md);
  `.claude/skills/talent-merger/SKILL.md` §7 y `references/02-protocolo-por-pr.md` §§6-8 (gates AND,
  `--match-head-commit`); `references/06-migraciones-y-slots.md` + el anexo de la instancia
  (PROC-M13/M14/M15, serialización de migraciones contra el ledger).
- **Puerta de salida actual (config)**: `scripts/setup-branch-protection.sh:91-98` (6 checks
  declarados) y `:131-152` (payload; `strict:true` en el script), `:107-129` (nota de tier);
  `.github/workflows/pr-gate.yml` (`on: pull_request`, jobs `validar-flujo-pr`/`concurrency`).
- **Churn de `strict=true`**: `.claude/memory/gotchas.md` (TAL-855); runbook
  [`security-deps-upgrades.md`](../runbooks/security-deps-upgrades.md);
  [`github-branch-protection.md`](../runbooks/github-branch-protection.md).
- **Tests/checks**: [ADR-0016](0016-tests.md) (stack de tests, gate `e2e-ola3`).
- **Regla operativa de migraciones**: regla 24 de `CLAUDE.md` (BD 100% sync antes de avanzar).

## References

- [Managing a merge queue — GitHub Docs](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue)
  (enforcement branch-level "Require merge queue"; evento `merge_group`; "Merge limits do not combine
  `merge_group` builds…"; comparación con "Require branches to be up to date").
- [Merging a pull request with a merge queue — GitHub Docs](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/merging-a-pull-request-with-a-merge-queue)
- [Merge queues availability for Github Team private repositories? — GitHub Community #131130](https://github.com/orgs/community/discussions/131130)
- [Merge Queue feature availability? — GitHub Community #51483](https://github.com/orgs/community/discussions/51483)
- [GitHub merge queue is generally available — GitHub Blog](https://github.blog/news-insights/product-news/github-merge-queue-is-generally-available/)
- [MADR 4.0](https://adr.github.io/madr/)
