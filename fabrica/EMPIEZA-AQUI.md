# Monta tu fábrica

Este paquete organiza el trabajo de un proyecto de software: una persona dirige,
una sesión coordina, otra revisa y fusiona, y los canales desarrollan los cambios.
CEO es quien dirige; el coordinador C1 reparte y sigue encargos; la estación de
merge M1 revisa y fusiona. Un canal es un contenedor de desarrollo, un runner
ejecuta comprobaciones y un pozo conserva una cuenta para moverla a un canal.
Al terminar tendrás una instalación comprobada y un pequeño cambio de documentación
que haya recorrido el proceso completo.
El cuestionario tiene unas 40 preguntas, muchas con un valor propuesto.

Necesitas una máquina Linux dedicada, al menos 12 GiB de RAM, 30 GiB libres y espacio para los
contenedores y 20 GiB de margen. Con 12–15 GiB se monta un canal y un runner;
con 16 GiB o más se admite un canal por cada 8 GiB, hasta nueve. Reserva varias
horas y mantén acceso a una terminal. Necesitas permisos de administración,
Incus, git, jq, tmux, cron, Python 3, ShellCheck, GitHub CLI y Claude Code.
La versión mínima de Claude está en el paquete; el primer chequeo la comprueba.
La batería inicial de F0 tarda, en una máquina de 4 núcleos (Intel N100), unos 85
minutos en Ubuntu 24.04 y unos 105 en 26.04; en máquinas rápidas tarda menos.
El comando muestra la duración al terminar.

## En Ubuntu 24.04

Desde una terminal administrativa, instala los requisitos:

```bash
apt-get update && apt-get install -y git jq tmux cron python3 shellcheck unzip curl sudo ca-certificates incus gh nodejs npm iptables btrfs-progs openssh-client procps sed grep gawk findutils tar gzip
npm install -g @anthropic-ai/claude-code
```

En el ensayo con Ubuntu 24.04 se usaron Incus 6.0.0, gh 2.45.0, Node 18.19.1
y Claude Code 2.1.289. En otros sistemas instala los equivalentes.
Como el usuario normal que va a instalar la fábrica, configura tu identidad
de Git con tu nombre y correo reales; F0 comprueba ambos valores:

```bash
git config --global user.name 'Tu nombre'
git config --global user.email 'tu-correo@example.invalid'
```

## En Ubuntu 26.04

Instala los mismos paquetes que en 24.04 más `locales`, y prepara tres cosas
que esta versión trae distintas:

```bash
apt-get update && apt-get install -y git jq tmux cron python3 shellcheck unzip curl sudo ca-certificates incus gh nodejs npm iptables btrfs-progs openssh-client procps sed grep gawk findutils tar gzip locales
npm install -g @anthropic-ai/claude-code
sudo locale-gen en_US.UTF-8 en_GB.UTF-8
```

- **Sudo clásico.** Ubuntu 26.04 trae `sudo-rs`, que no admite las reglas de
  sudoers que escribe F5 (límite de longitud del token). Vuelve al sudo clásico
  con `sudo update-alternatives --config sudo` y elige `sudo.ws`;
  visudo cambia con él (no hace falta una segunda orden).
  Comprueba con `sudo --version`: debe decir `Sudo version`, no `sudo-rs`.
- **Locales.** La batería de F0 usa `en_US.utf8` y `en_GB.utf8`; comprueba con
  `locale -a` que están.
- **Claude Code.** Puedes lanzar F0 desde una sesión de Claude Code: es seguro,
  porque la batería filtra las variables de sesión (las que terminan en
  `_TOKEN`, `_API_KEY`, `_SECRET` o `_PASSWORD`, `AWS_*` y las de GitHub) antes
  de arrancar las suites.

Antes de los 85 a 105 minutos de la batería, F0 comprueba en segundos las
herramientas (las lista todas las ausentes de una vez, con la orden
`apt-get` exacta), Linux, la identidad Git, `gh`, el sudo clásico y los
locales. Si algo falta, se detiene y dice qué.

## Antes de empezar

Prepara un repositorio de producto en GitHub y un equipo y proyecto en Linear.
Esta versión requiere que la rama principal y por defecto del repositorio sea
main. Si tiene otro nombre, tú decides si renombrarla antes del montaje;
el instalador no cambia las ramas automáticamente.
Necesitas cuentas del asistente con capacidad disponible y acceso a CodeRabbit,
el servicio que revisa cambios antes de fusionarlos. Su clave es obligatoria:
esta versión no ofrece una fusión sin ese revisor. Puedes usar Claude como auditor
o una cuenta de Codex, que se mueve entre canales de uno en uno.

Descomprime el paquete en una carpeta permanente, accesible a los usuarios de la
fábrica. No lo muevas después del montaje. Abre Claude Code en esa carpeta y di:

> Eres el CEO, monta la fábrica, pregúntame los datos que necesites del proyecto.

Te preguntará una sola cosa por turno: nombre del proyecto, repositorio, equipo,
usuarios, recursos, cuentas y comprobaciones del producto. Puedes aceptar el
valor propuesto cuando corresponda. Esta primera instalación monta CEO, C1 y M1
en una sola máquina; responde «no» a las ampliaciones ORQ y PM.

Nunca pegues claves, contraseñas ni tokens en la conversación. Los escribirás
tú mismo en la terminal con entrada oculta o en el fichero privado preparado.
Los logins de las cuentas también los haces tú. Antes de crear usuarios,
contenedores o tareas periódicas, verás un plan y aprobarás sus acciones.

Cada fase tiene una comprobación. Si sale roja, el montaje se detiene y conserva
el progreso para retomarlo. Si una respuesta queda retenida, no la repitas:
el instalador deja un informe mecánico y espera ayuda. No uses /clear.

Al terminar F8 la fábrica funciona. La certificación del repositorio queda
PENDIENTE hasta completar instalacion/fases/DESPUES-certificacion.md.
