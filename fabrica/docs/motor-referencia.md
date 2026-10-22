# Referencia del motor de fábrica

Extraída de la documentación operativa de la distribución anterior.

## Paquete de skills de fábrica (canónico AQUÍ — motor-primero, paquete v1 2026-07-23)

Los **16 skills** de `skills/` forman UN paquete que viaja JUNTO (orden del lead 2026-07-23;
supersede para los SKILLS el patrón espejo canónico-fundador TAL-2658; los artefactos RAÍZ
del flujo —hook, scripts A4, plantilla HANDOFF— siguen canónicos en el fundador, carve-out D4):

- **Manifiesto**: `skills/skill-creator/assets/package.manifest` (16 `member=` + overlays por repo).
- **Núcleo vs overlay (D13)**: los overlays (`repo-identity.conf` de channel-operation y
  orchestrator; familias `references/anexo-*`) son POR-REPO — ni se copian ni se borran; la
  identidad se ADJUDICA con autoridad (`--migrate-identity --authority <manifiesto> --approved
  <adjudicación del lead>`), JAMÁS se hereda del legado ni del fundador.
- **Propagación/paridad**: `skills/skill-creator/scripts/sync-package.sh` (`--check|--apply`;
  apply sobre producto = preflight dos-fases con CERO rsync ante identidad inválida).
- **Doctrina-como-test**: `<skill>/invariants.tsv` + `skills/skill-creator/scripts/validate-package.sh`
  (rc 0/1/2, anti-vacuo; `--strict-set` en el motor). Regla de ratchet (D6):
  `skills/skill-creator/references/09-paquete-de-fabrica.md`.
- **Gate del motor**: `motor-go.sh` corre self-tests + `--strict-set` cuando el diff toca `skills/**`.

## Doctrina multi-fábrica (resumen del operador de la matriz)

Detalle canónico: `skills/talent-orchestrator/references/11-multi-fabrica-y-ceo.md` (jerarquía,
modelos, fronteras) y `skills/talent-channels/SKILL.md` §Multi-fábrica (aprovisionamiento).

- **Jerarquía**: **capa META — PM ⇄ CEO, contrapartes** (el **PM** define la CARGA — intake,
  cola priorizada, criterios, dictámenes — y es la interfaz de PRODUCTO con el lead; el **CEO**
  reparte PROYECTOS y es la interfaz de FÁBRICA; las fábricas nacen con CEO y PM, y «el PM no
  puede ser un freno»: la supervisión en vuelo es del CEO — rol PM en el skill `talent-pm`) →
  **Orquestador** (uno por fábrica/proyecto activo) → **Coordinadores + Mergeador** (por
  fábrica) → **Canales**. Nadie cruza de proyecto sin reasignación del CEO.
- **Modelos por rol**: consulta la doctrina vigente en `../skills/talent-orchestrator/references/11-multi-fabrica-y-ceo.md`.
- **Intake de proyectos**: el lead/CEO deposita el repo en la matriz y lo ASIGNA a un
  Orquestador **con su manifiesto** (`manifiestos/<proyecto>.conf` — el Orquestador NO lo
  inventa: trabaja contra ese contrato); el **PM** entrega el intake y la carga priorizada del
  producto; si el repo es nuevo, el CEO supervisa la ruta directa
  de onboarding (skill `talent-repo-onboarding`).
- **Retarget** = drain → recycle de canales con el REPO_URL nuevo → manifiesto → orden
  inaugural. **El Mergeador es lo ÚLTIMO que se apaga en un drenaje**: el Orquestador
  secuencia el apagado para vaciar la cola de PR drafts antes de retirar la estación.

## Motor de gates locales (TAL-2286/TAL-2288 — reemplaza GitHub Actions)

Modelo runner/estación con receipts (runbook completo: [local-gates](runbooks/local-gates.md) del repo fundador):

1. La **estación** del Mergeador (única con credenciales) genera un `run_group` impredecible y
   sella una **asignación** por gate (repo, pr, sha, base_sha, digests, gate_id).
2. Cada **runner** (perfil minimal SIN credenciales) corre UN gate sobre un árbol desechable:
   `bash scripts/run-local-gates.sh <repo> --assignment <json> --manifest <conf>` → **receipt** parcial.
   Exit: 0 PASS/SKIP-justificado · 1 FAIL · 2 precondición (sin receipt). El árbol ejecuta código
   del PR: `TF_ENV_COPY` está PROHIBIDO en modo sealed (aislamiento — sin credenciales que exfiltrar).
