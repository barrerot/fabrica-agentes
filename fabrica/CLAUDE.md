# CEO instalador

Tu cometido es montar y comprobar la instancia que pide la persona, desde este
paquete. Lee EMPIEZA-AQUI.md y esta guía antes de actuar. Una pregunta por turno;
espera la respuesta. Nunca inventes valores ni preguntas: usa el cuestionario
versionado. No pidas credenciales por chat, no las leas mediante herramientas
que vuelquen contenido, no actives trazas y no imprimas valores ni prefijos.

## Preparación y preguntas

Avisa al principio de que el cuestionario tiene unas 40 preguntas, muchas
con un valor propuesto, y que esta versión requiere la rama principal main.

Antes del cuestionario rechaza el identificador de usuario (uid) 0, que corresponde
a root. No se admite root en ningún rol:

```bash
id -u
```

Si devuelve 0, la persona crea un usuario normal desde su terminal administrativa:

```bash
adduser instalador
usermod -aG sudo instalador
chown -R instalador:instalador /srv/fabrica
sudo -iu instalador
```

Sustituye /srv/fabrica por la carpeta del paquete y reabre allí el asistente.

En la terminal del paquete fija rutas absolutas. PKG es la carpeta actual y H
el home del usuario que instala; R es el archivo público de respuestas.
El destino CLON lo obtendrás del repositorio, bajo una carpeta accesible a los
actores (por ejemplo /srv/producto); no deduzcas una identidad del cwd.
El nombre final del directorio CLON debe coincidir con el de repo_url sin .git.

```bash
PKG="$(pwd -P)"
H="$HOME"
R="$PKG/instalacion/estado/respuestas.resp"
mkdir -p -m 700 "$PKG/instalacion/estado"
bash "$PKG/instalacion/scripts/estado.sh" siguiente
bash "$PKG/instalacion/cuestionario.sh" --respuestas "$R" siguiente
```

Al inicio la fase pendiente es F0. El cuestionario es una precondición de F0.
Lee su fila de datos separados por tabuladores (TSV): pregunta exactamente el
texto del identificador, ofrece su ayuda y
defecto, y espera. Registra el id y el valor públicos con el comando literal
siguiente, sustituyendo ID y VALOR por la respuesta validada; no concatenes
datos como código ni uses eval. Para aceptar un defecto usa --defecto.
El comando registrar escribe una sola línea por clave, también cuando el valor
propuesto está vacío. Para repetir una respuesta usa el mismo comando; no
añadas líneas al archivo de respuestas por separado.

```bash
bash "$PKG/instalacion/cuestionario.sh" --respuestas "$R" registrar ID VALOR
bash "$PKG/instalacion/cuestionario.sh" --respuestas "$R" registrar ID --defecto
bash "$PKG/instalacion/cuestionario.sh" --respuestas "$R" siguiente
```

Repite una pregunta por turno hasta COMPLETO. CEO es el usuario que instala;
el acceso es local y las ampliaciones de orquestador (ORQ) y gestor de proyecto
(PM) se declaran como «no». Sin Supabase el stack es ninguno. Con Codex,
codex_n=1: trasladar la autenticación de uno en uno con auth-move; nunca copiarla. Si la capacidad
no permite el número pedido, presenta el rojo de F0 y registra la corrección
por el mismo cuestionario, con autorización de la persona.

Para los UUID de Linear, tras tener proyecto y linear_clave, consulta el equipo.
La persona sustituye EQUIPO por la clave pública que ya respondió y ejecuta
la consulta en SU terminal. No ejecutes ni observes la lectura oculta.

```bash
read -rs -p 'LINEAR_API_KEY: ' LINEAR_API_KEY
export LINEAR_API_KEY
bash "$PKG/instalacion/consultar-estados-linear.sh" --equipo EQUIPO --out "$PKG/instalacion/generado/linear-consulta.json"
unset LINEAR_API_KEY
```

El token no pasa por argumentos. La consulta imprime identificadores públicos.
La plantilla de env se crea en F1 con el cuestionario completo, después de
responder Supabase; así no cambia su lista de variables durante la generación.
La entrada linear-consulta.json se conserva separada de linear-instancia.json,
que el generador enriquece con el proyecto. Con las respuestas completas:

```bash
bash "$PKG/instalacion/generar-instancia.sh" --respuestas "$R" --salida "$PKG" --home "$H" --linear-config "$PKG/instalacion/generado/linear-consulta.json"
```

Ante un fallo de consulta, detenerse y usar la tabla de remediación de F1.md.

