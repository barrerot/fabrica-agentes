---
title: "Runbook — Torre de Control (operación de la fábrica en tmux)"
created: 2026-07-08
updated: 2026-07-09
author: raulmartin
status: active
---

# Torre de Control — operación de la fábrica en tmux

> **Capa OPCIONAL de operación de la Fábrica v2 ([ADR-0043](../decisions/0043-fabrica-v2-mergeador-posture-cr.md)).**
> La Torre de Control permite que el **Orquestador** opere las sesiones de los actores de la
> fábrica (Mergeador y coordinadores) desde tmux —leyéndolas con `capture-pane` y relevándolas
> con `send-keys`— en vez de que el lead haga de relay entre terminales sueltas (**modo manual**).
> **La Torre es optimización, no dependencia**: la fábrica se arma y opera sin ella; el pipeline y
> los gates son idénticos en ambos modos. Doctrina de skill: `talent-orchestrator`
> `references/09-torre-de-control.md` (+ `talent-channel-operation` ref 01 / `talent-merger`
> «Modo de operación»).

## ¿Quién ejecuta y cuándo?

- **Quién**: el **Orquestador** (operador de la Torre). Los actores (Mergeador, coordinadores)
  son las sesiones operadas.
- **Cuándo migrar a Torre**: en un **lull** del actor (nada codificando ni gateando; sin CR/CLI en
  vuelo) — nunca a mitad de un gate. El actor avisa de su ventana limpia.
- **Cuándo volver a manual**: cuando convenga operar a mano (depuración, ausencia del Orquestador).

## Arquitectura (3 fases)

1. **Fase 1 — migración de sesión**: cada actor migra su sesión a una ventana tmux dedicada
   (`torre-<actor>`) con `claude --resume` + bypass de permisos, y el Orquestador la da de alta en
   su mapa.
2. **Fase 2 — cosecha + relevo**: el Orquestador barre los panes (`capture-pane`, solo lectura) y
   releva decisiones (`send-keys`); lo DURABLE sigue yendo a Linear.
3. **Fase 3 — watchdog externo (pendiente/futuro)**: un vigilante fuera de las sesiones que detecte
   panes parados/al límite y alerte. **No implementado**; hoy la vigilancia es del Orquestador por
   sweep + los wakeups que rearma.

## Helpers versionados (TAL-2278) — vía canónica

La operación torre-\* está script-ificada en `.claude/skills/talent-orchestrator/scripts/`
(funciones puras en `lib-torre.sh`, cubiertas por `tests/run-tests.sh`). Los comandos manuales de
las secciones siguientes quedan como **fallback** documentado; la vía canónica es:

| Operación | Helper | Endurecimiento |
|---|---|---|
| Resume canónico | `torre-resume.sh <actor> --cwd <dir> [--list\|--uuid u\|--dry-run]` | sesión viva por `mtime==ahora` (0 o >1 vivas → aborta listando); UUID validado en ambos caminos; comando shell-safe |
| Sweep | `torre-sweep.sh [actor…] [--ansi] [--scrollback N]` | read-only; resumen busy/ctx/flags; `--ansi` = captura con `-e` (ghost vs real) |
| Relevo | `torre-relay.sh <actor> --text '…'\|--file <ruta> [--queue]` | anti-fantasma: pre-check del composer, verificación post-paste PRE-submit (gotcha `/exit` fantasma), entrega verificada, jamás reintento ciego (rc 3 cola · rc 4 mismatch) |
| Compact-60 | `torre-compact.sh check [actor…]` · `run <actor>` | nonce único por ejecución (extracción anti-stale del handoff); jamás `/compact` sin handoff ya guardado fuera |

## Procedimiento — migración a Torre (por actor)

### 1. Identificar la sesión VIVA (crítico)

Con varias sesiones del MISMO directorio en un host (coordinador, Orquestador, Mergeador),
`--continue` es una ruleta. Se identifica la sesión por su **UUID** y se resume por UUID:

- El UUID está en la ruta del scratchpad (`/tmp/claude-*/.../<uuid>/scratchpad`) o en el transcript
  `~/.claude/projects/<proyecto>/<uuid>.jsonl`.
- **La sesión viva es la del transcript cuyo `mtime` es AHORA** (se escribe en vivo), **NO** «la
  hora más alta»: una sesión vieja del mismo dir puede mostrar una hora del día mayor pero fecha
  más antigua.
