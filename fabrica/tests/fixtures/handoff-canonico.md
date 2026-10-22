## HANDOFF · Tren ejemplo — compositor de piezas A2 (fixture de pruebas)

### Qué hace

Fixture REALISTA (no sintetico) de un comentario HANDOFF tal cual lo emite
`draft-handoff.sh`, usado por los canarios de `compose-identity.sh`/`compose-resolve.sh`
para probar `identity_issues_de_body` contra un cuerpo con forma real, no solo lineas
sueltas. No corresponde a un PR real del motor.

Issues del encargo: closes ABC-5391, Fixes ABC-5392, resolves abc-5393

### Decisiones y porqués

- Fixture congelado a proposito: si `plantillas/handoff-pr-draft.md` cambia de forma
  incompatible, este fichero se actualiza en el MISMO PR que lo cambie.
- Se incluye una mezcla de mayusculas/minusculas en los tres verbos de cierre
  (`closes`/`Fixes`/`resolves`) para que el fixture ejercite la normalizacion
  case-insensitive con una forma de documento real, no solo con canarios sinteticos.

### Invariantes sellados por el code-audit

- `identity_issues_de_body` extrae exactamente `ABC-5391`, `ABC-5392`, `ABC-5393` de este
  fichero, normalizados a mayusculas, deduplicados, sin importar el verbo ni el caso.

### Superficies tocadas y clasificación

- Superficies sensibles tocadas: NINGUNA
- Justificación de la clasificación: fixture de pruebas, no toca codigo de produccion.

### Migraciones

- Slots incluidos: NINGUNO
- ¿Destructiva (DROP/ALTER irreversible/DELETE batch)?: NO
- Nota de renumeración: N/A (fixture, no es un PR real).

### Archivos calientes

Ninguno — este fichero vive en `tests/fixtures/` y no se referencia desde produccion.

### Verificación local ejecutada

```bash
bash tests/scripts/resolve-canarios.sh
```

### Scope ledger (AC/NG)

- AC-1: `identity_issues_de_body` aplicado a este fichero devuelve `ABC-5391`, `ABC-5392`,
  `ABC-5393` (verificado en resolve-canarios.sh).
- NG-1: no se toca ningun fichero de produccion; lo prueba que este fixture solo vive bajo
  `tests/fixtures/`.
- Otros cambios de comportamiento: ninguno.

### Qué NO tocar / trampas

- No editar este fixture para "corregir" su formato Markdown salvo que
  `plantillas/handoff-pr-draft.md` cambie primero — el objetivo es parecerse al HANDOFF
  real, no ser un Markdown perfecto.

### Bloque machine-readable

```json
{
  "schema_version": 2,
  "issues": ["ABC-5391", "ABC-5392", "ABC-5393"],
  "head_sha": "af781be005081e3ea68e11c6349731b55fcafe97",
  "branch": "feat/tal-5383-compose-bootstrap-identity-resolve",
  "sensitive": false,
  "surfaces": [],
  "migration_slots": [],
  "destructive": false,
  "category": "ops"
}
```
