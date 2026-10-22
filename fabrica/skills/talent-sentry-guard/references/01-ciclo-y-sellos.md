# 01 — Ciclo, cursor, ticker, sellos y cadencia

> Fuente: TAL-5157 §B1 (la figura) + §B8 gotchas 8-9 (mudeces del ticker) +
> mecánica heredada de `~/.sentry-analista/ciclo.sh` de C3 (fuera del repo,
> versionada aquí). Leer antes de arrancar la guardia o tras un compact.

## Cadencia (B1)

| Señal | Cada | Qué |
|---|---|---|
| Tick del ciclo | 5 min | Un barrido de las 4 fuentes (ver `05-fuentes-y-consultas.md`) |
| Parte al bus | 15 min | Resumen al bus `/tmp/merge-claims.txt` vía `~/sellar.sh` |
| Heartbeat | 4 h | `SENTRY-HEARTBEAT` con el estado (nada nuevo ≠ nada corriendo) |
| Digest al CEO | 12 h | Resumen de incidentes, WATCH movidos, issues creadas |

## Cursor y diff incremental

- `~/.vigia-sentry/cursor.json` guarda el último barrido: por grupo, el
  `lastSeen` y el `count` vistos. El ciclo clasifica **solo el delta** contra
  ese cursor — un grupo que no se movió no se re-triagea.
- El cursor es de la máquina de la Vigía. Un tercero que valide fuentes NO
  lo tiene ni debe fabricarlo (ver gotcha #14 del SKILL y `--solo-fuentes`).
- `sentry_doctor.sh` exige `cursor.json` legible y JSON válido antes de
  abrir la puerta (check de RUNTIME, no de FUENTE).

## Ticker — las dos mudeces de la primera noche (gotcha 8)

**El pane quieto NO prueba que el tick esté vivo.** El despertador one-shot
murió en silencio dos veces la primera noche (50 min y 3h24m sin latido). Por
eso:

- El ticker es un **bucle infinito** que escribe un `TICK <ISO>` a
  `~/.vigia-sentry/tick.log` en cada vuelta — nunca un `sleep` one-shot.
- Un **monitor externo de staleness** vigila la mtime de ese log: si supera el
  umbral (900 s, fijo en producción), es fallo.
- `sentry_doctor.sh` (check `check_tick`) mide esa mtime contra ese umbral —
  un TICK viejo es PUERTA CERRADA, no calma. El umbral es override-able vía
  `SENTRY_DOCTOR_TICK_UMBRAL` (igual que `SENTRY_DOCTOR_TICK_LOG` para la
  ruta), pero **NO es config de tenant**: es un SEAM de test —
  `sentry_doctor.sh:149-157` lo enumera junto a cliente/header-file/path de
  runtime como override que `seams_presentes()` debe cazar, y su sola
  presencia en el entorno de producción significa "entorno contaminado", no
  "umbral ajustado a propósito". Úsalo solo para acortar la espera en un
  test local — nunca lo exportes en el runner real.

## Matar procesos del propio ciclo — self-match (gotcha 9)

`pkill -f <needle>` / `pgrep -f <needle>` con el nombre del propio watcher
**se auto-matchea** (el pgrep aparece en su propia búsqueda) → `exit 144` y el
proceso real sigue vivo. Matar por **PID exacto** (guardado al lanzar) o por un
needle fragmentado que no aparezca en la línea de comando del pgrep.

## Sellos al bus (vocabulario cerrado)

| Sello | Cuándo | Contenido mínimo |
|---|---|---|
| `SENTRY-URGENTE-<X>` | S0/S1 money o auth (ver `02-…`) | shortId + fuente + por qué es urgente + a quién se escaló |
| `SENTRY-CONSULTA-<X>` | S3 que no se puede sellar ni tiene default seguro | qué falta decidir + quién decide + gatillo |
| `SENTRY-VERIFICA-<TAL>-{OK\|CONSULTA}` | cese post-deploy (ver `04-…` E/D/5A) | sha del release + cifra exacta de eventos nuevos en la ventana |
| `SENTRY-HEARTBEAT` | cada 4 h | estado (WATCH activos, issues en vuelo) |

**El token JAMÁS aparece en un sello, ni un fragmento** (límite duro, B9).

## Arranque / relevo

- Torre del HOST (C3): relanzar SOLO con `--resume <uuid>` de
  `~/.config/talent-channels/env/c3.session` (pozo por cuenta, ley 1-sep).
- Tras un compact: `talent-context` (compact-60/relevo) + releer este fichero
  y `03-buckets-y-baselines.md` (el estado vivo de los sets) antes de reanudar
  el ciclo.
- Paso 0 SIEMPRE: `bash scripts/sentry_doctor.sh`. Sin PUERTA ABIERTA no hay
  guardia fiable.