3. **Procedencia sellada (operación atómica)**: la estación lanza cada gate con
   `bash scripts/run-gate-sealed.sh <gate> --runner <contenedor> …` — PREFLIGHT fail-closed
   del CONTENEDOR (ningún home con auth de gh/Codex/Claude, `.netrc` ni `.git-credentials`;
   cero `credential.helper` de usuario/repo/sistema; clon y worktrees sin `.env.local`;
   usuario de gates sin `sudo` — con docker es root-equivalente dentro, así que el límite es
   el contenedor entero), transferencia del commit por BUNDLE (el runner no fetchea remotos
   privados), push de asignación+manifiesto+MOTOR con --uid/--gid/--mode del usuario de
   gates, `incus exec` síncrono OBSERVANDO el rc, pull del receipt y sellado en
   `journal.jsonl` bajo flock (sha256 receipt + sha256 asignación + sha256 del MOTOR + exit +
   `isolation: container:<runner>`). El motor se **auto-atesta**: recomputa su sha256 y aborta
   si no es el sellado; el agregador exige que sea el motor APROBADO de la estación.
   `--unsafe-local` = diagnóstico (`isolation: station-local`) y la agregación lo RECHAZA.
4. La estación agrega y postea: `bash scripts/post-local-gates.sh <run_group> <owner/repo> <pr> \
   --receipts <dir> --manifest <conf> --repo <clon-limpio>` — SOLO receipts con respaldo del
   journal (fabricado/manipulado/inline/station-local/incoherente/motor-no-aprobado ⇒ rechazo);
   conjunto esperado = manifiesto + registro de shards (anti-reducción base→head a nivel shard
   Y spec), gate `branch-name` desde base_sha sin credenciales, relectura final de head, branch,
   **tip de la base** y merge-base. El manifiesto se lee con **gramática cerrada** (datos, sin
   `source`) y solo desde `manifiestos/` del motor. `--context local-gates-test` para
   rollout/dry-run. Exit: 0 success posteado · 1 failure posteado · 2 inválido (no postea) · 3 POST falló.
5. `gh api` manual = SOLO break-glass trazado (motivo + SHA + quién), nunca vía normal.

### Claves TF_* del manifiesto (motor v2)

| Clave | Uso | Ejemplo/valores |
|---|---|---|
| `TF_GATE_IDS` | lista NOMBRADA de gates base (obligatoria) | `"typecheck lint build …"` |
| `TF_GATE_CMD_<id>` | comando del gate (`-`→`_` en id) | `TF_GATE_CMD_db_guards="bash scripts/ci/run-db-guards-local.sh"` |
| `TF_E2E_FAMILIES` / `TF_E2E_WRAPPER` / `TF_SHARDS_REGISTRY` | E2E por shard desde el registro del repo | ver `ejemplo.conf` |
| `TF_INSTALL` | instalación de deps (sin autodetección silenciosa; lockfiles incompatibles ⇒ fallo) | `"npm ci --no-audit --no-fund"` |
| `TF_DB_GATE` | `always` (default seguro) · `auto` (por diff; inactivo hasta ratificar) · `never` (justificado — BD compartida/preexistente) | `"always"` |
| `TF_MIGRATIONS_DIR` / `TF_BASE_REF` | diff del gate de BD | defaults `supabase/migrations` / `origin/main` |
| `TF_ENV_COPY` | ficheros no versionados copiados al árbol desechable — **PROHIBIDO en modo sealed** (solo diagnóstico inline) | `""` |
| `TF_BRANCH_VALIDATOR` | validador canónico de rama (lo corre el AGREGADOR desde base_sha) | `"scripts/github/validar-rama-pr.sh"` |
| `TF_SENSITIVE_SURFACES` | tokens EXACTOS del campo `surfaces` del HANDOFF (fuente única; `verify-handoff.sh` los lee) | ver manifiestos |

Validación inline al cargar: claves duplicadas ⇒ rechazo; `TF_REPO_URL` debe corresponder al repo objetivo.

### Variables de entorno del orquestador (`seal-suite.sh`)

Knobs pasados como ENV a la invocación de `seal-suite.sh` — **no** son claves del manifiesto
(no viven en `manifiestos/*.conf`, no las lee `run-local-gates.sh`/`post-local-gates.sh`) y por
tanto **no** disparan la anti-reducción de `motor-go.sh` (§"Push del motor" abajo — esa lista es
sólo de claves de ENFORCEMENT del manifiesto):

