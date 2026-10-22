---
title: "Fábrica de agentes — leyes operativas y glosario"
created: 2026-09-05
updated: 2026-09-05
author: talent-engine
status: draft
---

# Fábrica de agentes — leyes operativas y glosario

> **Serie «fábrica de agentes»**: [A · Modelo y players](fabrica-agentes-modelo-y-players.md) ·
> [B · Flujos y cadencias](fabrica-agentes-flujos-y-cadencias.md) ·
> **C · Leyes operativas y glosario** (este documento) ·
> [D · Perfil de ejemplo Acme](fabrica-agentes-perfil-ejemplo.md).

## 1. Cómo leer la tabla

Cada ley es una regla **vigente al corte (2026-09-05)** con fecha de origen y quién la dictó:
*lead* (orden verbal o bronca), *CEO* (ruling con poderes delegados) o *incidente* (una medida que
obligó a la regla). La columna **enforcement** dice qué la hace cumplir hoy: un hook o script
(automático), o la disciplina de un rol (revisable en el bus). La columna **dónde vive** apunta a la
fuente durable. Una ley superseded no aparece: si cambia, se sustituye con fecha nueva.

## 2. Leyes vigentes

### 2.1 Mando y comunicación

| Ley | Fecha | Origen | Enforcement | Dónde vive |
|---|---|---|---|---|
| El lead delega su firma en el CEO: un ruling reservado al lead lo cumple un comentario del CEO con la fórmula de poderes delegados y la cita del log de terminal | 2026-09-03 | lead | disciplina CEO | memoria del CEO; `talent-ceo` ref 01 |
| Al lead se le habla en su idioma y los pendientes se presentan uno a uno | 2026-09-04 | lead | disciplina CEO | CLAUDE.md regla 22 |
| Dos tablas cada 15 min desfasadas 7,5 (estaciones :06/:21/:36/:51; coordinadores y canales :13/:28/:43/:58), enteras y por separado, filas contadas; los crons persisten a compacts y cambios de cuenta | 2026-09-02 | lead | crons del CEO | B §4; `talent-ceo` ref 03 |
| Respuestas al lead siempre en la terminal, destacadas al final del turno | 2026-08-30 | lead | disciplina CEO | memoria del CEO |
| Hora solo con `date`; la hora tecleada en un texto es narrativa, manda la medida por el sellador | 2026-09-01 | CEO | sellador | B §6 |
| Un sello de resultado (fundido, aplicado, enviado) solo se escribe tras re-medir por API dentro de un `if`/`case` | 2026-09-04 | incidente | disciplina | `talent-merger` ref 07 |
| Anti-duplicado del bus por la estampa exacta del marcador, nunca por el nombre desnudo | 2026-07-26 | incidente | sellador | `talent-merger` ref 07 |

### 2.2 Relays, panes y composers

| Ley | Fecha | Origen | Enforcement | Dónde vive |
|---|---|---|---|---|
| Los relays a las estaciones de merge los hace solo el CEO; los coordinadores publican en el bus con marcador | 2026-09-02 | CEO | disciplina | `talent-ceo` ref 02 |
| Los composers de los canales son borradores del arnés: el CEO jamás pulsa Enter ni teclea en un canal; el coordinador cierra encuestas (0) y modales de cuota (parar y esperar); el `/compact` de un canal lo teclea su coordinador | 2026-09-01 | lead + C2 | disciplina | `talent-channel-operation` ref 03 |
| Texto atenuado (`\e[2m`) en un composer es autocompletado del arnés, no una orden; se discrimina con captura con atributos y comprobando que el fichero citado existe | 2026-09-05 | incidente (C1) | sonda de ronda | `talent-orchestrator` ref 07 |
| Un relay se da por entregado cuando la captura muestra la cabecera; Escape borra el composer del pane de desarrollo y es necesario en el del auditor | 2026-09-04 | incidente | script de relay | `talent-orchestrator` scripts `torre-relay.sh` |
| Jamás la cadena literal de empuje de git en un comando ni en un heredoc del mando: el hook de auditoría de push bloquea el comando entero | 2026-09-02 | incidente | hook `check-push-audit` | CLAUDE.md hooks |

### 2.3 Evidencia, receipts y verdes

