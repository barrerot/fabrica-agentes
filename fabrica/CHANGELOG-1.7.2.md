# Distribución 1.7.2 — cambios y migración

Base: distribución 1.7.1, commit `c9902b7`; integra generador, montaje y batería de distribución.
El SHA de montaje es PROVISIONAL hasta su fusión; se centraliza para el cierre de publicación.
<!-- montaje_sha=f54c9a5 -->

## Cambios por área

- Identidad neutra y overlays adjudicados por instancia; plantillas en el ZIP.
- Renderer clásico y barra de contexto; versión mínima de Claude Code `2.1.289`.
- PLAN y handoff de compact leídos desde disco, con pantalla como respaldo.
- Higiene git, traslado de autenticación, auditor acreditado y supervisión durable.
- Empaquetado reproducible, ratchet de neutralidad y hashes por fichero en el taller.
- README de alumno y [perfil ilustrativo Acme](docs/fabrica-agentes-perfil-ejemplo.md).
- Cuestionario de configuración y [montaje F0–F8](EMPIEZA-AQUI.md), con comprobaciones y reanudación.
- Manifiesto del núcleo generado sobre el contenido final y verificado sobre el ZIP extraído.
- Instalación guiada por fases: cada comprobación conserva su resultado y detiene el
  avance ante un fallo; la reanudación conserva los intentos y sus causas.
- Modelos siempre en la versión vigente por rol: CEO, plan, replan y fallback de
  auditoría usan Opus vigente; coordinación, estación de merge, orquestador, gestor
  de proyecto, código y auditor Claude usan Sonnet vigente. Los identificadores
  completos salen del registro privado de modelos del usuario de cada rol.
- Despacho compatible con el CLI actual: reconoce el compositor y sus encuestas,
  comprueba la entrega del encargo y acredita cinco capturas de pantalla reales.
- Estado del bus persistente y privado por usuario; cada torre recibe su ruta
  adjudicada y el coordinador conserva evidencias fuera del estado del CEO.
- Fase 8: handoff comprobado antes de retirar el borrador, intentos inmutables
  ligados al mismo head y recibos de las siete etapas calculados desde artefactos
  reales. El cierre exige fusión, local-gates en verde y Done confirmado.
- La estación acredita el CLI de revisión y la etiqueta cr-review. La revisión
  automática de la App se comprueba y su posible gasto adicional se advierte
  antes de retirar el borrador; esa etiqueta no acredita una revisión limpia.

## Migración desde 1.7.1

La identidad propia debe **adjudicarse de nuevo**: no se hereda de la distribución anterior.
Usa la autoridad y la aprobación de tu instancia mediante
[sync-package.sh](skills/skill-creator/scripts/sync-package.sh) y sus plantillas de identidad.
El validador distingue `--estado distribucion` (sin overlays) e `instancia` (adjudicados).
Para una instalación nueva sigue [EMPIEZA-AQUI.md](EMPIEZA-AQUI.md); el montaje adjudica
la configuración, conserva progreso por fase y detiene el avance ante un chequeo rojo.
Una instalación existente debe revisar su configuración, renderer, barra de contexto,
identidad de repositorio y acreditación de actores; no basta con sustituir los skills.
La certificación posterior se completa con
[DESPUES-certificacion.md](instalacion/fases/DESPUES-certificacion.md).

El clon del producto debe ignorar los seis patrones que comprueba
[verify-repo-parity.sh](skills/talent-repo-onboarding/scripts/verify-repo-parity.sh), líneas 320–343:

```gitignore
.claude/.cr-review-ok
.claude/.draft-handoff
.claude/.audit-go
.claude/tf-manifest.conf
.claude/.motor-go
.claude/.cr-review-*
```

Las negaciones posteriores que vuelvan a incluir esos ficheros provocan fallo.

## Revisión y desfase producto ↔ motor

La estación de merge requiere `CODERABBIT_API_KEY` como puerta de fusión. El perfil Mergeador
incluye esta credencial y permisos de merge; producción no la recibe, según
[rol y fronteras](skills/talent-merger/references/01-rol-y-fronteras.md), líneas 1517–1522,
y [SKILL.md](skills/talent-merger/SKILL.md), línea 704. La revisión CodeRabbit forma parte
del protocolo y no se describe un modo de fusión sin revisor.

