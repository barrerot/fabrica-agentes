---
title: "Runbook — Gates locales: el commit-status `local-gates` que sustituye a la CI de GitHub Actions"
created: 2026-07-09
updated: 2026-09-12
author: operador
status: active
---

# Runbook · Gates locales (`local-gates`)

Cómo se produce, verifica y postea el **required check único de `main`**: el
commit-status **`local-gates`**, generado por el motor
`talent-factory/scripts/run-local-gates.sh` (v2) en runners sin credenciales y posteado
por la estación del Mergeador con `talent-factory/scripts/post-local-gates.sh`.

## Contrato de evidencia

La evidencia sellada del runner con estado se valida por la tupla
(gate, commit, manifiesto, base, asignación, grupo):

- (a) El agregador nunca acepta evidencia de otra tupla ni un receipt que no
  haya sellado el lanzador. Exige identidad vigente, asignación sellada y respaldo
  del receipt en el journal de la estación.
- (b) Cualquier rechazo o fallo del intento en otro grupo conserva la evidencia
  válida del grupo original, incluso si el llamador comparte el directorio de receipts.
- (c) La evidencia legítima previa de la MISMA tupla sigue siendo válida: un
  reintento rechazado o fallido NO la invalida. La agregación posterior puede
  aceptar esa evidencia original sin una nueva ejecución del gate.

Modelo de amenaza: fallo accidental, no un actor con el mismo UID.
Riesgo residual: un proceso con el mismo UID puede borrar o fabricar marcadores.

Mejora futura: un identificador de intento recibido del llamador permitiría invalidar evidencia previa; no se implementa en 1.7.2.

Este contrato conserva las interfaces de `run-gate-sealed.sh` y
`post-local-gates.sh`. El receipt remoto se retira por grupo antes de la ejecución;
el local se recibe en un temporal del mismo directorio y solo se reemplaza por
renombrado atómico tras recibirlo completo. Un fallo anterior conserva el destino.
El receipt temporal se sella con el nombre final antes de sustituir al anterior; el diagnóstico local sigue sin ser agregable.
Antes de promover se exige releer el sello del temporal; bajo el mismo candado se separa cualquier cola incompleta y el lector ignora líneas rotas, que nunca respaldan evidencia.

## Qué reemplaza y por qué

**GitHub Actions está OFF** (TAL-2286, 2026-07-09): el presupuesto de Actions de la org
se agotó ($200; reset 1-ago) y la decisión del lead es no depender de él — el modelo de
gates 100 % locales es además la clave multi-org (repos/orgs sin presupuesto de Actions
tienen exactamente el mismo gate). Los workflows (`ci.yml`, `pr-gate.yml`, `docs.yml`)
**siguen en el repo como referencia y fuente de extracción** de los wrappers — no se
ejecutan.

La branch protection de `main` requiere el contexto **`local-gates`**
(`scripts/setup-branch-protection.sh`; los 6 contextos de Actions quedaron retirados y
documentados como comentario histórico en ese script). Sin `local-gates=success` @head,
**ningún** merge pasa — tampoco el flujo clásico de terminal-sola.

### Inventario check retirado → gate local

| Check de Actions (retirado 2026-07-09) | Gate local que lo cubre |
|---|---|
| `validar-flujo-pr` | gate `branch-name` en el agregador (validador canónico `scripts/github/validar-rama-pr.sh` ejecutado desde base_sha en subprocess sin credenciales; excepción Dependabot por autor preservada) + gate `tenant` (`scripts/check-tenant-hygiene.sh`) + gate `node-parity` (`scripts/check-node-parity.sh`, TAL-2332) + gate `edge-pins` (`scripts/check-edge-pins.sh`, TAL-2502) en runner |
| `validar-build` | gates `typecheck` · `lint` · `build` · `unit` — más `i18n` y `flags` como **FORTALECIMIENTO NUEVO** (no formaban parte de `validar-build`) |
| `db-guards` | `scripts/ci/run-db-guards-local.sh` — corre **SIEMPRE** (`TF_DB_GATE=always`, ver abajo) |
| `integration` | `scripts/ci/run-integration-local.sh` |
| `e2e-ola3` / `e2e-pagos` | `scripts/ci/run-e2e-shard-local.sh <familia> <shard>` — un run por shard del registro `scripts/ci/e2e-shards.json` |

**Retirados-declarados: NINGÚN gate se retiró ni degradó** en la migración; `i18n` y
`flags` se AÑADEN. `node-parity` y `edge-pins` (TAL-2332/TAL-2502) se AÑADEN
posteriormente bajo el mismo principio (adición, no reducción). Cualquier
retiro/degradación futura exige ratificación explícita del lead y su declaración
individual en este runbook.

Dirección del espejo db-guards: `GUARD_FILES` de `run-db-guards-local.sh` es la fuente; el
listado del step `db-guards` de `pr-gate.yml` (Actions OFF) se sincroniza al tocar el array
(TAL-3335).

### Gate añadido: `tests-manifest` (TAL-2973)

`npm run` no lo envuelve — el gate corre directo `bash scripts/check-tests-manifest.sh`
(TAL-2039). Valida que `supabase/tests/MANIFEST.md` esté completo (todo archivo de
`supabase/tests/*.sql`/`*.sh` clasificado exactamente una vez) y que su columna
`allowlist=sí` coincida EXACTAMENTE con el conjunto que ejecuta hoy
`scripts/ci/run-db-guards-local.sh` (derivado por máquina del wrapper vivo — el script no
lee una copia hardcodeada, así que un cambio en el gate real lo hace fallar hasta que el
manifest se actualice). Es **estático, sin DB, sin red ni credenciales**.

Antes de TAL-2973 corría standalone: nada lo invocaba desde el pipeline y `main` llegó a
estar rojo en él (3 archivos nuevos sin clasificar) sin que ningún gate lo bloqueara — ver
`.claude/memory/gotchas.md` (incidente `check-tests-manifest.sh estaba ROJO en main ANTES
de tocar nada... run-db-guards no invoca ese check, así que mergeó`). TAL-2973 cierra ese
hueco cableándolo como gate propio (no como paso dentro de `db-guards`) en
`TF_GATE_IDS`/`TF_GATE_CMD_tests_manifest` de **`talent-factory/manifiestos/academy.conf`**
(fuera de este repo) — mismo patrón de 2 declaraciones que `tenant`/`markdownlint`/
`skills-package`, con su ratificación correspondiente en
`talent-factory/manifiestos/RATIFICACIONES.log` (el motor exige una entrada ahí para
cualquier alta de `TF_GATE_CMD_*`).

**Estado del aterrizaje:** el cambio del motor está preparado (commit local sobre `main` de
`talent-factory`, `bash scripts/motor-go.sh` verde, sentinel emitido) pero su push lo
coordina el carril de gates — entra en TODAS las corridas de `local-gates` de todos los PRs
en vuelo, así que el momento de aterrizarlo no es unilateral de este encargo. Añadir
`tests-manifest` al enumerado `for g in ...` de la sección "Terminal-sola" de abajo asume que
ya está live en el manifiesto del motor.

**Carve-out docs-only (`TF_CARVEOUT_DOCS_ONLY`):** hoy apagado (`0`, TAL-3439), así que el
gate corre siempre y esto es teórico. Si se reactiva: `tests-manifest` **NO** necesita ser
survivor (`TF_CARVEOUT_KEEP_GATES`) — un diff 100% `.md` bajo `docs/`/`.claude/skills/` no
puede alterar `supabase/tests/MANIFEST.md` ni `scripts/ci/run-db-guards-local.sh` (ambos
fuera de esos prefijos), así que saltar el gate en ese caso es correcto y no abre un hueco.
Decisión escrita a propósito para que, si el carve-out se reactiva, quede claro que la
ausencia de `tests-manifest` en `TF_CARVEOUT_KEEP_GATES` es intencional, no un olvido.

**Verificación en rojo forzado a nivel MOTOR (no solo el script):**
`scripts/ci/verify-tests-manifest-gate-wiring.sh` invoca el motor real
(`run-local-gates.sh --gate tests-manifest`) contra un fixture de `MANIFEST.md` roto y uno
limpio, y lee el campo `result` del receipt JSON emitido — prueba que el MOTOR rechaza la
deriva, no solo que el script standalone sale con exit 1 (eso ya lo cubre
`scripts/ci/test-tests-manifest-fail-propagation.sh`, que invoca `check_manifest()`
directamente). La corrida oficial se re-ejecuta contra `main` una vez que TAL-3446 (#1391 —
gatea el total en vez de declararlo a mano) esté mergeado y el gate del motor esté aterrizado;
hasta entonces cualquier corrida es validación mecánica del arnés, no la prueba oficial.

### Gate añadido: `lockfile-sync` (TAL-5230)

`npm run lock:check` envuelve `bash scripts/check-lockfile-sync.sh` (interfaz que la issue
prescribe como punto de entrada humano/documental — mismo patrón que `node:check`/`edge:check`);
el manifiesto del motor sigue invocando el script directo (`TF_GATE_CMD_lockfile_sync`, mismo
patrón que `tests-manifest`/`skills-package`, sin wrapper npm). Valida que `package-lock.json`
esté SINCRONIZADO con `package.json` (`npm ci --dry-run --ignore-scripts --no-audit --no-fund`
limpio). Es **estático, sin DB, sin red más allá de lo que `npm ci --dry-run` ya necesite para
resolver contra el lock** — un lock con entradas FALTANTES falla localmente (EUSAGE) sin tocar
el registry. `--ignore-scripts` es postura de conducta (el guard corre dentro de un gate; en
`--dry-run` es inerte por construcción — npm nunca instala nada, verificado empíricamente —,
pero es la bandera correcta igual, no por si acaso cambia algo).

**Motivo:** `main` quedó con `npm ci` roto DOS VECES por la misma clase de fallo — un merge que
dropea bloques del lock: TAL-3361 (jul-2026) y TAL-5230 (`#2155`, dependabot bump de
`browserslist`, sep-2026), ambas veces la familia `node_modules/puppeteer/node_modules/
proxy-agent@8`. La segunda vez se coló porque `#2155` se cerró por el **carril rápido de
dependabot**, que triangula su condición de aceptación por `npm ls` — y `npm ls` es **ciego a
entradas FALTANTES del lock** para paquetes que ni siquiera están instalados localmente (el
árbol instalado que `npm ls` inspecciona no incluye lo que falta en el lock). Un carril rápido
ciego a su propio modo de fallo. `check-lockfile-sync.sh` corre el mismo `npm ci` real del
`TF_INSTALL` oficial. **La detección temprana propia del guard ocurre en `draft-handoff.sh`**
(donde `lockfile-sync` es el PRIMER gate, antes de `typecheck`/`build` — ver más abajo); **en el
motor**, `TF_INSTALL` corre como fase de SETUP **antes** de la fase `GATE` (secciones separadas
en el log de `run-local-gates.sh`), así que ante un lock roto el `npm ci` de setup sigue siendo
la primera autoridad fail-closed — el guard entra en juego para acreditar que el fallo es
específicamente de sincronía del lock (diagnóstico propio, ver §4bis más abajo), no para
adelantarse al setup oficial.

**Dependencia de la versión de npm (medida el 2-sep-2026, CEO):** el diagnóstico `Missing: … from
lock file` lo produce `validateLockfile` de npm comparando el árbol ideal con el lock, y el árbol
ideal depende del resolutor de cada npm. El par roto real de `#2155` da 15 `Missing` bajo **npm 10**
(node 22, el pin del repo EN ESA FECHA — `.nvmrc`/`engines`; TAL-5329 subió el pin a Node 24 después,
2026-09-04, esta cifra es histórica) y **rc=0 bajo npm 11** (node 24, runtime declarado de
los runners sellados; medido en vibe-runner-delta-01, npm 11.17.0): en el lock no existe ningún
`proxy-agent@8` top-level (el top-level es 6.5.0) y npm 11 NO materializa la rama anidada
`puppeteer/node_modules/proxy-agent@8.0.2` (con su subárbol = las 15 ausencias) que npm 10 sí añade
al resolver un ERESOLVE de peers. Consecuencias: (a) el guard es fiel a *su* npm **y a su registry**
(el árbol ideal se resuelve contra el registry: sin red, el par real da rc=0 bajo npm 10 — falso verde
del guard — y el universal da rc≠0 sin `Missing`): protege donde `npm ci` fallaría y es verde donde
también lo sería; (b) el selftest y los DOS verificadores de wiring usan `broken-universal/` (par
mínimo con `is-odd@3.0.1` + `is-number@6.0.0` directos y pineados, rojo en cualquier npm con 2
`Missing` exactos) como oráculo rojo; el par real `broken/` queda como reproducción del incidente
**solo bajo npm ≤ 10** — bajo npm ≥ 11 el selftest exige rc=0 y declara un `SKIP` explícito, nunca
silencio; (c) la paridad node/npm de los runners con el pin del repo es un riesgo aparte (registrado
por M1 el 2-sep), no lo resuelve este gate.

A diferencia de `tests-manifest` (que solo vive en `local-gates`), `lockfile-sync` **también**
está cableado en `scripts/draft-handoff.sh` (antes de `typecheck`, por ser la comprobación más
barata y la más fundacional — un lock desincronizado revienta el `npm ci` de CUALQUIER runner
sellado antes de ejecutar nada; `typecheck`/`build` corriendo sobre el `node_modules` ya
instalado localmente no lo detectarían).

