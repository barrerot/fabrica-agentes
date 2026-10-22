---
title: "Runbook — CodeRabbit pre-PR por CLI + opt-in por label (modelo CR 2.0, amendado por Fábrica v2)"
created: 2026-06-28
updated: 2026-07-30
author: blackvamp
status: active
---

# CodeRabbit pre-PR por CLI + opt-in por label (modelo CR 2.0)

> **AMENDADO por Fábrica v2 ([ADR-0043](../decisions/0043-fabrica-v2-mergeador-posture-cr.md), 2026-07-07).**
> El actor del consumo de CodeRabbit cambia: los **canales de producción NO corren CR**
> (ni CLI ni App) — entregan PR **DRAFT + HANDOFF** con la exención draft del Gate 2 (ver
> sección «Entrega draft») y se olvidan. El **Mergeador** es el ÚNICO consumidor de ambos
> buckets (CLI y App). **El CLI limpio AUTORIZA el merge en cualquier superficie** (ruling
> del lead 2026-07-08: «si tenemos aprobación CLI no gastamos GH») — la review del App es
> EXCLUSIVAMENTE el fallback ante CLI rate-limited/caído (doctrina completa en el skill
> `talent-merger`). El flujo "por carril" de
> este runbook queda vigente para el **flujo no-draft**: pushes del Mergeador, sesiones de
> dev fuera del sistema de canales, y cualquier push que no sea una entrega draft.
>
> **CI de Actions SUSTITUIDA por gates locales (TAL-2286/TAL-2288, 2026-07-09):** GitHub
> Actions está OFF por presupuesto; donde este runbook diga «required checks verdes» o
> «CI» léase el commit-status **`local-gates`** (motor talent-factory + receipts +
> posteo desde la estación del Mergeador). Runbook canónico: [`local-gates.md`](local-gates.md).

## Propósito

Resolver el rate limit de CodeRabbit (CR) en olas multi-carril. El cuello de botella son
los **loops de review obligatorios por merge**: CR saca bloqueantes → se retrabaja → push →
CR re-revisa → repite. Con el auto-review clásico cada push quema 1 review del **bucket de PR**
de la identidad (`blackvamp`) en la org; bajo una sola identidad la Fair Usage (que es **PR-only**)
degrada a ~1 review/hora.

**Solución:** mover el review al **CLI de CR**, que corre sobre un **bucket separado**
(CLI, 10/h en Pro+) que **esquiva la Fair Usage**. **Posture vigente (ruling del lead
2026-07-08, ADR-0043): el CLI limpio AUTORIZA el merge — con aprobación CLI no se gasta
review del App.** El App queda EXCLUSIVAMENTE como **fallback** (label `cr-review` +
APPROVED@head) cuando el CLI no está disponible (rate-limited/caído). El pipeline:
**desarrollo codea → revisión/auditoría → CR-CLI → merge con la evidencia CLI** — la
auditoría y CR siguen siendo revisores **distintos** (cada uno caza lo que el otro no).

> El CLI y el review del App de CodeRabbit **comparten orquestación** (el App añade
> análisis arquitectónico/sandbox y contexto del repo). Por el ruling del lead, esa
> diferencia NO justifica gastar el bucket del App cuando hay aprobación CLI: el contexto
> extra del App solo entra en juego en el fallback.

## Cómo funciona (flujo por carril)

> **ÁMBITO (Fábrica v2):** este flujo channel-runs-CR aplica SOLO al **flujo no-draft (clásico)**
> — pushes del Mergeador, sesiones de dev fuera del sistema de canales, y cualquier push que no
> sea una entrega draft. **Los canales de producción NO ejecutan nada de esta sección**: entregan
> por la sección «Entrega draft» de más abajo (`draft-handoff.sh`, sin CodeRabbit) y se olvidan.
> Un dev de canal que se vea pidiendo auth de CR-CLI durante una entrega está en el flujo
> equivocado → redirigir a `scripts/draft-handoff.sh`.

```text
setup del carril (push-carril-env.sh, una vez): escribe ~/.coderabbit/auth.json directo (sin exponer la key en argv)
dev implementa + COMMITEA  (ya autenticado; el review tampoco pasa --api-key → el secret no se expone)
  └─ STOP-AUDIT ── el coordinador releva el GO de CÓDIGO de la auditoría sobre el commit (gate de auditoría, SEPARADO del CR-CLI)
  └─ CR-CLI gate pre-push: `bash scripts/cr-review.sh` → revisa el commit y EMITE el sentinel .claude/.cr-review-ok
                 (solo si 0 critical|major + 0 error/review_skipped); aplica critical|major + commitea + re-corre (tope 2)
  └─ git push  ── el hook .githooks/pre-push valida el sentinel; sin él BLOQUEA (capado → waiver explícito → push --no-verify)
  └─ abrir PR ("closes TAL-xxx") + In Review — SIN label `cr-review` (ruling ADR-0043)
merge (quien lo ejecute según el modelo vigente):
  └─ evidencia = CLI limpio TRAZABLE sobre el head EXACTO (sentinel + .cr-review-result.json
     con state==ok y head_sha==head del PR) + required checks verdes → merge SIN review del App
  └─ si un fix post-PR cambia headSha → re-correr cr-review.sh sobre el head nuevo → re-evaluar
  └─ SOLO si el CLI no estuvo disponible (fallback): label cr-review por REST verificado
     → App APPROVED@head → merge
```