El motor de esta distribución consume `.audit-go` en el Gate 1, según
[check-push-audit.sh](scripts/check-push-audit.sh), líneas 18 y 180–187.
Esta versión mantiene ese consumo. El script integrado no emite el aviso «DEPRECADO»;
la migración no presupone su presencia ni elimina la puerta de auditoría.

## Omisiones declaradas de suites en distribución

[proc-m13.selftest.sh](skills/talent-merger/references/proc-m13.selftest.sh) se ejecuta
en la instancia con stack `supabase`; en distribución se omite con cero asserts ejecutados.
La [batería](scripts/run-all-suites.sh) registra las omisiones aparte de las pruebas aprobadas.
Salida literal del validador de distribución sobre `015ed14`, tras incorporar el lote B:

```text
SKIP-OVERLAY talent-merger INV-ME-052 — target overlay ausente en la distribución (references/anexo-instancia.md)
SKIP-OVERLAY talent-merger INV-ME-137 — target overlay ausente en la distribución (references/anexo-instancia.md)
SKIP-OVERLAY talent-merger INV-ME-138 — target overlay ausente en la distribución (references/anexo-instancia.md)
SKIP-OVERLAY talent-merger INV-ME-139 — target overlay ausente en la distribución (references/anexo-instancia.md)
SKIP-OVERLAY talent-merger INV-ME-148 — target overlay ausente en la distribución (references/anexo-instancia.md)
SKIP-OVERLAY talent-merger INV-ME-318 — target overlay ausente en la distribución (references/anexo-instancia.md)
SKIP-OVERLAY talent-merger INV-ME-319 — target overlay ausente en la distribución (references/anexo-instancia.md)
SKIP-OVERLAY talent-merger INV-ME-326 — target overlay ausente en la distribución (references/anexo-instancia.md)
SKIP-OVERLAY talent-merger INV-ME-345 — target overlay ausente en la distribución (references/anexo-instancia.md)
SKIP-OVERLAY talent-merger INV-ME-352 — target overlay ausente en la distribución (references/anexo-instancia.md)
== resumen: miembros=16 · PASS=1451 FAIL=0 · invariantes-evaluadas=1092 · checks-A=16 · SKIP-STACK=0 · SKIP-OVERLAY=10 ==
```

Resto de las omisiones históricas de la ejecución completa sin git sobre `59ec411`:

```text
SKIP justificados (aparte de PASS):
  talent-ceo:   SKIP [r9-7]: sin raiz de repo; el Quick Start desde la raiz del repo no es evaluable
  talent-ceo: 1 omisiones internas declaradas; resultados ejecutados en /var/tmp/sima-v05-01-2424500-23577/tmp/tmp.iOUsZAPTri/talent-ceo.log
  talent-channel-operation: == [TA] tooling raíz en modelo defer-AUTOMÁTICO — tests de root-model v5.0 OMITIDOS (alineación del root = PR follow-up, CHANGELOG 5.0 #4) ==
  talent-channel-operation:   SKIP pre-push: draft OID+rama correctos pasa: ruta canónica de producto .githooks/pre-push ausente en este layout (carve-out D4; el motor porta githooks/pre-push propio con suite raíz). Las mismas 9 propiedades se ejercitan contra el hook real del motor en talent-factory/tests/run-tests.sh:126-160 ('pre-push del motor: sentinels OID+ref') — correspondencia verificada línea a línea (TAL-5570), no un carve-out sin contrapartida.
  talent-channel-operation:   SKIP pre-push: draft consumido one-shot: ruta canónica de producto .githooks/pre-push ausente en este layout (carve-out D4; el motor porta githooks/pre-push propio con suite raíz). Las mismas 9 propiedades se ejercitan contra el hook real del motor en talent-factory/tests/run-tests.sh:126-160 ('pre-push del motor: sentinels OID+ref') — correspondencia verificada línea a línea (TAL-5570), no un carve-out sin contrapartida.
  talent-channel-operation:   SKIP pre-push: draft de feat/x NO autoriza feat/y (binding de rama): ruta canónica de producto .githooks/pre-push ausente en este layout (carve-out D4; el motor porta githooks/pre-push propio con suite raíz). Las mismas 9 propiedades se ejercitan contra el hook real del motor en talent-factory/tests/run-tests.sh:126-160 ('pre-push del motor: sentinels OID+ref') — correspondencia verificada línea a línea (TAL-5570), no un carve-out sin contrapartida.
  talent-channel-operation:   SKIP pre-push: draft NO autoriza main (rechazo pre-sentinels): ruta canónica de producto .githooks/pre-push ausente en este layout (carve-out D4; el motor porta githooks/pre-push propio con suite raíz). Las mismas 9 propiedades se ejercitan contra el hook real del motor en talent-factory/tests/run-tests.sh:126-160 ('pre-push del motor: sentinels OID+ref') — correspondencia verificada línea a línea (TAL-5570), no un carve-out sin contrapartida.
  talent-channel-operation:   SKIP pre-push: sentinel CR NO autoriza main: ruta canónica de producto .githooks/pre-push ausente en este layout (carve-out D4; el motor porta githooks/pre-push propio con suite raíz). Las mismas 9 propiedades se ejercitan contra el hook real del motor en talent-factory/tests/run-tests.sh:126-160 ('pre-push del motor: sentinels OID+ref') — correspondencia verificada línea a línea (TAL-5570), no un carve-out sin contrapartida.
  talent-channel-operation:   SKIP pre-push: delete de main RECHAZADO (antes del bypass de deletes): ruta canónica de producto .githooks/pre-push ausente en este layout (carve-out D4; el motor porta githooks/pre-push propio con suite raíz). Las mismas 9 propiedades se ejercitan contra el hook real del motor en talent-factory/tests/run-tests.sh:126-160 ('pre-push del motor: sentinels OID+ref') — correspondencia verificada línea a línea (TAL-5570), no un carve-out sin contrapartida.
  talent-channel-operation:   SKIP pre-push: delete de rama normal pasa: ruta canónica de producto .githooks/pre-push ausente en este layout (carve-out D4; el motor porta githooks/pre-push propio con suite raíz). Las mismas 9 propiedades se ejercitan contra el hook real del motor en talent-factory/tests/run-tests.sh:126-160 ('pre-push del motor: sentinels OID+ref') — correspondencia verificada línea a línea (TAL-5570), no un carve-out sin contrapartida.
  talent-channel-operation:   SKIP pre-push: multi-ref (feat válida + main) → bloqueado: ruta canónica de producto .githooks/pre-push ausente en este layout (carve-out D4; el motor porta githooks/pre-push propio con suite raíz). Las mismas 9 propiedades se ejercitan contra el hook real del motor en talent-factory/tests/run-tests.sh:126-160 ('pre-push del motor: sentinels OID+ref') — correspondencia verificada línea a línea (TAL-5570), no un carve-out sin contrapartida.
  talent-channel-operation:   SKIP pre-push: fallo (por main) NO quema el sentinel draft: ruta canónica de producto .githooks/pre-push ausente en este layout (carve-out D4; el motor porta githooks/pre-push propio con suite raíz). Las mismas 9 propiedades se ejercitan contra el hook real del motor en talent-factory/tests/run-tests.sh:126-160 ('pre-push del motor: sentinels OID+ref') — correspondencia verificada línea a línea (TAL-5570), no un carve-out sin contrapartida.
  talent-channel-operation: 10 omisiones internas declaradas; resultados ejecutados en /var/tmp/sima-v05-01-2424500-23577/tmp/tmp.iOUsZAPTri/talent-channel-operation.log
  talent-buzz/probar-antifugas.sh: sin repo/main para auditar historia; el detector se prueba en probar-antifugas-fixtures.sh
  talent-buzz/probar-movil.sh: SKIP host_acreditado positivo (esta maquina no tiene tailnet)
  talent-buzz/probar-movil.sh: 1 omisiones internas declaradas; resultados ejecutados en /var/tmp/sima-v05-01-2424500-23577/tmp/tmp.iOUsZAPTri/talent-buzz_probar-movil.sh.log
  talent-buzz/probar-patches.sh: sin checkout local con el pin del proveedor; red no permitida en esta batería
  talent-llm-local/probar-puente.sh: llm-bridge no está activo en esta máquina
  llm-referencia: sin unidad /etc/systemd/system/vllm.service de referencia
  proc-m13: SKIP-OVERLAY: distribución (TF_PAQUETE_ESTADO=distribucion) sin anexo por repo (anexo-<proyecto>.md) — 0 asserts ejecutados; esta suite corre en la instancia
  proc-m13: 1 omisiones internas declaradas; resultados ejecutados en /var/tmp/sima-v05-01-2424500-23577/tmp/tmp.iOUsZAPTri/proc-m13.log
  proc13-pointers:   SKIP-OVERLAY  (4) distribución (TF_PAQUETE_ESTADO=distribucion): sin anexo del Mergeador (overlay por repo) — caso no evaluable aquí
  proc13-pointers: 1 omisiones internas declaradas; resultados ejecutados en /var/tmp/sima-v05-01-2424500-23577/tmp/tmp.iOUsZAPTri/proc13-pointers.log
  motor:   SKIP guard PreToolUse: hook de instancia no distribuido; no se evaluó su conducta
  motor: 1 omisiones internas declaradas; resultados ejecutados en /var/tmp/sima-v05-01-2424500-23577/tmp/tmp.iOUsZAPTri/motor.log

RESULTADO: PASS=47 FAIL=0 SKIP=11 TOTAL=58
VEREDICTO: PASS (rc=0)
```