- **Gotcha de zona horaria**: `ls` muestra hora LOCAL (host UTC-6); comparar contra `date -u`.

```bash
# vía canónica: candidatos con mtime UTC + edad (gotcha TZ resuelto en la salida)
bash .claude/skills/talent-orchestrator/scripts/torre-resume.sh <actor> --cwd "<pwd del actor>" --list

# fallback manual: el .jsonl con mtime a segundos de ahora es la sesión viva
ls -lt --time-style=full-iso ~/.claude/projects/<proyecto>/*.jsonl | head
date -u
```

### 2. Migrar con `--resume` SIEMPRE (nunca `--continue`)

```bash
# vía canónica (detecta la viva, valida el UUID, crea torre-<actor> y lanza con bypass):
bash .claude/skills/talent-orchestrator/scripts/torre-resume.sh <actor> --cwd "<pwd EXACTO del actor>"
# 0 vivas o >1 vivas -> aborta listando candidatos; con el UUID ya verificado: --uuid <uuid>

# fallback manual:
tmux new -s torre-<actor>        # p.ej. torre-mergeador / torre-c1 / torre-c2
cd "<pwd EXACTO del actor>"      # las sesiones son dir-scoped
bash .claude/skills/talent-context/scripts/install-statusline.sh   # .tui=default + barra ctx: (rc 0, o 3 si tu barra ya emite ctx:)
# Tras cargar lib-modelos.sh del paquete; CEO usa rol ceo y los demás coordinador.
model="$(tco_modelo_read "$rol")" && [ -n "$model" ] || exit 1
IS_SANDBOX=1 CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 claude --dangerously-skip-permissions --resume <session-id> --model "$model"
```

- **Relanzar con BYPASS de permisos** (`IS_SANDBOX=1 claude --dangerously-skip-permissions`): un
  `--resume` sin bypass hereda **modo permisos MANUAL** → cada `Bash` pide confirmación y el actor
  se atasca. El bypass está confinado al host de la fábrica (autonomía operativa, NO autoridad de
  merge — ver §Seguridad).
- **Renderer clásico + barra `ctx:`** (TAL-8038): `torre-resume.sh` y el relanzamiento de `pozos-install-token-torre.sh` lo
  hacen solos (env `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1` + `install-statusline.sh` antes de lanzar; abortan si Claude es
  menor que la mínima o si una barra ajena no emite `ctx:`). Sin ellos el pane cae en pantalla alternada (sin scrollback: PLAN y
  handoff no capturables) y la torre no emite `ctx: NN%` (compact-60 ciego).
- **Correr desde el `cwd` EXACTO** del actor (las sesiones son dir-scoped).
- **Acceso remoto** (p. ej. un coordinador en otra máquina): `ssh -t` de **sistema**
  (`ssh -t <user>@<host> '…'`, con Tailscale SSH `RunSSH:true`). **NO** `tailscale ssh -t`: ese flag
  **no existe**.

### 3. Checklist post-resume (en orden, ANTES de cualquier relay)

1. **Verificación de identidad**: la sesión confirma en 1 línea quién es y su último encargo
   («¿quién eres y último encargo?»). Si responde con contexto de OTRO actor → cerrar sin tocar
   nada y re-resume con el UUID correcto.
2. **Purga del TaskList stale del harness**: el `--resume` rehidrata el TaskList con tasks VIEJAS
   cuyo subject aparece en el spinner → la supervisión se engaña («Despachando TAL-…» cuando no es
   el trabajo real). Purgar/reconciliar el TaskList contra Linear + la orden curada.
3. **Rearmar wakeups/watchers**: NO sobreviven al relanzamiento. El Mergeador rearma su wakeup de
   status (~270 s); los coordinadores, sus monitores one-shot; el Orquestador, su sweep.

### 4. Alta en el mapa de la Torre

El Orquestador registra el actor (host, UUID, `pwd`, ventana tmux, watchers a rearmar) y hace un
primer **sweep de solo lectura** (`capture-pane`).

## Operación bajo la Torre

- **Sweep**: `torre-sweep.sh [actor…] [--ansi]` (read-only; fallback `tmux capture-pane -p [-e]`).
  El `-e` preserva los códigos ANSI — clave para distinguir **ghost-text** (autocomplete, prefijo
  `^[[2m` dim) de **cola real** («Press up to edit queued messages», brillo pleno): no
  sobre-reaccionar al gris. El resumen del helper clasifica el input (ghost/text) y marca
  `queued-msgs` / `usage-limit`.
