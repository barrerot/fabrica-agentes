# talent-factory

Distribución 1.7.3 (versión intermedia).

Fábrica de software portátil: skills de coordinación, canales de desarrollo, revisión,
entrega y supervisión; motor de gates, plantillas y configuración de ejemplo.

16 miembros + 1 adicionales = 17 skills.

El manifiesto de miembros vive en
[package.manifest](skills/skill-creator/assets/package.manifest).
El skill adicional es [talent-sentry-guard](skills/talent-sentry-guard/SKILL.md).

## Empieza aquí

Lee [EMPIEZA-AQUI.md](EMPIEZA-AQUI.md) para preparar y empezar la instalación.
El [montaje por fases F0–F8](instalacion/fases/F0.md) comprueba cada paso antes de avanzar.
Después sigue la [certificación del repositorio](instalacion/fases/DESPUES-certificacion.md).
La distribución contiene plantillas de identidad; adjudica la identidad de tu instancia
antes de operar sobre un producto. Los overlays por repositorio se generan en la instancia.

## Requisitos

Los recursos, herramientas, permisos y cuentas necesarios están en
[EMPIEZA-AQUI.md](EMPIEZA-AQUI.md). La versión mínima de Claude Code se declara en
[claude-min-version](skills/talent-context/assets/claude-min-version) y la verifica F0.
La clave de CodeRabbit es obligatoria para revisar y fusionar cambios.

## Qué contiene

| Directorio | Contenido |
|---|---|
| `skills/` | Miembros del paquete y Vigía de producción adicional |
| `scripts/` | Gates locales, handoff, auditoría y lanzadores sellados |
| `docs/` | Modelo, cadencias, leyes, perfil ilustrativo y runbooks |
| `manifiestos/` | Ejemplos de configuración, sin credenciales |
| `ledger/` | Ejemplo neutro de pozos y política de selección |
| `plantillas/` | Handoff de PR draft |
| `githooks/` | Comprobaciones de entrega antes de push |

## Lecturas

- [Cambios, migración y límites de 1.7.3](CHANGELOG-1.7.3.md).
- [Modelo y players](docs/fabrica-agentes-modelo-y-players.md).
- [Flujos y cadencias](docs/fabrica-agentes-flujos-y-cadencias.md).
- [Leyes operativas](docs/fabrica-agentes-leyes-operativas.md).
- [Perfil de ejemplo](docs/fabrica-agentes-perfil-ejemplo.md).
- [Referencia del motor](docs/motor-referencia.md).

## Verificar el paquete

Desde la raíz extraída, en el entorno aislado de pruebas:

```bash
bash skills/skill-creator/scripts/validate-package.sh --root skills --estado distribucion
bash skills/skill-creator/scripts/validate-package.sh --self-test
```

El estado distribución rechaza overlays operativos. El estado instancia exige identidad
adjudicada. La guía explica cuándo pasar de uno al otro.
