# Fábrica de software con agentes

Esto es un paquete que monta una especie de "planta de producción" de código con
agentes: coges issues de tu tracker, y salen PRs revisados y fusionados en `main`
sin que tú escribas código ni apruebes cada paso.

No es un plugin ni un asistente. Es infraestructura: contenedores, usuarios de
sistema, cron, y unas cuantas sesiones de agente con roles distintos hablando
entre ellas.

El paquete está en [`fabrica/`](fabrica/). Este README es el resumen
que me hubiera gustado leer antes de abrirlo.

---

## Antes de nada, la parte honesta

**Yo todavía no lo he visto funcionando.** Todo lo que cuento aquí sale de leer el
paquete entero, no de tener la fábrica montada. Así que tomadlo como "esto es lo
que dice que hace y cómo está diseñado", no como "esto funciona, probado".

Y lo segundo: **esto no se instala en cinco minutos**. Son varias horas, en una
máquina Linux dedicada, con un cuestionario de ~50 preguntas y nueve fases que se
van comprobando una a una. Si la máquina no cumple, se para en la primera y no
sigue. Lo digo ya para que nadie pierda la tarde.

---

## Aviso si abres esto con Claude Code

Cuidado con esto, que me pasó a mí.

El paquete trae un `CLAUDE.md` que convierte cualquier sesión de Claude Code
abierta en esa carpeta en **el instalador**. Si abres ahí una sesión y le dices la
frase de arranque, empieza a montar la fábrica y a preguntarte cosas.

Si solo quieres **leer y cotillear**, abre la sesión y pídele que te lo explique,
sin decir la frase. La frase (está en `fabrica/EMPIEZA-AQUI.md`) es:

> Eres el CEO, monta la fábrica, pregúntame los datos que necesites del proyecto.

Eso arranca el montaje de verdad. Mientras no la digas, no pasa nada.

---

## La idea buena

Si os quedáis con una sola cosa de todo el repo, que sea esta.

Cuando pones varios agentes a programar en paralelo, el problema **no es** la
calidad del código que escriben. El problema es que te reporten un verde que nadie
midió.

Un agente te dice "los tests pasan". ¿Pasaron? ¿Sobre qué commit? ¿Antes o después
del último cambio? ¿Los corrió, o lo dedujo del contexto? Te dice "ya está
mergeado". ¿Lo comprobó contra la API, o lo está narrando porque es el final lógico
de la historia que venía contando?

Todo el diseño del paquete gira alrededor de eso, y tiene nombre:

```
anti-self-report:  nadie declara verde lo que no ha medido sobre ese SHA exacto
fail-closed:       ante una lectura ambigua, el veredicto es "no medido",
                   nunca "verde"
```

Lo demás son consecuencias. En cuanto lo pillas, el resto del diseño se explica solo.

---

## Cómo está montado

```
                      TÚ (lead)
          prioridades · GO de lo irreversible
                         |
                        CEO  ............  PM
              mando operativo        qué se construye
                (decide CÓMO)         (decide QUÉ)
                         |
                   ORQUESTADOR
              agrupa issues en encargos
                         |
        +----------------+-----------------+
        |                                  |
  1.ª ESTACIÓN                      2.ª ESTACIÓN
  (producción)                         (merge)
        |                                  |
   COORDINADOR                     ESTACIÓN DE MERGE
        |                                  |
  CANAL 1..n  --- PR draft + HANDOFF -->  RUNNERS
  (contenedor)                        (sin credenciales)
        \                                 /
         \                               /
              BUS  (fichero append-only)
```

La clave está en el corte del medio: **las dos mitades tienen credenciales
distintas**.

- Los **canales** escriben código y abren el PR. **Nunca fusionan.** Y no tienen la
  clave del revisor automático ni el token de la base de datos.
- La **estación de merge** es la única que fusiona. Verifica, revisa, corre los
  tests y hace el merge.

O sea: quien escribe el código **no puede** aprobar su propio trabajo ni tocar
producción. No es que esté prohibido, es que no tiene las llaves.

En una instalación pequeña, una misma sesión puede hacer varios roles de mando. Lo
mínimo es: CEO + coordinador + estación de merge + un canal.

---

## Qué es un "canal"

Esto me costó pillarlo, así que lo pongo claro: **un canal no es una máquina, y no
es un contenedor Docker.**

