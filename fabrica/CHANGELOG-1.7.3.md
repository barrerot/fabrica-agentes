# Distribución 1.7.3 — cambios y migración

Base: distribución 1.7.2. Es un arreglo inmediato de lo que bloqueaba F0 en Ubuntu 26.04
y al lanzarla desde una sesión de Claude Code reciente. No añade funciones.

## Cambios

- **Entorno de la batería.** `f0-bateria.sh` ya no pasa a las suites las variables
  que `verificar-runner.sh` trata como credencial (`*_TOKEN`, `*_API_KEY`, `*_SECRET`,
  `*_PASSWORD`, `AWS_*`, `GH_TOKEN`, `GITHUB_TOKEN`, `GOOGLE_APPLICATION_CREDENTIALS`).
  Claude Code exporta `CLAUDE_CODE_MESSAGING_TOKEN` en cada sesión y volvía roja la
  batería entera. El patrón es el mismo que el de la sonda del runner, con una prueba de igualdad.
- **Comprobación previa de la batería.** Antes de los 85 a 105 minutos de la batería, `f0-bateria.sh` corre
  las mismas comprobaciones baratas que `check-F0` (una sola función): herramientas, Linux,
  identidad Git, versión de `gh`, sudo clásico y locales. Si falla alguna, se detiene en segundos
  con el mismo mensaje. Las herramientas ausentes se listan todas a la vez, con la orden
  `sudo apt-get install` exacta.
- **sudo-rs.** Ubuntu 26.04 trae `sudo-rs`, que rechaza las reglas de F5 por la longitud
  del token. F0 y F5 lo detectan y piden volver al sudo clásico con `update-alternatives`.
  La generación de las reglas no cambia. Basta `update-alternatives --config sudo` y elegir
  `sudo.ws`: en Ubuntu 26.04 visudo es esclava de esa alternativa y cambia con ella (issue 9010).
- **Locales.** F0 exige `en_US.utf8` y `en_GB.utf8` en `locale -a` y dice cómo generarlos.
- **Canarios bajo `nohup` (issue 9010).** Quien lanza la batería con `nohup` (o bajo un supervisor
  que ignora `SIGHUP`) heredaba esa señal ignorada y la suite de canarios daba `wait_rc=0` en lugar
  de 129. La fixture lanza ahora el runner con `SIGHUP` restaurado y su oráculo sigue exigiendo 129;
  si aun así falla con `SIGHUP` heredado ignorado, el mensaje nombra la causa.
- **Diagnóstico de los canarios rojos (issue 9010).** Un canario rojo imprimía el diagnóstico de un
  caso anterior («descendientes no verificables»); ahora imprime la salida real de su CLI y la cola de su log.
- **Copia del paquete en las pruebas del instalador (issue 9010).** `paquete_integro` fallaba a veces
  con ENOENT sobre un temporal de `instalacion/estado/` que otra prueba crea y borra mientras se copia.
  Ahora la copia usa la misma lista y la misma función que el manifiesto del núcleo (`nucleo.exclude`):
  un fichero de estado vivo que desaparece no es un error y cualquier otro sí.
- **Tope de la prueba de supervisión (issue 9010).** `tests/remediaciones.py` daba 600 s a
  `test-supervision.sh`, que tarda 800 s en Ubuntu 26.04 y 591 s en 24.04 (host de 4 núcleos); sube a 1600 s.
- **Topes de la batería medidos (issue 9010).** El tope de 5400 s cortaba la batería en Ubuntu 26.04
  (6155 s medidos; 24.04: 5146 s). Los topes pasan a la medida mayor por 1,5: batería 9900 s (constante
  `BATTERY_TIMEOUT` en `fases.py`), fase F0 10200 s y `TF_SUITE_TIMEOUT` por defecto 3060 s (antes 2400).
  Los papeles dicen ahora unos 85 minutos en Ubuntu 24.04 y unos 105 en 26.04, en 4 núcleos (Intel N100).
  Las pruebas del tope leen la constante y no un literal.
- **Documentación.** [EMPIEZA-AQUI.md](EMPIEZA-AQUI.md) gana la sección «En Ubuntu 26.04»;
  F0 cita los requisitos nuevos; F1 describe `waive-cr.sh` como lo que es (una exención por
  PR y SHA con el OK de la persona, no un modo sin revisor); dos citas apuntan al ADR-0043,
  el de la postura de CodeRabbit.

## Migración desde 1.7.2

Cambia el núcleo (`instalacion/scripts/fases.py` y su manifiesto): quien actualice tiene que
repetir F0 con el ZIP nuevo. Quien ya tiene la fábrica instalada no está obligado a actualizar.
