---
title: "ADR-0075: Merge commit vs squash para la cola apilada de piezas de fábrica"
created: 2026-09-12
updated: 2026-09-12
author: raulmartin
status: accepted
---

# ADR-0075: Merge commit vs squash para la cola apilada de piezas de fábrica

## Status

`accepted` · 2026-09-12. GO del lead: **Opción C — mantener squash-merge y la
regla 10 sin cambios**; el ahorro de re-medición de gates en cola apilada se
persigue por el lado del **agregador** (TAL-6674, ya fusionado, + TAL-6692, en
curso), no por el método de fusión a `main`. Decisiones que enmarcan este ADR
(issue de origen TAL-6694, más la ratificación posterior del lead):

| Parámetro | Valor | Quién | Fecha |
|---|---|---|---|
| Decisión | Opción C: mantener squash-merge (regla 10 sin cambios); ahorro vía agregador | Lead | 2026-09-12 |
| `required_linear_history` | Se **conserva en `true`** como salvaguarda de auditoría — no se toca branch protection | Lead | 2026-09-12 |
| Amendment de la regla 10 | Ninguno — no aplica bajo la Opción C | Lead | 2026-09-12 |
| Criterio de reapertura | Si tras el despliegue de TAL-6692 en producción las re-medidas por cambio de head siguen costando caro (medido, no estimado), se reabre esta decisión con datos reales | Lead | 2026-09-12 |
| Dato de partida verificado | `required_linear_history=true` en `main`: el merge commit está BLOQUEADO por configuración además de por esta decisión | CEO | 2026-09-11 |

**Régimen de cierre**: esta pieza (TAL-6694) cierra con la entrega de este ADR (PR +
merge con `closes TAL-6694`). La decisión ya está ratificada por el lead — no queda
pendiente de aprobación posterior; lo que sí queda pendiente es la **verificación
empírica** de que TAL-6692, una vez desplegado, cumple lo que promete (ver
`## Sealing checklist`).

## Context

La regla 10 de `CLAUDE.md` exige **squash-merge** para todo cambio hacia `main`. La
**cola apilada** (piezas P1..Pn de una fábrica de canales, cada una medida sobre el
head ya fundido de la anterior) paga un coste directo por esa regla: al fundir P1
por squash, GitHub crea un commit **nuevo** en `main` que **no es ancestro** del
head sobre el que se midieron los gates de P2 — así que P2 debe replantarse contra
el nuevo tip y re-medir sus ~37 gates en cascada. Con merge commit, el head medido
de cada pieza SÍ sería ancestro literal de `main`, y esa evidencia sobreviviría sin
recálculo. Esta observación es de M5 (2026-09-09) y es correcta en términos de pura
ancestría git — el careo completo de consecuencias (este ADR) es lo que decide si
vale la pena pagar el coste de cambiar el método de fusión para conseguirlo, o si
hay una vía más barata al mismo objetivo.