Las rutas de logs de esa salida pertenecen a la copia desechable del runner.
Las omisiones no acreditan la conducta omitida: certificación, proveedor, servicios
locales y PROC-M13 se comprueban en su instancia y entorno correspondientes.

## Trazabilidad FAB-OBS

Los SHA de esta tabla corresponden a commits del taller. `MONTAJE` remite al parámetro
de cabecera: la implementación está en `f992289` y la guía en `c277368`, con sus correcciones
posteriores incluidas en ese SHA provisional. Una referencia pendiente cierra el gate.
FAB-OBS-010 es una configuración del producto, sin arreglo de motor;
se referencia la base como evidencia de origen, sin atribuirle una corrección.

| Observación | Issue y resultado | SHA del taller |
|---|---|---|
| FAB-OBS-001 | TAL-8042: quiesce y auditor | bca8ad3, 34a36da |
| FAB-OBS-002 | TAL-8042: traslado de autenticación | bca8ad3, 34a36da |
| FAB-OBS-003 | TAL-8042: acreditación | bca8ad3, 34a36da |
| FAB-OBS-004 | TAL-8043: supervisión durable | f17ae48 |
| FAB-OBS-005 | TAL-8038 y TAL-8039: contexto y compact | d1cfde2, 3cdc35e |
| FAB-OBS-006 | TAL-8043 y TAL-8045: instancia y montaje | f17ae48, MONTAJE |
| FAB-OBS-007 | TAL-8041: batería distribuida | f7c2236 |
| FAB-OBS-008 | TAL-8040: higiene del clon | 706876b |
| FAB-OBS-009 | TAL-8043 y TAL-8045: configuración y montaje | f17ae48, MONTAJE |
| FAB-OBS-010 | Producto: sin corrección del motor; base de procedencia | c9902b7 |
| FAB-OBS-011 | TAL-8038 y TAL-8045: requisitos y guía, sin eludir safeguard | d1cfde2, MONTAJE |
| FAB-OBS-012 | TAL-8038 y TAL-8045: renderer y montaje | d1cfde2, MONTAJE |
| FAB-OBS-013 | TAL-8043 y TAL-8045: actores y montaje | f17ae48, MONTAJE |
| FAB-OBS-014 | TAL-8043: doctor | f17ae48 |
| FAB-OBS-015 | TAL-8040: sentinels y hooksPath | 706876b |
| FAB-OBS-016 | TAL-8037: identidad neutra y limpieza de residuos | acfcb4d, 1aa8515 |
| FAB-OBS-017 | TAL-8038: barra de contexto | d1cfde2 |