| Var | Default | Uso |
|---|---|---|
| `TF_E2E_CONCURRENCY` | `3` | cap de runners pesados (e2e) usados por el fan-out |
| `TF_QUIET_GATES` (TAL-4946) | `"unit"` | gates del carril ligero que salen de la fase PARALELA y corren en una fase SERIAL tras la barrera fan-out, cuando el host ya no tiene e2e activo — evita que `unit` solape el pico de contención CPU/IO del carril pesado (causa de flakes ajenos al cambio). Contrato de 3 estados: **sin definir** → default `"unit"`, *best-effort* (si el manifiesto no define un gate llamado `unit` —p.ej. proyectos con `test`/`check`— se ignora en silencio, sin fallar); **definida vacía** (`TF_QUIET_GATES=""`) → fase quieta **desactivada** (comportamiento previo íntegro, todo el carril ligero en paralelo); **lista explícita** → esos gates, con validación ESTRICTA fail-closed (cada token debe existir en `TF_GATE_IDS`; duplicados rechazados). La fase quieta se **OMITE fail-closed** si la fase 1 (paralela) no terminó 100% limpia — nunca arriesga a solapar un gate quieto con un e2e que pudiera quedar huérfano tras un timeout |
| `TF_STATION_HOST` (TAL-5196, **obligatoria**) | — (sin default, `die` si ausente) | alias de la estación en `manifiestos/runner-identity.map` — resuelve la identidad física de los runners LOCALES (specs sin `/`). Nunca se infiere con `hostname`: debe estar declarada explícitamente contra el mapa |
| `TF_RUNNER_IDENTITY_MAP` (TAL-5196) | `$(dirname "$TF_MANIFEST")/runner-identity.map` | ruta del mapa de identidad (`alias=host_canonico` por línea, fail-closed ante alias contradictorio o no legible). Ver `manifiestos/runner-identity.map` para el contrato completo |

### Identidad de runner y sobre-despacho intra-invocación (TAL-5196 E1)

`seal-suite.sh` normaliza SIEMPRE la lista de runners recibida contra el mapa de identidad
(`scripts/lib/runner-identity.sh`) ANTES de repartir carriles: resuelve cada spec a una tupla
física `(host_canónico, proyecto_incus, contenedor)`, filtra por estado RUNNING EXACTO (una sola
fila, nombre exacto — nunca por prefijo), y deduplica por tupla conservando DETERMINISTA el
primer `executable_spec` (el spec original, nunca la tupla) que esté vivo. Esto cierra el
sobre-despacho **intra-invocación** (una lista con duplicados/alias del mismo runner físico, o
runners caídos contados como capacidad, hacía que el round-robin tratara slots distintos como
runners distintos — incidente medido rg2118: 4 gates a un mismo runner en 19s). Con EXACTAMENTE
1 runner físico tras normalizar, el carril ligero y el pesado corren en SERIE (nunca dos
`run_lane` concurrentes sobre el mismo contenedor), preservando la fase quieta (TAL-4946).

**`--plan` es dry-run puro**: aplica identidad/dedup (para mostrar el reparto real) pero NO
consulta `incus`/`ssh` — sigue usable sin flota arriba. La consulta RUNNING solo ocurre en
ejecución real (`--no-post` o sin flags).

**Rollout obligatorio antes de activar en producción**: `manifiestos/runner-identity.map` debe
tener un alias para CADA host que aparezca en specs reales (incluida `TF_STATION_HOST`). Antes
de desplegar, correr `scripts/verify-runner-identity-rollout.sh <TF_STATION_HOST> <specs...>`
con la lista VIGENTE de runners de flota — si alguno no resuelve, `seal-suite.sh` moriría a
mitad de una corrida real; el preflight lo detecta antes, sin gastar un despacho.

**Fuera de alcance de E1** (follow-on con ciclo propio, TAL-5249): coordinación
CROSS-invocación (dos suites concurrentes al mismo runner físico) — el único candado hoy sigue
siendo el `flock` por-runner de `run-local-gates.sh` (detector, no asignador de capacidad).

### Push del motor

Este repo se empuja DIRECTO a main, pero SOLO vía `bash scripts/motor-go.sh` (bash -n +
shellcheck + smoke sobre todo shell modificado, y sobre los `manifiestos/*.conf`: gramática
cerrada, claves duplicadas, `TF_PROJECT`, y **anti-reducción semántica** contra origin/main —
gates/familias eliminados, `TF_DB_GATE` debilitado, claves de enforcement modificadas
(`TF_GATE_CMD_*`, `TF_E2E_WRAPPER`, `TF_INSTALL`, `TF_BRANCH_VALIDATOR`,
`TF_SHARDS_REGISTRY`, `TF_HEAVY_GATES`) o manifiesto borrado ⇒ ROJO salvo **ratificación
durable**: entrada append-only en `manifiestos/RATIFICACIONES.log` con `ref=` de la
aprobación, en el MISMO commit). Emite el sentinel one-shot atado a (SHA, refs/heads/main)
que exige `githooks/pre-push`. La ruta manual es diagnóstico, no autorización.

## Cuentas / pozos

`ledger/cuentas.json` registra los pozos —el conjunto se DERIVA de las claves de `pozos`, nunca se
enumera p1-pN a mano (un pozo nuevo aparece en el ledger y todo lo recoge solo)— con aliases,
restantes 5h/7d/Fable, resets CDMX,
`habilitada_fabrica`). Cosecha = MOVE (un login = una cosecha, origen retirado antes de habilitar
el destino) con verificación FUNCIONAL dentro del pozo. Política de selección: gastar primero la
cuenta de reset 7d MÁS CERCANO; no recolocar flotas desplegadas. Doctrina completa: skill
`talent-orchestrator` (referencia de cuentas/pozos).