**Cola apilada ya ha costado caro por otra vía, distinta a la evidencia de gates**:
`.claude/memory/gotchas.md:141-144` registra un incidente sellado real — al armar el
Tren B, la migración de TAL-4438 (#1763) hacía `CREATE OR REPLACE FUNCTION
app_internal.redeem_pack_canje_impl` sobre la versión que existía cuando esa rama se
ramificó; después, `main` ganó dos migraciones que reescribieron esa MISMA función
(TAL-4620, TAL-4622). Como la migración de TAL-4438 aplicaba al final, su cuerpo
viejo GANABA y borraba silenciosamente el trabajo de `main` — el merge **textual**
de git no lo detectó porque los cambios viven en ficheros de migración distintos,
sin conflicto de líneas. Es un eje **distinto** al de este ADR (clobber semántico de
SQL, no invalidación de evidencia de gates) — se cita aquí como motivación general
de que "cola apilada" es un riesgo real en este repo, no como prueba de que cambiar
el método de fusión lo resuelve. **Cambiar squash por merge commit no habría
evitado este incidente concreto** (el clobber vive en el contenido SQL, no en la
topología de commits) — otro dato a favor de no tratar el método de fusión como la
palanca correcta para los problemas de cola apilada en general.

**Hallazgo central que decide esta ADR**: el problema concreto que motivó la
observación de M5 (pérdida de evidencia de gates por ruptura de ancestría tras
squash) **ya se está resolviendo por el lado del agregador**, sin tocar la regla 10
ni la protección de `main`:

- **TAL-6674** (`talent-factory`, commit `3a105b9`, PR #92, **ya fusionado**
  2026-09-11): el agregador dejó de invalidar receipts por ancestría/exact-match de
  `base_tip_sha` y pasó a decidir por **identidad de blob** — compara el contenido
  que se probó contra el que realmente aterrizaría, no la topología. Cubre el eje
  "avance de `main`" (squash de piezas hermanas, rebases, etc.).
- **TAL-6692** (`talent-factory`, **En curso**, "Carveout del agregador para trenes
  sin `src`: no re-medir gates pesados cuyo insumo no cambia") — extiende ese MISMO
  principio (caducidad por identidad de contenido, no por topología) al eje que
  TAL-6674 todavía no cubre: el contrato `receipt.sha == HEAD_SHA`
  (`post-local-gates.sh:605`, ver eje 4 abajo) exige hoy una coincidencia EXACTA del
  head — cualquier replant, fixup o renumerado de slot (el "cambio de head" que un
  squash de cola apilada provoca) tira TODOS los receipts, incluidos los 27 gates
  pesados, aunque ningún insumo real haya cambiado. El coste medido que motiva
  TAL-6692 (lote S2 de skills: 3×37 gates re-medidos tres veces por churn de `main`
  y replants, sin que un solo insumo pesado cambiara) es la MISMA clase de coste
  que M5 documentó para la cola apilada — atacado en el sitio correcto (el
  agregador), no en el método de fusión.

Este ADR se lee con esa lente: los seis ejes de la issue de origen (TAL-6694) se
carean igual, pero el resultado del careo es que el ahorro perseguido por M5 se
consigue sin pagar el coste de cambiar de método de fusión.

## Decision drivers

Los seis ejes exigidos por TAL-6694 (sección "Incluye" de la issue), cada uno
verificado en vivo el 2026-09-12 contra `origin/main` real de este repo y del motor
`talent-factory` (no de memoria ni de un clon desactualizado — una pasada previa de
este trabajo investigó mal contra un clon 130/77 commits detrás; este documento usa
exclusivamente la re-verificación):

1. **Historial**: con squash, `main` recibe UN mensaje de commit por pieza — la
   regla 6 de `CLAUDE.md` (prohibición de atribución de autoría en commits) se
   vigila sobre ESE único mensaje antes de fundir. Con merge commit, entrarían a
   `main` los **N mensajes de commit del canal**, incluidos sus trailers, tal
   cual — cada uno tendría que cumplir regla 6 de forma independiente, y hoy no
   existe un mecanismo de revisión retroactiva de N commits históricos (el gate
   `local-gates` y CodeRabbit revisan el DIFF de la pieza, no el mensaje de cada
   commit individual que la compone). Este coste **desaparece por completo** bajo
   la Opción C: al no cambiar el método de fusión, la superficie de regla 6 se
   queda exactamente como está hoy.
2. **Herramientas que leen el historial**: la issue cita como ejemplo genérico
   `git show --name-only`. Verificado en ambos repos (`Academia-Ejemplo-2.0` y
   `talent-factory`): no existe un uso literal de `git show --name-only` en
   ningún script de gates o de auditoría — se declara así en vez de inventar un
   uso que no existe. El uso REAL y equivalente encontrado es
   `scripts/check-push-audit.sh:430` — `git rev-list --count
   "${sentinel_sha}..HEAD"` (sensible a topología no-lineal: un merge commit
   cambia el conteo de commits de un rango respecto a un squash equivalente).
   Bajo la Opción C, esta sensibilidad no se activa: la topología de `main` sigue
   siendo lineal.
3. **Branch protection de `main`**: verificado en vivo por API —
   `required_linear_history: true`, `required_status_checks.checks:
   [{"context":"local-gates"}]`, `strict: false`, `allow_force_pushes: false`,
   `allow_deletions: false`. `scripts/setup-branch-protection.sh:138` —
   `"required_linear_history": true,` — reproduce este mismo estado. Confirmado
   con la documentación oficial de GitHub (fecha de consulta 2026-09-11): "Require
   linear history" — *"Enforcing a linear commit history prevents collaborators
   from pushing merge commits to the branch"*, y *"any pull requests merged into
   the protected branch must use a squash merge or a rebase merge"*
   (docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).
   Bajo la Opción C, esta protección **se conserva sin cambios**, explícitamente
   como salvaguarda de auditoría (historia lineal + 1 mensaje vigilado por pieza,
   eje 1) — no como mero obstáculo a sortear. `local-gates` (TAL-2288) sigue
   siendo el único required check.
4. **Agregador de gates (`post-local-gates`)** — dos contratos DISTINTOS,
   verificados por separado contra `origin/main` de `talent-factory`:
   - `talent-factory/scripts/post-local-gates.sh:605` —
     `[ "$(jq -r '.sha' "$r")" = "$HEAD_SHA" ] || { bad "$r ($g): sha != head del
     PR"; id_ok=0; }`. El receipt debe corresponder EXACTAMENTE al head del PR
     que se está fusionando — el anti-self-report de la regla 12 de `CLAUDE.md`.
     Este es precisamente el contrato que TAL-6692 se propone extender con
     tolerancia por identidad de contenido (no eliminarlo: seguirá exigiendo que
     el contenido probado coincida con el que aterriza, solo que ya no exigirá
     coincidencia BYTE a BYTE del SHA cuando el contenido relevante no cambió).
   - El mecanismo de identidad de blob de TAL-6674 (`post-local-gates.sh:161-253`,
     funciones `bt_merge_tree`/`bt_prepara`) — calcula `TESTADO = merge-tree(rbt,
     HEAD_SHA)` vs `ATERRIZA = merge-tree(BASE_TIP_SHA, HEAD_SHA)` y compara
     BLOBS entre esos árboles: un avance de `main` que no cambia el contenido
     relevante para una pieza YA NO invalida su receipt por ese eje. Antes de
     TAL-6674 el agregador invalidaba por ancestría/exact-match de
     `base_tip_sha` sin mirar contenido; `docs/runbooks/local-gates.md:707-709`
     (de ESTE repo) todavía documenta ese contrato viejo — es una doc
     desactualizada respecto al motor real, señalada aquí como hallazgo derivado
     sin corregirla (fuera de alcance de una pieza docs-only sobre otro
     repositorio).
   - Caveat declarado honestamente: se confirmó que TAL-6674 (`3a105b9`) está
     fusionado a `origin/main` del repo motor; **no se pudo verificar desde este
     canal docs-only** (sin acceso a la infraestructura de runners) si esa
     versión ya está DESPLEGADA en los runners sellados que producen
     `local-gates` en producción hoy mismo. TAL-6692 sigue **En curso** (no
     fusionado) a fecha de este ADR. Ambos hechos son la base del criterio de
     reapertura (ver `## Status`): la Opción C apuesta a que TAL-6692 cierre el
     eje que falta; si no lo hace, o no reduce el coste medido, se reabre esta
     decisión con datos reales en vez de re-litigar sobre estimaciones.
5. **Propuesta operativa**: bajo la Opción C, **no hay propuesta operativa de
   cambio de método de fusión que ejecutar** — ver `## Decision` para el careo de
   las tres opciones y por qué se descartan A y B a favor de C.
6. **Riesgos y reversibilidad**: la Opción C no introduce ningún cambio
   `revers`ible ni irreversible sobre `main` — es, precisamente, la opción de
   MENOR riesgo de las tres, porque no toca ni la regla 10 ni la protección de
   rama. El riesgo que sí queda abierto es el de ejecución de TAL-6692 (una
   pieza de infraestructura que aún no ha aterrizado) — mitigado por el criterio
   de reapertura, no por este ADR.

## Decision

Tres opciones careadas, cada una contra los seis ejes de arriba:

**Opción A — Adoptar merge commit para toda la cola apilada** (la propuesta
original de M5): el head medido de cada pieza sería ancestro literal de `main`, y
la evidencia de gates sobreviviría sin recálculo por el eje de ancestría. **Costes**:
(i) bloqueada hoy por `required_linear_history=true` (eje 3) — exige desactivar esa
protección con su propio blast radius sobre TODO `main`, no solo sobre la cola
apilada, y su propio issue con GO explícito del lead; (ii) entrarían a `main` N
mensajes de commit de canal por pieza en vez de 1, con su superficie de regla 6 sin
mecanismo de revisión retroactiva hoy (eje 1). **Rechazada.**

**Opción B — Merge commit acotado/contingente** (solo para piezas cuyo head medido
sea ancestro verificado de la tip actual de `main` en el momento de fundir, con
receipts re-sellados contra esa tip): reduce el alcance de la Opción A, pero
mantiene el mismo bloqueo de plataforma (eje 3) y el mismo coste de regla 6 (eje 1)
para las piezas que sí calificarían. Además, una vez TAL-6674 (ya fusionado) y
TAL-6692 (en curso) cierran el problema de fondo por el lado del agregador, esta
opción deja de aportar un beneficio que no se consiga ya sin ella. **Rechazada por
redundante e innecesariamente costosa.**

**Opción C — Mantener squash-merge y la regla 10 sin cambios; perseguir el ahorro
de re-medición por el lado del agregador** (TAL-6674 ya fusionado + TAL-6692 en
curso, eje 4): cero cambio de regla 10, cero cambio de branch protection, cero
coste nuevo de regla 6 (eje 1), cero exposición a las herramientas sensibles a
topología no-lineal (eje 2). El coste de re-medición en cascada que motivó a M5 se
ataca en su causa real — el contrato de identidad del agregador — en vez de en un
síntoma (el método de fusión). **ACEPTADA.**

**Criterio de reapertura** (declarado en `## Status`): si, tras el despliegue de
TAL-6692 en producción, las re-medidas de gates por cambio de head en cola apilada
siguen costando caro **medido** (no estimado) — es decir, si el carveout de
TAL-6692 no reduce ese coste en la práctica — esta decisión se reabre con esos
datos reales sobre la mesa, no con una repetición de este careo teórico.

## Consequences

### Positivas

- Cero cambio de la regla 10, cero cambio de branch protection — cero riesgo
  nuevo introducido sobre `main`.
- El coste de re-medición en cascada que motivó la observación de M5 se resuelve
  en su causa (el agregador), con un mecanismo que YA demostró funcionar para el
  eje de ancestría (TAL-6674) y que se está extendiendo al eje de cambio-de-head
  (TAL-6692).
- `git log` de `main` se mantiene lineal; la superficie de auditoría de la regla 6
  se queda en un único mensaje de commit vigilado por pieza fundida.
- Reversibilidad total y trivial: no hay nada que revertir, porque no se cambió
  nada.

### Negativas / abiertas

- **Dependencia de una pieza en curso**: el beneficio pleno de la Opción C depende
  de que TAL-6692 aterrice y funcione como se espera. Mientras tanto, el coste de
  re-medición por cambio de head en cola apilada **sigue existiendo** para el eje
  que TAL-6692 todavía no cubre (línea 605 exige coincidencia exacta de SHA hoy).
  Mitigado por el criterio de reapertura, no eliminado por este ADR.
- **Doc-gap conocido, no corregido en esta pieza**: `docs/runbooks/
  local-gates.md:707-709` (de este repo) sigue describiendo el contrato
  PRE-TAL-6674 del agregador. Queda como hallazgo derivado para una issue aparte
  (fuera de alcance docs-only de este ADR, que vive en `Academia-Ejemplo-2.0` y no
  en el repo del motor).
- **Caveat de despliegue sin verificar**: no se pudo confirmar desde este canal
  docs-only si TAL-6674 ya está desplegado en los runners sellados de producción
  (solo que está fusionado al repo del motor).

## Alternatives considered

- **Rebase-merge**: excluido explícitamente por decisión ya sellada de la issue
  TAL-6694 ("El lead pidió específicamente el careo merge commit vs squash;
  ampliar la comparación es alcance nuevo") — no se evalúa aquí, se declara solo
  para que quede constancia de por qué no aparece.
- **Opción A** y **Opción B**: ver careo completo en `## Decision` — ambas
  rechazadas a favor de la Opción C.

## Sealing checklist

Este ADR nace `accepted` (decisión ya ratificada por el lead), pero conserva esta
sección porque queda **verificación de implementación pendiente** (README.md,
regla de conservación del Sealing checklist en ADRs ratificados con seguimiento
abierto):

- [ ] TAL-6692 fusionado a `origin/main` de `talent-factory` y desplegado en los
      runners sellados de producción que producen `local-gates`.
- [ ] Confirmar (Mergeador / infraestructura) si TAL-6674 (identidad de blob) ya
      está desplegado en producción — el caveat del eje 4 queda abierto hasta esa
      confirmación.
- [ ] Medir, tras el despliegue de TAL-6692, el coste real de re-medición por
      cambio de head en al menos una cola apilada real — este dato es el que
      dispara (o no) el criterio de reapertura.
- [ ] Decisión sobre si se abre una issue aparte para corregir el doc-gap de
      `docs/runbooks/local-gates.md:707-709` (contrato pre-TAL-6674 desactualizado).

## Trazabilidad

- **TAL-6694** — issue de origen de este ADR.
- **TAL-6674** — pieza del agregador de gates (`talent-factory`, PR #92), YA
  fusionada 2026-09-11; identidad de blob para el eje "avance de `main`".
- **TAL-6692** — pieza del agregador de gates (`talent-factory`), **en curso**;
  extiende la identidad de contenido al eje "cambio de head" — es la pieza de la
  que depende el beneficio pleno de la Opción C.
- **TAL-5694** — límite aparte citado por la issue de origen (serialización de
  merges entre estaciones); no se toca aquí.

## References

- GitHub Docs — "About protected branches" (fecha de consulta: 2026-09-11):
  <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches>
- GitHub Docs — "About pull request merges" (fecha de consulta: 2026-09-11):
  <https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/about-pull-request-merges>
- `docs/runbooks/local-gates.md` (este repo) — contrato del gate único requerido
  `local-gates`, incl. la sección desactualizada respecto a TAL-6674 (líneas
  707-709).
- `docs/decisions/0044-merge-queue-puerta-de-salida.md` — precedente de un ADR de
  esta fábrica que carea a fondo una propuesta de cambio de flujo de merge y
  concluye en mantener el statu quo.
- `.claude/memory/gotchas.md` (líneas 141-144) — incidente sellado del clobber
  semántico de Tren B / TAL-4438, motivación de Context.
- `talent-factory` commit `3a105b9` — `fix(gates): TAL-6674 el agregador de
  local-gates decide por identidad de blob, no ancestría (#92)`.
- Issue Linear TAL-6692 — "Carveout del agregador para trenes sin `src`: no
  re-medir gates pesados cuyo insumo no cambia (talent-factory)".