- **Relevo**: `torre-relay.sh <actor> --text '…'|--file <ruta>` (fallback `send-keys` a mano). El
  helper impone la secuencia anti-fantasma: pre-check del composer (cola real → escalar, texto ajeno
  → no clobbear, ghost → ignorar sin neutralizar), verificación de input **post-paste PRE-submit**
  (gotcha `/exit` fantasma: jamás submit a ciegas) y entrega verificada por eco/actividad — un send
  sobre pane ocupado se ENCOLA; reintentar a ciegas DUPLICA. Relevos con `git push` u órdenes
  compuestas → crear el fichero con la herramienta de archivos (no heredoc/echo que el hook del host
  vea como compound) y pasarlo con `--file`.
- **Reportes**: lo efímero se cosecha del pane; lo **durable** (rulings, entregas, veredictos de
  gate, dependencias cross-flota) SIEMPRE deja rastro en **Linear** (API directa).
- **Límite de cuenta del CLI**: el tope de uso (p. ej. 5 h / 7 días) es **por reloj/cuenta, NO por
  sesión** — reciclar no lo resetea. Ante ~90 %: reciclar ANTES del reset (contexto fresco + texto
  de regreso), no quemar el margen en un gate que muere a medias.
- **Compact-60**: al llegar el contexto de un actor al 60 %, handoff de regreso → copiar fuera →
  `/compact` → pegar al volver (protocolo del lead; cada nivel vigila al de abajo). Vía canónica:
  `torre-compact.sh check` (ctx% por pane, UNKNOWN fail-closed) y `torre-compact.sh run <actor>`
  (los 4 pasos con nonce único por ejecución: un handoff viejo del scrollback jamás se captura, y
  no hay `/compact` sin el handoff ya guardado fuera). El actor ESCRIBE el handoff con Write en
  `$TORRE_HANDOFF_DIR/<actor>.<TS>.pending.md` (el viewport del TUI pierde los largos); la recogida
  verifica el fichero (nonce, bloque completo, no anterior a la petición), cae a la pantalla de
  respaldo y prorroga mientras el turno viva, con tope `TORRE_HANDOFF_HARD_MAX`; sin handoff
  verificado aborta antes de `/compact`.
- **Zombies de relay**: un `incus exec … tmux send-keys` colgado de OTRA sesión/coordinador se
  **reporta, NO se mata** (matarlo podría afectar a su canal); lo mata el operador de la Torre tras
  confirmar el origen (TERM basta).

## Vuelta a modo manual

`tmux attach -t torre-<actor>` y operar a mano; el lead retoma el relay. El switchover es en ambos
sentidos y no pierde estado: todo lo durable está en Linear + git + los runs-dir de cada estación.
En manual, los coordinadores reportan al lead por mensaje; las decisiones durables igualmente van a
Linear.

## Seguridad — qué NO cambia con la Torre

- **GOs del lead** (destructivas, ventana live), **aprobaciones de plan** y la **regla 9** (nunca
  push/merge sin gates) siguen intactos.
- El **bypass de permisos** con que arranca una sesión de Torre es autonomía operativa, **NO**
  autoridad de merge: los gates AND del Mergeador y el GO del lead en destructivas se cumplen igual.
- Las migraciones destructivas → GO del lead SIEMPRE (regla 24 / ADR-0043).

## Si falla

- **La sesión resume con contexto de otro actor** → UUID equivocado: cerrar sin tocar y re-resume
  con el UUID de la sesión viva (mtime==ahora).
- **El actor pide confirmación en cada `Bash`** → se relanzó sin bypass: cerrar y relanzar con
  `torre-resume.sh <actor> --cwd <dir> --uuid <uuid>`, que exige el registro y fija el modelo por rol.
- **El spinner muestra un encargo que no es el real** → TaskList stale: purgar/reconciliar contra
  Linear (checklist post-resume, paso 2).
- **Un wakeup/watcher no dispara tras migrar** → no sobrevivió: rearmarlo (checklist post-resume,
  paso 3).
- **`tmux` no existe en el host** → prerequisito no instalado: `apt install tmux` (las sesiones
  `torre-*` corren en el host; ver `talent-channels` Gotcha 27).
