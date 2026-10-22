---
title: "ADR-0043: Fábrica v2 — pipeline de merge con Mergeador y posture CodeRabbit por riesgo"
created: 2026-07-07
updated: 2026-07-07
author: raulmartin
status: accepted
---

# ADR-0043: Fábrica v2 — pipeline de merge con Mergeador y posture CodeRabbit por riesgo

## Status

**Aceptado · 2026-07-07** (decisión del lead 2026-07-08 en la spec
[TAL-2192](https://linear.app/talent-engine/issue/TAL-2192); implementación fase 1 en
[TAL-2193](https://linear.app/talent-engine/issue/TAL-2193)). **No supersede ningún ADR
numerado**, pero **amenda la doctrina operativa del modelo "CR 2.0"** (runbook
[`coderabbit-cli-pre-pr.md`](../runbooks/coderabbit-cli-pre-pr.md), TAL-1502/TAL-1518, y la
doctrina Ola-5 TAL-1596) en dos puntos que quedan **retirados para los canales de
producción**:

1. «review real del App + label `cr-review` obligatoria en TODO merge» → **retirada**: el
   **CLI limpio AUTORIZA el merge** en cualquier superficie (ruling del lead 2026-07-08:
   «el CLI limpio autoriza el merge y esto queda así para siempre; si tenemos aprobación
   CLI no gastamos GH»). El App queda EXCLUSIVAMENTE como **fallback** cuando no hay
   aprobación CLI (rate-limit / CLI caído).
2. «CLI de CodeRabbit como gate pre-push corrido por el propio canal autor» → el canal de
   producción **deja de correr CodeRabbit por completo**; el consumo de ambos buckets (CLI
   y App) se centraliza en el **Mergeador**.

El racional anti-self-report de la doctrina anterior **se preserva**: aquella exigía review
del App porque el CLI lo corría el canal AUTOR (auto-atestación). En este modelo el CLI lo
corre el **Mergeador**, un actor independiente del autor, por lo que las capas de defensa
quedan: code-audit del canal (auditor) + CLI-por-Mergeador + checks de CI.

Precedente de forma: [ADR-0033](0033-retirada-cubic.md)/[ADR-0038](0038-detalle-madr-0033-retirada-cubic.md)
(cambio de política de reviewer documentado por ADR).

## Terminología

- **Canal** — término canónico para la unidad de trabajo (contenedor con equipo de
  desarrollo + equipo de auditoría). **«Carril» es sinónimo histórico de «canal»: si
  alguien dice carril se refiere a canal.** Los paths/scripts existentes que usan "carril"
  (`docs/carriles/`, `.claude/carril.local`, `audit-carril.sh`, flags `--carril`…) NO se
  renombran (romperían tooling vivo); la prosa nueva usa "canal".
- **Canal de producción** — canal que implementa issues y entrega PR draft + HANDOFF.
- **Mergeador** — coordinador de la 2ª estación (con canales propios de refactorización):
  único consumidor de CodeRabbit, dueño del merge y del post-merge.
- **Encargo** — unidad de despacho: bundle de 1..N issues cohesivos = una rama = un PR.
- **HANDOFF** — comentario obligatorio del PR draft (plantilla
  [`handoff-pr-draft.md`](../templates/handoff-pr-draft.md)): la interfaz entre estaciones.

## Context

Con el modelo CR 2.0, cada canal corre el CLI de CodeRabbit pre-push y el merge exige
además review real del App + label `cr-review` sobre el head auditado. En operación
multi-canal esto convirtió los rate-limits de CodeRabbit en el cuello dominante del
sistema: los buckets (CLI ~10/h · App ~10/h, con Fair Usage que degrada el bucket de PR a
~1 review/hora en rachas) se consumen desde N canales a la vez, y cada canal quema un
30-50% de su wall-clock esperando review/merge en vez de implementar. El síntoma se midió
en las olas de M11 y el drain de M1 (reviews del App de 15-40 min; colas de merge
serializadas detrás del bucket).

El framing de la solución es una **fábrica**: obra gruesa (canales de producción, que no
paran jamás) → acabados (Mergeador, que pule y funde 24/7). La spec completa del diseño,
con métricas del piloto y datos base observados, vive en TAL-2192.

## Decision drivers

- **Throughput de implementación**: recuperar el 30-50% de wall-clock que los canales
  queman esperando CodeRabbit/CI/merge (≈1.5-2× capacidad efectiva sin hardware nuevo).
- **Usar el bucket CLI 24/7 y no gastar el del App**: un solo consumidor (Mergeador)
  programa la cola contra el rate-limit del CLI; el bucket del App (degradable por Fair
  Usage) queda en reserva para el fallback — consumo esperado ~0 reviews App/PR.
- **No degradar la seguridad**: mantener defensa en profundidad sin self-report — el CLI
  lo corre un actor independiente del autor (misma orquestación de review que el App); los
  required checks de CI no cambian y las destructivas conservan el GO del lead.
- **Enforcement real, no doctrina de papel**: cada garantía nueva lleva su mecanismo
  verificable (sentinel + hook, script de verificación post-push, config de CodeRabbit
  activada). Sin mecanismo, la regla no se promete.
- **Más issues por viaje**: bundles cohesivos por PR (encargos) amortizan plan-gate,
  code-audit, review y merge.

## Decision

### 1. Canales de producción: entregan PR DRAFT + HANDOFF y se olvidan

El loop del canal termina en: plan-gate → código → code-audit (GO del auditor) → gates
locales verdes (`typecheck`/`lint`/`build`) → **push de entrega → PR en DRAFT + comentario
HANDOFF → siguiente encargo**. El canal de producción **NO corre CodeRabbit (ni CLI ni
App), no espera CI de GitHub, no rebasa post-entrega y no mergea**.

Mecanismo (enforcement):

- `scripts/draft-handoff.sh` valida los gates locales y emite el sentinel
  `.claude/.draft-handoff` (atado al SHA de HEAD, one-shot). `.githooks/pre-push` acepta
  ese sentinel como **exención SOLO del Gate 2** (CR-CLI); el Gate 1 de auditoría
  (`.claude/.audit-go`, `scripts/check-push-audit.sh`) queda **intacto** — un draft sigue
  exigiendo código auditado.
- `scripts/verify-handoff.sh <pr>` verifica **post-push** que la entrega es real
  (fail-closed): PR en draft, comentario HANDOFF con bloque machine-readable válido,
  `head_sha` == `headRefOid`, `closes TAL-N` por cada issue del encargo. Lo corren el
  canal al entregar, el coordinador al validar (deber nuevo) y el Mergeador en el intake.

### 2. Mergeador: único consumidor de CodeRabbit, dueño del merge 24/7

Protocolo por PR (detalle operativo en el skill `talent-merger`): validar HANDOFF
(rechazar draft sin él) → rebase sobre `main` → renumerar slots de migración contra el
**ledger real de prod** → correr CR-CLI → rutas:

- **Ruta A** — CLI limpio (CUALQUIER superficie) → ready **sin** label → gates AND →
  merge. **El CLI limpio autoriza el merge; con aprobación CLI no se gasta review del
  App** — nunca.
- **Ruta B (fallback)** — CLI no disponible (rate-limit / caído) → label `cr-review` +
  ready → review del App **APPROVED@head** → gates AND → merge. Única situación en que se
  consume el bucket del App.

Findings (CLI o App) → **canales de refactorización propios** del Mergeador (dev +
auditor), auditando contra los **invariantes del HANDOFF** → push → re-gate → merge.
Excepción de umbral alto: finding = **defecto de DISEÑO** → parquear el PR + issue nueva
al pool del Orquestador (bounce-to-pool). Migración destructiva → **GO explícito del lead
SIEMPRE** (coherente con la EXCEPCIÓN ÚNICA de la regla 24 de CLAUDE.md).

**Gates AND del merge** (objetivos, verificables por API; fail-closed): CLI-limpio
trazable (o, SOLO en fallback, App APPROVED@head) **∧** todos los required checks de
branch protection verdes (fuente canónica: `scripts/setup-branch-protection.sh`; hoy 6:
`validar-flujo-pr`, `validar-build`, `db-guards`, `e2e-ola3`, `integration`, `e2e-pagos`)
**∧** spot-check de disjunción/hot-files **∧** slot de migración sin colisión.

Post-merge en el mismo turno: apply de migración + advisors + confirmación del ledger →
Done (vía magic word `closes TAL-N`). El actor del apply a prod pasa del canal al
**Mergeador** (amendment de la regla 24 de CLAUDE.md); los canales declaran slots en el
HANDOFF y no aplican a prod.

### 3. Posture CodeRabbit: «el CLI limpio autoriza el merge — siempre»

Ruling del lead (2026-07-08, definitivo): **la aprobación del CLI autoriza el merge en
cualquier superficie; con aprobación CLI NO se gasta review del App de GitHub**. El App
existe solo como fallback ante CLI no disponible. Racional: el CLI y el App comparten la
orquestación de review; corrido por el Mergeador (actor independiente del autor) el CLI da
la misma señal sin consumir el bucket degradable por Fair Usage.

**Superficies sensibles** (lista canónica y path-patterns en
`talent-merger/references/03-superficies-sensibles.md`; regla fail-closed — en duda,
sensible): commerce/pagos/webhooks · auth/RLS · **migraciones SQL** · LLM/costes ·
seguridad (headers/proxy) · credenciales. Lista viva mantenida por el Orquestador. La
clasificación es **OPERATIVA, no gate de App**: gobierna el cuidado extra del Mergeador
(spot-check reforzado, prioridad de cola, verificación declaración-vs-diff del HANDOFF) y
el GO del lead en destructivas — que no cambia.

Para que el review vea el SQL de migraciones, **se elimina la exclusión
`!**/supabase/migrations/**` de `path_filters` en `.coderabbit.yaml`** — la
`path_instruction` específica de `supabase/migrations/**/*.sql` ya existía y estaba muerta
por ese filtro. Con el cambio, el CLI (y el App en fallback) ven el SQL.

### 4. Orquestador: bundles (encargos)

El Orquestador cura **bundles**: el máximo de issues que quepan en un PR manteniendo
cohesión temática, carga combinada auditable (estimate combinado >5 → partir), mismo tier
de riesgo, sin mezclar migración+UI ni dinero+cosmético, y archivos DISJUNTOS entre
encargos concurrentes. Cada encargo = una rama + un PR + `closes` múltiple + HANDOFF
único. La regla 10 de CLAUDE.md se amenda: «cada **encargo** = una rama». Algoritmo en
`talent-orchestrator/references/08-bundling.md`.

## Consequences

### Positivas

- Canales de producción recuperan el 30-50% de wall-clock → ~1.5-2× throughput de
  implementación; el merge pasa a usar el bucket CLI 24/7 con **~0 reviews App/PR** (App
  solo en fallback) y N issues/PR → techo efectivo ~2-3×.
- La review de CodeRabbit **gana** cobertura donde más importa: las migraciones SQL pasan
  de excluidas a revisadas (CLI siempre; App si hay fallback).
- Interfaz explícita entre estaciones (HANDOFF con bloque machine-readable + verificación
  fail-closed) — los bundles quedan trazables issue a issue.

### Negativas / residuales

- El Mergeador es un **single-point con poderes de merge + prod**: mitigado con gates AND
  codificados en el skill, GO del lead en destructivas y evidencia trazable por API. El
  aprovisionamiento de sus canales es infra aparte (fuera de esta fase).
- TODO merge con CLI-limpio va **sin** review del App (code-audit + CLI-por-Mergeador +
  CI): riesgo aceptado conscientemente por el lead a cambio del throughput («si tenemos
  aprobación CLI no gastamos GH»). Mitigación en superficies sensibles: cuidado operativo
  reforzado del Mergeador (spot-check, declaración-vs-diff) y GO del lead en destructivas.
- `git push --no-verify` sigue saltando el hook local (límite honesto ya documentado del
  modelo anterior): el sentinel draft es anti-olvido, no anti-malicia.

### Neutrales

- El tooling de merge existente (`merge-gate.sh`, `approve-merge.sh`, `waive-cr.sh`)
  permanece en `talent-channel-operation/scripts/` por acoplamiento a su `lib.sh`;
  lo ejecuta el Mergeador como verificador de apoyo (su AND v5 es un subconjunto
  compatible en la ruta de fallback). La doctrina de uso vive en `talent-merger`.
- Esta fase NO migra la operación en vivo: los coordinadores actuales siguen el modelo
  vigente hasta el piloto del Mergeador.

## Alternatives considered

- **Mantener CR 2.0 (CLI por canal + App en todo merge).** Descartada: es el statu quo
  que produce el cuello — N canales compitiendo por los mismos buckets y 30-50% de
  wall-clock en espera.
- **Pool de identidades CodeRabbit (Fase 2 del runbook) sin cambiar el pipeline.**
  Descartada como solución única: multiplica el bucket CLI pero no elimina la espera de
  App/merge del canal ni la serialización; sigue disponible como ampliación futura del
  Mergeador.
- **App review obligatoria también en superficies normales (solo centralizar).**
  Descartada: devuelve el cuello del bucket App (~10/h y Fair Usage); el code-audit del
  canal + CLI independiente + CI cubren el riesgo normal.
- **App review obligatoria ADEMÁS del CLI en superficies sensibles (posture inicial de la
  spec TAL-2192).** Retirada por ruling del lead 2026-07-08 antes del primer push: el CLI
  y el App comparten orquestación de review y el CLI ya lo corre un actor independiente —
  gastar el bucket del App duplicaba la señal y reintroducía la espera de 15-40 min en la
  cola sensible. La clasificación de superficies se conserva como control operativo.
- **Automatizar el merge sin actor humano-operado (auto-merge de gh).** Descartada:
  ya estaba descartada en el modelo anterior; el Mergeador opera gates AND verificables y
  el lead conserva el GO de destructivas.
- **Mover `merge-gate.sh` y compañía al skill nuevo.** Descartada en fase 1: acoplados a
  `lib.sh` (733 líneas) de `talent-channel-operation`; moverlos es refactor de alto riesgo
  sin ganancia funcional. Se declaran tooling compartido de la estación de merge.

## Trazabilidad

- **Spec**: [TAL-2192](https://linear.app/talent-engine/issue/TAL-2192) — SPEC · Fábrica
  v2: Mergeador + drafts + CR centralizado + bundles.
- **Implementación fase 1 (repo)**: [TAL-2193](https://linear.app/talent-engine/issue/TAL-2193)
  — hook draft-handoff + ADR + skill `talent-merger` + bundling en `talent-orchestrator`
  - update `talent-channel-operation`/`talent-channels`.
- **Precedentes del modelo CR 2.0**: TAL-1502 (CLI pre-PR + opt-in por label), TAL-1518
  (git hook versionado), TAL-1596 (doctrina Ola-5).
- **Código**: `.githooks/pre-push`, `scripts/draft-handoff.sh`, `scripts/verify-handoff.sh`,
  `scripts/cr-review.sh`, `.coderabbit.yaml` (`path_filters`), `docs/templates/handoff-pr-draft.md`.
- **Skills**: `.claude/skills/talent-merger/` (nuevo),
  `.claude/skills/talent-channel-operation/` (v6.0), `.claude/skills/talent-orchestrator/`
  (bundling), `.claude/skills/talent-channels/` (perfiles de canal).
- **Runbook**: [`coderabbit-cli-pre-pr.md`](../runbooks/coderabbit-cli-pre-pr.md) —
  actualizado con el actor Mergeador y la exención draft.

## References

- [MADR 4.0](https://adr.github.io/madr/) — formato de este ADR.
- [ADR-0033 — Retirada de Cubic](0033-retirada-cubic.md) y
  [ADR-0038 — Detalle MADR](0038-detalle-madr-0033-retirada-cubic.md) — precedente de
  cambio de política de reviewer.
- CodeRabbit — documentación de rate limits y review por CLI: <https://docs.coderabbit.ai>
