# Después de F8: certificar el repositorio para producción

La fábrica funciona tras F8. Esta guía no es una fase ni bloquea el montaje.
La certificación permanece PENDIENTE hasta que el verificador devuelve rc 0.
No despachar trabajo de producción mientras el DoR siga pendiente. Los siete
recibos siguen el protocolo de
skills/talent-repo-onboarding/references/03-verificacion-y-ensayo.md:
placeholder → evidencia → edición del comentario → recibo. Nunca inventar éxitos.

En una terminal nueva del instalador, sustituye las rutas absolutas públicas:

```bash
PKG=/srv/fabrica/talent-factory
CLON=/srv/producto
H=/home/instalador
PROYECTO=ejemplo
REPO=org-example/producto
D="$H/.local/share/fabrica/$PROYECTO/receipts"
mkdir -p -m 700 "$D"
```

Declara autoridades con aprobación del responsable. LOGIN es la identidad real
autorizada; repite la consulta por cada autoridad y guarda sus ids en un CSV:

```bash
LOGIN=operador-example
gh api "users/$LOGIN" --jq .id
printf '%s\n' 123456 > "$D/autoridades.txt"
chmod 600 "$D/autoridades.txt"
```

123456 se sustituye por el id releído, nunca por el ejemplo. Varias autoridades:
ids separados por comas, sin espacios. No basta el actor que escribe el JSON:
el verificador relee user.id del comentario y exige pertenencia a esta lista.

Completa CADA comprobación y prepara evidencia.json como objeto con los campos
de esta tabla. Conserva las salidas originales que respaldan la declaración:

| ID | Acción real y campos de evidencia.json |
|---|---|
| linear-integration | Verificar que la magic word del PR cerró la issue correcta en Linear. pr_url, issue_id. |
| cr-app-instalada | Instalar la App en el repo y conservar una revisión real. pr_url, review_id. |
| cr-app-draft-silencio | Abrir PR draft, observar que no genera reviews; conservar la observación y el intervalo. pr_url. |
| push-sentinel-block | En rama de prueba sin sentinel, intentar push y guardar su rechazo real; no desactivar hooks. commit_sha, branch. |
| audit-issue-maquina-limpia | Ejecutar audit-go en máquina limpia del equipo, guardar salida y su sha256. issue_id, salida_sha256. |
| ensayo-e2e | Usar el ciclo completo de F8, local-gates sobre su head, handoff/merge/Done. pr_url, status_context, issue_id. |
| accesos-y-deploy | Probar accesos y URLs de smoke con códigos reales, documentar el anexo aplicable. smoke_urls_codes, anexo_ref. |

Los tipos y contenido de los campos corresponden a evidencia real. Por ejemplo
ensayo-e2e usa status_context=local-gates. Añade attest_comment_id únicamente
tras obtener el id del placeholder. Para CADA fila, fija CHECK al ID exacto,
PR al número real que contendrá la atestación y EVIDENCIA al JSON de esa fila.
El firmante debe estar conectado con su propia cuenta gh autorizada:

```bash
CHECK=ensayo-e2e
PR=1
EVIDENCIA=/home/instalador/evidencias/ensayo-e2e.json
SHA="$(git -C "$CLON" rev-parse HEAD)"
CANON=paquete
ACTOR="$(gh api user --jq .login)"
ACTOR_ID="$(gh api user --jq .id)"
COMMENT="$(gh api --method POST "repos/$REPO/issues/$PR/comments" -f body='Atestación en preparación; pendiente' --jq .id)"
ISSUED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EXPIRES="$(date -u -d "$ISSUED +7 days" +%Y-%m-%dT%H:%M:%SZ)"
jq --arg check "$CHECK" --arg repo "$REPO" --arg sha "$SHA" --arg canon "$CANON" --arg actor "$ACTOR" --arg issued "$ISSUED" --arg expires "$EXPIRES" --argjson comment "$COMMENT" '{receipt_version:"1",check_id:$check,repo:$repo,branch:"main",sha_probado:$sha,sha_canonico:$canon,actor:$actor,issued_at:$issued,expires_at:$expires,evidencia:(. + {attest_comment_id:$comment})}' "$EVIDENCIA" > "$D/borrador.json"
CANON_EVID="$(jq -S -c .evidencia "$D/borrador.json")"
DIGEST="$(printf '%s' "$CANON_EVID" | sha256sum | cut -d ' ' -f 1)"
printf 'attest v1 check_id=%s repo=%s branch=main sha_probado=%s sha_canonico=%s actor=%s evidencia_sha256=%s\n' "$CHECK" "$REPO" "$SHA" "$CANON" "$ACTOR_ID" "$DIGEST" > "$D/comentario.txt"
jq -Rs '{body:.}' "$D/comentario.txt" > "$D/comentario.json"
gh api --method PATCH "repos/$REPO/issues/comments/$COMMENT" --input "$D/comentario.json"
gh api "repos/$REPO/issues/comments/$COMMENT" --jq '{user,body}'
cp "$D/borrador.json" "$D/$CHECK.json"
chmod 600 "$D/$CHECK.json"
```

CANON=paquete es la autoridad que usa el verificador en modo ZIP; no inventar
un SHA git del producto como canon. El hash se calcula sin el newline que una
tubería directa jq → sha256sum añadiría. Relee la primera línea y user.id antes
de emitir el recibo. Caducidad exacta: 604800 segundos (7 días); renueva evidencia
y atestación cuando caduque. No reciclar comentario de otro check/repo/head.

Comprobar la certificación, desde esa misma terminal:

```bash
export TRO_CANON_PACKAGE_DIR="$PKG"
export TRO_RECEIPTS_DIR="$D"
export TRO_RECEIPT_AUTHORITIES="$(cat "$D/autoridades.txt")"
export TF_LINEAR_TEAM_KEY=ABC
bash "$CLON/.claude/skills/talent-repo-onboarding/scripts/verify-repo-parity.sh" "$CLON"
```

Sustituye ABC por la clave real del cuestionario. Rc 0 certifica; rc 3 mantiene
pendientes por nombre; rc 1/2 es rojo. El check-F4 fija estas rutas automáticamente
durante montaje. Plan privado gratuito: el pendiente procedimental de protección
puede impedir rc 0 aunque los siete recibos sean válidos; se declara pendiente
hasta resolver el plan/política, nunca se certifica por excepción.