Es un contenedor de **sistema** (Incus, el fork de LXD). Dentro hay un Linux
completo con su init, sus usuarios y sesiones de terminal persistentes. Hace falta
eso porque un canal no es un proceso que se tira y se recrea: es un **puesto de
trabajo** con el repo clonado, la toolchain, el agente logueado y sesiones vivas.

Y dentro de cada canal hay **dos agentes, no uno**:

```
panel 0  ·  DESARROLLO           panel 1  ·  AUDITOR
---------------------------      ---------------------------
escribe el plan                  revisa el plan     -> GO/NO-GO
escribe el código                revisa el diff     -> GO/NO-GO
commits + push                   firma actas ancladas al SHA
abre el PR draft + HANDOFF
                                 nunca escribe código
nunca fusiona                    nunca sube nada a GitHub
```

El auditor es **adversarial a propósito**: recibe el trabajo del panel 0 como texto
no confiable, con delimitadores, y su trabajo es buscarle los fallos.

Dos reglas: **una sola issue por canal a la vez**, y **no avanza de fase sin el GO
de su auditor**.

Los canales se clonan de una plantilla por copy-on-write, así que montar el
segundo cuesta segundos y casi nada de disco. La regla de capacidad es **un canal
por cada 8 GiB de RAM**, hasta nueve por máquina.

---

## El circuito de un cambio

```
 1  issue en el tracker
 2  el orquestador la agrupa en un ENCARGO
 3  gate pre-issue ....................... falla algo -> NO se despacha
 4  fase A · plan ....................... GO del auditor
 5  fase B · código ..................... GO del auditor
 6  fase C · entrega .................... PR draft + HANDOFF
       [aquí el canal termina y coge el siguiente encargo]
 7  la estación hace intake y valida el HANDOFF
 8  rebase sobre main · revisión automática · tests en los runners
 9  los 4 GATES ......................... falla uno -> BOUNCE al canal
10  merge · post-merge · issue a Done
```

Detalle del paso 3 que dice mucho del diseño: si tu cuenta tiene el modelo bueno
agotado y el trabajo caería a un modelo degradado, **el despacho se muere** en vez
de ponerse a trabajar peor en silencio.

Y el paso 6 no entrega "un PR". Entrega un PR en borrador **más un comentario
HANDOFF** que declara qué entrega, con qué evidencia, qué gates corrió y sobre qué
SHA. Es verificable por API. Si el HANDOFF no cuadra, el PR rebota al canal con el
motivo medido.

---

## Los 4 gates antes de cada merge

Son AND: falla uno y no hay merge. Y se corren **justo antes** de fusionar, porque
—textual del paquete— *"no valen fotos de hace una hora"*.

| # | Gate | Qué exige |
|---|---|---|
| 1 | Review | El revisor automático en verde con **cero hallazgos** sobre el SHA exacto |
| 2 | Tests verdes + corrida propia | El check verde en ese head **y** que la estación pueda trazar la medición a una ejecución suya |
| 3 | Disjunción / hot-files | Que los ficheros no choquen con lo que entró en `main` ni con otros PRs en vuelo |
| 4 | Slot de migración | Solo si hay migraciones: que el número de slot siga libre |

Dos cosas del gate 1 y el 2 que me parecieron de alguien que se ha quemado:

- La evidencia del review **se lee de un log append-only buscando por SHA**, no de
  un `.json` de resultado que cualquier corrida posterior pisa. Y la clave es el
  SHA, no el número de PR, porque un mismo PR tiene varios heads si lo actualizas.
- El gate 2 **no se conforma con ver el check verde**: comprueba que esa corrida
  sea suya, cruzando el id de ejecución contra su propio journal. Un verde que no
  puede trazar a una medición propia no cuenta.

### Los runners

La CI vive en local, no en GitHub Actions. La branch protection de `main` exige **un
único check obligatorio**, que lo produce el motor del paquete en sus propios
contenedores. Sin ese check verde en el head, no hay merge por ningún camino.

Y el contrato del runner es la ausencia:

```
un runner NO tiene ninguna credencial
ni token del repo, ni del tracker, ni del revisor, ni de la base de datos
```

Solo corre los gates que declares (lint, tipos, tests, build, lo que tengáis) y
emite "receipts": evidencia firmada con el SHA, el manifiesto, la base y su grupo
de ejecución.

Efecto secundario que no es poca cosa: unos gates 100% locales funcionan igual en
cualquier org, **sin depender del presupuesto de CI de nadie**.

### El merge