| Ley | Fecha | Origen | Enforcement | Dónde vive |
|---|---|---|---|---|
| Receipts sin journal de procedencia no son agregables: solo el lanzador sellado desde la estación acredita; un lanzador propio mide pero no acredita | 2026-09-04 | incidente (M4) | agregador | [local-gates](runbooks/local-gates.md) |
| Los receipts se cuentan por contenido (base_tip == `main` vivo o ancestro con insumos no tocados), nunca por número de ficheros | 2026-09-05 | incidente (M2) | agregador | `talent-merger` ref 08 |
| Acreditación = ruta + hash + `head_sha == headRefOid` + línea literal del veredicto; y el auditor visible por captura (trabajando o quieto) | 2026-09-02 | lead | `verify-handoff` + disciplina | `talent-channel-operation` ref 04 |
| Detectar no es enrojecer: el rc del arnés es el veredicto; un `exit 0` ante una diferencia medida es hallazgo mayor | 2026-09-04 | incidente | disciplina de auditoría | `talent-channel-operation` ref 04 |
| NO MEDIDO es solo «el instrumento no arrancó»; con salida de dominio y rc ≠ 0 es INCUMPLIDO | 2026-09-03 | CEO | disciplina | `talent-channel-operation` ref 09 |
| Al exigir independencia se dice de qué eje: fuente, motor o ejecución | 2026-09-04 | CEO | disciplina | `talent-channel-operation` ref 04 |
| Un brief escrito no es una ronda despachada: termina cuando el auditor está trabajando por captura | 2026-09-05 | CEO | sonda de ronda | `talent-channel-operation` ref 03 |
| Un rojo intermitente no se atribuye a una causa sin medirlo en esa corrida; un rojo que se repite por causa se corrige, nunca se exculpa con un waiver | 2026-09-05 | CEO | disciplina | `talent-merger` ref 07 |

### 2.4 Entrega e intake

| Ley | Fecha | Origen | Enforcement | Dónde vive |
|---|---|---|---|---|
| Ningún canal codea sin auditor adversarial en el pane 1; un PR sin veredicto no se acepta | 2026-09-01 | lead | disciplina del coordinador | `talent-channel-operation` ref 01 |
| El intake exige veredicto anclado al head vivo; sin él, bounce sin gatear | 2026-09-01 | CEO | estación | `talent-merger` ref 02 |
| CERO×2 es el gate de entrega: dos pasadas limpias sobre el mismo head; un rebase mecánico (patch-id idéntico) conserva el GO, un cambio de contenido exige par nuevo | 2026-09-03 | CEO | disciplina | `talent-channel-operation` ref 04 |
| El HANDOFF lleva `plan_verdict` y `code_verdict` (ruta + hash); `verify-handoff` falla si falta alguno | 2026-09-04 | incidente | `verify-handoff` | [handoff-pr-draft](../plantillas/handoff-pr-draft.md) |
| `verify-handoff` justo tras un push no vale: esperar a que la API devuelva el SHA empujado; identificadores derivados por comando, nunca tecleados | 2026-09-05 | incidente (M2) | disciplina | `talent-merger` ref 07 |
| Cada ronda comprueba por API que la issue sigue abierta y que la pieza no está ya en `main`; el `updatedAt` del DoD se lee y se cita en esa ronda | 2026-09-04 | incidente (ch06) | disciplina | `talent-channel-operation` ref 09 |
| Entregar rama = rama en origin; empujar sin hooks está prohibido | 2026-09-03 | CEO | hook pre-push | CLAUDE.md hooks |
| Sin fragmento propio en los registros compartidos no hay intake (registro por fragmentos) | 2026-09-05 | CEO | estación | B §3 |

### 2.5 Merge, slots y migraciones