Piezas (todas en este repo):

- **`.coderabbit.yaml`** → `auto_review.enabled: false` + `labels: ["cr-review"]`. `auto_incremental_review` se queda en `true` (ver Troubleshooting › deadlock).
- **`02-golden.sh`** instala el CLI **desde el artefacto versionado con verificación sha256 (fail-closed)** — NO usa el `curl|sh` del vendor (que no verifica checksum) porque el binario es parte del gate pre-PR. `CR_CLI_VERSION` + los sha256 por arquitectura están **hardcodeados** (no overrideables por env); subir de versión exige editar ambos en el script. El golden instala **`unzip`** (requisito del instalador del CLI; sin él, el paso 5b falla con `Missing required tools: unzip`). **`push-carril-env.sh`** configura la sesión per-carril escribiendo `~/.coderabbit/auth.json` **directo** (formato `{"type":"api_key","apiKey":"…"}`, con `printf` builtin — **NO** `auth login --api-key`, que expondría la key en argv/ps) — el CLI **NO** lee `CODERABBIT_API_KEY` del entorno. **`creds.manifest`** declara `CODERABBIT_API_KEY`; **`lib.sh`** lo redacta en logs.
- **`prompt-dispatch.tmpl`** (contrato del dev) + **`scripts/cr-review.sh`** (gate pre-push: emite el sentinel `.claude/.cr-review-ok`; sin él, el hook bloquea el push). Fallback (ÚNICA vía que gasta App, ruling ADR-0043): CR App con label `cr-review` cuando el CLI no está disponible (no hay loop post-PR automatizado).

## Known debt — findings aceptados ligados al árbol auditado (TAL-2272)

La doctrina de la fábrica (skill `talent-merger`, ref 04) deja findings que NO se van a
arreglar: el waiver flip-flop (finding no reproducible ≥2/3) y la deuda aceptada/gated. Sin
registro, `cr-review.sh` re-reporta el mismo finding aceptado en CADA re-run sobre el mismo
árbol y el sentinel no sale nunca (condena a re-triage o a `--no-verify`). El registro
automatiza ese waiver de forma **granular y fail-closed**:

```bash
bash scripts/cr-review.sh --list-findings            # listado NUMERADO del último run + estado del store
bash scripts/cr-review.sh --accept-debt 1,3 "nota"   # acepta SOLO esos índices; nota obligatoria
bash scripts/cr-review.sh                            # re-run: los aceptados ya no bloquean
```

Reglas del mecanismo (implementación en `scripts/cr-review.sh`, store
`.claude/.cr-review-known-debt.jsonl` local + gitignored):

- **Granular por diseño — sin bulk**: la selección es SIEMPRE por índice explícito contra el
  listado revisable de `--list-findings`; no existe atajo `all`. En el caso mixto real (un major
  real + un falso positivo) un bulk registraría también el real y degradaría el gate a bypass.
- **Nota obligatoria** (waiver documentado): motivo por invocación, p. ej.
  `"flip-flop 1/3 no reproducible"` o `"deuda gated TAL-N"`. Motivos distintos → invocaciones
  separadas (cada entrada del store conserva su nota).
- **Identidad por huella, no por título**: cada finding se identifica con
  `fp = sha256(tojson([file, lineStart, lineEnd, title, category, fpMaterial]))` sobre el shape
  NORMALIZADO por `cr-finding-normalize.jq`, donde `fpMaterial = [description, comment,
  codegenInstructions, suggestions, prompt]` (normalizadas: strings recortados, no-string
  serializados). Incluir TODAS las fuentes textuales —no solo la primera que `description`/`prompt`
  colapsan— cierra el dedupe fail-open (ronda 2 · síntesis r1, TAL-2816): dos findings idénticos
  salvo por `codegenInstructions`/`suggestions` producían la MISMA huella y una deuda aceptada
  suprimía otro finding materialmente distinto (falso GO). `tojson` es injectivo (escapa
  comillas/control, distingue string de array de objeto → serializa `suggestions` no-string).
  `severity` queda FUERA (un flip critical↔major del mismo finding no reabre la deuda). Dos findings
  del mismo archivo con el mismo título en líneas distintas NUNCA comparten huella — aceptar uno no
  suprime el otro. Si el CLI varía el texto entre runs (no-determinismo), la huella no matchea y el
  finding se RE-REPORTA: jamás se suprime de más.
- **Binding triple = expiración automática**: la supresión exige `tree_sha == HEAD^{tree}` actual
  **y** `base_sha == origin/main` actual **y** huella idéntica. Cualquier commit, rebase o avance
  de `main` expira la deuda → re-triage completo (fail-closed).