No lo serializa un candado propio: lo serializa **GitHub**, exigiendo que la base
esté al día. Un merge sobre base obsoleta lo rechaza la API. Menos código que
mantener, misma garantía.

---

## El reloj

El mando no vigila cuando se acuerda: va por **cron**, a minutos fijos.

```
estaciones de merge        :06   :21   :36   :51
coordinadores y canales       :13   :28   :43   :58     (desfase 7,5 min)
parte de guardia           a minuto fijo de cada hora
suite completa sobre main  cada noche
tren de versiones          semanal
```

Y todo se registra en el **bus**: un fichero append-only con lock. Cada sello lleva
marcador de actor (`CEO-*`, `C1-*`, `M1-*`, `CH07-*`) y hora medida. Cada lector
avanza su propio cursor, así que nadie se pisa.

Mis tres frases favoritas de esta parte, literales:

```
"suite en curso" sin proceso en el runner = incidente
un marcador citado pero no publicado es un aviso, no un sello
la cuenta logueada en el host no manda; el token del proceso sí
```

La primera es la mejor: no vale que una estación diga que está trabajando. Se
comprueba que **hay un PID vivo** haciéndolo. Es la misma desconfianza del gate 2,
aplicada a la supervisión.

En la misma línea: un relay se da por entregado **cuando la captura muestra la
cabecera enviada**, no cuando se envió. Y un "fundido" o un "aplicado" solo se
escribe **tras re-medir por API**.

### Las cuentas ("pozos")

Cada cuenta del proveedor de modelos es un "pozo" con su cuota. Cuando una se
acerca al límite, el mando conmuta a otra. Y lo verifica a lo bestia: el hash del
token **en el entorno del proceso vivo** tiene que coincidir con el pozo destino.

Con una sola cuenta no hay a dónde conmutar, así que los pozos solo tienen sentido
con varias.

### El contexto

Esto le interesa a cualquiera que use agentes largos, montéis la fábrica o no.

Toda sesión compacta su contexto, pero **solo en un checkpoint limpio**: sin gate
propio en vuelo, sin edición a medias, sin modal abierto. Y **antes** de compactar
escribe un "banco de regreso" fuera del repo, y lo verifica.

Al volver ejecuta el **paso-0**, siempre igual: mide la hora, lee el banco entero,
lee el bus desde su cursor, **re-crea los crons**, sella el paso-0, re-mide
estaciones y canales, re-arma los vigías verificando por PID, y te presenta los
pendientes uno a uno.

```
un canal compactado sin paso-0 ni orden está parado
una medida heredada del banco no autoriza a contradecir una orden posterior:
se re-mide la fuente vigente
```

---

## Qué necesitáis para montarlo

### Máquina

Linux dedicada (Ubuntu 24.04 es el terreno probado; la 26.04 funciona pero pide dos
arreglos extra). Usuario normal: **root se rechaza en todos los roles**.

| | Mínimo que tiene sentido | Cómodo |
|---|---|---|
| RAM | 16 GiB | 32 GiB |
| Canales | 2 | 4 |
| vCPU | 4 | 8 |
| Disco | 80 GiB | 200 GiB |

Por debajo de 12 GiB de RAM no arranca. Entre 12 y 15 GiB sale un canal. Y al disco
hay que sumarle un margen obligatorio por encima del pool de contenedores, así que
no vayáis justos.

Herramientas: `git jq tmux cron python3 shellcheck incus btrfs-progs gh nodejs npm`
y Claude Code con una versión mínima que la primera fase comprueba. La lista exacta
está en `fabrica/EMPIEZA-AQUI.md`.

### Cuentas (y lo que cuesta al mes)

- Un **repo** con permisos de admin y rama principal `main`.
- Un **tracker** (Linear) con equipo y proyecto creados.
- **CodeRabbit**: obligatorio. No hay modo sin revisor, y es de pago.
- **Varias cuentas de Claude** con cuota. Esto es lo que de verdad limita cuánto
  produce la fábrica.

No os engañéis con esto: el hardware lo podéis tener tirado en casa, pero el
revisor y las cuentas son coste recurrente todos los meses.

---

## Cómo se instala

Resumen. El detalle real está en
[`fabrica/EMPIEZA-AQUI.md`](fabrica/EMPIEZA-AQUI.md) y en
[`fabrica/instalacion/fases/`](fabrica/instalacion/fases/).

