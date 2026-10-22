---
title: "Fábrica de agentes — perfil de ejemplo Acme"
created: 2026-10-03
updated: 2026-10-03
status: ejemplo ilustrativo
---

# Fábrica de agentes — perfil de ejemplo Acme

> **Ejemplo ilustrativo**, con datos ficticios. No configura una instancia operativa.
> Serie: [A · Modelo y players](fabrica-agentes-modelo-y-players.md) ·
> [B · Flujos y cadencias](fabrica-agentes-flujos-y-cadencias.md) ·
> [C · Leyes operativas](fabrica-agentes-leyes-operativas.md) · D · Perfil.

## 1. Identidad

| Campo | Valor ficticio |
|---|---|
| Organización | Acme |
| Producto | `org/producto` |
| Motor | `org/talent-factory` |
| Tracker | Linear, equipo `ABC` |
| Gate requerido | `local-gates`; [runbook](runbooks/local-gates.md) |
| Datos y despliegue | Proveedores adjudicados por la instancia |

## 2. Máquinas y lo que aloja cada una

| Host lógico | Rol ilustrativo |
|---|---|
| `alfa` | Mando, coordinador, canales y estación de merge |
| `beta` | Runners aislados, sin credenciales de terceros |

Los nombres se resuelven en la red privada de la instancia. Los techos de carga y el reparto
de contenedores se determinan con el perfil adjudicado, sin copiar una topología ajena.
El usuario por defecto de los contenedores es `vivecoder`.

## 3. Capa de mando

El lead adjudica identidad, recursos y responsabilidades. El PM gestiona la carga de producto,
el CEO supervisa la fábrica, el orquestador conduce el proyecto y los coordinadores reparten
trabajo a los canales. CEO, plan, replan y fallback de auditoría usan Opus vigente.
Coordinación, estación de merge, orquestador, gestor de proyecto, código y auditor Claude
usan Sonnet vigente. Ningún rol fija versiones: los identificadores completos salen del
registro del usuario del rol, `~/.config/talent-channel-operation/modelos.conf`.
La política se describe en
[la doctrina multi-fábrica](../skills/talent-orchestrator/references/11-multi-fabrica-y-ceo.md).

## 4. Canales (primera estación)

Cada canal trabaja en su contenedor con panes de desarrollo y auditoría. La cantidad, el
coordinador responsable y las credenciales se adjudican mediante el perfil de la instancia.
Los canales de producción no llevan la credencial de revisión de la estación de merge.

## 5. Estaciones de merge y reparto de runners

La estación coordina revisión, gates y fusión. Usa `CODERABBIT_API_KEY` para CodeRabbit.
Los runners reciben árboles desechables y producen receipts; no reciben credenciales.
El reparto se declara en el perfil, con un único trabajo por runner y procedencia sellada.

## 6. Cadencias

El perfil fija las ventanas de reporte, el barrido de canales y la suite nocturna. El CEO
comprueba que cada parte llegue; un resultado rojo exige investigar antes de reanudar entregas.
Las horas de este ejemplo se adjudican durante el montaje, según la zona horaria del operador.

## 7. Cuentas (pozos)

El ledger declara los pozos `pN`. El conjunto se deriva de sus claves. El lead adjudica cuentas
y permisos; este ejemplo no fija cuenta principal, terna ni orden de uso. Los tokens se guardan
fuera del paquete, con permisos restrictivos y acreditación funcional por pozo.

## 8. Rutas y ficheros operativos

El motor vive en el directorio de la matriz; el producto, en su clon hermano. El ejemplo
[ejemplo.conf](../manifiestos/ejemplo.conf) declara comandos y nombres de variables de entorno.
El bus, sellador, escrow, receipts y bancos de regreso se adjudican con el perfil. Ninguna ruta
de este documento debe interpretarse como un valor operativo por defecto.

## 9. Puntos abiertos al corte

Antes de operar: asignar responsables, verificar identidad, declarar hosts y runners, acreditar
actores y comprobar el ciclo de supervisión. La guía de montaje exige pruebas de cada fase.
Este perfil conserva las nueve secciones para explicar el modelo sin publicar cuentas reales.