- **Supresión visible, nunca silenciosa**: con bloqueantes nuevos, el run sale `findings` y
  reporta "M suprimido(s) como known debt"; si SOLO queda deuda aceptada, emite el sentinel `ok`
  con razón `review_completed_known_debt(N)` (el hook lo acepta: valida SHA + estado, la razón es
  informativa) y lista los suprimidos. El `.cr-review-result.json` lleva el detalle redactado en
  el campo aditivo `known_debt` (+ `base_sha` para la trazabilidad del binding).
- **Guards del registro**: `--accept-debt` exige último run con `state=findings`, `head_sha` ==
  HEAD actual (commit posterior → rechazo), `base_sha` presente en el result (runs de versiones
  previas del script → re-correr; sin fallback) y `sha256sum`/`shasum` disponible.

## Evidencia y adjudicación de phantoms (TAL-2816)

Los findings **phantom/TEXTLESS** (sin cuerpo textual real — line-0, flip-flop entre runs —
precedentes #982/#986/#987) se adjudicaban re-corriendo el CLI (quema bucket) y con memoria del
operador. La triageabilidad la define UNA sola fuente de verdad: el filtro compartido
`cr-finding-normalize.jq` (TAL-2610), que solo emite findings con cuerpo, más el gate de **paridad**
(`normalized == blockers`) que FALLA-CERRADO si algún bloqueante no salió triageable — un
textless-phantom aborta el gate con `state=error` (nunca llega a known debt ni al universo del
historial) y su crudo queda como evidencia. Ya no hay un predicado `is_textless` propio (evita el
drift jq↔código). Ahora cada run deja evidencia objetiva y durable, sin quemar bucket:

- **`.claude/.cr-review-history.jsonl`** — ledger **append-only** por run/SHA (una línea por run,
  **incluye universo vacío** — el vacío es señal), gitignored (`.claude/.cr-review-*`). Campos
  **sanitizados** por allowlist: `run_id`, `gen{epoch,value}`, `sha`, `base_sha`, `ts`, `branch`,
  `state`, `seat_fp`, `finding_count`,
  `findings[{severity,file,lineStart,lineEnd,title,category,fp}]`
  (normalizado por el filtro compartido, solo triageables → sin campo `textless`).
  **`seat_fp` (TAL-3637)** es la misma huella truncada del asiento que lleva el `result` — jamás la
  credencial. Está aquí porque el `result` lo **pisa** la corrida siguiente y el ledger es el único
  artefacto que sobrevive: al investigar una colisión de asientos, la atribución tiene que estar donde
  se puede leer después. Vale `null` en los runs que terminaron antes del guard de auth
  (`deferred`/`blocked`/`error` temprano) y en las entradas `orphaned` del reconciliador — «no hubo
  asiento» y «el asiento fue la cadena vacía» no son lo mismo para quien audita.
  **NO persiste `description`/`prompt`** (llevan snippets de código); la `fp` es la MISMA huella que
  usa el known-debt (ver fórmula arriba).
- **`.claude/.cr-review-raw-<run_id>.jsonl`** (nombre FINAL) — CRUDO del CLI preservado (evidencia
  bruta, local, gitignored). El CLI escribe SIEMPRE a un `.claude/.cr-review-raw-<run_id>.jsonl.partial`
  primero; el rename atómico al nombre final SOLO ocurre si el review completa limpio (rate-limit/
  error/incompleto salen antes de promover, conservando el `.partial` como evidencia). A lo sumo UNO
  de los dos (final o `.partial`) existe por run. Podado (ambas formas, más su lockfile por-run) cuando
  su `run_id` es evictado por retención — y, si el proceso murió por `SIGKILL`/OOM antes de dejar
  CUALQUIER entrada en el historial (ningún trap de bash captura `SIGKILL`), el crudo huérfano se
  reconcilia en el arranque del siguiente run. **Vivacidad probada por `flock`, no por heurística**:
  cada run sostiene un `flock` sobre `.claude/.cr-review-runlock-<run_id>` durante toda su vida
  (adquirido ANTES de crear el crudo — si existe un crudo, su lock ya está tomado); el kernel lo libera
  al morir el proceso (SIGKILL incluido). El reconciliador escanea AMBAS formas (`.partial` de crash
  pre-promoción Y `.jsonl` final de crash post-promoción) y, para un crudo sin entrada en el historial,
  intenta adquirir su `runlock` con `flock -n`: si lo adquiere → dueño muerto → lo registra como
  `state=orphaned` (universo vacío, rama tomada del contenido del lockfile) y lo poda; si no lo adquiere
  → dueño VIVO (aunque su CLI lleve horas silencioso) → lo deja intacto. Sin PID, sin `mtime`, sin
  ventana. El crudo SOLO se borra si el registro `orphaned` se confirmó persistido (fallo → se conserva
  para reintentar, nunca se pierde evidencia sin su registro).
- **Adjudicar sin re-correr el CLI**: comparar la presencia/ausencia de una `fp` a través de los runs
  del mismo SHA en el historial (`fp` en run X, ausente en Y/Z = flip-flop no reproducible). Esa
  evidencia se cita en la **nota** de `--accept-debt` cuando el finding es **real** (deuda
  aceptada/gated). **Doctrina**: un finding **textless/phantom NO se waivea** — la impone el filtro
  compartido + la paridad (un phantom deja `normalized < blockers` → gate abortado con `state=error`,
  nunca llega a `$FINDINGS` ni a `--accept-debt`); se adjudica por la red del gate (el flip-flop se
  resuelve al re-correr / desaparece solo), con el crudo en `$RAW` como evidencia. Jamás se silencia.
- **Retención**: `CR_REVIEW_HISTORY_RETENTION` runs por rama (default 20); el crudo (final o
  `.partial`) se poda con su entrada.
- **Concurrencia fail-closed**: toda mutación del estado por-SHA (`RESULT`/`FINDINGS`/`SENTINEL`/
  `HISTORY`) va bajo el lock `.claude/.cr-review-ledger.lock` (`flock`, util-linux) y ordenada por
  una **generación no-reutilizable — el fencing token** — `.claude/.cr-review-gen` =
  `{epoch aleatorio de 128 bits, value creciente}`. La generación se valida ANTES de tocar
  CUALQUIER artefacto, incluido el historial: un run cuyo `{epoch,value}` ya no coincide con el
  fichero de generación queda `superseded` y su entrada de historial persiste con **universo
  VACÍO** — nunca pisa ni afirma el verdict de un run más nuevo. Sin `flock` disponible, el script
  **FALLA CERRADO** (ningún fallback mkdir/timeout es seguro contra un propietario vivo que tarda
  más del umbral — un timeout no es un fencing token); sin `/dev/urandom` (128 bits exactos), el
  `epoch` también falla cerrado, sin degradar a una fuente predecible. El `epoch` cierra el ABA
  ante borrado/reset del contador (autoriza solo con epoch+value exactos).
  `start_run` **invalida el sentinel PRIMERO**; `commit_run` revalida **bajo lock** un fingerprint
  de snapshot con reflog (detecta cambio-y-restauración A→B→A de HEAD/base durante el review —
  reflog deshabilitado/vacío → fail-closed) y publica el sentinel el **ÚLTIMO**, solo si
  RESULT+FINDINGS+HISTORY persistieron.
- **TOCTOU sentinel/SHA cerrado**: `HEAD_SHA` se captura al arrancar el script — una lectura vieja.
  `REVIEW_HEAD` (el commit que realmente se envía al CLI) se lee EN VIVO justo antes de gastar la
  corrida y se valida contra `HEAD_SHA` (si ya difiere, aborta sin revisar el commit equivocado); y,
  justo antes de publicar, `commit_run` vuelve a leer HEAD/tree en vivo y exige que coincidan con
  `REVIEW_HEAD`/`REVIEW_TREE` Y con `HEAD_SHA` — el sentinel nunca autoriza un SHA distinto del que
  realmente se auditó, ni siquiera si HEAD volvió a coincidir por casualidad (A→B→A).
  `RESULT` es el snapshot coherente (estampado `gen`/`run_id`) que un lector sin lock consume de un
  solo `open`. El `state` autorizante sigue siendo **`ok`** (el limpio-módulo-deuda usa `state=ok` +
  `reason=review_completed_known_debt(N)`, sin estados nuevos). Disciplina de exit (M7): un exit
  inesperado sin estado terminal committeado (`interrupted` con código de salida `0`) se fuerza a
  no-cero — nunca se lee como éxito.

## Setup (lead-managed, una vez)

1. **Add-on:** `app.coderabbit.ai` → Subscription & Billing → pestaña **Usage-based add-on** →
   activar pay-as-you-go. **Sin auto-refill** (o cap mínimo) → tope de gasto duro.
2. **API-key:** sección **API Keys** del dashboard → generar **Agentic API key** con el seat de
   `blackvamp`. Guardar como `CODERABBIT_API_KEY` (va al `.env.local` de cada carril, scope `shared`
   en Fase 1).
3. **Paso 0 — test empírico (GATE de la Fase 2):** con 2 keys de 2 seats, verificar (a) que el CLI
   corre en un repo de **otra** org y cobra al bucket de la org de la key (cross-repo), (b) que 2 keys
   dan **2 buckets independientes**, (c) la calidad del review "en frío" en repos no onboarded.

## Control de coste

- **$0 dentro de cuota** (10 CLI/h por seat en Pro+; con ~1.6 reviews/h de media, sobra).
- **Over-limit:** $0.25 por **archivo revisado** ($1 = 4 archivos). Mediana de PRs ≈ 4 archivos → ~$1/review.
- **Sin créditos comprados**, un over-limit se **pausa** (no cobra): no hay gasto sorpresa.
- Resumen: **sin coste recurrente esperado; puede requerir un buffer one-time mínimo** para cubrir
  picos. El tope lo fija lo que compres (sin auto-refill).

## Troubleshooting

| Síntoma | Causa / Solución |
|---|---|
| **merge-gate "revisión obligatoria (CodeRabbit) aún NO presente"** | Solo aplica en el modelo pre-fábrica o en el FALLBACK (ruling ADR-0043: con CLI limpio trazable @head se mergea SIN label ni App). En fallback: añadir el label por REST verificado y comprobar que **existe** en el repo (`gh label create cr-review`). |
| **El push del carril se bloquea (sin sentinel)** | El sentinel `.claude/.cr-review-ok` ausente o el CR-CLI dejó `critical/major`/`error`/`review_skipped`. El dev corre `bash scripts/cr-review.sh` y lo deja limpio (tope 2 pasadas) antes de pushear; si está capado, **waiver explícito** del coordinador (push `--no-verify`). |
| **deadlock en merge-gate tras un fix post-PR** | El fix cambia el `headSha` y el gate compara contra el SHA auditado. El **coordinador** lo detecta (`headSha != SHA auditado`), re-audita el SHA nuevo y re-evalúa el merge-gate. **No** poner `auto_incremental_review: false` (los pushes se ignorarían y el App no re-revisaría el SHA nuevo). |
| **`Invalid or expired API key` (401) en el review** | El CLI **NO** lee `CODERABBIT_API_KEY` del entorno; usa la sesión en `~/.coderabbit/auth.json`. Si hay un `auth.json` viejo/incorrecto → 401. Solución: re-escribir `~/.coderabbit/auth.json` con la key correcta (lo hace `push-carril-env.sh` per-carril, sin exponer la key en argv). Verificar con `coderabbit auth status`. |
| **El gate CR-CLI bloquea siempre** | Shape del JSONL `--agent` validado en CLI 0.6.4/0.6.5: `type:"finding"`+`severity:"critical"/"major"`, `type:"complete"`+`status:"review_completed"`, `type:"error"`. La normalización de findings vive en `scripts/lib/cr-finding-normalize.jq` (compartido con el test unit `tests/unit/cr-review-finding-normalize.test.ts`) y soporta **ambos schemas**: 0.6.4 (texto en `.title`/`.description`, líneas en `.lineStart`/`.lineEnd`) y **0.6.5** (texto en `.codegenInstructions`/`.comment`/`.suggestions`, archivo en `.fileName`, líneas embebidas como "around lines N - M") — TAL-2610. El parser es **fail-closed**: el filtro solo emite findings TRIAGEABLES (con cuerpo de texto real) y `cr-review.sh` exige **paridad** (`normalized == blockers`) antes de tocar known debt; un textless-phantom o un schema no reconocido aborta el gate. El crudo del run queda en `.claude/.cr-review-raw-<run_id>.jsonl` (per-run, TAL-2816) para triage sin re-correr el CLI. Si una versión nueva vuelve a cambiar el schema, revalidar y ajustar el filtro `.jq`. |
| **Coste inesperado** | Revisar usage en el dashboard. Sin auto-refill el gasto está topado por el buffer comprado. PRs grandes (decenas de archivos) over-limit son la cola cara. |
| **Un finding ya waiveado/aceptado re-bloquea el gate en cada re-run** | El waiver era solo manual (doctrina flip-flop / deuda aceptada). Registrarlo: `bash scripts/cr-review.sh --list-findings` → `--accept-debt <n>[,<n>...] "<nota>"` (granular, por índice; ver sección «Known debt»). Expira con cualquier commit/rebase/avance de `main`. |

## Doctrina operativa (Ola-5 — TAL-1596)

Aprendizajes de operación validados en la Ola-5 (decisión del lead incluida):

- **El CLI es SOLO un gate local pre-push.** NUNCA publica evidencia de merge a GitHub
  (commit-status ni equivalente): en una flota donde el carril tiene las credenciales `gh`, una
  auto-atestación del propio carril no es evidencia independiente ("no self-report gates").
  *(Amendado por ADR-0043, ruling 2026-07-08)*: el gate de CR del merge era la **review
  real del App + label `cr-review`** en todo merge; con Fábrica v2 el CLI lo corre el
  **Mergeador** (actor independiente del autor — el racional anti-self-report se preserva)
  y **el CLI limpio AUTORIZA el merge en cualquier superficie**; el App queda
  EXCLUSIVAMENTE como fallback ante CLI rate-limited/caído.
- **Findings-state ≠ rate-limit.** Si el CLI devolvió findings (`complete` con findings), NO hay
  deferral al App: se arreglan (`critical`/`major`) o se documentan. El deferral es solo para el
  error recoverable (`rate_limit`).
- **Flip-flop no reproducible del CLI.** El review en frío no converge monótonamente (cada pasada
  muestrea asperezas distintas). Tope: **1 re-run + 1 captura**; si el finding no reproduce →
  **waiver documentado del coordinador**. Nunca iterar indefinidamente (quema el bucket).
- **Spending-cap del App ≠ rate-limit del CLI.** Solo relevante en el FALLBACK (ruling
  ADR-0043): el cap del App se gestiona con **re-triggers cadenciados (~10 min, 1 canal)** y
  cede; su commit-status residual "cap reached" (no-required) no bloquea el squash cuando la
  evidencia del fallback (review real @head + label) ya está.
- **Título del PR:** solo `feat|fix|refactor|docs|chore|hotfix` — el Title check de CodeRabbit
  rechaza `test:`/`ci:` (usar `chore:` para trabajo de tests/CI).

Detalle operativo en el skill `talent-channel-operation`
(`references/12-aprendizajes-ola5.md` + `references/02-pipeline-y-gates.md`).

## Fase 2 — Pool de identidades (opcional, gateado por el Paso 0)

Multiplica la capacidad de CLI: N identidades con seat Pro+ en `org-ejemplo` → N×10 CLI/h,
**cross-repo** (cubren todos los repos en local). Requiere machine accounts **de pago** (ToS GitHub:
solo 1 free machine account adicional). `creds.manifest` pasa `CODERABBIT_API_KEY` a scope `percarril`
(balanceo estático: cada carril una key del pool). Solo si el Paso 0 confirma que 3 keys = 3 buckets.

## Entrega draft — exención del Gate 2 + verificación post-push (Fábrica v2, TAL-2193)

Fuente canónica del mecanismo de entrega draft (los skills referencian esta sección):

```text
canal: implementa + COMMIT → STOP-AUDIT → GO de código del auditor (Gate 1 intacto: .claude/.audit-go)
  └─ bash scripts/draft-handoff.sh   ← valida working tree limpio + rama con prefijo válido (≠ main)
  │                                     + gates locales verdes (typecheck · lint · build — build
  │                                       opt-in-skippable en flotas débiles, TA_DRAFT_SKIP_BUILD=1,
  │                                       TAL-2820, ver más abajo)
  │                                     + [si el diff origin/main…HEAD trae supabase/migrations/*]
  │                                       supabase db reset --local from-scratch (reproducibilidad, TAL-2274)
  │                                     y EMITE el sentinel .claude/.draft-handoff (SHA de HEAD, one-shot)
  └─ git push                        ← .githooks/pre-push acepta el sentinel draft para el OID empujado
  │                                     (exención SOLO del gate CR-CLI; lo consume tras validar TODO el stdin)
  └─ gh pr create --draft ("closes TAL-N…") + comentario HANDOFF (docs/templates/handoff-pr-draft.md)
  └─ bash scripts/verify-handoff.sh <pr>  ← verificación POST-push fail-closed: isDraft == true ·
                                             bloque machine-readable válido · head_sha == headRefOid ·
                                             un "closes TAL-N" por cada issue del bloque
```

- **Qué exime y qué NO**: el sentinel `.claude/.draft-handoff` exime SOLO del sentinel
  CR-CLI (`.claude/.cr-review-ok`). El Gate 1 de auditoría (`.claude/.audit-go`,
  `scripts/check-push-audit.sh`) sigue aplicando — una entrega draft exige código auditado.
- **Repo-aware (TAL-5232)**: `check-push-audit.sh` solo evalúa `.audit-go`/`.draft-handoff`
  cuando el `cwd` es el repo que `.claude/tf-manifest.conf` declara como propio. Un push desde
  OTRO repo (p. ej. el motor `talent-factory`) recibe un `deny` honesto que remite al contrato
  propio de ese repo — ya NO sugiere `draft-handoff.sh`/`audit-go.sh`, que nunca lo autorizarían.
- **Árbol auditado = `cwd` del evento, no el `$PWD` ambiente (TAL-5509)**: el `cwd` a evaluar
  (identidad, HEAD, sentinels) se deriva SIEMPRE del campo `cwd` del evento `PreToolUse` — la
  fuente autoritativa de "en qué directorio trabaja Claude" según la documentación oficial
  (sigue worktrees y `cd`) —, nunca del `$PWD` ambiente del propio proceso del hook. Fail-closed
  si ese campo falta o no resuelve a un repo git: un push emitido desde un worktree se audita
  contra el worktree, no contra el directorio de proyecto de la sesión.
- **Sentinel**: 5 líneas (`head_sha` / `branch` / timestamp UTC / `db-reset: <estado>` /
  `build: <estado>`), mismo patrón que `.audit-go`. El hook pre-push solo lee las líneas 1
  (SHA) y 2 (rama); las líneas 4-5 son traza local del gate de migraciones y del gate de
  build (ver abajo). Atado al SHA exacto: un commit nuevo exige re-emitirlo. One-shot: el
  hook lo consume (`rm`) al permitir el push, y solo DESPUÉS de validar todas las refs del stdin.
- **Gate de migraciones from-scratch (TAL-2274)**: si el diff `origin/main…HEAD` toca
  `supabase/migrations/*`, `draft-handoff.sh` corre `supabase db reset --local` (drop +
  recreate desde TODAS las migraciones + seed) ANTES de emitir el sentinel — atrapa en el
  canal las migraciones que no aplican limpio desde cero (que romperían `db-guards` + TODOS
  los shards del CI efímero que corre el Mergeador). Sin migraciones en el diff, se OMITE.
  `db reset` es SIEMPRE local/efímero (`--local`): jamás toca prod (el canal no aplica a prod,
  eso es del Mergeador — regla 24). **Fail-closed** si hay migraciones y el stack local no
  puede correr (sin Docker/CLI o daemon caído); salida consciente `DRAFT_HANDOFF_SKIP_DB_RESET=1`.
  **Trazabilidad del skip**: el estado (`VALIDADO` / `OMITIDO` / `n/a`) queda en la 4ª línea
  del sentinel y en el resumen del script — si se usa el skip, DECLARARLO en el HANDOFF
  («Verificación local ejecutada»): el Mergeador no puede distinguir un reset validado de uno
  omitido salvo que el canal lo declare.
- **Gate de build opt-in-skippable en flotas débiles (TAL-2820)**: `draft-handoff.sh` corre
  `npm run build` SIEMPRE salvo que el canal tenga `TA_DRAFT_SKIP_BUILD=1` en su entorno
  (opt-in POR MÁQUINA — activación operativa, ver «Activación por flota» más abajo). El
  motivo: el `next build` del canal es un pre-filtro; varios canales corriéndolo a la vez en
  hosts débiles (N95 y similares) pueden llevar la máquina a swap-death (incidente
  2026-07-16, `vibecoder-05`). El gate OFICIAL de build es `local-gates` en los runners
  sellados, que **re-corre `build` SIEMPRE** (`docs/runbooks/local-gates.md`, gate
  `validar-build`) — por eso un head que no compila **nunca llega a mergear**. El skip **NO
  es "sin riesgo"**: traslada el fallo de build al Mergeador → **rebote tardío posible** del
  draft si el head no compila (el canal se entera después, no antes). Trade-off aceptado en
  hosts débiles. Estado (`VALIDADO` / `OMITIDO`) queda en la 5ª línea del sentinel y en el
  resumen del script; si se usa el skip, DECLARARLO en la sección humana del HANDOFF
  («Verificación local ejecutada») — NO en el bloque machine-readable (el hard-enforce de un
  campo `build` allí, con validación fail-closed en `verify-handoff.sh` y bump a
  `schema_version 2`, queda diferido a un follow-up que abre el coordinador).
- **La entrega no está hecha hasta que `verify-handoff.sh` sale 0**: el push con sentinel
  NO garantiza el draft+HANDOFF; la verificación post-push es parte del protocolo (la
  corren canal, coordinador y Mergeador — contrato del bloque en el template).
- **CodeRabbit en drafts**: `.coderabbit.yaml` tiene `drafts: false` + auto-review opt-in
  por label — un PR draft no consume review del App; el Mergeador corre CR al procesarlo.

### Activación por flota de `TA_DRAFT_SKIP_BUILD` (paso operativo, NO parte de TAL-2820)

El código de `draft-handoff.sh` (arriba) es **inerte** hasta que `TA_DRAFT_SKIP_BUILD=1` quede
puesto en el entorno de los canales de una máquina débil. TAL-2820 entrega el mecanismo
(script + doctrina); **activar el knob por máquina es un paso operativo separado**, no un
deliverable de código ni una condición de cierre de esa issue.

- **Owner**: el **lead / coordinador** que gestiona `$SECRET_DIR/env/*.env` — NO el canal-dev.
- **Mecanismo existente**: el loader `talent-channels/assets/tokens.bashrc.tmpl` exporta cada
  `KEY=VALUE` de `.env.local` al abrir un shell interactivo (salvo la blocklist de variables
  de control de shell — `TA_DRAFT_SKIP_BUILD` NO está en esa blocklist, se exporta igual que
  cualquier token); `talent-channels/scripts/push-carril-env.sh <canal>|all` distribuye
  `$SECRET_DIR/env/<canal>.env` → `.env.local` (0600) del canal.
- **Pasos (host débil, p. ej. N95)**:
  1. Añadir la línea `TA_DRAFT_SKIP_BUILD=1` al env per-canal (`$SECRET_DIR/env/<canal>.env`)
     de CADA canal de esa máquina.
  2. `push-carril-env.sh <canal>` (o `all` si aplica a toda la máquina).
  3. **Relanzar los panes/procesos de agente del canal** — el loader solo actúa al iniciar un
     shell interactivo; un agente ya abierto conserva el entorno viejo y NO hereda la var
     hasta que se relance.
- **Verificación (desde el proceso relanzado, SIN prefijar la var a mano)**: dentro del canal,
  `echo "$TA_DRAFT_SKIP_BUILD"` debe imprimir `1`, y `bash scripts/draft-handoff.sh` (sin
  prefijo) debe imprimir el AVISO de build omitido y NO ejecutar `gate: build`.
- **Máquinas fuertes**: NO añadir la línea — el comportamiento por defecto (build local
  completo) se mantiene sin cambios.
- **Rollback**: quitar la línea del env per-canal, re-correr `push-carril-env.sh`, y relanzar
  los panes (o `unset TA_DRAFT_SKIP_BUILD` en la shell activa).

## Enforcement repo-wide (TAL-1518)

El review pre-PR por CLI deja de depender de que el agente "se acuerde": un **git hook versionado** lo exige en **todo** `git push` (cualquier cliente de git, interactivo o directo). CR es el **gate final pre-PR** — córrelo cuando ya tienes el OK del revisor autorizado para abrir el PR, NO al codificar (el bucket CLI es escaso).

- **`scripts/cr-review.sh`** — córrelo antes de pushear. Hace `git fetch origin main`, corre `coderabbit review --agent --base origin/main <flag-de-alcance>`, y emite el sentinel `.claude/.cr-review-ok` **solo** si `complete.status==review_completed` + 0 `error`/`review_skipped` + 0 findings `critical|major`. Escribe además `.claude/.cr-review-result.json` (estado `running|ok|findings|deferred|blocked|error` + findings redactados, más `cli_version`/`scope_flag` — ver TAL-5477 abajo) en todos los caminos de salida. Persiste evidencia durable por run/SHA (`.claude/.cr-review-history.jsonl` + `.claude/.cr-review-raw-<run_id>.jsonl`) y serializa las mutaciones por-SHA bajo lock + generación no-reutilizable (`.claude/.cr-review-gen`) — ver «Evidencia y adjudicación de phantoms». Findings bloqueantes → no sentinel (arreglar y re-correr, o aceptar deuda granular con `--accept-debt` — ver sección «Known debt»).
  - **TAL-5477 — flag de alcance resuelta por versión del CLI**: la CLI retiró `--type` en 0.7.0 (sustituida por `--committed`/`--uncommitted`/`--include-untracked`). El helper `cr_scope_flag()` lee `coderabbit --version` y elige `--type committed` si `<0.7.0`, `--committed` si `>=0.7.0`; **fail-closed** (estado `error`, sin sentinel) si la versión no se puede leer o parsear. **Troubleshooting**: si ves `error: unknown option '--type'` al correr `coderabbit config validate --type committed` a mano, o si el review de golpe empieza a mirar cambios sin commitear, es que la CLI instalada es `>=0.7.0` — en 0.7.x el subcomando `review` (a diferencia de `config validate`) **ignora en silencio** una flag desconocida y amplía el alcance a "todos los cambios trackeados", en vez de fallar.
- **Degradación (CLI no disponible: sin auth / red / rate-limit):** se difiere al App, pero **solo** si existe un PR para la rama y se le verifica el label `cr-review`. En **primer push sin PR** → estado `blocked`, NO sentinel → el push se bloquea (salida consciente: `git push --no-verify` + abrir el PR con `--label cr-review`).
- **`.githooks/pre-push`** — valida el commit que Git **realmente** empuja (stdin, no HEAD); cubre `push origin otra-rama`, `<sha>:branch`, `--all`. `deferred` caduca a las 2 h. Acepta además el sentinel draft `.claude/.draft-handoff` como exención de la entrega Fábrica v2 (ver «Entrega draft»).
- **Formato del sentinel `.claude/.cr-review-ok`** (TAL-3629 / H-9 del spike TAL-3568 — antes su única
  fuente era un comentario inline del script): son **siempre 5 líneas**, en este orden.

  | línea | contenido | ¿quién lo lee? |
  |---|---|---|
  | L1 | `HEAD_SHA` — el commit auditado | el hook, contra el OID que se empuja |
  | L2 | `base_sha` | **nadie — RESERVADO** |
  | L3 | `state` (`ok` \| `deferred`) | el hook |
  | L4 | `reason` | **nadie — RESERVADO** |
  | L5 | `ts` (ISO-8601 UTC) | el hook, solo si L3=`deferred` (TTL de 2 h) |

  L2/L4 se escriben y no se leen: quedan **reservados a propósito**. Ambos hooks (producto y motor)
  parsean **por número de línea**, así que eliminar o reordenar cualquier línea rompería los dos a la
  vez y bloquearía todo push en ambos repos. Se añade al final o no se toca.
- **Activación (`core.hooksPath`):** en máquinas de devs, **una vez:** `bash scripts/setup-githooks.sh`. **Carriles: la activación del hook en el golden llega en PR2** (modelo unificado); entre tanto el gate es el mismo `scripts/cr-review.sh` + sentinel `.claude/.cr-review-ok` corrido a mano por el dev, bajo **waiver explícito** del coordinador si el CLI está capado.
- **Límite honesto:** `git push --no-verify` lo salta (acto deliberado, no olvido) y requiere `core.hooksPath` activado; el sentinel local es anti-olvido, no anti-malicia (sin backstop server-side por decisión del lead).

## Fuera de alcance

- **Bucket IDE** (10/h): no aprovechable headless (la extensión exige login por navegador).
- **Mover repos entre orgs**: innecesario para capacidad (el pool CLI es cross-repo).
- **Required check server-side / automation server-side**: descartado (consumiría bucket del App).

## Referencias

- Plan de implementación: `~/.claude/plans/mossy-snacking-biscuit.md` · Linear **TAL-1502**.
- Skill `coderabbit-talent` (`references/rate-limits.md`) — pendiente de actualizar a la Fair Usage 2026-06 (PR follow-up).