**Estado del aterrizaje — BILATERAL, declarado explícitamente para no repetir el fallo que este
gate existe para cerrar:** el cambio del motor (`TF_GATE_IDS`/`TF_GATE_CMD_lockfile_sync` +
entrada en `RATIFICACIONES.log` de `talent-factory/manifiestos/academy.conf`, fuera de este
repo, mismo patrón de 2 declaraciones que `tenant`/`markdownlint`/`skills-package`/
`tests-manifest`) está **preparado en commit local** (`bash scripts/motor-go.sh` verde) pero
**SIN PUBLICAR**, bloqueado por TAL-5232 (hueco de la fábrica en el push a un repo secundario
desde un canal cuyo cwd primario es otro). **Mientras esa pieza no aterrice, `lockfile-sync` NO
existe en la fuente oficial del motor y NO se ejecuta en `local-gates`** — el guard SÍ está
activo en `draft-handoff.sh` (cablea contra el propio repo del canal, sin depender del
manifiesto del motor), pero la protección de `local-gates` contra el resto de la flota (PRs que
no pasan por un canal, o cuyo autor se salta `draft-handoff.sh`) queda pendiente del aterrizaje
del motor. El verde de la entrega de producto de TAL-5230 **no** significa "ya protegidos" en
`local-gates` hasta ese segundo paso.

**Verificación en rojo forzado a nivel MOTOR (no solo el script) — con la salvedad del log en
PASS:** `scripts/ci/verify-lockfile-sync-gate-wiring.sh` invoca el motor real
(`run-local-gates.sh --gate lockfile-sync`) contra un manifiesto fixture con `TF_INSTALL=true`
(aísla el `npm ci` de SETUP del guard bajo prueba — sin esto, contra un lock roto el setup
fallaría primero y un receipt FAIL no demostraría que el GUARD se ejecutó) y exige, en AMBAS
ramas, `LG_KEEP_LOGS=1` (el motor borra el log en todo resultado ≠ FAIL por defecto,
`run-local-gates.sh:442`) + la ruta del log resuelta desde el campo `.log` del receipt: verde =
`PASS` + firma positiva exclusiva de `check-lockfile-sync.sh` en el log; rojo aislado = `FAIL` +
diagnóstico de las 15 ausencias, sin ningún fallo de setup mezclado. Eso ya lo distingue de la
prueba standalone del script (`scripts/ci/test-lockfile-sync-fail-propagation.sh`, que invoca
`check_lockfile_sync()` directamente) y del verificador de wiring DE PRODUCTO
(`scripts/ci/verify-lockfile-sync-wiring.sh`, ejecutor independiente sin recursión que acredita
el cableado real en `run-db-guards-local.sh` y `draft-handoff.sh` — ver su propio comentario de
cabecera). La corrida oficial contra el motor se re-ejecuta una vez que TAL-5232 esté resuelto y
el gate del motor aterrizado; hasta entonces cualquier corrida es validación mecánica del
arnés contra la rama local preparada, no la prueba oficial.

**Carve-out docs-only (`TF_CARVEOUT_DOCS_ONLY`):** hoy apagado (`0`, TAL-3439), así que el gate
corre siempre y esto es teórico. Si se reactiva: `lockfile-sync` **NO** necesita ser survivor
(`TF_CARVEOUT_KEEP_GATES`) — un diff 100% `.md` bajo `docs/`/`.claude/skills/` no puede alterar
`package.json`/`package-lock.json` (ambos fuera de esos prefijos), así que saltar el gate en ese
caso es correcto y no abre un hueco.

### Candidato de gate NUEVO: `admin-client` (TAL-1723, pendiente de wiring del motor)

`npm run admin-client:check` (`bash scripts/check-admin-client-callsites.sh`) es un ratchet
POR-FICHERO — mismo mecanismo que `tenant`/`node-parity`/`edge-pins` — que falla si aparece
un call-site NUEVO de `createAdminClient()` (service-role, bypassa RLS) en `src/` fuera del
baseline versionado `scripts/admin-client-callsites.allowlist`, o si un fichero sellado sube
su count de ocurrencias sin re-justificar. Ver el inventario clasificado completo y el
alcance/límite del guardrail en `docs/audit/tal-1723-admin-client-callsites.md`.

Es un gate **estático, sin DB** — pertenece al mismo cohorte que `tenant`/`node-parity`/
`edge-pins` (cobertura de `validar-flujo-pr`, no `db-guards`). **Cablearlo al manifiesto real
del motor** (`talent-factory/manifiestos/academy.conf`, fuera de este repo) y añadirlo al
enumerado `for g in ...` de abajo es **follow-up del motor de fábrica, fuera del alcance de
TAL-1723** — este encargo solo entrega el script + npm script + esta documentación,
siguiendo el mismo patrón "adición, no reducción" que `node-parity`/`edge-pins`. Hasta que se
cablee, correrlo es responsabilidad manual del autor del PR (`npm run admin-client:check`
antes de push) igual que cualquier check no bloqueante.

### Candidato de gate NUEVO: `functions` / `deno` (TAL-2030, pendiente de wiring del motor)

`npm run functions:check` (`bash scripts/check-functions.sh`) valida las **Edge Functions Deno**
de `supabase/functions/**` — `embed_text` y `chunk_and_embed_transcript` (núcleo del RAG),
`vendor_smoke_test`, `hello`, `_shared` — que corren en runtime Deno y están EXCLUIDAS de
`tsconfig.json` + `eslint.config.mjs`, de modo que `typecheck`/`lint`/`build` de Node NO las
validan. Con un binario Deno resuelto y pineado a `.dvmrc` (`2.9.2`, misma pin que CI)
corre: `deno fmt --check` + `deno lint` + `deno check` — este último con `--node-modules-dir=none`
para aislar el grafo del `node_modules` raíz de Next (que lleva otra versión de
`@supabase/supabase-js`; además es paridad con el edge-runtime de prod, sin node_modules) y con
`--frozen --lock` para que un drift de `deno.lock` sea ROJO, no falso verde. La regla `deno lint`
`no-import-prefix` está excluida en `supabase/functions/deno.json`: el idioma de las Edge
Functions es `import … "jsr:…@X.Y.Z"` inline, cuyo PINEADO exacto ya garantiza `edge:check`
(`scripts/check-edge-pins.sh`), no esa regla de estilo.

Es un gate **estático, sin DB** — mismo cohorte que `tenant`/`node-parity`/`edge-pins`. A
diferencia de `admin-client`, ya está cableado como `run_gate` en `scripts/draft-handoff.sh`
(antes de `build`, para fallar rápido), por lo que corre en el flujo de canales. **Cablearlo al
manifiesto real del motor** (`talent-factory/manifiestos/academy.conf`, fuera de este repo) y
añadirlo al enumerado `for g in ...` de abajo es **follow-up del motor de fábrica, fuera del
alcance de TAL-2030** — este encargo entrega el script + npm script + gate de canal + esta
documentación, siguiendo el mismo patrón "adición, no reducción" que `node-parity`/`edge-pins`.
Hasta que se cablee, en el flujo terminal-sola correrlo es responsabilidad manual del autor del
PR (`npm run functions:check` antes de push).

### Candidato de gate NUEVO: `date-bomb` (TAL-5139, pendiente de wiring del motor)