1. Instalar los paquetes del sistema y configurar `git config --global user.name`
   y `user.email` con datos reales (la fase 0 los comprueba).
2. Dejar el paquete en una carpeta **permanente** y accesible —algo tipo
   `/srv/fabrica/`—, no en vuestro `~/Descargas`. **No se puede mover después del
   montaje**, y los usuarios de rol que se crean necesitan poder recorrer sus
   directorios padre.
3. Preparar el repo (rama `main`) y el equipo/proyecto en el tracker.
4. Abrir Claude Code **en esa carpeta** y decir la frase de arranque.
5. Responder ~50 preguntas, una por turno. Muchas traen valor propuesto.
6. Pasar las nueve fases, F0 a F8.

Las fases, por encima:

| Fase | Qué hace |
|---|---|
| F0 | Comprueba la máquina y el paquete. Incluye una batería de 1,5–2 h |
| F1 | Credenciales y usuarios de sistema |
| F2 | Contenedores: disco, red, plantilla golden, clones, runner |
| F3 | Logins de las cuentas de los modelos |
| F4 | Instala el "contrato" en vuestro repo (identidad, protección de rama, gates) |
| F5 | Arranca las sesiones: mando, coordinador, estación de merge |
| F6 | Bus, cursores, tablas y cron |
| F7 | "Doctor": contrasta toda la declaración contra los procesos reales |
| F8 | Ensayo real: un cambio mínimo recorre el circuito completo |

Reglas del instalador, que son la misma desconfianza aplicada a sí mismo:

- Cada fase sale **verde, roja o "falta una precondición"**. En rojo **se para** y
  conserva el progreso. No avanza a ver si cuela.
- Un resultado **no verificable nunca se convierte en verde**. Tampoco un comando
  que se queda colgado hasta agotar su tiempo.
- El estado es append-only con hash encadenado. Tocar una fase ya verde **obliga a
  reabrirla** y a reabrir las siguientes.
- Antes de cada acción con privilegios te enseña un **plan** y la ejecutas **tú** en
  tu terminal. No automatiza logins ni aprobaciones.
- **Las credenciales no pasan por el chat jamás.** Las escribes tú con entrada
  oculta o en un fichero privado.
- Si una respuesta del modelo queda retenida, **para en seco**, sella un informe y
  espera a un humano. No reintenta ni cambia de modelo. Y no uses `/clear`.

**F8 es la prueba de que existe de verdad:** una issue real que cambia un fichero
`.md` recorre issue → plan → código → auditoría → handoff → merge → Done. Hasta que
eso pasa, la instalación no se declara buena.

Ojo: después de F8 la fábrica funciona, pero la **certificación del repo sigue
pendiente**. Es un procedimiento aparte
(`fabrica/instalacion/fases/DESPUES-certificacion.md`) y hasta cerrarlo no
se despacha trabajo de producción.

---

## Cómo se usa, una vez montada

Vuestro bucle es corto:

1. Escribís o priorizáis issues en el tracker. Esa es la entrada del sistema.
2. Le dais prioridades y carga al mando. No repartís trabajo a mano.
3. Leéis las rondas que llegan cada 15 minutos: una fila por estación, una por
   canal, con lo que cada uno está haciendo **medido**, no reportado.
4. Respondéis los pendientes uno a uno: GO para lo irreversible, decisiones cuando
   hay ambigüedad, cambio de cuenta cuando se agota la cuota.
5. Revisáis lo que entra en `main`.

Lo que dejáis de hacer: teclear código, aprobar cada commit, perseguir el estado de
cada tarea, fusionar.

Lo que no puede hacer nadie más que vosotros: autorizar lo irreversible, fijar
prioridades, y decidir cuando dos lecturas válidas se contradicen.

---

## Lo que no me gusta / avisos

- **Cuesta dinero todos los meses.** CodeRabbit y varias cuentas de modelos.
- **Necesita máquina dedicada.** En el portátil de trabajo no.
- **La documentación mezcla el motor con el ejemplo.** El motor es agnóstico del
  repo, pero mucho del detalle de los documentos viene de **otra instancia real**:
  veréis issues `TAL-xxxx`, migraciones de Supabase, ficheros calientes tipo
  `next.config.ts`. No esperéis que los nombres encajen con vuestro proyecto; lo
  vuestro se declara en el cuestionario y en el anexo del repo.
- **Nueve fases es mucha superficie para fallar.** La mitad de las paradas que vais
  a tener no serán del diseño, serán de la máquina.