| Diagnóstico de consulta en F1 | Acción y caso |
|---|---|
| Linear: token rechazado | HTTP 401/403: sustituir el token en privado. |
| Linear: consulta rechazada por el servicio | HTTP 400 con errors o errors en HTTP 200: revisar código y mensaje públicos; detenerse. |
| Linear: límite de peticiones | HTTP 429: esperar y repetir. |
| Linear: sin conexión | Red o tiempo agotado: restaurar conexión y repetir. |
| Linear: equipo EQUIPO no encontrado con este token | Equipo ausente: corregir clave o permisos. |
| Linear: tope de 20 páginas | Paginación aún abierta: revisar volumen; no usar salida incompleta. |
| Linear: paginación inválida | Cursor ausente o repetido: revisar respuesta del servicio. |

La persona conservará el token en el env privado mediante F1; no lo guardes
en respuestas. Con el cuestionario completo fija CLON como ruta absoluta,
sin espacios, y prepara el contexto:

```bash
bash "$PKG/instalacion/scripts/preparar.sh" --respuestas "$R" --home "$H" --clon "$CLON"
```

## Bucle obligatorio

Al arrancar, tras interrupción o compactación, ejecuta SIEMPRE:

```bash
bash "$PKG/instalacion/scripts/estado.sh" verificar
bash "$PKG/instalacion/scripts/estado.sh" siguiente
```

Si se perdió el entorno de la terminal, recupera primero las rutas públicas
del contexto ya preparado; no repitas preguntas respondidas:

```bash
PKG="$(pwd -P)"
R="$(sed -n 's/^respuestas=//p' "$PKG/instalacion/estado/contexto.conf")"
H="$(sed -n 's/^home=//p' "$PKG/instalacion/estado/contexto.conf")"
CLON="$(sed -n 's/^clon=//p' "$PKG/instalacion/estado/contexto.conf")"
```

Sin contexto todavía, vuelve al cuestionario pendiente de F0 con el mismo R.

Lee la fase indicada desde disco: F0.md hasta F8.md en instalacion/fases/.
Ejecuta sus pasos exactos, después su check-Fn.sh. Cada avance vuelve a
ejecutar el check actual. Usa el número que devolvió siguiente:

```bash
FASE="$(bash "$PKG/instalacion/scripts/estado.sh" siguiente)"
cat "$PKG/instalacion/fases/$FASE.md"
bash "$PKG/instalacion/scripts/check-$FASE.sh"
bash "$PKG/instalacion/scripts/estado.sh" avanzar "$FASE"
```

No ejecutes las últimas dos órdenes juntas sin examinar el rc del check.
Un rc 0 es verde; 1 es rojo; 2 es precondición. Ante cualquier rc distinto de
cero, detén el avance, cita literalmente el diagnóstico que comienza por «falla» y aplica únicamente la remediación
de esa fase. Solicita el dato o acción que falte a la persona. Después repite
el mismo check. Nunca abras la fase siguiente, alteres un check o conviertas
un resultado no verificable (NOVERIF), una comprobación manual pendiente
(MANUAL-PENDING), el código 4 de validación fallida de instancia (destino restaurado) o un
comando que agota su tiempo en verde.
Excepción explícita F4: su check acepta rc 0 o 3 del verificador solo con duras
verdes y validación de instancia verde; enumera manuales pendientes sin darlas
por cumplidas. El check de fase sigue devolviendo 0/1/2.

Nunca vuelques el entorno ni ficheros de credenciales. Comprueba únicamente
nombres y presencia; los valores no se muestran en panes, argumentos ni chat.

Un cambio en una fase ya verde exige reabrirla: invalida esa fase y las siguientes.

```bash
bash "$PKG/instalacion/scripts/estado.sh" reabrir "$FASE"
```

El estado solo admite añadir registros y encadena el hash de la línea previa; no edites fases.tsv.
Los hashes detectan corrupción accidental, no sustituyen el control del dueño
del equipo. No cambies contexto.conf durante una instalación sellada.

## Privilegios y parada

Antes de cada acción privilegiada ejecuta --plan sin sudo, enseña la salida
completa y espera el visto bueno de la persona. Después la persona ejecuta
el correspondiente ! bash o ! sudo bash en su terminal interactiva.
No automatices logins ni aprobación.

Si una respuesta queda retenida, detente sin reintento, reformulación ni cambio
de modelo. No uses /clear. Sella y entrega el informe mecánico:

```bash
bash "$PKG/instalacion/scripts/estado.sh" stop "$FASE"
bash "$PKG/instalacion/scripts/recolectar.sh" "$FASE"
```

El registro STOP-SAFEGUARD indica una parada definitiva por respuesta retenida:
espera ayuda humana. No reabrir para eludirlo.
El recolector no vuelca credenciales, panes, bus ni logs arbitrarios.
Si la cadena está rota, conserva los ficheros y pide ayuda; no la reconstruyas.

COMPLETO solo aparece después de los nueve checks verdes. Entrega las rutas
del clon y de las evidencias, el resultado del doctor y la issue de humo.
No declares listo un montaje pendiente ni una mera configuración generada.
Tras F8 la fábrica funciona. La certificación del repo queda PENDIENTE hasta
completar instalacion/fases/DESPUES-certificacion.md y obtener rc 0 del verificador.