| Ley | Fecha | Origen | Enforcement | Dónde vive |
|---|---|---|---|---|
| La ventana de merge se da al primero en verde real, jamás por turno fijo | 2026-08-31 | lead | disciplina | `talent-merger` ref 02 |
| La ventana concedida por el CEO se respeta aunque se tenga verde | 2026-09-05 | incidente (M2) | disciplina | B §3 |
| Batching por disjunción de ficheros en ventana de 15 min + suite nocturna completa a las 03:00; rojo nocturno = incidente y batching suspendido; destructivas, money-path SEV y cambios de `package.json` van solos | 2026-09-04 | lead | estaciones + nocturna | B §3 |
| Nunca una estación parada: toda estación con tarea en curso verificada en cada tabla; suite terminada sin reacción = estación parada | 2026-08-31 | lead | tabla del CEO | B §4 |
| Drenaje paralelo en todas las estaciones: suites por máquina, solo los merges serializados | 2026-08-31 | lead | bus | B §3 |
| Slots: manda el registro del CEO, no «tope + 1»; un slot bajo el techo con reserva no se renumera, sin reserva sí; se renumera contra ledger ∪ `main` ∪ PR abiertos | 2026-09-05 | CEO | estación | `talent-merger` ref 06 |
| Una renumeración byte a byte conserva el cuerpo: el contenido se re-verifica contra `main` en ese slot (sobrecarga de función = NOT UNIQUE) | 2026-09-05 | incidente (#2235) | disciplina | `talent-merger` ref 06 |
| Migraciones no destructivas se aplican en el mismo turno del merge con advisors y ledger; destructivas solo con GO del lead; un guard textual que salta por lógica dentro de una función se justifica por escrito | 2026-05-22 · 2026-09-05 | lead · CEO | aplicador con guard | CLAUDE.md regla 24 |
| No rebasar por reflejo: si la base sigue siendo ancestro, se re-mide solo lo cruzado; el rc del fetch se comprueba antes de la intersección | 2026-09-05 | incidente (M1, M4) | disciplina | `talent-merger` ref 07 |
| Adelantar el clon compartido del motor solo con los runners a cero o con cada estación pineando su motor | 2026-09-04 | incidente | disciplina | `talent-merger` ref 08 |
| Hijas de un tren: se cierran como superseded en el mismo acto de integrar, con contención línea a línea; nunca antes de que el padre exista | 2026-09-05 | CEO (propuesta C1) | estación | `talent-merger` ref 09 |

### 2.6 Carga, cuentas y planta

| Ley | Fecha | Origen | Enforcement | Dónde vive |
|---|---|---|---|---|
| La cota de carga manda sobre la urgencia; el que ejecuta re-mide antes de actuar; el turno del host es de autoservicio por orden de cola (un turno concedido por relay nace caducado) | 2026-09-05 | incidente (C1) | vigía de carga | A §6; B §3 |
| No correr e2e en los runners del host con carga > 24; una suite lanzada no se mata por reprioridad | 2026-09-05 | CEO | disciplina | B §3 |
| Techos de gates pesados por máquina | 2026-09-04 | CEO | estaciones | D §2 |
| La terna de pozos la decide el lead; nadie conmuta por su cuenta; el CEO conmuta con los instaladores y verifica por hash del proceso vivo | 2026-09-01 · 2026-09-05 | lead | instaladores | B §7 |
| El uso de un pozo se mide por consumidor en su barra, no por un lector del host | 2026-09-04 | incidente | disciplina | B §7 |
| Tokens jamás en pane, bus ni argv: escrow 0600 y comparación por hash | 2026-09-01 | lead | instaladores | `talent-channels` ref 05 |
| Instalador: solo el número del canal, el token del escrow y el modelo completo leído de la barra; rc 10 → «continuemos», rc 6 → forzar solo con ocioso verificado, rc 8 → bypass solo por orden expresa | 2026-09-04 · 2026-09-05 | CEO | instalador | B §7 |
| «Opus» en la fábrica = la versión estable más nueva del proveedor, no un ID fijo; siempre a la última estable con tren semanal; cuando sube el `engines` del producto, canales, golden y runners suben en la misma orden | 2026-09-03 · 2026-09-04 | lead | checker + tren | CLAUDE.md regla 0 |
| Flota permitida: host y los tres satélites; contenedores de otras fábricas no cuentan | 2026-09-01 | lead | perfil | D §2 |
| Una orden destructiva necesita sujeto (PID → padre → cgroup); jamás matar por patrón; jamás parar las pilas de la base local; jamás tocar TLS/DNS/red sin orden concreta | 2026-09-03 · 2026-09-04 | lead + incidente | disciplina | memoria del CEO |
| Jamás datos personales en el tracker, el PR, el HANDOFF ni el bus | 2026-09-02 | incidente | disciplina | `talent-channel-operation` ref 08 |

### 2.7 Estados, ociosidad y relevo

| Ley | Fecha | Origen | Enforcement | Dónde vive |
|---|---|---|---|---|
| Un canal con acta fresca sin cosechar no está ocioso: está esperando al coordinador; pregunta de un canal sin respuesta 15 min = incidente de la torre | 2026-09-04 | CEO | vigía de actas | `talent-channel-operation` ref 05 |
| Un canal compactado sin paso-0 ni orden está parado | 2026-09-05 | CEO | tabla del CEO | `talent-context` ref 03 |
| «Lee este fichero» no es una orden de ejecutar: los briefs abren con imperativo | 2026-09-05 | CEO | disciplina | `talent-orchestrator` ref 07 |
| Paso-0 canónico tras compact (hora, banco, bus, crons, sello, medir, pendientes) | 2026-09-02 | CEO | disciplina | B §8 |
| Los vigías mueren con cada relanzamiento: re-armar y verificar por PID; un vigía que «no dispara» no prueba nada | 2026-09-05 | incidente | disciplina | B §8 |
| Una medida heredada del banco no autoriza a contradecir una orden posterior | 2026-09-04 | incidente | disciplina | `talent-context` ref 03 |
| Los nombres de agente rotan en cada relanzamiento: identificar por columna tmux | 2026-09-04 | incidente (C1) | disciplina | `talent-orchestrator` ref 09 |
| Al tercer parche a la misma sonda, dejar de añadir marcadores y buscar la invariante estructural | 2026-09-05 | C2 | disciplina | `talent-channel-operation` ref 09 |

## 3. Glosario

| Término | Definición |
|---|---|
| **Acta / veredicto** | Fichero del auditor con GO/NO-GO anclado a un SHA, ruta y hash; captura íntegra del pane, nunca por rango de líneas. |
| **Ancla viva** | Entre veredicto y entrega no se empuja: amend, rebase o fixup cambian el SHA y obligan a re-auditar. |
| **Banco de regreso** | Fichero fuera del repo que una sesión escribe antes de compactar y lee entero al volver; el CEO los numera. |
| **Batching** | Fundir en la misma ventana varias piezas disjuntas del churn sin re-suite; lo respalda la nocturna. |
| **Bounce** | Devolver una pieza a su canal con el motivo medido (HANDOFF pobre, veredicto sin anclar, rojo por contenido). |
| **Bus** | Fichero append-only con lock donde CEO, coordinadores y estaciones sellan con marcador. |
| **CERO×2** | Dos pasadas de auditoría con cero hallazgos sobre el mismo head. |
| **Canal** | Contenedor aislado con pane de desarrollo y pane de auditor; «carril» es su sinónimo histórico. |
| **Cursor** | Posición de lectura del bus propia de cada lector. |
| **Encargo** | Bundle de 1-N issues cohesivas que viaja como una rama y un PR draft. |
| **Estación** | Sesión que fusiona: intake, suite sellada, merge, apply. |
| **Ghost-text** | Texto atenuado en un composer: propuesta del arnés, no orden. |
| **HANDOFF** | Comentario canónico del PR draft con la evidencia de entrega; su plantilla es la única enumeración de campos. |
| **Journal** | Registro de procedencia de un receipt: qué lanzador, en qué runner, sobre qué SHA. |
| **Ledger** | Tabla de migraciones aplicadas en producción; fuente de verdad del techo de slots. |
| **Modal** | Diálogo del arnés en un pane (encuesta, cuota, plan); lo cierra el coordinador con la opción canónica. |
| **Paso-0** | Secuencia fija que toda sesión ejecuta al volver de un compact o relanzamiento. |
| **Pozo** | Cuenta del proveedor de modelos con su cuota; se opera por token largo en escrow. |
| **Receipt** | Resultado de un gate (SHA, resultado, journal) emitido por el motor en un runner. |
| **Run group** | Identificador de una suite completa; los receipts se agregan por run group y contenido. |
| **Sello** | Escritura en el bus con marcador único y hora medida. |
| **Slot** | Timestamp de una migración; se renumera contra el ledger real. |
| **Suite sellada** | Los gates de `local-gates` corridos uno a uno en runners sin credenciales. |
| **Terna** | Conjunto de pozos autorizados en un momento; la fija el lead. |
| **Tren** | PR padre que integra varias piezas del mismo dominio con una sola suite y un solo squash. |
| **Turno permanente** | Autorización de autoservicio: el primero de la cola entra cuando su propia medida de carga lo permite. |
| **Ventana** | Intervalo en que una estación tiene derecho a fundir; la concede el mando o la gana el primer verde real. |
| **Vigía** | Proceso que emite por transición; se verifica por PID tras cada relanzamiento. |

Términos de producto (programa, enrollment, tier…) en [glossary](reference/glossary.md).