- **Escala hasta nueve canales en una máquina.** Más allá hay que añadir máquinas, y
  eso ya no es la instalación mínima.

---

## Sobre el nombre

He renombrado la carpeta del paquete a `fabrica/` y el repo se llama
`fabrica-agentes`, pero la anonimización es **parcial y no puede ser completa**.

Por dentro vais a ver `talent-factory`, `talent-ceo`, `talent-merger` y así hasta
17 skills con ese prefijo, más el README y el changelog del propio paquete. Eso
**no se puede renombrar**: los nombres y rutas están firmados en
`fabrica/instalacion/DISTRIBUCION.sha256` y `NUCLEO.sha256`, y la fase F0 comprueba
esos hashes. Si tocáis un nombre de dentro, la instalación se cae en la primera
fase.

Así que el nombre de fuera es nuestro y el de dentro es el que trae. No le deis más
vueltas.

---

## Si vais a hacer push de este repo

Lo mismo lo sabéis, pero por si acaso: **no subáis `instalacion/estado/` ni
`instalacion/generado/`**. Ahí están las respuestas del cuestionario y los UUID del
equipo del tracker de quien instaló.

El `.gitignore` del paquete ya los excluye, y sigue funcionando aunque la raíz del
repo sea esta carpeta de arriba (git lee los `.gitignore` de los subdirectorios).
Pero comprobadlo con `git status` antes del primer commit, no después.

---

## Glosario rápido

| Término | Qué es |
|---|---|
| **Canal** (o carril) | Contenedor aislado con panel de desarrollo y panel de auditor |
| **Encargo** | Bundle de 1–N issues cohesivas que viaja como una rama y un PR |
| **HANDOFF** | El comentario del PR con la evidencia de entrega |
| **Acta / veredicto** | Fichero del auditor con GO/NO-GO anclado a un SHA |
| **Ancla viva** | Entre veredicto y entrega no se empuja: cambiar el SHA obliga a re-auditar |
| **Bounce** | Devolver una pieza a su canal con el motivo medido |
| **Estación** | La sesión que fusiona: intake, tests, merge, post-merge |
| **Runner** | Contenedor sin credenciales donde corren los gates |
| **Receipt** | Resultado de un gate: SHA, resultado y journal de procedencia |
| **Journal** | De dónde viene un receipt: qué lanzador, qué runner, qué SHA |
| **Bus** | El fichero append-only con lock donde todos sellan |
| **Sello** | Una escritura en el bus, con marcador único y hora medida |
| **Cursor** | Por dónde va leyendo el bus cada actor |
| **Pozo** | Una cuenta del proveedor de modelos, con su cuota |
| **Terna** | Las cuentas autorizadas en un momento dado |
| **Ventana** | El rato en que una estación tiene derecho a fusionar |
| **Banco de regreso** | Lo que una sesión escribe antes de compactar y lee al volver |
| **Paso-0** | La secuencia fija que ejecuta toda sesión al volver de un compact |
| **Vigía** | Proceso que avisa por transición; se verifica por PID |
| **CERO×2** | Dos pasadas de auditoría con cero hallazgos sobre el mismo head |

---

## Qué hay en el paquete

| Ruta | Qué es |
|---|---|
| `fabrica/EMPIEZA-AQUI.md` | **Por aquí.** Requisitos y arranque |
| `fabrica/instalacion/fases/` | Las nueve fases, F0 a F8, y la certificación |
| `fabrica/skills/` | Los 17 "roles": CEO, coordinador, estación de merge, canales... |
| `fabrica/docs/` | El modelo, las cadencias y las leyes operativas |
| `fabrica/scripts/` | El motor de gates y los lanzadores |
| `fabrica/CHANGELOG-1.7.3.md` | Qué cambió en esta versión y sus límites |

Si solo vais a leer una cosa del paquete, que sea
`fabrica/docs/fabrica-agentes-modelo-y-players.md`. Ahí está el modelo
entero, con la tabla de todos los actores.

---

## Montar el repo

```bash
cd fabrica-agentes
git init
git add .
git status          # comprobad que NO aparece fabrica/instalacion/estado/
git commit -m "Primera versión: paquete y README"
```

El `.gitignore` del paquete ya excluye `instalacion/estado/` y
`instalacion/generado/`, y funciona igual desde esta raíz porque git lee los
`.gitignore` de los subdirectorios. Pero mirad el `git status` antes del commit, no
después.