**Qué detecta, sin sobre-prometer (re-declarado en ronda 5 de auditoría, hallazgo Mayor 5:
la redacción anterior sugería detección SEMÁNTICA de uso-como-vigencia; el gate es y sigue
siendo LÉXICO — busca TOKENS con forma de fecha, no evalúa si esa fecha se usa como
vigencia/expiración o como dato histórico de referencia; esa distinción semántica queda
fuera de alcance de un checker bash+grep sin dependencias nuevas, restricción explícita de
la propia issue de origen — ver "Falsos negativos aceptados" más abajo, que ya reconocía
esto para otros casos y ahora lo hace explícito también para éste)**: `npm run
date-bomb:check` (`bash scripts/ci/check-date-bombs.sh`) falla cuando un fixture NUEVO o
MODIFICADO en el diff (`supabase/tests/**`, `supabase/seed*.sql`, `supabase/fixtures/**`,
`tests/unit/**`, `tests/e2e/**`, `tests/integration/**`, `tests/fixtures/**`,
`tests/eval/fixtures/**`, `scripts/ia-academy-import/fixtures/**`,
`scripts/repesca/fixtures/**`, `scripts/verify/**`, `.claude/skills/**/tests/**`) contiene
un TOKEN con forma de fecha absoluta — case-insensitive, espacio opcional antes del
paréntesis en las llamadas de función (ronda 5, hallazgo Mayor 1): literal `YYYY-MM-DD` o
`YYYY/MM/DD` (cubre timestamptz), `make_date(`/`MAKE_DATE(`, `to_date(`, `Date.UTC(`/`Date.UTC
(`, `new Date(<año>,` — dondequiera que aparezca en una línea añadida dentro de esas rutas,
SIN evaluar si está anclado a `now()`/`current_date` o no (el gate NO comprueba anclaje: ronda
1 de auditoría eliminó la exención "now() en la misma línea" por insegura; hoy CUALQUIER
token con forma de fecha en una línea añadida dispara, esté o no acompañado de `now()`).
Origen (medido, 1-sep-2026): 5 PRs existieron solo para desatascar `main` por fixtures con
fecha absoluta que caducan con el calendario (#2039, #2042, #2044, #2098, #2112) — rojo
simultáneo en 5 estaciones, 203 min sin merges. Gotcha sellado: «fix de date-bomb pgTAP verde
HOY ≠ robusto a run-date — anclar vigencia a `now()`». Aprobado por el lead 2026-09-01 21:55
CDMX.

Excepción deliberada, ANCLADA AL VALOR (nunca a la línea ni al fichero entero — ronda 4 de
auditoría, hallazgo Bloqueante 2, reproducido en verde con 2 casos reales antes del fix: una
anotación legítima para una fecha histórica eximía OTRA fecha sin relación en la misma
línea; un sidecar existente por un campo histórico eximía CUALQUIER fecha nueva añadida
después al mismo JSON — "puerta trasera trivial", basta poner tu fecha al lado de una ya
justificada): `-- date-bomb-ok: <motivo>` / `// date-bomb-ok: <motivo>` en la misma línea,
pero SOLO exime si la línea tiene EXACTAMENTE un valor de fecha (2+ valores = ambigüedad =
NO se exime, el autor separa en líneas distintas); en JSON (sin comentarios válidos) el
escape es un **fichero sidecar** `<fixture>.date-bomb-ok`, EXPRESSION-scoped (ronda 5,
reabre el hallazgo Bloqueante 2: value-scoped por sí solo no distinguía CAMPOS — un sidecar
que justificaba `2026-07-31` para `capturedAt` eximía igual un `expiresAt` NUEVO con el
MISMO literal, reproducido en verde antes de este fix): cada línea aporta `clave:valor`
(la clave JSON que gobierna el valor en esa línea), y el sidecar debe listar ESE PAR exacto
— no basta con que el valor solo aparezca en el sidecar, ni con que el fichero exista/no
esté vacío. NO una key embebida en el propio JSON: una key embebida mutaría el
payload/schema del fixture, la proximidad de línea no demuestra pertenencia al mismo
objeto, y con `--unified=0` una anotación ya existente sin tocar no aparecería en el diff
(falso FAIL). El sidecar vive fuera del JSON y se comprueba contra el árbol de trabajo, no
contra el diff, así que una anotación pre-existente para el MISMO par clave:valor siempre
se ve — pero un par nuevo (clave nueva, o la MISMA clave con valor nuevo, o el MISMO valor
en una clave nueva) no listado en el sidecar sigue disparando aunque el fichero ya tenga
sidecar por otro motivo. (Límite aceptado: si la clave vive en otra línea que el valor —
JSON multi-línea infrecuente — se cae a exigir solo el valor, mismo límite ya documentado
para "fechas partidas entre variables".) Los propios sidecars (`*.date-bomb-ok`) están
excluidos del escaneo en ambos modos (gate y full-scan): son metadata de exención, no
fixtures, y desde que anclan a la expresión pueden contener legítimamente la fecha literal
que justifican.

Es un gate **diff-only, estático, sin DB** — solo líneas AÑADIDAS, nunca re-escanea
contenido ya existente en `main` sin tocar (así el gate no puede empezar rojo sobre `main`,
y no reabre incidentes históricos ya fixeados). Usa `--no-renames` en el `git diff` a
propósito y VERIFICADO EMPÍRICAMENTE: sin ese flag, git colapsa un rename de 100%
similitud en un bloque `rename from/to` con CERO líneas añadidas (un fixture ya-red movido
a una ruta vigilada quedaría invisible); con `--no-renames` el mismo rename se ve como
delete+add con el contenido completo como líneas `+`, así que el checker lo escanea. Selftest
con 39 casos (`scripts/ci/selftest-date-bombs.sh`), incluida verificación empírica contra el
patrón real de ancla-fecha-fija usado en los fixes de TAL-5106/TAL-5120
(`supabase/tests/study_plan_blocks.sql`, `supabase/tests/tal4578_projection_contexto_terminal.sql`),
rename puro hacia ruta vigilada, rutas con espacios, múltiples hunks en un mismo archivo.

**Dependencias, verificadas por EJECUCIÓN REAL, no por presencia en PATH** (`git`, `awk`,
`grep`, `tail`, `sed` — ronda 6 sumó `tail`/`sed`, ver abajo): un canario funcional
(entrada conocida, salida EXACTA esperada) corre al inicio del script para las cinco;
`command -v`/presencia-en-PATH NO basta (no distingue un binario roto de uno sano —
ronda 5, ver abajo).

**Ronda 14 de auditoría** (rebote de M2/CodeRabbit CLI sobre ronda 13, un único MAJOR real
verificado en código — no falso positivo): el caso 39 del selftest (~L1089) invocaba el
checker sin aislar `BASE_SHA` del entorno del PROCESO que corre el selftest (a diferencia
del caso 11c, L431, que ya usaba `env -u BASE_SHA`) — el comentario del caso PRESUPONÍA
"sin BASE_SHA" pero el comando no lo garantizaba. Reproducido de propia mano ANTES del
fix (`BASE_SHA=HEAD` exportado + código vulnerable revertido temporalmente): caso 39 rojo
real, `esperado exit 2... got 0` — el checker toma la rama "candidato recibido" en vez del
fallback que el caso existe para probar. Fix: mismo patrón que 11c (`env -u BASE_SHA`).
Verificado inmune a la MISMA contaminación tras el fix (`SELFTEST_EXIT=0` con
`BASE_SHA=HEAD` exportado). **Barrido exhaustivo del RESTO del fichero — corregido en un
segundo intento (veredicto r14, MAYOR 2: el barrido original limitaba la búsqueda al
patrón `bash "$CHECKER"` y llegaba a 47 por dos errores que se cancelaban — contaba el
cuerpo del wrapper `run_checker()` como caso adicional y omitía `bash "$parent_checker"`
del caso 38; el número salía bien por coincidencia aritmética, no por enumeración
completa).** Un único comando que cubre las TRES formas de invocación (comando + salida
íntegra en
[`MUTATION-TESTING-RECEIPT-ronda14.md`](../../scripts/ci/MUTATION-TESTING-RECEIPT-ronda14.md)):
**20** invocaciones directas `bash "$CHECKER"` (todas con `BASE_SHA=` o `env -u BASE_SHA`
explícitos salvo el caso 39 ya corregido) + **26** vía el wrapper `run_checker()` (siempre
`BASE_SHA="$2"` explícito) + **1** vía `bash "$parent_checker"` (caso 38, también con
`BASE_SHA="$base"` explícito — no era un segundo bug funcional, solo faltaba en el
recuento) = **47 invocaciones totales, cero sin aislar**. Selftest sin cambio de casos
(**39** — 47 aserciones, sin cambio de recuento).

**Ronda 13 de auditoría** (cero bloqueantes desde ronda 11; cierra las dos MAYORES que
quedaron abiertas en el veredicto de ronda 12 — ver
[`scripts/ci/MUTATION-TESTING-RECEIPT-ronda13.md`](../../scripts/ci/MUTATION-TESTING-RECEIPT-ronda13.md)
para el detalle completo):

- **MAYOR 2 — cerrada bajando la descripción, con medición propia.** M5/M6 ya se
  declaraban "RETIRADAS, no corregidas" desde ronda 12, pero sin una medición fresca y
  literal de su no-aplicación contra el head vigente. Añadida: `git apply --check`
  (M5) y `git apply -R --check` (M6) contra el checker actual, ambos
  `EXIT=1` — coincide exactamente con lo que midió el auditor. M8/M9 quedan explícitos
  como cobertura NUEVA, nunca "corrección" de M5/M6.
- **MAYOR 3(a) — correspondencia contradictoria entre `ronda9.md` (M7 reemplaza a M6) y
  `ronda12.md` (M8/M9 sustitutos de M5/M6, implicando M9↔M6) — resuelta con una tabla
  única.** El caso 36 tiene un mutante propio en cada mecanismo sucesivo (M5→M6→M8,
  cada eslabón retirado cuando su mecanismo es sustituido); M7 es la reversión CONJUNTA
  de la transición completa (discrimina 36+37 por diseño, no es un reemplazo 1:1); el
  caso 37 no existió antes de ronda 10, así que M5/M6 nunca lo ejercitaron; M9 (guard de
  `merge-base`) no reemplaza nada — es cobertura nueva sin relación con M6. Ambos AVISOs
  contradictorios (`ronda9.md`, `ronda12.md`) quedan editados para apuntar a la tabla
  única en vez de afirmar su propia versión.
- **MAYOR 3(b) — el vigilante del caso 37 no tenía mutación aislada propia** (solo se
  ponía rojo en combinación con el 36, vía M7). **M10, nueva**: reintroduce una llamada a
  `cat-file` sobre el candidato REDUNDANTE junto a `rev-parse` (un "doble-check"
  defensivo que no se da cuenta de que reintroduce exactamente la fragilidad que 37
  existe para prevenir) — verificado end-to-end que pone rojo el caso 37 y SOLO el 37 en
  los 39 casos completos (`grep -c "^✗ caso"` = 1), caso 36 confirmado explícitamente
  verde en la misma corrida, control post-restauración 39/39 verde. Selftest sin cambio
  de casos (**39** — 37 ya existía desde ronda 10; lo nuevo es su mutante aislado, no el
  caso). Mecanismos vigentes probados con mutación discriminante: **8** (M1-M4, M7, M8,
  M9, M10) — M5/M6 retirados, no cuentan.

**Rondas 11-12 de auditoría** (el Bloqueante (a) SÍ quedó CERRADO en ronda 11 — el
discriminador `rev-parse --verify -q` de ronda 10 "hace su trabajo"; lo que siguió
abierto fue el MAYOR de los comandos de verificación, que había empeorado):

- **Ronda 11 — MAYOR: los comandos publicados de mutation-testing eran falsamente verdes
  y varios ya no reproducían sus mutaciones.** El auditor re-ejecutó LITERALMENTE cada
  bloque publicado (M1-M7) en clones aislados del head. M1-M4 y M7 imprimían
  `SELFTEST_EXIT` correctamente pero el BLOQUE PUBLICADO, si un tercero lo corre entero y
  comprueba `$?`, seguía terminando en `grep`/`tail` (`DECLARED_BLOCK_EXIT=0` medido para
  los 5 pese a `SELFTEST_EXIT=1` real) — la corrección de ronda 10 arregló lo que se
  IMPRIMÍA, no el exit code real del bloque. M5 y M6 eran más graves: sus parches atacan
  el mecanismo de `cat-file` ya retirado en ronda 10 — `git apply`/`git apply -R`
  FALLABAN contra el head vigente, sin guard de `rc` el bloque seguía adelante, y
  publicaba una suite verde SIN haber mutado nada. La afirmación de que M1-M6 habían sido
  "re-verificados con comandos corregidos" en ronda 10 no estaba acreditada.
- **Ronda 12 — fix real**: cada bloque se envuelve en un subshell `( ... )` que TERMINA en
  `exit "$SELFTEST_EXIT"` sin ningún comando después de la `)` de cierre — el exit code
  del bloque, comprobado como paso aparte tras ejecutarlo, es el resultado real (meter un
  `echo` final ahí reproduciría el mismo bug un nivel más arriba). Cada bloque comprueba
  además el `rc` de `git apply` y el hash resultante ANTES de correr el selftest, fallando
  RUIDOSAMENTE (no en silencio) si el parche no aplica. M5 y M6 quedan RETIRADOS (no
  "corregidos" — su código ya no existe) con AVISO explícito y parche conservado como
  registro histórico en formato `diff` puro (sin heredoc, para que no se pueda copiar y
  correr por error); su reemplazo conceptual contra el mecanismo VIGENTE son M8 y M9,
  nuevos en esta ronda: M8 aísla el discriminador `verify_rc` (caso 36, ya existente); M9
  aísla el guard de `git merge-base` (`|| return 2`), una afirmación de "ya blindado, no
  hace falta mutación" que llevaba TRES rondas sin ejercitarse — sí resultó discriminante
  (caso 39, nuevo, permanente: `origin/main` con historia disjunta, `merge-base` falla de
  verdad, sin shim). **Bug propio auto-detectado en el camino** (no reportado por el
  auditor): el shim del caso 36 exportaba la función `git` (`export -f git`) pero NO la
  variable `base` que su cuerpo referenciaba — bajo `set -u` (heredado por la función, que
  no forkea) esto rompía el shim de una forma que, por coincidencia, seguía dando el exit
  code esperado por una vía distinta a la que el caso decía probar; corregido con
  `export base`. Selftest: 38 → **39 casos**. Full-scan sin cambio (**2578**). Nuevo:
  [`scripts/ci/MUTATION-TESTING-RECEIPT-ronda12.md`](../../scripts/ci/MUTATION-TESTING-RECEIPT-ronda12.md)
  (M8, M9); comandos corregidos en
  [`ronda7.md`](../../scripts/ci/MUTATION-TESTING-RECEIPT-ronda7.md),
  [`ronda8.md`](../../scripts/ci/MUTATION-TESTING-RECEIPT-ronda8.md),
  [`ronda9.md`](../../scripts/ci/MUTATION-TESTING-RECEIPT-ronda9.md) y
  [`ronda10.md`](../../scripts/ci/MUTATION-TESTING-RECEIPT-ronda10.md) (esta última
  retracta explícitamente su propia afirmación de MAYOR-cerrado).

**Ronda 10 de auditoría** (Bloqueante (a) reabierto por SÉPTIMA vez, en el MISMO sitio
del fix de ronda 9 — el fix de ronda 9 no era un hermano nuevo tampoco: era el MISMO
mecanismo con un defecto de diseño):

- **El canario de ronda 9 verificaba una llamada DISTINTA de aquella cuyo fallo
  importa**: `cat-file -e "HEAD^{commit}"` (canario) y `cat-file -e "${candidate}^{commit}"`
  (uso productivo) son dos procesos `cat-file` separados — un `git` selectivo que deja
  pasar `HEAD^{commit}` pero rompe CUALQUIER OTRO argumento con 128 supera el canario Y
  sigue leyendo el 128 del candidato como "inválido", fallback silencioso. Medido:
  `CAT_FILE_HEAD_CANARY_PASS_CANDIDATE_FATAL_128_EXIT=0`. Cita del veredicto, que es el
  criterio de diseño del fix: "no basta con que el verificador no falle abierto; tiene
  que verificar la MISMA llamada que puede fallar". **Fix**: se abandona `cat-file -e`
  por completo — se sustituye por `git rev-parse --verify -q "<candidato>^{commit}"`,
  verificado empíricamente que separa limpiamente los dos significados que `cat-file -e`
  conflaba (`rc=0` válido, `rc=1` no resuelve a un commit — sintaxis inválida, objeto
  inexistente, o blob/tree con `^{commit}`, los tres probados —, `rc=128` reservado a
  fallos genuinamente fatales). Es UNA sola llamada, sobre el candidato, cuyo resultado
  se lee directamente — no un canario sobre un objeto distinto. Mismo patrón que
  `git rev-parse --verify -q origin/main`, ya certificado fail-closed sin necesitar
  mutación propia. Caso 36 (reescrito: shim selectivo sobre `rev-parse --verify -q` del
  candidato, deja intactos `origin/main`/`show-toplevel`/`merge-base`) + caso 37 (nuevo:
  inmunidad al shim de `cat-file` del auditor — el mecanismo actual no llama a
  `cat-file`, así que ese shim no tiene efecto) + caso 38 (nuevo: control negativo — el
  mismo shim del auditor SÍ degrada el checker de ronda 9, `87ad680348f6`, a fallback
  verde falso, reproducido de propia mano).
- **MAYOR del veredicto de ronda 10, cerrado**: los comandos de verificación publicados
  para M1-M6 (`bash scripts/ci/selftest-date-bombs.sh 2>&1 | grep -E "..."`) devolvían el
  exit code de `grep`, no el del selftest — en una tubería, `$?` es del ÚLTIMO comando.
  Falsamente verde para un tercero que solo mirara el número. Las mutaciones ya eran
  aisladas y los hashes ya coincidían; el comando que las acreditaba no. Corregido en los
  seis mutantes (ronda7.md, ronda8.md, ronda9.md): `SELFTEST_EXIT` se lee del `bash`
  directamente, sin tubería, re-verificado de propia mano contra copias limpias de cada
  head histórico.
- **Selftest**: 37 → **38 casos**. Full-scan sin cambio (**2578**). Mutation-testing
  nuevo: [`scripts/ci/MUTATION-TESTING-RECEIPT-ronda10.md`](../../scripts/ci/MUTATION-TESTING-RECEIPT-ronda10.md)
  (M7, mecanismo completo — necesariamente más de un caso discrimina, declarado así).

**Ronda 9 de auditoría** (Bloqueante (a) reabierto por SEXTA vez, en el MISMO sitio del
fix de ronda 8 — el fix cerró (a) y (b) de ronda 8, pero (c) resultó ser un fix
incompleto, no un hermano nuevo):

- **`git cat-file -e ...^{commit}` devolviendo 128: mismo código para "objeto no existe"
  Y para errores fatales internos**: el fix de ronda 8 (aceptar `rc∈{1,128}` como "SHA
  inválido") asumía que 128 significaba inequívocamente "no existe" — pero medido por el
  auditor con git real, el mismo código cubre causas opuestas:
  `GIT_CAT_FILE_NOT_A_REPO_EXIT=128` y `GIT_CAT_FILE_INVALID_OBJECT_EXIT=128`. Cambiando
  el fallo selectivo de ronda 8 (`return 70`, un valor que git real nunca produce) a
  `return 128` (el valor real y ambiguo), el checker de ronda 8 volvía a degradar a
  fallback silencioso: `SELECTIVE_GIT_CAT_FILE_FATAL_128_EXIT=0`, diff vacío, verde falso.
  No hay forma de leer el rc de esa llamada y saber cuál de las dos causas es. **Fix**: la
  misma disciplina de canario funcional que ya protege el arranque del script se aplica
  en el propio punto de uso — `cat-file -e "HEAD^{commit}"` (un objeto que se SABE
  válido) se prueba ANTES de leer cualquier resultado sobre el candidato; si el canario
  también falla, `cat-file` mismo está roto y el checker muere con precondición sin leer
  ninguna lectura de su salida. Solo si el canario demuestra, en esa misma ejecución, que
  `cat-file` distingue válido de inválido, se confía en un rc no-cero sobre el candidato
  como "BASE_SHA inválido" legítimo. Caso 36 (reescrito para ejercitar 128 en vez de 70),
  más caso 37 (mismo shim contra el checker del padre `3ef8e07f6`, confirma que el
  mutante reproduce un bug real).
- **MAYOR del veredicto de ronda 9, verificado (no heredado)**: el veredicto no declaró
  cerrada la reproducibilidad de los receipts anteriores, así que este canal re-ejecutó
  de propia mano, contra una copia limpia extraída del head auditado, las 5 mutaciones ya
  publicadas (M1-M3 de ronda 7, M4-M5 de ronda 8): las 5 aplican limpio, cada hash de
  mutante coincide exactamente con el citado, y cada una pone rojo EXACTAMENTE su caso
  discriminante sin tocar ningún otro. Confirmado por verificación propia, no por
  confianza en el sellado anterior.
- **Selftest**: 36 → **37 casos**. Full-scan sin cambio (**2578**). Mutation-testing
  nuevo: [`scripts/ci/MUTATION-TESTING-RECEIPT-ronda9.md`](../../scripts/ci/MUTATION-TESTING-RECEIPT-ronda9.md)
  (M6, más la re-verificación de M1-M5).

**Ronda 8 de auditoría** (Bloqueante (a) reabierto por QUINTA vez, en DOS sitios más, fuera
del barrido habitual de `grep`/`awk`/`tail`/`sed` sobre `DATE_RE` porque ninguno de los dos
corre sobre el patrón de fecha — encontrados por el auditor tras que este canal cerrara "el
hermano conocido" y entregara sin repetir la tercera pregunta de control sobre el resto del
fichero):

- **`git rev-parse --show-toplevel` / `cd "$ROOT"` sin comprobar su estado**: un `git` que
  supera el canario del inicio pero falla EN ESTE uso productivo — ejecutado desde un
  subdirectorio — deja el checker posicionado en el directorio equivocado; los pathspecs de
  `WATCHED_PATHS` (relativos a la raíz del repo) dan diff vacío y un fixture infractor real
  PASA. Medido: `SELECTIVE_GIT_SHOW_TOPLEVEL_FAILURE_EXIT=0`. Fix: comprobar `$?` de
  `rev-parse --show-toplevel` y del propio `cd`, fallando cerrado (`_dep_fail`) ante
  cualquiera de los dos. Caso 35.
- **`git cat-file` degradado a fallback silencioso ante CUALQUIER fallo**: `resolve_base_sha()`
  trataba CUALQUIER código de salida no-cero de `git cat-file -e ...^{commit}` (no solo
  "objeto no existe") como "BASE_SHA inválido", cayendo al fallback de `origin/main` — con
  `origin/main` apuntando al propio HEAD infractor, el fallback calcula `base=HEAD`, diff
  vacío, verde falso. Medido: `SELECTIVE_GIT_CAT_FILE_FAILURE_EXIT=0`. Fix: distinguir
  `rc=1`/`128` ("objeto no existe o SHA sintácticamente inválido" — verificado empíricamente
  en este entorno que `cat-file -e ...^{commit}` devuelve 128, no 1, para un SHA inexistente;
  se acepta también 1 por si otra versión de git difiere) de cualquier otro código (la
  herramienta reventando), que ahora falla cerrado. Caso 36.
- **Barrido de cierre repetido con el comando exacto del auditor** (`git show <head>:... |
  nl -ba | rg '\b(git|awk|grep|tail|sed|jq|perl|python|sort|cut|tr|wc|head|find|xargs)\b'`):
  confirmado que `git rev-parse --verify -q origin/main` y `git merge-base` YA fallaban
  cerrado ante cualquier código no-cero desde su diseño original (no hay rama "legítima vs
  rota" que distinguir ahí) — no necesitan fix nuevo, declarado explícitamente en el receipt
  en vez de dejarlo implícito.
- **MAYOR del veredicto de ronda 7, cerrado en esta ronda**: el receipt de mutation-testing
  de ronda 7 no era reproducible (solo salida pegada, sin comandos/parches/hashes) y
  presentaba una mutación combinada (re-extracción + membresía a la vez) como parte de "3
  mutaciones aisladas". Reescrito completo con parche unificado + hash del mutante + comando
  exacto por mecanismo, 3 mutaciones GENUINAMENTE aisladas (una por check, verificado que
  solo su caso correspondiente se pone rojo).
- **Selftest**: 34 → **36 casos**. Full-scan sin cambio (**2578**). Mutation-testing con
  receipt guardado, ambos reescritos/nuevos con parches reproducibles:
  [`scripts/ci/MUTATION-TESTING-RECEIPT-ronda7.md`](../../scripts/ci/MUTATION-TESTING-RECEIPT-ronda7.md)
  (reescrito) y
  [`scripts/ci/MUTATION-TESTING-RECEIPT-ronda8.md`](../../scripts/ci/MUTATION-TESTING-RECEIPT-ronda8.md)
  (nuevo).

**Ronda 7 de auditoría** (Bloqueante (a) reabierto por CUARTA vez, en un QUINTO sitio, más
tres hermanos encontrados en el barrido propio del canal — regla de fábrica sellada por el
CEO tras esta ronda, `CEO-REGLA-DESCRIPCION-A-LA-BAJA` aplicada aquí a un caso distinto,
"tercera pregunta de control": no basta con medir el fix pedido, hay que preguntar "¿es
esto TODO lo que hay, o solo lo primero que encontré?"):

- **Quinto sitio sin control de estado — el que reportó el auditor** (`scripts/ci/check-
  date-bombs.sh`, rama JSON de la excepción expression-scoped): el `grep -oiE "$DATE_RE"`
  que re-extrae los valores de fecha para comprobar la excepción corría dentro de una
  **process substitution** (`while … done < <(comando)`) cuyo código de salida NUNCA se
  comprobaba — a diferencia del `grep -oiE` gemelo de `match_count` (ya comprobado desde
  ronda 6), ESTE era un segundo uso productivo idéntico del mismo patrón, distinto en que
  su salida alimenta un `while read` vía `< <(...)` en vez de una sustitución de comandos
  capturada. Si ese grep superaba el canario Y la comprobación de `match_count`, pero
  fallaba AQUÍ, la process substitution no producía líneas, el bucle se ejecutaba CERO
  veces, `all_listed` se quedaba en el `1` con el que se inicializó, y el infractor quedaba
  EXIMIDO sin haber comprobado nada — verdad vacua. Medido por el auditor:
  `SIBLING_PROCESS_SUBSTITUTION_GREP_FAILURE_EXIT=0`. **Fix**: la salida se captura en
  variable (deja de ser process substitution) y su código de salida se comprueba ANTES del
  bucle — esta línea YA se confirmó con ≥1 match en `match_count`, así que un re-extraído
  vacío es SIEMPRE anómalo. Caso 32, con fixture rediseñado para que el diff añada
  EXACTAMENTE una línea (la coma de la clave previa ya vive en el commit base) — con dos
  líneas añadidas, la primera consume una de las dos invocaciones "gratis" del contador del
  shim de prueba y el checker moriría por el chequeo de `match_count` (ya cerrado en ronda
  6) sobre la SEGUNDA línea en vez de por el sitio bajo prueba — el mismo defecto de diseño
  de test que ya había aparecido con el shim de `tail`/`sed` de la ronda 6 (medir el objeto
  equivocado), encontrado y corregido ANTES de esta entrega.
- **Barrido propio del canal — tres hermanos más, mismo patrón, mismo tratamiento**: los
  dos `grep -qF` de membresía contra el sidecar (rama JSON) y de detección del marcador
  `date-bomb-ok:` (rama no-JSON) colapsaban "no encontrado" (rc=1, legítimo) y "grep
  revienta" (cualquier otro rc) en el mismo `||` — un fallo real aquí no exime
  incorrectamente (falla hacia lo ESTRICTO: reporta un hallazgo falso sobre un valor
  legítimamente eximido, en vez de silenciarlo), pero sigue ocultando que la herramienta se
  rompió. Casos 33 (rama JSON) y 34 (rama no-JSON), cada uno mutation-testeado de forma
  AISLADA (revertir SOLO ese chequeo, sin tocar los demás, confirma que el caso
  correspondiente y solo ese se pone rojo). Además, la misma disciplina se extendió a la
  cadena de 3 comandos de `--full-scan` (`git grep | grep -v | grep -v`, antes con
  `|| true` absorbiendo CUALQUIER fallo para permitir el "0 hallazgos" legítimo) — desglosada
  en pasos verificables, sin caso de selftest dedicado (full-scan es informativo, nunca
  cableado a un gate, y `git grep` no es shimmable vía PATH como `grep`/`awk`/`tail`/`sed`:
  invoca su propio motor de regex interno, no el binario externo — construir un shim
  fiable habría exigido interceptar el subcomando `grep` de `git` sin romper `git diff`/
  `rev-parse`/`merge-base`, usados en el resto del script, con más riesgo de introducir
  otro bug de test bajo presión de tiempo que beneficio de cobertura sobre un modo que
  nunca gatea un merge).
- **Selftest**: 31 → **34 casos**. Full-scan sin cambio (**2578**). Mutation-testing con
  receipt guardado:
  [`scripts/ci/MUTATION-TESTING-RECEIPT-ronda7.md`](../../scripts/ci/MUTATION-TESTING-RECEIPT-ronda7.md).

**Ronda 6 de auditoría** (Bloqueante (a) reabierto por segunda vez + coherencia de
alcance — ambos, en palabras del auditor: "no basta con que la herramienta arranque al
principio, tiene que fallar CERRADO cuando falla en el punto donde se usa de verdad"):

- **El canario del inicio prueba que la herramienta ARRANCA, no que funcione en CADA uso
  productivo posterior** (Bloqueante (a), tercera vez que se reabre este hallazgo — ver
  rondas 4 y 5 arriba): un `awk`/`grep` que SUPERA el canario trivial pero falla en el
  programa/flags REALES usados más adelante (`awk` con `BEGIN{...}`; `grep` con
  `-qiE`/`-oiE`/`-oE`) seguía dando `EXIT=0` sobre un fixture infractor —medido por el
  auditor: `SELECTIVE_awk_FAILURE_EXIT=0`, `SELECTIVE_grep_FAILURE_EXIT=0`. Además, la
  excepción JSON expression-scoped (arriba) introdujo `tail`/`sed` SIN sumarlos a las
  dependencias comprobadas — medido: `MISSING_tail_JSON_EXPRESSION_EXIT=0`,
  `MISSING_sed_JSON_EXPRESSION_EXIT=0`. **Fix, en dos capas**: (1) `tail`/`sed` entran al
  canario funcional del inicio (mismo mecanismo que `awk`/`grep` desde ronda 5) — cierra
  la ausencia; (2) los TRES usos productivos (paso 1 awk de parseo del diff; grep de
  match/conteo del bucle principal; grep/tail/sed de extracción de clave JSON) ahora
  comprueban el código de salida de ESE uso concreto, no solo el del canario, y
  distinguen "no matchea" (`grep -q` rc=1, legítimo) de "la herramienta reventó"
  (cualquier otro código) para no colapsar ambos casos en un mismo `continue`. Casos
  NUEVOS 26/27 (tail/sed ausentes, vía el canario) y 28/29/30/31 (tail/sed/awk/grep
  RESUELVEN y pasan el canario trivial pero fallan en el uso real — shims que discriminan
  por CONTENIDO/flags del programa real frente al canario, no solo "romper todo").
  Regla operativa sellada por el CEO tras esta ronda: **toda herramienta que entra en el
  camino entra en la lista de dependencias comprobadas EL MISMO COMMIT en que se
  introduce.** Mutation-testing con receipt guardado:
  [`scripts/ci/MUTATION-TESTING-RECEIPT-ronda6.md`](../../scripts/ci/MUTATION-TESTING-RECEIPT-ronda6.md).
- **Coherencia de alcance — contrato > ejecución, MAYOR/BLOQUEANTE por regla de fábrica**
  (bus `CEO-REGLA-DESCRIPCION-A-LA-BAJA`: la descripción de una protección se alinea A LA
  BAJA con lo que de verdad ejercita, nunca al revés): este runbook ya declaraba
  correctamente el alcance LÉXICO (párrafo de arriba, re-declarado en ronda 5), pero el
  PROPIO `scripts/ci/check-date-bombs.sh` seguía afirmando detección SEMÁNTICA en su
  cabecera y en el mensaje de hallazgo ("fecha absoluta sin anclar a
  `now()`/`current_date`") — dos contratos distintos para el mismo comportamiento, y
  quien lee la salida del checker (no este runbook) se cree el semántico. Corregido: la
  cabecera del script y el mensaje de hallazgo ahora dicen explícitamente LÉXICO/TOKEN,
  sin mención de anclaje real a `now()`.

**Ronda 5 de auditoría** (2 bloqueantes reabiertos + 3 ampliaciones — mutation-testing
manual ejecutado con la misma metodología documentada en el receipt de ronda 6 de arriba;
sin receipt propio guardado en el repo para esta ronda específica en su momento —
reabierto precisamente por eso en ronda 6 ("afirma mutation-testing sin log ni receipt").
Cada caso discriminante (21/22/18/19/19b/23/24/25) fue ADEMÁS reproducido de forma
independiente por el auditor externo contra el checker padre antes de dar el GO — ver
veredicto citado en el hilo de #2147, sección "Control de las aserciones nuevas"):

- **Dependencias que RESUELVEN pero FALLAN al ejecutar** (Bloqueante 1 reabierto):
  `command -v` solo confirma presencia en PATH, no ejecución correcta — con awk/grep
  resolviendo pero devolviendo error, un fixture infractor real seguía dando `EXIT=0`.
  Corregido con un canario funcional (entrada conocida, salida EXACTA esperada) para
  `awk`/`grep`, más `git --version`. Casos 21/22 simulan el binario RESOLVIBLE pero roto
  (no ausente — eso ya lo cubrían los casos 16/17 de la ronda 4).
- **Excepción JSON atada al literal, no a la expresión** (Bloqueante 2 reabierto): ver
  arriba — casos 19 (clave nueva) y 19b (mismo literal, clave nueva — la evasión exacta
  reproducida por el auditor).
- **Argumentos desconocidos caían en silencio al modo normal** (Mayor 3): cualquier
  argumento distinto de `--full-scan` (o más de un argumento) ahora falla con `exit 2` y
  mensaje explícito — antes `--definitely-not-valid` corría el gate en modo normal como si
  no se hubiera pasado nada. Caso 23.
- **`tests/fixtures/**` fuera del inventario** (Mayor 2): directorio real, distinto de
  `tests/eval/fixtures`, con contenido real — una fecha nueva ahí daba diff vacío y
  `EXIT=0`. Añadido a `WATCHED_PATHS`. Caso 24.
- **Formatos declarados pero no detectados** (Mayor 1, ver arriba la re-declaración del
  alcance): `MAKE_DATE(` mayúsculas, `Date.UTC (` con espacio, `2026/01/01` con `/` —
  extensión barata del regex (case-insensitive + espacio opcional + alternativa slash) sin
  cambiar el diseño. Caso 25.

Ronda 4 (fixes previos, siguen vigentes): fail-closed sin dependencias (casos 16/17,
ausencia total), exención value-scoped como base de la expression-scoped de ronda 5, y los
fixes F1 (caso 15, temporal con nombre fijo fuera de `$WORKDIR` — flake en flota, corregido)
y F2 (caso 20, glob `seed*.sql`) de la ronda de CR-CLI de la estación de merge.

Falsos negativos aceptados por restricción de presupuesto (bash+grep, sin dependencias
nuevas — la propia issue lo exige): fechas partidas entre variables, concatenación de
strings, epochs numéricos crudos, JSON construido por partes, e interval sobre un ancla fija
declarada en otra línea. También (encontrado en autoauditoría de ronda 5, no reproducible
contra ningún fixture real del repo — todos pretty-printed, una clave por línea, verificado):
la extracción de clave del sidecar JSON toma la ÚLTIMA `"clave":` de la línea añadida, no
necesariamente la más cercana al valor de fecha — un JSON minificado con varias claves en
una sola línea, donde una clave NO-fecha aparece DESPUÉS de la que sí gobierna el valor,
atribuiría el valor a la clave equivocada (fail-closed: el efecto es un falso FAIL, no una
exención indebida). Justificación completa de cada uno en el HANDOFF de TAL-5139.
`BASE_SHA` se recibe de entorno; si no llega, cae a `git merge-base origin/main HEAD` y lo
declara EXPLÍCITAMENTE como `FALLBACK LOCAL` en el output — nunca se presenta como
equivalente al `base_sha` sellado en el receipt del motor. **Nota para el wiring**: el motor
(`talent-factory/scripts/run-local-gates.sh`) invoca cada `TF_GATE_CMD_*` vía
`bash -c "$GATE_CMD"` y hoy NO exporta `BASE_SHA` a ese subprocess (verificado: sin ningún
`export` en el archivo) — quien cablee este gate debe resolver ese contrato (exportar
`BASE_SHA` en el motor, o interpolarlo en el propio `TF_GATE_CMD_date_bomb`) para que el
checker reciba el `base_sha` real del run en vez de caer siempre al fallback local.

**Cablearlo al manifiesto real del motor** (`TF_GATE_IDS`/`TF_GATE_CMD_date_bomb` en
`talent-factory/manifiestos/academy.conf`, fuera de este repo) **NO es responsabilidad de
este repo ni queda como follow-up huérfano de TAL-5139** — es un paso posterior que ejecuta
el CEO directamente, post-merge (adjudicación 2026-09-02 22:20 CDMX), con conocimiento pleno
del punto de `BASE_SHA` de arriba. Hasta entonces, correrlo es responsabilidad manual del
autor del PR (`npm run date-bomb:check` antes de push). Barrido inicial informativo sobre
`main` (`bash scripts/ci/check-date-bombs.sh --full-scan`, modo de solo-lectura NUNCA
cableado a ningún gate): ~2578 líneas existentes matchean el patrón crudo (mayoría datos mock
de test sin relación con vigencia real — el modo full-scan no distingue semántica, a
propósito, mismo diseño que el modo gate); desglose por directorio y consideración de
seguimiento en el HANDOFF de TAL-5139. No se corrige aquí — issue de triage aparte.

**Nota de sintaxis de pathspec** (verificado empíricamente, ronda 3 de auditoría): un
pathspec con `*` SIN el prefijo `:(glob)` es LITERAL en `git diff`/`git grep`, no un glob —
`.claude/skills/*/tests` no matchea nada; hace falta `:(glob).claude/skills/**/tests/**`. Un
pathspec-glob así tampoco es una ruta real de filesystem, así que un `[ -e "$p" ]` sobre él
es siempre falso — el checker lo trata como caso especial para no filtrarlo por error.

## Arquitectura: runner / estación / receipts / agregación

Límite de confianza base/head: **quien ejecuta código del PR no tiene credenciales; quien
tiene credenciales solo valida datos** (receipts) y jamás ejecuta código de head_sha.

```text
ESTACIÓN del Mergeador (con credenciales: token gh, SUPABASE_ACCESS_TOKEN)
  1. genera run_group IMPREDECIBLE
  2. asigna gates/shards del inventario (manifiesto + registro) a runners libres
  3. recoge y SELLA cada receipt (almacenamiento no modificable por el runner)
  4. post-local-gates.sh <run_group> <owner/repo> <pr>
       agrega por (repo, pr, head_sha, base_sha, manifest_digest, run_group)
       relee headRefOid/headRefName/base al final → cambio = run INVÁLIDO
       → POST commit-status `local-gates` (o `local-gates-test` en rollout)
          │
          │  incus file push (script + manifiesto)
          ▼
RUNNERS (perfil minimal SIN credenciales — ejemplo: runner-01..04 en host-ejemplo)
  bash /tmp/run-local-gates.sh <repo> --sha X --run-group G --gate <gate-id>
    → worktree DESECHABLE + checkout interno + assert HEAD == --sha
    → ejecuta UN gate (los wrappers scripts/ci/run-*-local.sh son dueños
      de su stack Supabase efímero: lo crean, resetean y destruyen)
    → escribe UN receipt parcial JSON
```

- **Receipt parcial** (contrato cerrado): identidad de corrida (`schema_version`,
  `repo`, `pr`, `sha`, `base_sha`, `manifest_digest`, `base_registry_digest`,
  `head_registry_digest`, `run_group`, `run_id`, timestamps) + **exactamente UN
  `gate_id`** + `PASS|FAIL|SKIP` con razón verificable. Cero o más de un gate → rechazo.
  El conjunto esperado NO vive en el receipt.
- **El agregador es el único dueño del conjunto esperado** (manifiesto + registro de
  shards leído en runtime). Gate sin receipt, duplicado o con clave distinta → NO se
  postea (fail-closed).
- **Anti-reducción del registro**: el registro de shards de **base_sha es el mínimo
  confiable**; una reducción en head (de shards **o de specs dentro de un shard**) FALLA con
  diagnóstico y exige **ratificación durable** en `scripts/ci/REGISTRY-RATIFICACIONES.log`:
  entrada nueva con **formato cerrado** `… | ref=<aprobación> | items=<fam:s1,fam:s2:spec> | …`
  donde cada item retirado aparece como **token exacto** (`fam:s1` no queda cubierto por
  `fam:s10`). El log es **append-only y se verifica en TODO PR** (toque o no el registro), así
  que no se puede purgar el historial de aprobaciones en un PR y reducir en el siguiente. Las
  adiciones de head se incorporan al conjunto.
- **`base_tip_sha` viaja sellado** desde la asignación hasta el receipt: el gate se corrió
  sobre ESE estado de la rama base. Si `main` avanza, los receipts quedan invalidados aunque
  el merge-base no se mueva.

### Caducidad por insumo, dos ejes (TAL-5462/TAL-6674/TAL-6692)

Un receipt puede quedar potencialmente afectado por dos cosas distintas — el agregador las
trata por separado, con el MISMO mapa de datos (`talent-factory/scripts/lib/insumos-por-gate.conf`,
fuente única, fuera del manifiesto: no invalida suites en vuelo ni cambia `motor_sha256`):

| Eje | Qué compara | Mecanismo | Issue |
| -- | -- | -- | -- |
| **Avance de `main`** | `base_tip_sha` sellado del receipt vs el tip ACTUAL de `main` | `bt_prepara()`/`gate_afectado()`: si `base_tip` es ancestro del tip actual, el avance se valida GATE A GATE contra sus insumos declarados — solo re-corren los gates cuyo insumo tocó ese avance | TAL-5462 (mapa de insumos + exclusiones), TAL-6674 (identidad de blob vía `merge-tree`, no ancestría) |
| **Cambio de head** | `receipt.sha` vs el `HEAD_SHA` actual del PR | `hc_gate_elegible()`/`hc_prepara()`: si el gate es ELEGIBLE y el delta `receipt.sha..HEAD_SHA` (`git diff --name-only`, mismo PR, sin semántica de fusión) no toca ningún insumo del gate, el receipt se RE-ANCLA al head nuevo | TAL-6692 |

El default en AMBOS ejes sigue siendo el rechazo — la conservación es la excepción demostrada,
nunca el comportamiento por omisión. Un gate sin entrada en el mapa, un digest/diff no
computable, o cualquier duda: rechazo, re-correr.

**Tabla de clases medida para el eje «cambio de head»** (qué rutas son insumo REAL de cada uno
de los 27 gates pesados — 25 shards e2e + `integration` + `db-guards` —, derivada por grep de lo
que cada runner EJECUTA/LEE, no por intuición):

| Gate(s) | `.claude/skills/**` | `scripts/**` (ex `scripts/ci/**`) | `*.md` raíz / `docs/**` / `.github/**` | Elegible para re-anclaje |
| -- | -- | -- | -- | -- |
| 25 shards `e2e-*` | inerte (0 refs en `run-e2e-shard-local.sh`) | inerte — solo referencia `scripts/ci/**` | inerte | **sí** |
| `integration` | inerte (0 refs en `run-integration-local.sh`) | inerte — solo referencia `scripts/ci/**` | inerte | **sí** |
| `db-guards` | inerte | **NO inerte** — `run-db-guards-local.sh` ejecuta `scripts/sql/**` (≥18 scripts) + `scripts/lib/test-check-ai-attribution.sh` + `scripts/check-security-definer-searchpath.sh`, ninguno declarado hoy en `TF_INPUTS_db_guards` | inerte | **no** (ver gap abajo) |

**Gap conocido, preexistente, fuera de alcance de TAL-6692**: `TF_INPUTS_db_guards` no declara
`scripts/sql/**` ni `scripts/check-security-definer-searchpath.sh`, que su runner sí ejecuta.
Esto afecta también al eje de avance de `main` YA FUSIONADO (TAL-5462): un avance de `main`
limitado a esos ficheros se trataría hoy como que no afecta a `db-guards`, y su receipt se
conservaría — posible falso verde en producción. Issue de deuda de seguimiento abierta por el
coordinador de fábrica; no se resuelve en TAL-6692 (ampliar el insumo de `db-guards` sin medir
el impacto real habría sido scope creep sobre una pieza ya acotada).

## Invocación canónica

```bash
# Desde la ESTACIÓN, por gate — operación ATÓMICA del launcher sellado: asignación (digests
# del clon limpio) → incus file push → incus exec SÍNCRONO (rc observado por la estación) →
# incus file pull del receipt → sellado en journal.jsonl. Sin pasos manuales.
bash talent-factory/scripts/run-gate-sealed.sh <gate-id> \
  --runner <contenedor> --runner-user <usuario> --runner-repo <ruta-repo-en-runner> \
  --repo <clon-limpio> \
  --run-group <G> --sha <head_sha> --pr <n> \
  --manifest talent-factory/manifiestos/academy.conf --receipts <dir> \
  --repo-slug <owner/repo> 

# En la ESTACIÓN (agrega receipts SELLADOS + revalida head/base/branch + postea):
bash talent-factory/scripts/post-local-gates.sh <run_group> <owner/repo> <pr> \
  --receipts <dir> --manifest <conf> --repo <clon-limpio>
#   [--context local-gates|local-gates-test]   (únicos valores aceptados)
```

**Runners remotos (`--runner host/contenedor`)**: `--runner` acepta tanto un contenedor
local (`<contenedor>`) como la forma remota **`host/contenedor`** (TAL-2753) — el launcher
resuelve el salto a la máquina remota antes de entrar al contenedor. `--runner-user` es
obligatorio en runners remotos: el usuario de gates dentro de ese contenedor (p. ej.
`vivecoder` en los contenedores `ta-*`, cuyo clon vive en `/home/vivecoder/repo`, distinto
de `/home/vivecoder/Producto-2.0` en el host). Ejemplos:

```bash
# Runner local, usuario por defecto
--runner vibe-channel-85 --runner-user runner --runner-repo /home/runner/repo

# Runner remoto en un contenedor ta-*, usuario vivecoder, ruta de repo del contenedor
--runner black-omega/ta-03 --runner-user vivecoder --runner-repo /home/vivecoder/repo
```

Exit codes del motor: `0` gate verde · `1` gate rojo · `2` precondición (repo/manifiesto/
gate-id inválido). El motor NO postea nada (no tiene credenciales): el posteo es
exclusivo de `post-local-gates.sh` desde la estación, que **solo agrega receipts con
procedencia sellada**: respaldados por `journal.jsonl` (sha256 del receipt + sha256 de la
asignación real + exit observado + `isolation: container:<runner>`, escrito SOLO por la
estación vía `run-gate-sealed.sh`) y `result` coherente con el exit observado. **El código
del PR se ejecuta EXCLUSIVAMENTE dentro del contenedor runner**: un receipt `inline` (motor
a mano) o `station-local` (`--unsafe-local`, subprocess de la estación) es diagnóstico y la
agregación lo RECHAZA — quien tiene credenciales jamás ejecuta código de head_sha.
`TF_ENV_COPY` está PROHIBIDO en modo sealed (canal de exfiltración) y los wrappers
convierten un teardown de Supabase fallido en ROJO. La anti-reducción del registro opera a
dos niveles (shards y specs dentro de cada shard), y `motor-go.sh` aplica anti-reducción
semántica a los manifiestos (gates/familias eliminados, `TF_DB_GATE` debilitado, claves de
enforcement modificadas —`TF_GATE_CMD_*`, `TF_E2E_WRAPPER`, `TF_INSTALL`,
`TF_BRANCH_VALIDATOR`, `TF_SHARDS_REGISTRY`— o manifiesto borrado ⇒ rojo salvo
**ratificación durable** en `manifiestos/RATIFICACIONES.log`, append-only y en el mismo
commit, con `ref=` de la aprobación; ese log se verifica append-only en **todo** push, no
solo cuando hay reducción). Los manifiestos se parsean con **gramática cerrada** (datos, sin
`source`), solo desde el directorio confiable del motor y **nunca por symlink**.

## Perfil runner + cómo llega el motor

Perfil RUNNER minimal (decisión del lead 2026-07-09): contenedores Incus **dedicados**
clonados (hoy `vibe-channel-85..88`), local-only sin Tailscale, identidad regenerada,
**SIN credenciales de ningún tipo** (ni agentes, ni CodeRabbit, ni token `gh`, ni tokens
Linear/Supabase) — solo repo + node + docker + supabase CLI local. Dimensionado:
`runners ≈ profundidad de cola / duración del run (~30 min)`.

Esto se **verifica, no se declara**: el usuario de gates necesita `docker` (stacks
efímeros) y por tanto es root-equivalente DENTRO del contenedor — el límite de aislamiento
es el **contenedor entero**. El preflight del launcher es fail-closed y barre TODOS los
homes (`/root`, `/home/*`) buscando `~/.config/gh`, `~/.codex/auth.json`,
`~/.claude/.credentials.json`, `.netrc`, `.git-credentials`, exige cero `credential.helper`
(usuario/repo/sistema), clon y worktrees sin `.env.local`, y que el usuario de gates **no
esté en `sudo` ni en sudoers**. Los `vibe-channel-85..88` clonados del golden NO cumplen
hoy (traen credenciales de `vivecoder`): sanearlos o re-provisionarlos es requisito del
rollout.

**Saneo tras cambio de cuenta del agente de desarrollo**: un cambio de cuenta en un canal
propaga sus credenciales operativas a los runners sellados si el push de credencial no los
excluye explícitamente — el preflight fail-closed de arriba detecta esas credenciales y
marca el runner SUCIO (rc=2) en TODOS los runners a la vez, no solo en el que originó el
cambio. La exclusión NO se hace por patrón de nombre (un filtro como excluir por rango
numérico o por substring del hostname no cubre naming schemes nuevos, como los runners
remotos `ta-*`/`atlas-*` de más abajo, y deja un hueco real de fuga de credenciales). La
exclusión canónica es la **ground-truth DECLARADA por canal**: el perfil de cada canal
(`produccion` | `mergeador` | `runner`) vive en el mapa de escrow
`$SECRET_DIR/channel-profiles.list` (`canal=perfil`), con overrides por
`TC_RUNNER_CHANNELS`; un canal SIN declarar o con perfiles en conflicto entre fuentes falla
fail-closed — nunca se asume `runner` ni se asume `limpio` por defecto (ver skill
`talent-channels`, `references/05-credenciales-por-carril.md`). Tras **CADA** cambio de
cuenta: sanear los runners afectados según su perfil declarado y re-correr el preflight
antes de asignarles trabajo nuevo — un runner que no re-preflightó tras un cambio de cuenta
se trata como sucio por defecto, no como limpio hasta que se demuestre lo contrario.

### Runners remotos por estación

Los runners no viven todos en la misma máquina física. El transporte hacia un runner remoto
es `ssh root@<host>` para llegar a la máquina y `incus exec <contenedor> -- ...` para entrar
al contenedor concreto — la forma `--runner host/contenedor` de la invocación canónica
(arriba) hace ambos saltos por sí sola, sin pasos manuales.

| Estación | Pool de runners |
|---|---|
| M1 / M2 | En el host |
| M3 | black-omega |
| M4 | Pendiente de reubicar |
| M5 | black-alpha |

**Ley de flota**: únicamente el host + Alpha (`alpha.tailnet.example`) + Delta (`delta.tailnet.example`) +
Omega (`omega.tailnet.example`) participan como runners. `host-01/02` y `host-dedicado` están
PROHIBIDOS — `host-dedicado` es infraestructura dedicada de otro programa, fuera del pool de
gates.

**Concurrencia**: 1 suite completa por MÁQUINA FÍSICA a la vez; hasta 2 suites en paralelo
por estación; serializar ENTRE flotas (no lanzar la misma suite pesada en dos estaciones
distintas sobre la misma máquina física a la vez).

**Los canales de producción NO son runners**: sus árboles llevan trabajo congelado y
`.env.local` token-por-canal; un `git clean`/checkout de gates los destruiría. Gates solo
en runners dedicados, y siempre sobre worktree/clon desechable.

El runner no ve el path del motor en el host (y el host no tiene la toolchain completa).
**No hay pasos manuales**: `run-gate-sealed.sh` (invocación canónica arriba) hace el
preflight, empuja motor+manifiesto+asignación con `--uid/--gid` del usuario de gates,
transfiere el commit por bundle, ejecuta `incus exec` observando el rc y recoge/sella el
receipt. Un `run-local-gates.sh` invocado a mano produce evidencia que el agregador rechaza.

## Wrappers de producto (`scripts/ci/run-*-local.sh`)

Extraídos 1:1 de los jobs de `pr-gate.yml` (misma lista, mismo orden, mismos env). Cada
wrapper DB/E2E/integration es **dueño de su stack Supabase efímero** (lo crea, resetea y
destruye); el motor solo asigna runner y `flock`.

| Wrapper | Cubre |
|---|---|
| `scripts/ci/run-db-guards-local.sh` | Supabase efímero + advisors gate (`scripts/ci/run-advisors-gate.sh`, ratchet vs `supabase/advisors/baseline.txt`, catálogo pristino ANTES de pgTAP) + la lista exacta de SQL/pgTAP/search-path/tests contables del job `db-guards` |
| `scripts/ci/run-e2e-shard-local.sh <familia> <shard>` | Un shard de `e2e-ola3` o `e2e-pagos`: stack Supabase efímero propio + app buildeada + `E2E_SHARD=<shard>` con el env/mocks del workflow |
| `scripts/ci/run-integration-local.sh` | Supabase efímero propio + `npm run test:integration` con el env del job |

## Caché verificado opt-in (TAL-2728 · ADR-0063)

Los wrappers pueden reutilizar el artefacto `.next` y el estado post-reset de Supabase
entre shards, SIN erosionar el modelo sellado. Es **opt-in y default OFF**: el mecanismo
solo actúa si el runner setea `TA_GATES_CACHE_DIR`. Lib compartida: `scripts/ci/lib/gate-cache.sh`.

| Variable | Efecto |
|---|---|
| `TA_GATES_CACHE_DIR` | Directorio escribible del store de caché. **Sin ella (default) ⇒ caché OFF ⇒ reset+build from-scratch idéntico a hoy (regresión cero).** |
| `TA_GATES_CACHE_DISABLE` | Kill-switch: si está seteada (a cualquier valor), fuerza caché OFF aunque `TA_GATES_CACHE_DIR` esté puesta. |

**Contrato de integridad (por qué es seguro):** dos artefactos —`.next` y el estado
post-reset de Supabase— se reutilizan SOLO ante coincidencia de un digest de contenido
completo (la "clave"). Cualquier miss/duda/corrupción cae al camino caro-correcto de hoy
(reset+build from-scratch): **fail-toward-correct**. El caché guarda solo artefactos
derivados del propio head + migraciones/seed públicas + datos del stack local (demo, sin
secrets) → no es canal de exfiltración; el runner sigue sin credenciales.

- **Build (`.next`):** en el camino de caché, `npm run build` corre bajo entorno CERRADO
  (`env -i` + base inerte + SOLO la allowlist de app: `NEXT_PUBLIC_*` + `CI` + las vars
  no-públicas de `ta_build_env_allowlist_names()` — hoy solo `TA_COMMERCE_HOSTS`; es una
  función FUENTE-DE-VERDAD en la lib, no env-overridable a propósito). La clave modela la env efectiva
  COMPLETA por construcción — no por enumeración. `env -i` acota solo el subproceso del
  build; el paso e2e posterior conserva su env runtime. Con caché OFF NO se sanea (env
  heredada como hoy). El ratchet `scripts/ci/check-build-env-coverage.sh` obliga a
  clasificar CADA lectura scope-módulo de env no-pública nueva (→ allowlist o lista de
  inertes documentada), fail-closed.
- **Supabase:** la clave digiere migraciones, `seed.sql`, el bloque `[db]` de `config.toml`
  y la versión de la CLI. El snapshot SOLO existe porque un `db reset` real lo produjo
  (anti-false-green intacto). El **restore recrea la base `postgres` desde `template0` (vacía)
  ANTES de aplicar el dump** — así ningún objeto de un volumen stale sobrevive (`--clean` sobre
  el stack vivo NO basta: sólo dropea lo que está en el snapshot) — e **incluye privilegios**
  (sin `--no-privileges`) para que los GRANT/REVOKE/ACLs se restauren igual que en un reset
  from-scratch. Antes de habilitarlo en cualquier runner, el harness
  `scripts/ci/test-gate-cache-equivalence.sh` (requiere docker+supabase) debe probar
  `dump(reset from-scratch) == dump(restore snapshot)`, que un objeto stale NO sobrevive al
  restore, y que un cambio de GRANT/REVOKE rompe la equivalencia.

**Cómo un runner lo habilita:** exportar `TA_GATES_CACHE_DIR` a un directorio persistente
entre corridas (p.ej. montado en el contenedor sellado) antes de invocar los wrappers. El
cableado en el motor `talent-factory` es un follow-up fuera del repo del canal. Self-test
sin docker: `bash scripts/ci/test-gate-cache.sh`. Ratchet de env: `bash scripts/ci/check-build-env-coverage.sh`.

## Registro canónico de shards (`scripts/ci/e2e-shards.json`)

Fuente ÚNICA de la lista de shards E2E, consumida por `playwright.ci.config.ts`, el
wrapper y el agregador. El conjunto esperado se **obtiene SIEMPRE del registro en
runtime** — ninguna doctrina, manifiesto ni rollout fija cifras ni enumera shards.
Validación con schema: familias permitidas, IDs únicos, arrays no vacíos, ningún spec
duplicado entre shards. Reducciones vs base_sha → fallo + ratificación del lead (ver
Arquitectura).

## `TF_DB_GATE`

`TF_DB_GATE=always` para Academy **hasta ratificación explícita del lead**: el job
`db-guards` de Actions corría SIEMPRE y cubre también tests SQL/baselines/scripts de
seguridad que la detección por diff de migraciones no ve. El modo `auto` (correr solo si
el diff toca la superficie DB ampliada) queda implementado pero **INACTIVO**.

## Terminal-sola (fuera del sistema de canales) — paso a paso

El flujo clásico de una sesión individual también necesita `local-gates` (branch
protection no distingue actores). Reglas 10 y 12 de `CLAUDE.md`:

1. Rama → commits (igual que siempre).
2. Durante el desarrollo, correr los gates a mano lo que haga falta (`npm run typecheck`,
   `lint`, `build`, wrappers…) — eso es DIAGNÓSTICO tuyo, no evidencia.
3. Push (`audit-go`/sentinels del hook como siempre) + `gh pr create`.
4. **Generar la evidencia por la MISMA vía canónica que la estación** — el agregador solo
   acepta receipts sellados de contenedor, así que terminal-sola también pasa por un runner
   limpio (esto no es burocracia: el aggregate rechazará cualquier otra cosa):

   ```bash
   # run_group impredecible: fuente CSPRNG (date/$RANDOM son predecibles y colisionables).
   RG="rg-$(openssl rand -hex 16)" || { echo "openssl requerido para un run_group impredecible" >&2; exit 1; }
   for g in typecheck lint build unit i18n flags tenant node-parity edge-pins tests-manifest db-guards integration <shards…>; do
     bash talent-factory/scripts/run-gate-sealed.sh "$g" \
       --runner <runner-limpio> --runner-user <usuario> --runner-repo <ruta-repo-en-runner> \
       --repo <tu-clon> \
       --run-group "$RG" --sha <headSHA> --pr <n> \
       --manifest talent-factory/manifiestos/academy.conf --receipts /tmp/lg-$RG
   done
   bash talent-factory/scripts/post-local-gates.sh "$RG" <owner/repo> <pr> \
     --receipts /tmp/lg-$RG --manifest talent-factory/manifiestos/academy.conf --repo <tu-clon>
   ```

   El `gh api -X POST .../statuses/...` manual es SOLO break-glass trazado (ver abajo),
   nunca el camino normal.

   **`lockfile-sync` (TAL-5230) NO está en el enumerado de arriba a propósito:** el motor
   todavía no lo tiene registrado (bloqueado por TAL-5232, ver "Gate añadido: `lockfile-sync`"
   más arriba) — añadirlo hoy haría fallar `run-gate-sealed.sh` con `gate-id desconocido`.
   Añadirlo aquí es follow-up automático del aterrizaje de esa pieza del motor, no una tarea
   aparte.
5. Review según posture vigente (CodeRabbit) → `gh pr merge --squash` (branch protection
   deja mergear con `local-gates=success` @head).

**HANDOFF v3 — rollout gateado, no reloj de runner (TAL-5156, cierra TAL-2683; retoque TAL-5494)**:
el HANDOFF de entrega puede ir en `schema_version 3` (exige `audit_verdict` anclado al head,
bundle de las dos corridas plan-gate/code-gate) — pero `scripts/verify-handoff.sh` lo **rechaza
activamente** hasta que el rollout esté activo: la constante `VH_V3_ROLLOUT_DATE` del script
(literal versionado, NUNCA leído de env en producción) se compara contra el `createdAt`
SERVER-SIDE del comentario HANDOFF ganador, nunca el reloj del runner. Hoy ese literal sigue en
`9999-12-31` (no-op): usar `schema_version 2` mientras tanto. `TAL-5177` (procedimiento de
re-auditoría del Mergeador tras rebase) activa el rollout editando ese literal vía PR normal — un
solo cambio expira `1`/`2` y habilita `3` atómicamente en toda la flota. **`model_per_phase` NO
forma parte de este contrato** (TAL-5494: la regla absoluta 6 prohíbe publicar el ID de modelo por
fase en cualquier artefacto publicable, así que ese campo se retiró de la plantilla) — si aparece
en el bloque JSON del HANDOFF, en **cualquier** `schema_version` (1, 2 o 3), `verify-handoff.sh` lo
rechaza fail-closed, sin excepción de versión. Contrato completo en
`docs/templates/handoff-pr-draft.md`.

**Anti-self-report (regla dura)**: la evidencia sale del runner limpio sobre ESE head
exacto (el launcher lo garantiza: preflight + bundle + rc observado + journal). **Cada
push nuevo cambia el head → re-correr el run_group entero y re-postear.** Jamás a ciegas.

**Runtime de Node para `unit` local (paridad `engines`)**: `npm run test:unit` local exige
Node dentro del **rango** `engines` del repo (`package.json` → `>=24.0.0 <25.0.0`); fuera
de rango (p. ej. un major posterior en macOS) la suite `unit` puede dar **falsos fallos** que
NO reflejan `main` (evidencia: TAL-3306, 13 tests sobre `origin/main` limpio). Antes de
`npm run test:unit`, correr `nvm use` / `fnm use` (ambos respetan `.nvmrc`). **Desde TAL-5329**
el gate `node-parity` (TAL-2332) ya NO es puramente estático: su 5ª comprobación lee el Node
del PROCESO que corre el propio guard (3 estados — coincide/diverge/NO MEDIDO) y falla si
diverge de `.nvmrc`, lo que cubre el runner que ejecuta `node-parity` en sí. Sigue sin
re-verificar el runtime en cada gate POSTERIOR de la misma corrida (p. ej. si algo cambiara el
`PATH` entre `node-parity` y `unit` dentro del mismo `local-gates`) — por eso `nvm use` antes de
`test:unit` sigue siendo la práctica recomendada, no redundante. Los runners sellados de
`local-gates` corren Node 24.x.

**Concurrencia de `unit` en máquinas de flota débiles (TAL-4919)**: `npm run test:unit`
(= `vitest run`) usa por default una concurrencia = nº de CPUs. En canales que
sobre-suscriben (poca RAM/pocos núcleos frente al nº de workers que lanza vitest), esto
**flakea por contención de recursos**: `import` se dispara (~1400 s medidos), saltan
timeouts (5000 ms) y el set de tests que falla VARÍA entre corridas — tests AJENOS al
cambio en curso, no regresiones reales. Bajo una concurrencia acotada la MISMA suite pasa
VERDE y determinista. Mitigación sellada por el lead (2026-08-28,
`C3-ADJ-TESTUNIT-CONCURRENCIA-APLICADA`): acotar la concurrencia **por perfil de máquina**,
nunca globalmente (los runners potentes no deben ralentizarse).

- **Knob: `TA_VITEST_MAX_WORKERS`** (env propia, leída por `vitest.config.ts` vía
  `tests/unit/support/max-workers.ts`). Contrato **fail-closed**:
  - **AUSENTE** → sin cap; comportamiento default de vitest intacto (runners potentes no
    se ven afectados).
  - **PRESENTE**, entero en `[1, nº de CPUs de la máquina]` → fija `test.maxWorkers` a ese
    valor exacto.
  - **PRESENTE e INVÁLIDA** (vacía, no-entera, `0`, negativa, entero inseguro, o
    `> nº de CPUs`) → la carga de la config **ABORTA** con un error explícito. Nunca cae
    al default: un valor corrupto en un canal débil NO debe reproducir el flake en
    silencio.
- **Por qué NO la nativa `VITEST_MAX_WORKERS` de vitest**: vitest 4.1.10 la lee en
  `node_modules/vitest/dist/chunks/coverage.DM_a_rWm.js:380`
  (`if (process.env.VITEST_MAX_WORKERS) resolved.maxWorkers = Number.parseInt(...)`)
  **DESPUÉS** de resolver la config del repo — pisaría cualquier `maxWorkers` fijado aquí,
  y además usa `parseInt` puro (`'50%'` se interpretaría como `50`, no como un
  porcentaje). Por eso `TA_VITEST_MAX_WORKERS` es una env namespaced propia, distinta de
  la nativa. **Si ambas están presentes a la vez** (`TA_VITEST_MAX_WORKERS` + una
  `VITEST_MAX_WORKERS` nativa con valor truthy), la config detecta el conflicto y
  **ABORTA** — nunca hay un override silencioso de la nativa sobre el cap propio. Si
  necesitas la nativa por algún motivo ajeno a este mecanismo, dejar
  `TA_VITEST_MAX_WORKERS` sin setear.
- **Activación por canal (persistente) — SOLO canales ordinarios, NO runners sellados**: se
  añade `TA_VITEST_MAX_WORKERS=<entero>` al MISMO fichero per-carril que ya usan otras vars
  de flota (`$SECRET_DIR/env/<canal>.env`, empujado a `$ENV_DEST`/`.env.local` con
  `talent-channels/scripts/push-carril-env.sh <canal>` — el mismo mecanismo que activa
  `TA_DRAFT_SKIP_BUILD=1`, TAL-2820). Sobrevive reinicio de sesión/runner (se re-exporta al
  arrancar). **Runners SELLADOS quedan EXCLUIDOS de esta vía**: su preflight fail-closed
  (§Perfil runner) prohíbe CUALQUIER `.env.local` en el clon/worktree — seguir esta
  activación ahí hace fallar el preflight, no activa el cap. Cuál es el mecanismo real de
  inyección para runners sellados es un **gap documental abierto, no resuelto aquí**.
  **Verificación — declarada NO VERIFICABLE hoy, sin receta que sobre-declare**: un receipt
  verde del gate `unit` (`run-gate-sealed.sh unit --runner ...`, invocación posicional — ver
  «Invocación canónica», el `<gate-id>` va PRIMERO, nunca como flag `--gate`) confirma
  AUSENCIA de flake en esa corrida, pero el contrato fail-closed de arriba admite la
  variable AUSENTE sin abortar (cae al default de vitest) — un verde NO demuestra que el
  cap estuviera activo. `tests/unit/support/vitest-config-maxworkers.test.ts` tampoco sirve
  como evidencia de despliegue: BORRA la variable real del entorno y la sustituye por
  valores sintéticos propios de su matriz — prueba que la LÓGICA de parseo responde
  correctamente a entradas controladas, no que `TA_VITEST_MAX_WORKERS` llegó al proceso
  Vitest exterior en una corrida real. Mientras no exista observabilidad del entorno
  EFECTIVO del proceso exterior en un runner dado, ni el receipt ni ese test se presentan
  como acreditación del cap — es deuda de observabilidad conocida, no resuelta aquí. La
  provisión de
  `$SECRET_DIR/env/*.env` en los hosts de la flota y la activación de la env en el runner
  sellado del motor son responsabilidad del coordinador/lead (fuera de este repo — ver
  `talent-channels`); el gate de ese despliegue es el propio `local-gates` sellado
  (ejecutor autoritativo de `unit`).
- **Tests que prueban el mecanismo**: `tests/unit/support/max-workers.test.ts` (matriz del
  parser: ausencia, válido, rechazo fail-closed, conflicto con la nativa) y
  `tests/unit/support/vitest-config-maxworkers.test.ts` (carga la config REAL en
  subproceso y afirma el `test.maxWorkers` EFECTIVO — falla si se retira el spread de
  `vitest.config.ts`).

## Rollout / dry-run con `local-gates-test`

Antes de que el contexto requerido `local-gates` dependa del motor v2: correr la suite
COMPLETA (todos los gates + TODOS los shards obtenidos del registro en runtime +
agregación) contra un SHA real y publicarla como contexto **`local-gates-test`**. Solo
con esa corrida verde de extremo a extremo se re-ejecuta `setup-branch-protection.sh` y
el requerido pasa a producirse por el motor v2. `local-gates-test` NUNCA satisface el
gate requerido.

## Break-glass (trazado obligatorio)

`gh api -X POST repos/<owner>/<repo>/statuses/<sha> -f state=success -f context=local-gates`
manual queda **eliminado del flujo normal** (omite receipts, conjunto de gates y
branch-name). Solo como break-glass: gates corridos de verdad + registrar **motivo + SHA
exacto + quién** en un comentario del PR y en el registro de la estación. Un break-glass
sin traza se trata como incidente.

## Troubleshooting

| Síntoma | Causa | Salida |
|---|---|---|
| El motor espera indefinidamente al arrancar | `flock` ocupado (otro run del mismo repo en el runner) | Esperar o asignar a otro runner; nunca matar el lock a mano sin verificar el run dueño |
| `git worktree add` falla ("already exists" / paths huérfanos) | Worktree desechable huérfano de un run abortado | `incus exec <runner> -- sudo -u <usuario-de-gates> git -C "<ruta-repo-en-runner>" worktree prune` (runner remoto: `ssh root@<host> "incus exec <contenedor> -- sudo -u <usuario-de-gates> git -C '<ruta-repo-en-runner>' worktree prune"` — ver «Runners remotos por estación»; `-C` citado soporta rutas con espacios; obligatorio, sin él `git` falla fuera de un repositorio; `sudo -u <usuario-de-gates>` es obligatorio — `incus exec` sin él corre como el usuario implícito del contenedor, no el usuario de gates real, y puede dejar el worktree con ownership incorrecto o fallar por safe-directory) y re-lanzar |
| El checkout del `--sha` falla (SHA no fetcheable) | El head vive solo en la ref del PR (fork / rama borrada) | Fetch por ref de PR (`--pr` / `refs/pull/<n>/head`) y re-invocar con el mismo `--sha` |
| El agregador falla con "reducción de registro" | `e2e-shards.json` de head tiene MENOS shards que el de base_sha | No es flake: exige ratificación explícita del lead (anti-reducción); las adiciones no fallan |
| Gate rojo sin log visible | Los logs del run son `0600` en dir `0700` del runner (confidencialidad) | Leer la ruta protegida indicada por el receipt; `--show-tail` solo con el redactor canónico disponible |
| Status posteado pero el merge sigue bloqueado | Contexto `local-gates-test` (rollout) o head cambió tras el post | Verificar contexto y `headRefOid` actual; re-correr sobre el head vigente |

### Limpieza de un runner atascado — secuencia FAIL-CLOSED

Ante un `flock` que no cede o un proceso zombie en un runner, seguir este orden estricto —
nunca actuar sin completar los pasos previos, y nunca matar el lock a mano sin verificar el
run dueño (fila de arriba):

**Transporte obligatorio, sin excepción**: TODO comando de esta secuencia se dirige al
runner con el transporte explícito de «Runners remotos por estación» (arriba) — nunca se
escribe pelado, ni siquiera en un paso de solo lectura. Runner LOCAL: `incus exec <runner>
-- <comando>`. Runner REMOTO (delta/omega/alpha): `ssh root@<host> "incus exec <contenedor>
-- <comando>"` — la orden remota va SIEMPRE como una única cadena citada para ssh (que
concatena sus argumentos posteriores y los reenvía SIN re-citarlos; sin la cadena completa
entre comillas, cualquier tubería, redirección o argumento agrupado del `<comando>` puede
partirse y ejecutarse parcialmente en el shell remoto). Un comando sin este prefijo se
ejecuta donde esté PARADO el operador — típicamente el HOST, nunca el runner — que es
exactamente el incidente que mató 4 gates de M2 en runners compartidos.

1. **Identificar antes de tocar nada**:
   - Runner local: `incus exec <runner> -- pgrep -af 'lg-pr|supabase'`
   - Runner remoto: `ssh root@<host> "incus exec <contenedor> -- pgrep -af 'lg-pr|supabase'"`
     (OpenSSH concatena con espacios los argumentos posteriores al host y los reenvía SIN
     re-citarlos — sin las comillas dobles envolviendo la orden remota COMPLETA, el `|`
     se interpretaría como tubería del shell remoto, no como parte del patrón de `pgrep`)

   para mapear el `run_group` y el propietario EN-CONTENEDOR. "`flock` ocupado" puede ser
   serialización legítima de OTRA corrida, no un runner atascado. Un `pgrep` corrido en el
   sitio equivocado (host en vez de contenedor, o el host en vez del host REMOTO) da un
   vacío falso — no "no hay proceso", sino "miré donde no era".
2. **Condición de aborto**: si el proceso/`run_group` identificado NO es el tuyo o su
   dueño no se puede determinar → ABORTAR; no matar nada, no retirar ningún lock. Solo
   proceder si el runner está confirmado huérfano (proceso zombie sin `run_group` vigente).
3. **Limpieza, solo entonces, atómica**: adquirir el lock y ejecutar el `pkill` DENTRO de
   la misma sección crítica, sin soltarlo entre medias, con el MISMO transporte del paso 1:
   - Runner local: `incus exec <runner> -- flock -n /tmp/local-gates-runner.lock -c 'pkill -9 -f "[s]upabase"'`
   - Runner remoto: `ssh root@<host> "incus exec <contenedor> -- flock -n /tmp/local-gates-runner.lock -c 'pkill -9 -f \"[s]upabase\"'"`
     (mismo motivo que el paso 1: la orden remota completa va como UNA cadena citada para
     ssh, con las comillas dobles internas de `"[s]upabase"` escapadas — sin esto, `-c`
     pierde su cuerpo como argumento único al recomponerse en el shell remoto)

   El lock de
   `run-local-gates.sh` (`exec {LOCK_FD}>"/tmp/local-gates-runner.lock"` seguido de
   `flock -n "$LOCK_FD"`) ata al FD/inode abierto, NO al pathname: una comprobación que
   suelta el lock antes de matar (p. ej. `flock -n path -c true` seguido de un `pkill`
   aparte) deja una ventana donde una corrida legítima puede colarse y adquirir el lock real
   entre medias — el `pkill` la interrumpiría a ELLA. Manteniendo el `pkill` DENTRO del
   mismo `-c` del `flock` se cierra esa ventana. Si `flock -n` FALLA al adquirir, hay un
   proceso vivo con el fd abierto → ABORTAR, no tocar el fichero ni matar nada. El fichero
   de lock **NUNCA se borra**: un `rm` mientras el inode viejo sigue bloqueado deja que una
   corrida nueva abra un fichero DISTINTO en el mismo pathname y adquiera un lock DISTINTO,
   perdiendo la exclusión mutua entre ambas corridas. **Ejecutar el `pkill` FUERA del
   wrapper de contenedor —aunque el `flock`/`-c` interno sea correcto— mata procesos del
   HOST, no del runner: es exactamente el incidente que causó el bounce de este runbook.**

> **El abort del paso 3 (cuando `flock -n` no adquiere) es INTENCIONAL, no un bug — y su
> límite está declarado a propósito**:
>
> - **Por qué se aborta en vez de matar igualmente**: un proceso muerto YA liberó el fd del
>   lock, así que si `flock -n` falla es porque hay un proceso VIVO reteniéndolo. Vivo no
>   distingue "colgado" de "simplemente lento": el mismo estado observable puede ser una
>   corrida legítima que tarda o una atascada. Matar ahí es ADIVINAR, y la asimetría manda —
>   mil abortos molestos son preferibles a un solo `kill` de la suite de otra corrida, que
>   además no se enteraría. Por eso el fail-closed aborta en lugar de forzar.
> - **Qué caso queda FUERA de alcance de esta secuencia**: un proceso vivo-pero-atascado que
>   RETIENE el lock (un muerto ya lo habría liberado; el colgado no). Esta secuencia no lo
>   resuelve por diseño.
> - **Qué hace el operador en ese caso**: intervención manual. Por ser una acción
>   **destructiva sobre infraestructura**, exige autorización explícita (misma disciplina que
>   el break-glass de abajo y de §Break-glass) — NO la improvisa quien pase por ahí, y en
>   particular NO se sustituye por un `kill -9` a ojo, que es justo el hazard que esta
>   secuencia existe para prevenir.
> - **Por qué NO se resuelve matando por PID/PGID ANTES del `flock`** (dejado escrito para que
>   quien lo proponga —persona o revisor— encuentre la respuesta y no reabra el debate):
>   adelantar el kill al fd-check cambia un fallo VISIBLE (el abort) por un riesgo SILENCIOSO
>   — reintroduce exactamente el kill-a-ciegas de la corrida equivocada que el aborto evita,
>   en el único escenario (vivo, indistinguible hung/lento) donde no hay forma de acertar.
> - **Por eso el hallazgo del revisor automático de código sobre este abort-cuando-el-lock-
>   está-tomado queda como waiver aceptado (fail-closed intencional), no como defecto
>   pendiente**. El waiver cubre ÚNICAMENTE este finding concreto —el abort del paso 3 cuando
>   `flock -n` no adquiere—, no el fichero ni esta zona: un hallazgo NUEVO y distinto en este
>   mismo sitio no queda tapado por él. El registro del waiver que desbloquea el merge lo
>   gestiona la estación de merge (ADR-0043); esta declaración solo explica el porqué a quien
>   revise el documento después.

**`incus restart --force` / `incus pause` quedan PROHIBIDOS como paso ordinario de esta
secuencia** — no son un cuarto paso de limpieza normal, por tres razones:

- **Alcance de contenedor entero vs. alcance de corrida**: un contenedor puede tener más de
  una cosa viva a la vez. `incus restart` MATA también la corrida legítima de OTRO proceso
  ajeno — el mismo riesgo del paso 2 de arriba, pero a nivel de contenedor completo. `incus
  pause` no mata nada: CONGELA todos los procesos del contenedor por igual, interrumpiendo
  (sin matar) cualquier corrida ajena en curso mientras dure la pausa.
- **Colisión con el pool de slots compartido de la flota** (`fleet-slot-1..4.lock` en
  `/tmp/host-gate-slots`, bind-montado y visible en los 28 contenedores de la flota):
  `incus restart` mata también el proceso que sostiene el `flock` del slot — el slot SÍ se
  libera, pero porque el trabajo de ESE contenedor terminó de forma abrupta ANTES de
  reconciliar su estado/receipt con el dispatcher, no porque haya terminado limpio. `incus
  pause` en cambio CONGELA el proceso sin matarlo — el fd del `flock` sigue abierto, así que
  el slot NO se libera: el riesgo de `pause` es el opuesto, un slot ocupado/bloqueado
  mientras el contenedor sigue pausado, agotando la capacidad efectiva del pool para el
  resto de la flota hasta que alguien lo reanude.
- **Ni un cambio de configuración lo justifica**: añadir un disk device a los 29
  contenedores de la flota se hizo EN CALIENTE, sin reiniciar ninguno y con tmux intacto en
  todos — ni siquiera eso requirió un restart.

**Excepción break-glass — SOLO con las CUATRO condiciones JUNTAS**: (1) identificar la
corrida por `run_group`; (2) verificar que NO hay dueño vivo; (3) abortar si el ownership es
ajeno o desconocido; (4) dejar registro de quién lo hizo y por qué. Sin las cuatro, no se
ejecuta — se trata como incidente, igual que un break-glass no trazado del propio gate
`local-gates` (ver §Break-glass arriba).

## Bugs abiertos del motor `talent-factory` (fuera del repo)

Catálogo de defectos del motor de gates y sus scripts satélite (repo `talent-factory`,
fuera de este repositorio — ningún fichero de ahí se toca ni se corrige desde aquí: esto es
spec para que el CEO aplique el fix directamente en ese árbol). 7 de 9 defectos catalogados
por la auditoría de fábrica están verificados aquí con evidencia fresca contra el árbol
real; 2 quedan declarados explícitamente pendientes de verificación — no se transcriben
como hechos confirmados sin evidencia propia.

| # | Fichero:línea | Síntoma | Fix |
|---|---|---|---|
| 1 | `seal-suite.sh:163` vigente (citado originalmente como `seal-suite.sh:120` @ `ecd8c1772`, 2026-07-26/27 — se movió tras el commit `18cd460`, TAL-4946) | `--runner-user runner --runner-repo /home/runner/repo` hardcodeado GLOBAL mientras `RUNNERS` mezcla runners locales y `ta-*`/`atlas-*` (`vivecoder`) → el preflight muere y la suite sale falsamente roja | Derivar `--runner-user`/`--runner-repo` POR RUNNER (p. ej. formato `RUNNERS="host/ct:user:repo"`), no un par global |
| 2 | `seal-suite.sh:126` (citado originalmente como `:85`) | `HEAVY_POOL=("${RUNNERS[0]}")`: con 1 solo runner, el carril ligero y el pesado corren en paralelo en él y compiten por el mismo `flock` | Con 1 solo runner, concatenar fast+shards en un único `run_lane` SERIAL, no en paralelo |
| 3 | `clean-runner.sh` — no existe (0 hits en todo el motor) | No hay forma programática de limpiar un runner atascado sin intervención manual | Crear `clean-runner.sh` implementando la secuencia FAIL-CLOSED de arriba, CON el transporte explícito hacia el runner en cada paso: local `incus exec <runner> -- <comando>`; remoto `ssh root@<host> "incus exec <contenedor> -- <comando>"` — la orden remota va como UNA cadena citada completa para ssh (que concatena y reenvía sin re-citar), nunca como argumentos sueltos ni pelada. Identificar `run_group`/propietario, abortar si ownership ajeno/desconocido, y solo entonces, con el MISMO transporte, `flock -n /tmp/local-gates-runner.lock -c 'pkill -9 -f "[s]upabase"'` (remoto: comillas dobles internas escapadas dentro de la cadena citada para ssh; pkill DENTRO del mismo `-c`, lock nunca borrado) |
| 4 | `seal-suite.sh:176` (citado originalmente como `:131`, dentro de `run_lane`) | `rm -f /tmp/lg-$RG*` sin mapear el `run_group` EN-CONTENEDOR — puede borrar el slate de una corrida ajena | Mapear el `run_group` EN-CONTENEDOR antes del `rm -f`, no incondicionalmente al iniciar el carril |
| 5 | `draft-handoff.sh` del motor, 108 líneas | No implementa `TA_DRAFT_SKIP_BUILD=1` (TAL-2820) ni el `supabase db reset --local` de reproducibilidad ante migraciones (TAL-2274) que el `draft-handoff.sh` de este repo (185 líneas) sí tiene | Backport repo → motor de ambos mecanismos |
| 6 | `fix-gh-env-relaunch.sh` | ⏳ **PENDIENTE DE VERIFICACIÓN** — no accesible desde ningún canal de producto para confirmar contra el árbol vigente | Ver TAL-5182 |
| 7 | `--continue` en `pozos-install-token.sh`, `pozos-install-token-remote.sh` y `fix-gh-env-relaunch.sh` | ⏳ **PENDIENTE DE VERIFICACIÓN** — mismo motivo que el 6 | Ver TAL-5182 |
| 8 | `pozo-sync.sh:19` (`SAT_HOSTS`) y `pozo-sync.sh:80` (lista de pozos) — dos hardcodes DISTINTOS en el mismo fichero, no un único contrato | (a) Línea 80: `LISTA=(p1 p2 ... p9)` hardcodeado — SÍ contradice una fuente derivable real (`ledger/cuentas.json` tiene un objeto `pozos` con exactamente esas claves como datos estructurados). (b) Línea 19: `SAT_HOSTS=(omega.tailnet.example alpha.tailnet.example delta.tailnet.example)` hardcodeado — hoy sin fuente estructurada única (`docs/pozos.md` solo lo documenta en prosa) | (a) Derivar la lista de pozos de `ledger/cuentas.json` en vez de hardcodearla. (b) Para `SAT_HOSTS` no hay fuente que derivar todavía — establecer una (campo estructurado en el ledger o en `docs/pozos.md`) antes de poder eliminar el hardcode; mientras tanto es deuda conocida y documentada, no un contrato roto |
| 9 | `lib/preflight.sh` — sin `set -u` (38 líneas, invocado por `run-gate-sealed.sh` vía `bash -c`) | Una variable no definida degrada en silencio en vez de fallar cerrado | Añadir `set -u` (o `set -euo pipefail`, patrón de sus hermanos) al inicio del fichero |

Los defectos 6 y 7 viven bajo `~/.config/talent-channels/bin/` en una máquina de la flota
con ese instalador desplegado; ningún canal de producto tiene acceso a esa ruta. Seguimiento
para completar su verificación: **TAL-5182**.

## Firma histórica: presupuesto de Actions agotado (hoy N/A)

Para diagnóstico futuro en cualquier org que aún corra Actions — la firma que precipitó
esta migración (2026-07-09): jobs que fallan en **~2 s**, `runner_name` **vacío**,
`steps == 0`, `conclusion=failure`, **sin logs ni anotaciones**, en **todos los PRs a la
vez**, **persistente entre reruns**. Verificar con
`gh api .../actions/jobs/<id> -q .runner_name` (vacío) y `-q '.steps|length'` (0).
Confirmado → es **infra/billing, NO el PR**: escalar al billing admin. Corolarios: los
full-reruns de shards flaky queman presupuesto (usar `rerun --failed` con tope);
`rerun --failed` puede dejar el aggregator con resultado stale (needs-context viejo); un
run in-progress no puede re-lanzarse ("cannot be rerun") hasta completar.

## Referencias

- Doctrina de la estación de merge: skill `talent-merger`
  (`.claude/skills/talent-merger/references/08-gates-locales.md`).
- Branch protection: `scripts/setup-branch-protection.sh` +
  `docs/runbooks/github-branch-protection.md`.
- Posture de review: `docs/runbooks/coderabbit-cli-pre-pr.md`.
- Gobierno de gates (cómo un gate nuevo pasa de advisory a requerido en el manifiesto):
  [`gate-promotion-policy.md`](gate-promotion-policy.md).
- Limpieza de runners atascados y prohibición de `incus restart`/`incus pause`: sección
  «Limpieza de un runner atascado — secuencia FAIL-CLOSED» en §Troubleshooting.
- Bugs abiertos del motor `talent-factory` (fuera del repo, con `path:línea` y fix):
  sección «Bugs abiertos del motor `talent-factory` (fuera del repo)», seguimiento de los
  defectos 6-7 en TAL-5182.
- Linear: TAL-2286 (gates 100 % locales) · TAL-2288 P0 (motor v2 + doctrina) · TAL-5175
  (runners remotos + saneo + spec de bugs del motor) · TAL-5182 (follow-up de verificación
  de los defectos 6-7).
