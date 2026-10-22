#!/usr/bin/env python3
"""Contratos unitarios y negativos; dobles del paquete no acreditan verdes de fase.

Los positivos con consumidores íntegros se ejecutan en positivos-fases-reales.py.
"""
import hashlib
import json
import os
from pathlib import Path
import pwd
import shutil
import shlex
import subprocess
import sys
import tempfile
import time
import importlib.util
import inspect
import io
import re
import contextlib
import tarfile
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import patch
from remediaciones import observar, observar_orden, comprobar

# Padres seguros del fixture positivo; los negativos fijan sus modos explícitos.
os.umask(0o022)
PACKAGE = Path(__file__).resolve().parents[1]
PASS = FAIL = 0
LAST = ''
# Estas pruebas miden el ciclo de vida de procesos de la batería, no el host: el preflight de
# herramientas se cubre aparte con dobles (issue 9010), así que se neutraliza en su copia.
SIN_PREFLIGHT = ('    preflight_f0()\n    started = ', '    started = ')
# El tope de la batería es UNA constante con nombre en fases.py (issue 9010). Las simulaciones de timeout
# sustituyen su VALOR, sea cual sea, y fallan en ROJO si no hallan exactamente una sustitución: una
# simulación que no simula nada no puede pasar en silencio.
TOPE_BATERIA = re.compile(r'^(BATTERY_TIMEOUT = )\d+$', re.M)


def simular_timeout(texto, segundos=1):
    """Devuelve `texto` con el valor del tope de la batería cambiado; ValueError si no hay exactamente una."""
    nuevo, hallados = TOPE_BATERIA.subn(r'\g<1>'+str(segundos), texto)
    if hallados != 1:
        raise ValueError('simulación de timeout: se esperaba exactamente 1 sustitución del tope de la batería '
                         '(BATTERY_TIMEOUT) y hubo '+str(hallados))
    return nuevo


def simulacion_timeout(etiqueta, texto):
    """Aplica la simulación; si no sustituye exactamente una vez, el caso sale ROJO con el motivo."""
    global LAST
    try:
        nuevo = simular_timeout(texto)
    except ValueError as error:
        LAST = str(error)
        expect(etiqueta+' simulación de timeout encuentra el tope', False)
        return texto
    expect(etiqueta+' simulación de timeout encuentra el tope', True)
    return nuevo


def diagnostico_impreso():
    """Texto que `expect` imprime bajo un FAIL: el LAST vigente."""
    return 'diagnóstico: '+LAST[:2000]


def expect(label, condition):
    global PASS, FAIL
    if condition:
        PASS += 1
        print('PASS '+label)
    else:
        FAIL += 1
        print('FAIL '+label)
        print(diagnostico_impreso())


def battery_safety_contracts(package, temporary, check, observe):
    """CLI real; solo se sustituye el agregado largo y se acorta su timeout."""
    global LAST
    for case in ('perfil', 'enlace-root', 'enlace-valido', 'dentro-root',
                 'enlace-ancestro', 'inexistente', 'grupo', 'sesion', 'grupo-verde', 'sesion-roja',
                 'sesion-fuera', 'nieto-fuera', 'subreaper-fallo', 'subreaper-ausente'):
        work = temporary/('seguridad-'+case)
        work.mkdir(mode=0o700)
        fixture = work/'paquete'
        shutil.copytree(package, fixture, ignore=shutil.ignore_patterns('.git', '__pycache__', 'estado', 'generado'))
        parent = work/'temporales'
        parent.mkdir(mode=0o700)
        trace = work/'ruta'
        pids = work/'pids'
        marker = work/'copiado'
        source = fixture/'instalacion/scripts/fases.py'
        original = source.read_text().replace(*SIN_PREFLIGHT)
        # El marcador detecta incluso una copia que precediese a un rechazo tardío.
        original = original.replace('def battery_tree(base):',
                                    'def battery_tree(base):\n    Path('+repr(str(marker))+').touch()')
        child = '#!/usr/bin/env bash\npwd > '+shlex.quote(str(trace))+'\n'
        child += 'echo "RESULTADO: PASS=1 FAIL=0 SKIP=0 TOTAL=1"\n'
        expected = {'perfil':'batería: padre temporal con perfiles en ancestros',
                    'enlace-root':'batería: padre temporal enlazado',
                    'enlace-valido':'batería: padre temporal enlazado',
                    'enlace-ancestro':'batería: padre temporal enlazado',
                    'inexistente':'batería: padre temporal no verificable',
                    'dentro-root':'batería: árbol temporal dentro de la instancia',
                    'subreaper-fallo':'batería: descendientes no verificables',
                    'subreaper-ausente':'batería: descendientes no verificables'}
        if case == 'perfil':
            (work/'manifiestos').mkdir()
            (work/'manifiestos/ajeno.perfil.tsv').write_text('tipo\tid\n')
        elif case in ('enlace-root', 'dentro-root'):
            target = fixture/'temporales'
            target.mkdir(mode=0o700)
            if case == 'enlace-root':
                parent.rmdir()
                parent.symlink_to(target, target_is_directory=True)
            else:
                parent = target
        elif case in ('enlace-valido', 'enlace-ancestro'):
            alias = work/'alias'
            alias.symlink_to(parent, target_is_directory=True)
            if case == 'enlace-ancestro':
                (parent/'privado').mkdir(mode=0o700)
                parent = alias/'privado'
            else:
                parent = alias
        elif case == 'inexistente':
            parent.rmdir()
        elif case.startswith('subreaper-'):
            replacement = ('type("Libc", (), {"prctl": staticmethod(lambda *args: -1)})()'
                           if case == 'subreaper-fallo' else 'object()')
            original = original.replace('ctypes.CDLL(None, use_errno=True)', replacement)
        else:
            if case in ('grupo', 'sesion', 'sesion-fuera', 'nieto-fuera'):
                original = simulacion_timeout('F0 seguridad '+case, original)
            descendant = ('import os,time,signal\nfrom pathlib import Path\n'
                          'tree=Path.cwd()\n'
                          + ('os.setsid()\n' if case.startswith('sesion') or case == 'nieto-fuera' else
                             'os.chdir('+repr(str(work))+')\n')
                          + ('os.chdir("/")\n' if case.endswith('-fuera') else '')
                          + 'signal.signal(signal.SIGTERM,signal.SIG_IGN)\n'
                          + 'born=Path("/proc/self/stat").read_text().rsplit(")",1)[1].split()[19]\n'
                          'Path('+repr(str(pids))+').write_text(str(os.getpid())+" " +str(os.getpgrp())+" "+born)\n'
                          'time.sleep(4)\ntree.mkdir(parents=True,exist_ok=True)\n'
                          '(tree/"resto.txt").write_text("resto")\ntime.sleep(20)\n')
            child = ('#!/usr/bin/env bash\npwd > '+shlex.quote(str(trace))+'\n'
                     'python3 -c '+shlex.quote(descendant)+' &\nwait\n')
            if case == 'nieto-fuera':
                launcher = 'import subprocess\nsubprocess.Popen(["python3", "-c", '+repr(descendant)+'])\n'
                child = ('#!/usr/bin/env bash\npwd > '+shlex.quote(str(trace))+'\n'
                         'python3 -c '+shlex.quote(launcher)+'\nsleep 30\n')
            if case in ('grupo-verde', 'sesion-roja'):
                child = child.removesuffix('wait\n')
                child += ('while [ ! -f '+shlex.quote(str(pids))+' ]; do sleep 0.02; done\n'
                          + ('echo "RESULTADO: PASS=1 FAIL=0 SKIP=0 TOTAL=1"\n' if case == 'grupo-verde' else
                             'echo "RESULTADO: PASS=0 FAIL=1 SKIP=0 TOTAL=1"\nexit 1\n'))
        source.write_text(original)
        (fixture/'scripts/run-all-suites.sh').write_text(child)
        env = dict(os.environ, TMPDIR=str(parent))
        def invoke(name, *args):
            global LAST
            result = subprocess.run(['bash', str(fixture/'instalacion/scripts'/(name+'.sh')), *args],
                                    env=env, capture_output=True, text=True, timeout=120)
            LAST = result.stdout+result.stderr
            print('E45ca '+case+' '+name+' rc='+str(result.returncode), flush=True)
            observe('F0', result.returncode, LAST)
            return result.returncode
        check('F0 seguridad sella '+case, invoke('manifiesto-nucleo', '--generar') == 0)
        if case in expected:
            rc = invoke('f0-bateria')
            check('F0 seguridad rechaza '+case, rc == 1 and expected[case] in LAST)
            check('F0 seguridad rechaza antes de copiar '+case, not marker.exists() and not trace.exists())
        else:
            outsider = subprocess.Popen(['sleep', '30'], cwd=work)
            try:
                rc = invoke('f0-bateria')
                receipt = fixture/'instalacion/estado/f0-bateria.json'
                data = json.loads(receipt.read_text()) if receipt.exists() else {}
                wanted_rc = {'grupo-verde':0, 'sesion-roja':1}.get(case, 124)
                check('F0 seguridad resultado '+case, rc == (0 if wanted_rc == 0 else 1) and data.get('rc') == wanted_rc)
                tree = Path(trace.read_text().strip())
                check('F0 seguridad ausencia inmediata '+case, not tree.exists())
                time.sleep(4.2)
                check('F0 seguridad ausencia tardía '+case, not tree.exists() and not list(parent.iterdir()))
                pid, group, born = map(int, pids.read_text().split())
                members = []
                for proc in Path('/proc').iterdir():
                    if proc.name.isdigit():
                        try:
                            fields = (proc/'stat').read_text().rsplit(')', 1)[1].split()
                            if int(fields[2]) == group:
                                members.append(int(proc.name))
                        except (FileNotFoundError, ProcessLookupError):
                            pass
                check('F0 seguridad ningún descendiente '+case, not Path('/proc', str(pid)).exists() and not members)
                check('F0 seguridad conserva proceso ajeno '+case, outsider.poll() is None)
            finally:
                outsider.terminate()
                outsider.wait(timeout=5)
                # Limpiar solo el PID creado por este fixture si una mutación lo dejó vivo.
                if pids.exists():
                    pid, group, born = map(int, pids.read_text().split())
                    try:
                        proc = Path('/proc', str(pid))
                        fields = (proc/'stat').read_text().rsplit(')', 1)[1].split()
                        if proc.stat().st_uid == os.getuid() and int(fields[19]) == born:
                            os.kill(pid, 9)
                    except ProcessLookupError:
                        pass
                    except FileNotFoundError:
                        pass


def canary_cli(package, temporary, observe, name, suite_text=None):
    """Agregado reducido a la suite de canarios, por la CLI de F0; `suite_text` la sustituye en la copia."""
    fixture = temporary/(name+'-paquete')
    shutil.copytree(package, fixture, ignore=shutil.ignore_patterns('.git', '__pycache__', 'estado', 'generado'))
    parent = temporary/(name+'-temporales')
    parent.mkdir(mode=0o700)
    trace = temporary/(name+'-ruta')
    suite = fixture/'tests/scripts/resolve-canarios.sh'
    source = fixture/'instalacion/scripts/fases.py'
    source.write_text(source.read_text().replace(*SIN_PREFLIGHT))
    if suite_text is not None:
        suite.write_text(suite_text)
    digest = hashlib.sha256(suite.read_bytes()).hexdigest()
    (fixture/'scripts/run-all-suites.sh').write_text(
        '#!/usr/bin/env bash\npwd -P > '+shlex.quote(str(trace))+'\n'
        'bash tests/scripts/resolve-canarios.sh\nrc=$?\n'
        'if [ "$rc" -eq 0 ]; then echo "RESULTADO: PASS=1 FAIL=0 SKIP=0 TOTAL=1"; '
        'else echo "RESULTADO: PASS=0 FAIL=1 SKIP=0 TOTAL=1"; fi\nexit "$rc"\n')
    env = dict(os.environ, TMPDIR=str(parent))
    sealed = subprocess.run(['bash', str(fixture/'instalacion/scripts/manifiesto-nucleo.sh'), '--generar'],
                            env=env, capture_output=True, text=True, timeout=60)
    result = subprocess.run(['bash', str(fixture/'instalacion/scripts/f0-bateria.sh')],
                            env=env, capture_output=True, text=True, timeout=150)
    observe('F0', result.returncode, result.stdout+result.stderr)
    receipt = fixture/'instalacion/estado/f0-bateria.json'
    data = json.loads(receipt.read_text()) if receipt.exists() else {}
    text = Path(data['log']).read_text() if 'log' in data else ''
    # El diagnóstico de un FAIL es la salida REAL de esta CLI anidada y de su log, no el rastro
    # del último caso que fijó LAST (antes salía el de subreaper-ausente: «descendientes no verificables»).
    global LAST
    failures = [line for line in text.splitlines() if line.startswith('FALLO ') or 'ERROR_GRUPO_NO_QUIETO' in line]
    LAST = (result.stdout+result.stderr+'--- FALLOS del log anidado ---\n'+'\n'.join(failures[:5])+
            '\n--- cola del log anidado ---\n'+text[-400:])
    return SimpleNamespace(sealed=sealed, result=result, data=data, text=text, suite=suite,
                           digest=digest, trace=trace, parent=parent)


def battery_canary_contracts(package, temporary, check, observe):
    """Agregado reducido con canarios reales e intactos, por la CLI de F0."""
    run = canary_cli(package, temporary, observe, 'canarios')
    check('F0 canarios sella agregado reducido', run.sealed.returncode == 0)
    print('CANARIOS_CLI rc='+str(run.result.returncode)+' recibo_rc='+str(run.data.get('rc')), flush=True)
    print(run.text, flush=True)
    check('F0 canarios CLI y recibo verdes',
          run.result.returncode == 0 and run.data.get('rc') == 0 and run.data.get('FAIL') == 0)
    check('F0 canarios reales sin fallos de grupo',
          not any(line.startswith('FALLO ') for line in run.text.splitlines())
          and 'ERROR_GRUPO_NO_QUIETO' not in run.text
          and 'FALLOS=0' in run.text)
    check('F0 canarios suite intacta', hashlib.sha256(run.suite.read_bytes()).hexdigest() == run.digest)
    check('F0 canarios árbol borrado', run.trace.exists() and not Path(run.trace.read_text().strip()).exists()
          and not list(run.parent.iterdir()))


def battery_canary_diagnostic(package, temporary, check, observe):
    """Con un canario rojo, el diagnóstico que imprime `expect` es el de la CLI anidada, no el de un caso anterior."""
    global LAST
    LAST = 'falla batería: descendientes no verificables'  # rastro de un caso anterior (subreaper-ausente)
    red = ('#!/usr/bin/env bash\n'
           'echo "FALLO canario-falso-9010 out=[real] (esperado [otro])"\n'
           'echo "RESULTADO: OK=0 FALLOS=1"\nexit 1\n')
    run = canary_cli(package, temporary, observe, 'canarios-rojo', suite_text=red)
    shown = diagnostico_impreso()
    print('CANARIOS_ROJO rc='+str(run.result.returncode)+' recibo_rc='+str(run.data.get('rc')), flush=True)
    print(shown, flush=True)
    check('F0 canario rojo: la CLI anidada falla de verdad', run.result.returncode == 1 and run.data.get('rc') == 1)
    check('F0 canario rojo: el diagnóstico impreso es el de su CLI y su log',
          'canario-falso-9010' in shown and 'batería: log=' in shown)
    check('F0 canario rojo: el diagnóstico no es el rancio del caso anterior',
          'descendientes no verificables' not in shown)


def run_nohup_canaries(package, temporary, name, edit=None):
    """Lanza resolve-canarios.sh bajo `nohup` (SIGHUP ignorado heredado) con tiempo acotado; (rc, salida)."""
    nohup = shutil.which('nohup')
    if nohup is None:
        return 127, 'nohup ausente'
    fixture = temporary/(name+'-paquete')
    shutil.copytree(package, fixture, ignore=shutil.ignore_patterns('.git', '__pycache__', 'estado', 'generado'))
    parent = temporary/(name+'-temporales')
    parent.mkdir(mode=0o700)
    suite = fixture/'tests/scripts/resolve-canarios.sh'
    original = suite.read_text()
    mutated = edit(original) if edit else original
    if mutated == original and edit:
        return 125, 'la edición no cambió la suite'
    suite.write_text(mutated)
    try:
        run = subprocess.run([nohup, 'bash', str(suite)], cwd=fixture, env=dict(os.environ, TMPDIR=str(parent)),
                             stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=150)
    except subprocess.TimeoutExpired:
        return 124, 'tiempo agotado'
    return run.returncode, run.stdout+run.stderr


def battery_nohup_canaries(package, temporary, check):
    """El alumno que lanza F0 con nohup hereda SIGHUP ignorado: la suite de canarios debe seguir verde."""
    global LAST
    nohup = shutil.which('nohup')
    probe = subprocess.run([nohup or 'nohup', 'python3', '-c',
                            'import signal; print(signal.getsignal(signal.SIGHUP) == signal.SIG_IGN)'],
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
    LAST = probe.stdout+probe.stderr
    check('F0 canarios nohup deja SIGHUP ignorado (precondición)', probe.stdout.strip() == 'True')
    def resumen(rc, out):
        key = [line for line in out.splitlines() if line.startswith('FALLO ') or 'EXIT independiente (HUP' in line]
        return 'rc='+str(rc)+'\n'+'\n'.join(key[:5])+'\n--- cola ---\n'+out[-400:]
    rc, out = run_nohup_canaries(package, temporary, 'canarios-nohup')
    LAST = resumen(rc, out)
    exit_line = next((line for line in out.splitlines() if 'EXIT independiente (HUP' in line), '')
    check('F0 canarios bajo nohup verdes, EXIT independiente con 129',
          rc == 0 and 'FALLOS=0' in out and exit_line.startswith('OK') and 'wait_rc=129' in exit_line)
    # Mutante: sin el reseteo de SIGHUP del lanzador, el rojo tiene que nombrar la causa.
    def sin_reseteo(text):
        return re.sub(r'^  local lanzador_hup=\(python3 .*\)$', '  local lanzador_hup=(env)', text, flags=re.M)
    rc, out = run_nohup_canaries(package, temporary, 'canarios-nohup-mutante', edit=sin_reseteo)
    LAST = resumen(rc, out)
    check('F0 canarios nohup sin reseteo de SIGHUP: rojo y dice HUP ignorado heredado',
          rc == 1 and 'wait_rc=0' in out and 'HUP_IGNORADO_HEREDADO' in out)


def battery_cleanup_failures(package, temporary, check, observe):
    """Fallos del sistema y recreación simulados; ejecutar la limpieza real."""
    fixture = temporary/'fallos-limpieza'
    shutil.copytree(package, fixture, ignore=shutil.ignore_patterns('.git', '__pycache__', 'estado', 'generado'))
    (fixture/'scripts/run-all-suites.sh').write_text(
        '#!/usr/bin/env bash\necho "RESULTADO: PASS=1 FAIL=0 SKIP=0 TOTAL=1"\n')
    sealed = subprocess.run(['bash', str(fixture/'instalacion/scripts/manifiesto-nucleo.sh'), '--generar'],
                            capture_output=True)
    check('F0 fallos limpieza sella fixture', sealed.returncode == 0)
    spec = importlib.util.spec_from_file_location('limpieza_fixture', fixture/'instalacion/scripts/fases.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    parent = temporary/'padre-limpieza'
    parent.mkdir(mode=0o700)
    def rejected(label, action, diagnostic):
        try:
            action()
        except module.Error as error:
            observe('F0', error.rc, str(error))
            check(label, error.rc == 1 and diagnostic in str(error))
        else:
            check(label, False)
    with patch.object(module.ctypes, 'CDLL', lambda *a, **k: SimpleNamespace(prctl=lambda *a: -1)):
        def unavailable():
            with module.battery_session(parent):
                check('F0 subreaper fallido no arranca hijo', False)
        rejected('F0 rechaza descendientes no verificables', unavailable,
                 'batería: descendientes no verificables')
    calls = []
    def prctl(option, value, *args):
        if option == 37:
            value._obj.value = 1
        else:
            calls.append((option, value))
        return 0
    with patch.object(module.ctypes, 'CDLL', lambda *a, **k: SimpleNamespace(prctl=prctl)):
        with module.battery_session(parent):
            pass
    check('F0 restaura subreaper anterior activo', calls == [(36, 1), (36, 1)])
    proc = temporary/'proc-sintetico'
    proc.mkdir()
    def stat_record(pid, ppid, group, born):
        fields = ['0']*20
        fields[0], fields[1], fields[2], fields[19] = 'S', str(ppid), str(group), str(born)
        entry = proc/str(pid)
        entry.mkdir(exist_ok=True)
        (entry/'stat').write_text(str(pid)+' (fixture) '+' '.join(fields))
    stat_record(101, 1, 101, 10)
    stat_record(102, 101, 999, 20)
    stat_record(103, os.getpid(), 999, 30)
    stat_record(104, 1, 999, 40)
    stat_record(105, 101, 101, 50)
    native_stat = Path.stat
    def proc_stat(path, *args, **kwargs):
        info = native_stat(path, *args, **kwargs)
        if path == proc/'105':
            return SimpleNamespace(st_uid=os.getuid()+1, st_mode=info.st_mode)
        return info
    def proc_path(*args):
        return proc.joinpath(*args[1:]) if args and args[0] == '/proc' else Path(*args)
    with patch.object(module, 'Path', proc_path), patch.object(Path, 'stat', proc_stat):
        check('F0 selección unión ascendencia y adopción solo mismo uid',
              module.battery_processes(101, parent) == {(101, 10), (102, 20), (103, 30)})
        check('F0 identidad estable acepta arranque original', module.battery_identity((102, 20)))
        stat_record(102, 101, 999, 21)
        check('F0 identidad estable rechaza PID reutilizado', not module.battery_identity((102, 20)))
        check('F0 identidad estable rechaza otro uid', not module.battery_identity((105, 50)))
        stat_record(101, os.getpid(), 101, 10)
        stat_record(105, os.getpid(), 999, 50)
        reaped = []
        with patch.object(module.os, 'waitpid', lambda pid, flags: reaped.append((pid, flags))):
            module.battery_reap(SimpleNamespace(pid=101, poll=lambda: None))
        check('F0 recoge todo adoptado sin bloquear y reserva agregado a Popen',
              set(reaped) == {(103, os.WNOHANG), (105, os.WNOHANG)})
    process = subprocess.Popen(['sleep', '30'], cwd=parent, start_new_session=True)
    try:
        with patch.object(module.os, 'killpg', lambda *a: None), patch.object(module.os, 'kill', lambda *a: None), \
                patch.object(module.time, 'monotonic', side_effect=[0, 2, 2, 8]):
            rejected('F0 limpieza imposible roja', lambda: module.battery_stop(process, parent),
                     'batería: descendientes no terminados; conservar árbol temporal')
        check('F0 limpieza imposible conserva árbol', parent.exists())
    finally:
        process.kill()
        process.wait(timeout=5)
    created = []
    mkdtemp = module.tempfile.mkdtemp
    def tracked(*args, **kwargs):
        path = mkdtemp(*args, **kwargs)
        created.append(Path(path))
        return path
    def recreate(seconds):
        if created and not created[-1].exists():
            created[-1].mkdir(mode=0o700)
    with patch.dict(os.environ, TMPDIR=str(parent)), patch.object(module.tempfile, 'mkdtemp', tracked), \
            patch.object(module.time, 'sleep', recreate), patch.object(module, 'preflight_f0', lambda: None, create=True):
        rejected('F0 recreación tras borrado roja', module.battery_run, 'batería: árbol temporal reapareció')
    check('F0 recreación no acredita recibo', not (fixture/'instalacion/estado/f0-bateria.json').exists())
    for tree in created:
        if tree.exists():
            shutil.rmtree(tree)


sys.path.insert(0, str(PACKAGE/'tests/fixtures/instalacion'))
from gh_contrato import validar_orden, respuesta_estricta
from compatibilidad_gh import casos as casos_gh
casos_gh(PACKAGE, expect)

with tempfile.TemporaryDirectory(prefix='fases-') as td:
    tmp = Path(td)
    pkg = tmp/'paquete'
    shutil.copytree(PACKAGE, pkg, ignore=shutil.ignore_patterns('.git', '__pycache__', 'estado', 'generado'))
    # No se toca skills del árbol de trabajo: solo consumidores dobles de esta copia.
    def stub(path, body='exit 0\n'):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#!/usr/bin/env bash\n'+body)

    stub(pkg/'skills/skill-creator/scripts/validate-package.sh')
    # Doble del consumidor: la igualdad real y su diagnóstico se prueban en verify-etapas.py.
    channel_settings = tmp/'canal/home/operador/.claude/settings.json'
    channel_settings.parent.mkdir(parents=True)
    channel_settings.write_text('{}')
    alias_trace = tmp/'verificador-alias.log'
    verify_channels_body = ('if jq -e \' .model == "sonnet" \' "'+str(channel_settings)+'" >/dev/null; then\n'
                            '  echo consulta >> "'+str(alias_trace)+'"\n  exit 1\nfi\nexit 0\n')
    stub(pkg/'skills/talent-channels/scripts/verify.sh', verify_channels_body)
    stub(pkg/'skills/talent-channels/scripts/auth-move.sh')
    battery_stub = ('[ "$TF_PAQUETE_ESTADO" = distribucion ] && [ "$*" = "--sin talent-channels" ] || exit 1\n'
                    'echo ejecucion >> "${TF_SUITES_LOG_DIR%/*}/ejecuciones"\n'
                    'echo bateria-doble-verificada\necho "RESULTADO: PASS=1 FAIL=0 SKIP=1 TOTAL=2"\n')
    stub(pkg/'scripts/run-all-suites.sh', battery_stub)
    clon = tmp/'producto'
    clon.mkdir()
    for path in ('talent-ceo/scripts/lib-perfil.sh', 'talent-ceo/scripts/doctor.sh',
                 'talent-repo-onboarding/scripts/verify-repo-parity.sh',
                 'skill-creator/scripts/validate-package.sh', 'talent-ceo/scripts/bus-leer.sh'):
        stub(clon/'.claude/skills'/path)
    stub(clon/'.claude/skills/talent-channel-operation/scripts/preparar-sesiones.sh')
    shutil.copyfile(PACKAGE/'skills/talent-ceo/scripts/leer-acreditacion.sh',
                    clon/'.claude/skills/talent-ceo/scripts/leer-acreditacion.sh')
    stub(clon/'scripts/verify-handoff.sh', 'echo no-ejecutar-tras-merge >&2; exit 99\n')
    stub(clon/'.claude/skills/talent-ceo/scripts/tablas-cron.sh', 'echo 07,22,37,52\n')
    stub(clon/'.claude/skills/talent-channel-operation/scripts/lib.sh',
         'tco_fixture_secret_scan() { return 0; }\n'
         'tco_pane_busy_from() { read -r st; case "$st" in idle) return 1 ;; busy) return 0 ;; *) return 2 ;; esac; }\n')
    home = tmp/'home'
    home.mkdir()
    actorhomes = tmp/'actores'
    actorhomes.mkdir()
    ceo = pwd.getpwuid(os.getuid()).pw_name
    text = (pkg/'instalacion/tests/fixtures/minima.resp').read_text().replace('usuario_ceo=operador', 'usuario_ceo='+ceo)
    state = pkg/'instalacion/estado'
    state.mkdir(mode=0o700)
    answers = state/'respuestas.resp'
    answers.write_text(text)
    answers.chmod(0o600)
    (state/'contexto.conf').write_text('respuestas='+str(answers)+'\nhome='+str(home)+'\nclon='+str(clon)+'\n')
    projecthome = home/'ejemplo'
    projecthome.mkdir(mode=0o700)
    envfile = projecthome/'.env.local'
    secret = 'valor-sintetico-no-publicar'
    envfile.write_text('GITHUB_TOKEN='+secret+'\nLINEAR_API_KEY='+secret+'\nCODERABBIT_API_KEY='+secret+'\n')
    envfile.chmod(0o600)
    escrow = home/'.config/talent-channels'
    escrow.mkdir(parents=True, mode=0o700)
    for name in ('git-bootstrap-token', 'cuser-pass'):
        (escrow/name).write_text(secret)
        (escrow/name).chmod(0o600)
    (escrow/'channel-profiles.list').write_text('vibe-channel-11=produccion\nvibe-channel-12=produccion\nrunner-ejemplo=runner\n')
    for kind in ('talent-channel-operation', 'talent-orchestrator'):
        configdir = home/'.config'/kind
        configdir.mkdir(mode=0o700, exist_ok=True)
        (configdir/'agents.conf').write_text('TF_MANIFEST="'+str(pkg/'manifiestos/ejemplo.conf')+'"\n')
    (projecthome/'bus').write_text('')
    (projecthome/'bus').chmod(0o660)
    (projecthome/'bus.lock').write_text('')
    (projecthome/'bus.lock').chmod(0o660)
    for user in (ceo, 'ejemplo-c1', 'ejemplo-m1'):
        h = actorhomes/user
        (h/'.claude').mkdir(parents=True)
        (h/'.claude/.credentials.json').write_text('contenido-no-inspeccionado')
        (h/'.claude/.credentials.json').chmod(0o600)
        (h/'.claude.json').write_text('{"preferencia":"conservada"}\n')
        (h/'.config/talent-factory').mkdir(parents=True, exist_ok=True)
        (h/'.config/talent-factory/runtime.conf').write_text('export TA_BUS_STATE_DIR='+str(h/'.local/state/talent-ceo')+'\n'
            'export TA_BUS='+str(projecthome/'bus')+'\nexport TA_BUS_LOCK='+str(projecthome/'bus.lock')+'\n')
        cursor = h/'.local/state/talent-ceo/cursores'
        cursor.mkdir(parents=True)
        cursor.chmod(0o700)
        cursor.parent.chmod(0o700)
        (cursor/({'ejemplo-c1':'C1', 'ejemplo-m1':'M1'}.get(user, 'CEO')+'.cursor')).write_text('0')
        (cursor/({'ejemplo-c1':'C1', 'ejemplo-m1':'M1'}.get(user, 'CEO')+'.bus')).write_text(
            str((projecthome/'bus').stat().st_dev)+':'+str((projecthome/'bus').stat().st_ino))
    (actorhomes/'ejemplo-m1/producto/.git').mkdir(parents=True)
    (actorhomes/'ejemplo-c1/producto/.git').mkdir(parents=True)
    stub(actorhomes/'ejemplo-c1/producto/.claude/skills/talent-channel-operation/scripts/preparar-sesiones.sh')
    (pkg/'manifiestos').mkdir(exist_ok=True)
    generator_spec = importlib.util.spec_from_file_location('generador_fixture', pkg/'instalacion/instalacion.py')
    generator = importlib.util.module_from_spec(generator_spec)
    generator_spec.loader.exec_module(generator)
    with patch.object(generator.pwd, 'getpwnam', lambda user: SimpleNamespace(pw_dir=str(actorhomes/user))):
        public = generator.render(dict(line.split('=', 1) for line in text.splitlines()), pkg, home)
    for rel in ('manifiestos/ejemplo.conf', 'manifiestos/ejemplo.perfil.tsv', 'manifiestos/runner-identity.map'):
        (pkg/rel).write_text(public[rel])
    for directory in (clon, actorhomes/'ejemplo-c1/producto', actorhomes/'ejemplo-m1/producto'):
        (directory/'manifiestos').mkdir(parents=True, exist_ok=True)
        (directory/'manifiestos/ejemplo.perfil.tsv').write_text(public['manifiestos/ejemplo.perfil.tsv'])
    stationdir = actorhomes/'ejemplo-m1/.config/talent-factory'
    stationdir.mkdir(parents=True, exist_ok=True)
    (stationdir/'station.conf').write_text('TF_STATION_HOST=host-example\nTF_CLONE='+str(actorhomes/'ejemplo-m1/producto')+
        '\nTF_MANIFEST='+str(pkg/'manifiestos/ejemplo.conf')+'\nTF_SLUG=org-example/producto\nTF_RUNNER_USER=runner\n'
        'TF_RUNNER_REPO=/home/runner/repo\nTF_RUNNERS=runner-ejemplo\n')
    (stationdir/'station.conf').chmod(0o644)
    stub(pkg/'scripts/seal-suite.sh')
    for kind in ('talent-channel-operation', 'talent-orchestrator'):
        (home/'.config'/kind/'agents.conf').write_text(public['agents.conf']+
                'TF_MANIFEST="'+str(pkg/'manifiestos/ejemplo.conf')+'"\nTCO_PANE_CALIBRATED="claude:2.1.289"\n')
    (pkg/'ledger').mkdir(exist_ok=True)
    (pkg/'ledger/cuentas.json').write_text(json.dumps({
        'coordinator_host':'host-example',
        'pozos': {'p1': {'cuenta':'cuenta1'}, 'p2': {'cuenta':'cuenta2'}},
        'cuentas': [{'alias':'cuenta1', 'tipo':'claude'}, {'alias':'cuenta2', 'tipo':'claude'}]}))
    bindir = tmp/'bin'
    bindir.mkdir()
    for fixture in ('gh_contrato.py', 'gh-2.45.0.json'):
        shutil.copyfile(PACKAGE/'tests/fixtures/instalacion'/fixture, bindir/fixture)
    for tool in ('sudo', 'uname', 'free', 'df', 'claude', 'timeout', 'getent', 'id', 'git', 'tmux', 'crontab', 'incus', 'gh', 'shellcheck', 'stat', 'curl', 'coderabbit', 'test',
                 'iptables', 'unzip', 'node', 'npm', 'ssh', 'ssh-keygen', 'btrfs', 'apt-get', 'ps', 'pgrep', 'sysctl',
                 'locale', 'visudo'):
        shutil.copyfile(PACKAGE/'tests/fixtures/instalacion/cliente.py', bindir/tool)
        (bindir/tool).chmod(0o755)
    for tool in ('bash', 'python3', 'dirname', 'cat', 'cmp', 'sed', 'chmod', 'env', 'jq', 'awk', 'grep', 'wc', 'tail', 'head', 'cut', 'tr', 'sort', 'uniq', 'basename', 'find', 'tar', 'gzip', 'install', 'mktemp', 'flock', 'date', 'mv', 'rm'):
        os.symlink(shutil.which(tool), bindir/tool)
    env = os.environ.copy()
    env.update(PATH=str(bindir), DOBLE_HOME=str(actorhomes), DOBLE_CEO_HOME=str(home),
               DOBLE_CEO_STATE=str(actorhomes/ceo/'.local/state/talent-ceo'), HOME=str(actorhomes/ceo),
               DOBLE_PKG=str(pkg), DOBLE_CLON=str(clon))
    scripts = pkg/'instalacion/scripts'
    for user in (ceo, 'ejemplo-c1', 'ejemplo-m1'):
        subprocess.run(['bash', str(scripts/'modelos-rol.sh'), '--resolver'],
                       env=dict(env, HOME=str(actorhomes/user)), capture_output=True, check=True)

    def cli(name, *args, extra=None):
        global LAST
        e = env.copy()
        if extra:
            e.update(extra)
        # El sellado es operación del empaquetador, con el ledger distribuido.
        ledger = pkg/'ledger/cuentas.json'
        saved_ledger = ledger.read_bytes() if name == 'manifiesto-nucleo' else None
        if saved_ledger is not None:
            ledger.write_bytes((PACKAGE/'ledger/cuentas.json').read_bytes())
        try:
            p = subprocess.run(['/bin/bash', scripts/(name+'.sh'), *map(str, args)], env=e,
                               text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
        finally:
            if saved_ledger is not None:
                ledger.write_bytes(saved_ledger)
        LAST = p.stdout+p.stderr
        observar_orden(nombre=name, args=args, rc=p.returncode, salida=LAST)
        return p.returncode, LAST

    expect('fase inicial F0', cli('estado', 'siguiente') == (0, 'F0\n'))
    expect('no avanzar F3 con F2 pendiente', cli('estado', 'avanzar', 'F3')[0] == 1)
    # La respuesta distinta de OK ahora acredita: el contrato mide compleción.
    rc, out = cli('claude-capacidad')
    expect('capacidad texto real distinto de OK verde', rc == 0 and not out)
    for mode, diagnostic in [('auth', 'credencial rechazada'), ('limite', 'sin cupo ahora'),
                             ('otro', 'otro error (subtype=error_during_execution'),
                             ('invalida', 'JSON inválido o vacío'), ('vacia', 'JSON inválido o vacío'),
                             ('rc', 'rc=7'), ('timeout', 'sin respuesta en 90 s'),
                             ('sin-subtype', 'otro error'), ('result-vacio', 'otro error'),
                             ('result-numero', 'otro error'),
                             ('error-success', 'JSON inválido o vacío'),
                             ('success-error', 'JSON inválido o vacío'),
                             ('two-success', 'JSON inválido o vacío'),
                             ('list', 'JSON inválido o vacío')]:
        rc, out = cli('claude-capacidad', extra={'DOBLE_CAPACIDAD': mode})
        expect('capacidad roja '+mode, rc == 1 and diagnostic in out and
               'Ready when' not in out and 'Invalid OAuth token' not in out)
    login_capacity = actorhomes/ceo/'.claude/.credentials.json'
    login_capacity.rename(login_capacity.with_suffix('.ausente'))
    rc, out = cli('claude-capacidad')
    expect('capacidad sin login ni token sin acreditar', rc == 1 and 'sin acreditar' in out)
    login_capacity.with_suffix('.ausente').rename(login_capacity)
    # Ejecutar solo las funciones/bloques de sonda, sin relanzar terminales.
    probe_home = tmp/'sondas'
    probe_home.mkdir()
    (probe_home/'.claude_token.env').write_text('export CLAUDE_CODE_OAUTH_TOKEN=synthetic-token\n')
    (probe_home/'neutro.token').write_text('synthetic-token')
    orch = pkg/'skills/talent-orchestrator/scripts'
    prelude = ('tco_modelo_read() { echo modelo-neutro; }\n'
               'timeout() { shift; "$@"; }\n'
               'incus() { bash -c "${@: -1}"; }\n'
               'remote_cmd() { printf "%s" "$1"; }\n'
               'ssh() { bash -c "${@: -1}"; }\n'
               'ch=01; CTN=canal; t=torre; tf=fixture; CWD=/fixture; H=example.invalid; S=torre; '
               'ENV_FILE="$HOME/.claude_token.env"; TOKENS_DIR="$HOME"\n')
    for name, failure in [('pozos-install-token.sh', 7), ('pozos-install-token-torre.sh', 5),
                          ('pozos-install-token-remote.sh', 7), ('pozos-rotador.sh', 7)]:
        source = (orch/name).read_text()
        if name == 'pozos-rotador.sh':
            body = next(line for line in source.splitlines() if line.startswith('probe(){'))+'\nprobe neutro\n'
        else:
            body = source[source.rindex('probe_model='):]
        for mode in ('', 'rc'):
            p = subprocess.run(['/bin/bash', '-c', prelude+body],
                               env=dict(env, HOME=str(probe_home), DOBLE_CAPACIDAD=mode),
                               capture_output=True, text=True, timeout=10)
            expect('sonda por rc '+name+' '+(mode or 'texto real'),
                   p.returncode == (failure if mode else 0))

    expect('núcleo se genera solo para fixture', cli('manifiesto-nucleo', '--generar')[0] == 0)
    expect('núcleo fixture íntegro', cli('verificar-nucleo', '--en', pkg)[0] == 0)
    (pkg/'instalacion/generado').mkdir()
    coordination = 'instalacion/generado/anexos/talent-coordination/anexo-ejemplo.md'
    (pkg/coordination).parent.mkdir(parents=True)
    (pkg/coordination).write_text(public[coordination])
    (pkg/'instalacion/generado/dato').write_text('dato público cambiado')
    expect('núcleo excluye generado', cli('verificar-nucleo', '--en', pkg)[0] == 0)
    corefile = pkg/'instalacion/requisitos.env'
    original = corefile.read_bytes()
    corefile.write_bytes(original+b'x')
    rc, out = cli('verificar-nucleo', '--en', pkg)
    expect('núcleo byte cambiado rc1', rc == 1 and 'hash distinto' in out)
    corefile.write_bytes(original)
    expect('núcleo restaurado verde', cli('verificar-nucleo', '--en', pkg)[0] == 0)
    untracked = pkg/'instalacion/scripts/extra.sh'
    untracked.write_text('extra')
    expect('núcleo detecta archivo añadido', cli('verificar-nucleo', '--en', pkg)[0] == 1)
    untracked.unlink()
    expect('F0 sin recibo rojo con orden de regeneración', cli('check-F0')[0] == 1 and
           'recibo ausente' in LAST and 'recolectar.sh F0' in LAST and 'f0-bateria.sh' in LAST)
    expect('F0 batería usa distribución y excluye canales', cli('f0-bateria')[0] == 0)
    receipt_path = state/'f0-bateria.json'
    receipt_text = receipt_path.read_text()
    receipt = json.loads(receipt_text)
    expect('F0 conserva rc contadores fecha log y núcleo', receipt['rc'] == 0 and receipt['FAIL'] == 0 and
           receipt['PASS'] == 1 and receipt['SKIP'] == 1 and 'bateria-doble-verificada' in Path(receipt['log']).read_text() and
           receipt['nucleo_sha256'] == hashlib.sha256((pkg/'instalacion/NUCLEO.sha256').read_bytes()).hexdigest())
    expect('contrato unitario F0 con batería y validador sustituidos', cli('check-F0')[0] == 0)
    for version, rc_expected, diagnostic in (
            ('gh version 2.45.0 (2025-07-18 Ubuntu 2.45.0-1ubuntu0.3)', 0, ''),
            ('gh version 2.44.1', 1, 'versión de gh encontrada 2.44.1; mínima exigida 2.45.0'),
            ('gh version 2.100.0', 0, ''),
            ('salida desconocida', 1, 'versión de gh no verificable')):
        rc, out = cli('check-F0', extra={'DOBLE_GH_VERSION':version})
        expect('F0 versión gh '+version, rc == rc_expected and diagnostic in out)
    rc, out = cli('check-F0', extra={'DOBLE_FALLO':'gh'})
    rc_old, out_old = cli('check-F0', extra={'DOBLE_GH_VERSION':'gh version 2.44.1'})
    expect('F0 mínimo gh nombra versión encontrada mínima y receta Ubuntu', rc_old == 1 and
           'encontrada 2.44.1' in out_old and 'mínima exigida 2.45.0' in out_old and
           'Ubuntu 24.04: sudo apt-get install gh' in out_old and 'gh --version' in out_old)
    expect('F0 cliente gh fallido rojo', rc == 1 and 'versión de gh no verificable' in out)
    requirements = pkg/'instalacion/requisitos.env'
    saved_requirements = requirements.read_text()
    for invalid in ('MIN_GH=x', ''):
        requirements.write_text(saved_requirements.replace('MIN_GH=2.45.0', invalid))
        rc, out = cli('check-F0')
        expect('F0 mínimo gh inválido o ausente '+repr(invalid), rc == 1 and 'requisitos inválidos: MIN_GH' in out)
    requirements.write_text(saved_requirements)
    cli('check-F0', extra={'DOBLE_VERSION':'1.0.0'})
    answers.write_text(text.replace('usuario_ceo='+ceo, 'usuario_ceo=otro-operador'))
    cli('check-F0')
    answers.write_text(text)
    for key, value in [('rc', 1), ('FAIL', 1), ('nucleo_sha256', '0'*64),
                       ('fecha', (datetime.now(timezone.utc)-timedelta(hours=24)).strftime('%Y-%m-%dT%H:%M:%SZ')),
                       ('fecha', (datetime.now(timezone.utc)+timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))]:
        receipt_path.write_text(json.dumps(dict(receipt, **{key:value})))
        expect('F0 rechaza recibo alterado '+key+' '+str(value), cli('check-F0')[0] == 1 and 'f0-bateria.sh' in LAST)
    receipt_path.write_text(receipt_text)
    for patch_receipt, cause in [({'rc':1}, 'rojo'),
                                 ({'fecha':(datetime.now(timezone.utc)-timedelta(hours=25)).strftime('%Y-%m-%dT%H:%M:%SZ')}, 'caducado'),
                                 ({'nucleo_sha256':'0'*64}, 'de otro núcleo'),
                                 ({'log_sha256':'0'*64}, 'inválido')]:
        receipt_path.write_text(json.dumps(dict(receipt, **patch_receipt)))
        expect('F0 diagnóstico de recibo '+cause, cli('check-F0')[0] == 1 and
               'recibo '+cause in LAST and 'recolectar.sh F0' in LAST)
    receipt_path.write_text(receipt_text)
    logfile = Path(receipt['log'])
    logtext = logfile.read_text()
    logfile.write_text('RESULTADO: PASS=0 FAIL=4 SKIP=0 TOTAL=4\n')
    receipt_path.write_text(json.dumps(dict(receipt, rc=1, PASS=0, FAIL=4, SKIP=0,
                                          log_sha256=hashlib.sha256(logfile.read_bytes()).hexdigest())))
    expect('F0 recibo rojo nombra cuatro suites', cli('check-F0')[0] == 1 and
           'recibo rojo: 4 suites fallidas' in LAST and 'recolectar.sh F0' in LAST)
    expect('avance F0 conserva causa del recibo rojo', cli('estado', 'avanzar', 'F0')[0] != 0 and
           'recibo rojo: 4 suites fallidas' in LAST and 'recolectar.sh F0' in LAST)
    logfile.write_text(logtext)
    receipt_path.write_text(receipt_text)
    expect('F0 check no repite batería', cli('check-F0')[0] == 0 and
           (state/'f0-bateria/ejecuciones').read_text().splitlines() == ['ejecucion'])
    for key in ('user.name', 'user.email'):
        expect('F0 exige identidad Git '+key, cli('check-F0', extra={'DOBLE_SIN_IDENTIDAD':key})[0] == 1 and
               'git config --global '+key in LAST)
    battery_path = pkg/'scripts/run-all-suites.sh'
    battery_original = battery_path.read_bytes()
    battery_path.write_text('#!/bin/bash\nexit 99\n')
    # Ningún check ni avance vuelve a ejecutar la batería acreditada.
    expect('F0 check reutiliza recibo sin ejecutar batería', cli('check-F0')[0] == 1 and 'núcleo' in LAST)
    # Se sella el núcleo cambiado: el recibo anterior sigue siendo rojo.
    cli('manifiesto-nucleo', '--generar')
    expect('F0 núcleo nuevo invalida recibo', cli('check-F0')[0] == 1 and 'f0-bateria.sh' in LAST)
    battery_path.write_bytes(battery_original)
    cli('manifiesto-nucleo', '--generar')
    for body, label in [('echo "  FAIL ejemplo: rc=1 log=/fixture/rojo.log"\n'
                         'echo "RESULTADO: PASS=5 FAIL=2 SKIP=0 TOTAL=7"\n'
                         'echo "RESULTADO: PASS=0 FAIL=1 SKIP=0 TOTAL=1"\nexit 1\n', 'fila roja'),
                        ('echo "RESULTADO: PASS=0 FAIL=1 SKIP=0 TOTAL=1"\n', 'FAIL con rc cero'),
                        ('echo resumen-ausente\n', 'sin resumen')]:
        stub(battery_path, body)
        cli('manifiesto-nucleo', '--generar')
        rc, out = cli('f0-bateria')
        failed = json.loads(receipt_path.read_text())
        expect('F0 batería rechaza '+label+' y conserva log', rc == 1 and Path(failed['log']).is_file() and
               'log=' in out and ('FAIL ejemplo' in out and failed['FAIL'] == 1 and failed['PASS'] == 0
                                 if label == 'fila roja' else True))
        expect('F0 recibo rojo bloquea check '+label, cli('check-F0')[0] == 1 and 'f0-bateria.sh' in LAST and
               ('recibo rojo: batería incompleta' in LAST if label == 'sin resumen' else 'recibo rojo:' in LAST))
    battery_path.write_bytes(battery_original)
    cli('manifiesto-nucleo', '--generar')
    # issue 9010: entorno de la batería y preflight barato (F0-04, F0-01, F0-03, F0-05).
    entorno = state/'f0-bateria/entorno'
    stub(battery_path, 'compgen -e > "${TF_SUITES_LOG_DIR%/*}/entorno"\n'
                       'echo "RESULTADO: PASS=1 FAIL=0 SKIP=0 TOTAL=1"\n')
    cli('manifiesto-nucleo', '--generar')

    def caso(nombre, comando, extra, textos, rechaza=True, prohibe=()):
        """Un caso F0: rc y mensaje por la CLI real; la batería no debe arrancar si rechaza."""
        entorno.unlink(missing_ok=True)
        rc, out = cli(comando, extra=extra)
        print('F0CASO '+nombre+' '+comando+' rc='+str(rc), flush=True)
        arranco = entorno.exists()
        expect('F0 '+comando+' '+nombre, rc == (1 if rechaza else 0) and all(t in out for t in textos) and
               not any(t in out for t in prohibe) and (comando != 'f0-bateria' or arranco != rechaza))
        return out
    secretos = {'CLAUDE_CODE_MESSAGING_TOKEN': 'x', 'GH_TOKEN': 'x', 'OTRA_API_KEY': 'x', 'UN_SECRET': 'x',
                'UN_PASSWORD': 'x', 'AWS_REGION': 'x', 'GOOGLE_APPLICATION_CREDENTIALS': 'x'}
    caso('verde con credenciales de sesión', 'f0-bateria', dict(secretos, TF_NO_CREDENCIAL='1'), [], rechaza=False)
    visibles = set(entorno.read_text().split()) if entorno.exists() else set()
    expect('F0 batería no hereda variables de credencial', bool(visibles) and not visibles & set(secretos))
    expect('F0 batería conserva el resto del entorno',
           {'PATH', 'HOME', 'TF_NO_CREDENCIAL', 'TF_PAQUETE_ESTADO'} <= visibles)
    # En Ubuntu 26.04 visudo es esclava de la alternativa sudo: --config visudo da "no alternatives" (issue 9010).
    for nombre, extra, textos, prohibe in (
            ('sudo-rs', {'DOBLE_SUDO_RS': '1'},
             ['sudo-rs', 'update-alternatives --config sudo', 'sudo.ws', 'visudo cambia con él'], ['--config visudo']),
            ('sin en_GB', {'DOBLE_LOCALES': 'C.utf8 en_US.utf8'}, ['en_GB.utf8', 'locale-gen'], [])):
        for comando in ('f0-bateria', 'check-F0'):
            caso(nombre, comando, extra, textos, prohibe=prohibe)
    empieza = (PACKAGE/'EMPIEZA-AQUI.md').read_text()
    expect('F0 EMPIEZA-AQUI no manda a --config visudo', '--config visudo' not in empieza)
    expect('F0 EMPIEZA-AQUI dice que visudo cambia con sudo', 'visudo cambia con él' in empieza)
    for tool in ('tmux', 'incus'):
        (bindir/tool).rename(bindir/('ausente-'+tool))
    for comando in ('f0-bateria', 'check-F0'):
        caso('varias herramientas ausentes', comando, None,
             ['herramienta ausente: tmux, incus', 'sudo apt-get install -y tmux incus'])
    for tool in ('tmux', 'incus'):
        (bindir/('ausente-'+tool)).rename(bindir/tool)
    (bindir/'claude').rename(bindir/'ausente-claude')
    expect('F0 claude ausente no se instala con apt', 'apt-get install -y claude' not in
           caso('claude ausente', 'check-F0', None, ['herramienta ausente: claude', 'Claude Code']))
    (bindir/'ausente-claude').rename(bindir/'claude')
    # Una sola fuente del patrón de credenciales: el de la sonda del runner.
    flt_spec = importlib.util.spec_from_file_location('f0_entorno_fixture', pkg/'instalacion/scripts/fases.py')
    flt = importlib.util.module_from_spec(flt_spec)
    flt_spec.loader.exec_module(flt)
    probe = re.search(r'case "\$name" in ([^)]*)\)', (PACKAGE/'instalacion/scripts/verificar-runner.sh').read_text())
    expect('F0 patrón de credenciales igual al de verificar-runner.sh',
           bool(probe) and getattr(flt, 'CREDENTIAL_ENV', None) == tuple(probe[1].split('|')))
    clean = getattr(flt, 'clean_environment', None)
    expect('F0 filtro quita credenciales y deja el resto', clean is not None and set(clean(
        {'PATH': 1, 'GH_TOKEN': 1, 'X_TOKEN': 1, 'AWS_X': 1, 'A_API_KEY': 1, 'TOKEN_X': 1, 'MY_TOKENS': 1, 'TF_X': 1})) ==
        {'PATH', 'TOKEN_X', 'MY_TOKENS', 'TF_X'})
    rs = getattr(flt, 'sudo_rs', None)
    expect('F0 sudo-rs por versión', rs is not None and rs('sudo-rs 0.2.8', '/usr/sbin/visudo') is True)
    expect('F0 sudo-rs por ruta de visudo', rs is not None and rs('Sudo version 1.9.15p5', '/usr/lib/cargo/bin/visudo') is True)
    expect('F0 sudo clásico no es sudo-rs', rs is not None and rs('Sudo version 1.9.15p5', '/usr/sbin/visudo.ws') is False)
    source_f5 = inspect.getsource(flt.infrastructure)
    expect('F5 comprueba sudo clásico antes de visudo -c', 'require_classic_sudo()' in source_f5 and
           source_f5.index('require_classic_sudo()') < source_f5.index("'visudo'"))
    battery_path.write_bytes(battery_original)
    cli('manifiesto-nucleo', '--generar')
    expect('F0 batería restaurada verde', cli('f0-bateria')[0] == 0)
    timeout_pkg = tmp/'timeout-paquete'
    stub(timeout_pkg/'scripts/run-all-suites.sh', (PACKAGE/'scripts/run-all-suites.sh').read_text())
    stub(timeout_pkg/'skills/talent-context/tests/run-tests.sh',
         'sleep 3\necho "== RESULTADO: 1 ok, 0 FAIL =="\n')
    timeout_env = dict(os.environ, TF_SUITE_TIMEOUT='1', TF_SUITES_LOG_DIR=str(tmp/'timeout-logs'))
    timed = subprocess.run(['timeout', '10', 'bash', str(timeout_pkg/'scripts/run-all-suites.sh'),
                            '--solo', 'talent-context'], env=timeout_env, capture_output=True, text=True)
    timeout_diagnostic = timed.stdout+timed.stderr
    observar('F0', timed.returncode, timeout_diagnostic)
    expect('F0 timeout real conserva rojo y explica la remediación', timed.returncode == 1 and
           'tiempo agotado tras 1 s; la máquina es lenta o la suite se colgó' in timeout_diagnostic)
    (bindir/'incus').rename(bindir/'sin-incus')
    expect('F0 fallo controlado incus ausente rc1', cli('check-F0')[0] == 1)
    (bindir/'sin-incus').rename(bindir/'incus')
    expect('RAM 11 rojo', cli('check-F0', extra={'DOBLE_RAM':'11'})[0] == 1)
    expect('RAM 14 rechaza dos canales', cli('check-F0', extra={'DOBLE_RAM':'14'})[0] == 1)
    answers.write_text(text.replace('canales_n=2', 'canales_n=1'))
    expect('RAM 14 un canal verde', cli('check-F0', extra={'DOBLE_RAM':'14'})[0] == 0)
    answers.write_text(text)
    expect('pool mayor que disco rojo', cli('check-F0', extra={'DOBLE_DISCO':'40'})[0] == 1)
    rc, out = cli('check-F1')
    expect('F1 presente sin valores', rc == 0 and secret not in out and 'GITHUB_TOKEN: present' in out)
    for variable, mode, diagnostic in (
            ('DOBLE_GITHUB', 'rechazado', 'GITHUB_TOKEN: rechazado'),
            ('DOBLE_GITHUB', 'push', 'GITHUB_TOKEN: sin permiso push sobre el repositorio'),
            ('DOBLE_GITHUB', 'admin', 'GITHUB_TOKEN: sin permiso admin sobre el repositorio'),
            ('DOBLE_GITHUB', 'red', 'sin red: GITHUB_TOKEN'),
            ('DOBLE_LINEAR', 'rechazada', 'LINEAR_API_KEY: rechazada'),
            ('DOBLE_LINEAR', 'equipo', 'LINEAR_API_KEY: equipo declarado ausente'),
            ('DOBLE_LINEAR', 'red', 'sin red: LINEAR_API_KEY')):
        rc, out = cli('check-F1', extra={variable:mode})
        expect('F1 diagnóstico '+diagnostic, rc == 1 and diagnostic in out and secret not in out and 'Traceback' not in out)
    for tool in ('iptables', 'btrfs', 'ssh', 'ssh-keygen', 'node', 'npm', 'unzip'):
        (bindir/tool).rename(bindir/('ausente-'+tool))
        rc, out = cli('check-F0')
        expect('F0 detecta herramienta '+tool, rc == 1 and 'herramienta ausente: '+tool in out)
        (bindir/('ausente-'+tool)).rename(bindir/tool)
    expect('F0 mínimo disco único', cli('check-F0', extra={'DOBLE_DISCO':'29'})[0] == 1 and 'mínimo 30 GiB' in LAST)
    answers.write_text(text.replace('pool_gib=300', 'pool_gib=40').replace('canales_n=2', 'canales_n=1'))
    expect('F0 máquina del ensayo 80 GiB válida', cli('check-F0', extra={'DOBLE_DISCO':'78'})[0] == 0)
    expect('F0 exige margen declarado', cli('check-F0', extra={'DOBLE_DISCO':'59'})[0] == 1 and 'menos 20 GiB' in LAST)
    answers.write_text(text)
    exported = home/'.config/talent-channel-operation/agents.conf'
    saved_agents = exported.read_text()
    exported.write_text('\n'.join('export '+line for line in saved_agents.splitlines())+'\n')
    expect('F1 acepta exports de agents.conf', cli('check-F1')[0] == 0)
    exported.write_text(saved_agents+'export MAL="$dato"\n')
    expect('F1 export no literal rechazado', cli('check-F1')[0] == 2 and 'no literal' in LAST)
    exported.write_text(saved_agents)
    bootstrap = escrow/'git-bootstrap-token'
    bootstrap.write_text('otra-credencial-sintetica')
    expect('F1 rechaza bootstrap desactualizado sin valores', cli('check-F1')[0] == 1 and
           'git-bootstrap-token: distinto de GITHUB_TOKEN' in LAST and secret not in LAST)
    bootstrap.write_text(secret)
    for tool, diagnostic in [('uname', 'Linux requerido'), ('free', 'RAM no verificable'),
                             ('df', 'disco no verificable'), ('claude', 'versión de Claude no verificable')]:
        rc, out = cli('check-F0', extra={'DOBLE_FALLO':tool})
        expect('F0 auxiliar rc no cero '+tool, rc == 1 and diagnostic in out)
    validator = pkg/'skills/skill-creator/scripts/validate-package.sh'
    validator_original = validator.read_bytes()
    stub(validator, 'exit 1\n')
    cli('manifiesto-nucleo', '--generar')
    rc, out = cli('check-F0')
    expect('F0 validador rc no cero conserva diagnóstico', rc == 1 and 'validador de paquete rojo' in out)
    validator.write_bytes(validator_original)
    cli('manifiesto-nucleo', '--generar')
    questionnaire = pkg/'instalacion/cuestionario.sh'
    questionnaire_original = questionnaire.read_bytes()
    stub(questionnaire, 'exit 1\n')
    cli('manifiesto-nucleo', '--generar')
    cli('check-F0')
    rc, out = cli('check-F1')
    expect('configuración traduce cuestionario rc no cero', rc == 1 and 'cuestionario pendiente' in out)
    questionnaire.write_bytes(questionnaire_original)
    cli('manifiesto-nucleo', '--generar')
    envfile.chmod(0o644)
    expect('F1 modo inseguro rc1', cli('check-F1')[0] == 1)
    envfile.chmod(0o600)
    envtext = envfile.read_text()
    envfile.write_text(envtext.replace('CODERABBIT_API_KEY='+secret, 'CODERABBIT_API_KEY='))
    rc, out = cli('check-F1')
    expect('F1 fallo controlado clave ausente rc1', rc == 1 and 'CODERABBIT_API_KEY: missing' in out and secret not in out)
    envfile.write_text(envtext)
    envfile.write_text(envtext+'GITHUB_TOKEN=duplicado\n')
    cli('check-F1')
    envfile.write_text(envtext)
    for rel in ('manifiestos/ejemplo.conf', 'manifiestos/ejemplo.perfil.tsv', 'ledger/cuentas.json'):
        path = pkg/rel
        saved_piece = path.read_bytes()
        path.unlink()
        expect('F1 detecta ausencia '+rel, cli('check-F1')[0] == 1)
        path.write_bytes(saved_piece)
    expect('F1 detecta grupo ausente', cli('check-F1', extra={'DOBLE_GRUPOS':'otro'})[0] == 1)
    agentfile = home/'.config/talent-channel-operation/agents.conf'
    agenttext = agentfile.read_text()
    agentfile.write_text(agenttext.replace('TCO_DEV_CARRILES="11 12"', 'TCO_DEV_CARRILES="01"'))
    expect('F1 detecta ruteo incoherente', cli('check-F1')[0] == 1)
    agentfile.write_text(agenttext)
    profilefile = pkg/'manifiestos/ejemplo.perfil.tsv'
    profiletext = profilefile.read_text()
    profilefile.write_text(profiletext.replace('usuario=ejemplo-c1', 'usuario=otro-c1'))
    expect('F1 detecta perfil válido de usuario ajeno', cli('check-F1')[0] == 1)
    profilefile.write_text(profiletext)
    for role, user in (('CEO', ceo), ('C1', 'ejemplo-c1'), ('M1', 'ejemplo-m1')):
        runtime = actorhomes/user/'.config/talent-factory/runtime.conf'
        saved_runtime = runtime.read_text()
        for variable in ('TA_BUS', 'TA_BUS_LOCK'):
            for mutation in ('ausente', 'distinto'):
                lines = []
                for line in saved_runtime.splitlines():
                    if line.startswith('export '+variable+'='):
                        if mutation == 'ausente':
                            continue
                        line = 'export '+variable+'=/ruta/incorrecta'
                    lines.append(line)
                runtime.write_text('\n'.join(lines)+'\n')
                rc, out = cli('check-F5')
                expect('F5 rechaza '+variable+' '+mutation+' '+role,
                       rc == 1 and 'configuración bus distinta: '+role in out)
        runtime.write_text(saved_runtime)
    expect('contrato unitario F5 detecta ctx ausente', cli('check-F5', extra={'DOBLE_SIN_CTX':'1'})[0] == 1)
    actual_state = str(actorhomes/'ejemplo-c1/.local/state/talent-ceo')
    profilefile.write_text(profiletext.replace(actual_state, '/otro/home/.local/state/talent-ceo'))
    for phase in ('F5', 'F6'):
        rc, out = cli('check-'+phase, extra={'DOBLE_FALLO':'git'})
        expect(phase+' rechaza home divergente antes de consultar clones', rc == 1 and
               'estado_bus distinto: C1' in out and actual_state in out and
               '/otro/home/.local/state/talent-ceo' in out and 'generar-instancia.sh' in out)
    profilefile.write_text(profiletext)
    for tool in ('getent', 'gh', 'git', 'coderabbit'):
        cli('check-F5', extra={'DOBLE_FALLO':tool})
    cli('check-F5', extra={'DOBLE_RENDERER':'1'})
    own = actorhomes/'ejemplo-c1/producto'
    own.rename(own.with_name('producto-guardado'))
    cli('check-F5')
    own.with_name('producto-guardado').rename(own)
    prepare_channel = own/'.claude/skills/talent-channel-operation/scripts/preparar-sesiones.sh'
    stub(prepare_channel, 'exit 1\n')
    cli('check-F5')
    stub(prepare_channel)
    cli('check-F4', extra={'DOBLE_ORIGIN':'https://github.com/org-example/otro.git'})
    validator_product = clon/'.claude/skills/skill-creator/scripts/validate-package.sh'
    stub(validator_product, 'exit 1\n')
    cli('check-F4')
    stub(validator_product)
    verify_channels = pkg/'skills/talent-channels/scripts/verify.sh'
    stub(verify_channels, 'exit 1\n')
    cli('manifiesto-nucleo', '--generar')
    cli('check-F2')
    stub(verify_channels)
    cli('manifiesto-nucleo', '--generar')
    stub(verify_channels, '[ "$*" = "--etapa creado" ] && exit 0\n'
         '[ "$*" = "--etapa acreditado" ] && [ "$TCO_MODELOS_REGISTRO" = '+str(actorhomes/'ejemplo-c1/.config/talent-channel-operation/modelos.conf')+' ] || exit 1\n')
    cli('manifiesto-nucleo', '--generar')
    expect('secuencia F2 creado verde con infraestructura doble', cli('check-F2')[0] == 0)
    expect('secuencia F3 logins verde con infraestructura doble', cli('check-F3')[0] == 0)
    expect('secuencia F5 acreditado verde y registro propio de C1', cli('check-F5')[0] == 0)
    guide = (pkg/'instalacion/fases/F5.md').read_text()
    guide_order = next(line for line in guide.splitlines() if line.startswith('bash ') and 'check-F5.sh' in line)
    guide_result = subprocess.run(['bash', '-c', guide_order], env=dict(env, PKG=str(pkg)),
                                  capture_output=True, text=True, timeout=120)
    expect('guía F5 orden literal desde terminal del instalador verde', guide_result.returncode == 0)
    stub(verify_channels, 'exit 1\n')
    rc_verify, out_verify = cli('check-F5')
    expect('F5 verificador rojo cierra fase', rc_verify == 1 and 'verify.sh completo FAIL' in out_verify)
    stub(verify_channels, verify_channels_body)
    cli('manifiesto-nucleo', '--generar')
    cli('check-F3', extra={'DOBLE_INCUS_OPERACION':'claude-capacidad', 'DOBLE_INCUS_CONTENEDOR':'vibe-channel-11'})
    cli('check-F3', extra={'DOBLE_INCUS_OPERACION':'claude-capacidad', 'DOBLE_INCUS_CONTENEDOR':'p1'})
    for mode, diagnostic in [('auth', 'credencial rechazada'), ('limite', 'sin cupo ahora'),
                             ('timeout', 'sin respuesta en 90 s'), ('otro', 'otro error (subtype=error_during_execution')]:
        rc, out = cli('check-F3', extra={'DOBLE_CAPACIDAD': mode})
        expect('F3 conserva diagnóstico seguro '+mode, rc == 1 and diagnostic in out)
    move = pkg/'skills/talent-channels/scripts/auth-move.sh'
    stub(move, 'exit 1\n')
    cli('check-F3')
    stub(move)
    ledger = pkg/'ledger/cuentas.json'
    old_ledger = ledger.read_text()
    invalid_move = json.loads(old_ledger)
    invalid_move['cuentas'][0]['verificado'] = 'sin-health-check'
    ledger.write_text(json.dumps(invalid_move))
    cli('check-F3')
    ledger.write_text(old_ledger)
    rc, out = cli('check-F5', extra={'DOBLE_AVISO':'No, exit'})
    expect('contrato unitario F5 distingue aviso de sesión lista', rc == 1 and 'sesión parada en un aviso: CEO' in out)
    rc, out = cli('check-F6', extra={'DOBLE_FALLO':'stat'})
    auth_rc, auth_out = cli('check-F5', extra={'DOBLE_CR_AUTH':'1'})
    expect('estación con CLI no autenticado cierra fase', auth_rc == 1 and 'CodeRabbit CLI sin autenticación' in auth_out)
    rc_models, out_models = cli('check-F6', extra={'DOBLE_SIN_CRON_MODELOS':'1'})
    expect('cron semanal ausente cierra fase con causa', rc_models == 1 and 'cron modelos ausente o distinto' in out_models)
    rc_tables, out_tables = cli('check-F6', extra={'DOBLE_SIN_CRON_TABLAS':'1'})
    expect('cron de tablas ausente con cron semanal presente cierra fase', rc_tables == 1 and 'cron CRON ausente' in out_tables)
    expect('fallo nombra destino orden y ruta sin clave', rc == 1 and 'destino=' in out and
           'stat' in out and str(actorhomes/ceo/'.local') in out and secret not in out)
    expect('etiqueta ausente bloquea F4', cli('check-F4', extra={'DOBLE_SIN_CR_LABEL':'1'})[0] == 1 and
           'etiqueta cr-review ausente' in LAST)
    rc, out = cli('check-F3', extra={'DOBLE_FALLO':'git'})
    expect('F3 git host auxiliar rc1 nombra rol', rc == 1 and 'git sin autenticación: CEO' in out)
    for operation, diagnostic in [('gh auth status', 'gh sin sesión: canal vibe-channel-11'),
                                  ('ls-remote', 'git sin autenticación: canal vibe-channel-11')]:
        rc, out = cli('check-F3', extra={'DOBLE_INCUS_OPERACION':operation})
        expect('F3 canal auxiliar rc1 '+operation, rc == 1 and diagnostic in out)
    expect('contrato unitario F5 detecta clon de M1 de otro repositorio', cli('check-F5', extra={'DOBLE_ORIGIN':'https://github.com/org-example/otro.git'})[0] == 1)
    rc, out = cli('check-F5', extra={'DOBLE_GIT_OPERACION':'ls-remote'})
    expect('contrato unitario F5 git sin autenticación nombra clon propio', rc == 1 and 'git sin autenticación: C1' in out)
    rc, out = cli('check-F5', extra={'DOBLE_FALLO':'sudo'})
    expect('contrato unitario F5 consulta sudo rechazada nombra rol', rc == 1 and 'limpieza del clon no verificable: C1' in out)
    rc, out = cli('check-F5', extra={'DOBLE_TMUX_SESION':'torre-c1'})
    expect('F5 sesión ausente se comprueba tras acreditar limpieza', rc == 1 and 'sesión ausente: C1' in out)
    rc, out = cli('check-F2', extra={'DOBLE_INCUS_OPERACION':'lg_preflight', 'DOBLE_INCUS_CONTENEDOR':'runner-ejemplo'})
    expect('contrato unitario F2 preflight real sucio bloquea runner', rc == 1 and 'runner preflight sucio' in out)
    for phase in ('F5', 'F6'):
        rc, out = cli('check-'+phase, extra={'DOBLE_GIT_SUCIO': ' M manifiestos/ejemplo.perfil.tsv'})
        expect(phase+' rechaza cambios seguidos', rc == 1 and 'clon con cambios seguidos: CEO' in out)
    rc, out = cli('check-F2', extra={'DOBLE_RUNNER_ORIGIN': 'https://github.com/org-example/otro.git'})
    expect('F2 rechaza origin de runner distinto', rc == 1 and 'runner origin distinto' in out)
    rc, out = cli('check-F5', extra={'DOBLE_INCUS_OPERACION': 'TF_CHECK_REPO_ONLY=1', 'DOBLE_INCUS_CONTENEDOR': 'runner-ejemplo'})
    expect('F5 exige correspondencia del motor real', rc == 1 and 'runner correspondencia del motor fallida' in out)
    station_path = stationdir/'station.conf'
    station_content = station_path.read_text()
    station_path.write_text(station_content.replace('TF_STATION_HOST=host-example', 'TF_STATION_HOST=otro-host'))
    rc, out = cli('check-F5')
    expect('contrato unitario F5 configuración estación distinta bloquea plan', rc == 1 and 'configuración estación distinta' in out)
    station_path.write_text(station_content)
    for phase, tool in [('F2', 'incus'), ('F3', 'gh'), ('F5', 'tmux'), ('F6', 'crontab')]:
        expect('contrato unitario '+phase+' con consumidores sustituidos', cli('check-'+phase)[0] == 0)
        rc, out = cli('check-'+phase, extra={'DOBLE_FALLO':tool})
        expect(phase+' fallo controlado '+tool+' rc1', rc == 1 and 'falla ' in out)
    expect('contrato unitario F2 contenedor ausente rc1', cli('check-F2', extra={'DOBLE_CONTENEDOR_AUSENTE':'golden-ejemplo'})[0] == 1)
    loginfile = actorhomes/'ejemplo-c1/.claude/.credentials.json'
    loginfile.unlink()
    expect('F3 login ausente rc1', cli('check-F3')[0] == 1 and
           'login Claude ausente o modo: C1 (usuario ejemplo-c1)' in LAST and 'Traceback' not in LAST)
    loginfile.write_text('contenido-no-inspeccionado')
    loginfile.chmod(0o600)
    bus_saved = (projecthome/'bus').read_text()
    (projecthome/'bus').unlink()
    expect('contrato unitario F6 bus ausente rc1', cli('check-F6')[0] == 1)
    (projecthome/'bus').write_text(bus_saved)
    (projecthome/'bus').chmod(0o660)
    (projecthome/'bus.lock').chmod(0o600)
    expect('contrato unitario F6 lock inseguro rojo', cli('check-F6')[0] == 1)
    (projecthome/'bus.lock').chmod(0o660)
    cli('check-F6', extra={'DOBLE_ACCESO':'1'})
    cursor = actorhomes/ceo/'.local/state/talent-ceo/cursores'/ 'CEO.cursor'
    for user in (ceo, 'ejemplo-c1', 'ejemplo-m1'):
        role = {'ejemplo-c1':'C1', 'ejemplo-m1':'M1'}.get(user, 'CEO')
        (actorhomes/user/'.local/state/talent-ceo/cursores'/(role+'.bus')).write_text(
            str((projecthome/'bus').stat().st_dev)+':'+str((projecthome/'bus').stat().st_ino))
    role_state = cursor.parent.parent
    for content in ('AUSENTE', 'NO_ACREDITADO', 'ACREDITADO'):
        accredited = role_state/'acreditacion'
        accredited.mkdir(mode=0o700, exist_ok=True)
        file = accredited/'CEO.estado'
        if content == 'AUSENTE':
            file.unlink(missing_ok=True)
        else:
            file.write_text(content+'\n')
        rc, out = cli('check-F6')
        expect('F6 lector real permite '+content, rc == 0)
    parent = role_state.parent
    original_mode = parent.stat().st_mode & 0o777
    parent.chmod(0o777)
    rc, out = cli('check-F6')
    expect('F6 padre escribible por terceros rojo', rc == 1 and 'padres de estado' in out)
    parent.chmod(original_mode)
    parent.chmod(0o775)
    rc, out = cli('check-F6')
    expect('F6 sin preparación rechaza state 775 con grupo primario real',
           rc == 1 and 'padres de estado' in out)
    parent.chmod(original_mode)
    file.write_text('INVALIDO\n')
    rc, out = cli('check-F6')
    expect('F6 lector contenido inválido rojo', rc == 1 and 'contenido inválido' in out)
    file.unlink()
    file.symlink_to('/dev/null')
    rc, out = cli('check-F6')
    expect('F6 lector rc2 rojo', rc == 1 and 'lector acreditación no comprobable' in out)
    file.unlink()
    cursor.write_text('inválido')
    cli('check-F6')
    cursor.write_text('0')
    cursor.rename(cursor.with_suffix('.guardado'))
    cli('check-F6')
    cursor.with_suffix('.guardado').rename(cursor)
    cursor.parent.chmod(0o755)
    cli('check-F6')
    cursor.parent.chmod(0o700)
    cli('cron-tablas', 'CRON', extra={'DOBLE_SIN_CTX':'1'})
    (projecthome/'bus').chmod(0o600)
    expect('contrato unitario F6 bus sin modo compartido rojo', cli('check-F6')[0] == 1)
    (projecthome/'bus').chmod(0o660)
    for user in (ceo, 'ejemplo-c1', 'ejemplo-m1'):
        role = {'ejemplo-c1':'C1', 'ejemplo-m1':'M1'}.get(user, 'CEO')
        (actorhomes/user/'.local/state/talent-ceo/cursores'/(role+'.bus')).write_text(
            str((projecthome/'bus').stat().st_dev)+':'+str((projecthome/'bus').stat().st_ino))
    for phase, consumer in [('F4', 'talent-repo-onboarding/scripts/verify-repo-parity.sh'),
                            ('F7', 'talent-ceo/scripts/doctor.sh')]:
        path = clon/'.claude/skills'/consumer
        expect('contrato unitario '+phase+' traduce rc0 del consumidor doble', cli('check-'+phase)[0] == 0)
        path.unlink()
        expect(phase+' pieza ausente rc1', cli('check-'+phase)[0] == 1)
        stub(path, 'exit 1\n')
        expect(phase+' fallo controlado consumidor rojo rc1', cli('check-'+phase)[0] == 1)
        stub(path, 'exit 2\n')
        expect(phase+' precondición consumidor nunca verde', cli('check-'+phase)[0] == 1)
        stub(path)
    parity_stub = clon/'.claude/skills/talent-repo-onboarding/scripts/verify-repo-parity.sh'
    stub(parity_stub, 'echo "MANUAL [ensayo-e2e]: sin receipt — pendiente"\nexit 3\n')
    rc, out = cli('check-F4')
    expect('F4 acepta rc3 e informa nombres pendientes', rc == 0 and 'manuales pendientes=1 ensayo-e2e' in out)
    stub(parity_stub, 'echo "receipt ensayo-e2e: EXPIRADO"\nexit 3\n')
    rc, out = cli('check-F4')
    expect('F4 cuenta recibos rechazados como pendientes por nombre', rc == 0 and 'manuales pendientes=1 ensayo-e2e' in out)
    stub(parity_stub)
    expect('hash canal distinto rc1', cli('verificar-nucleo', '--en', 'vibe-channel-11', extra={'DOBLE_FALLO':'incus'})[0] == 1)
    missing = pkg/'instalacion/NUCLEO.sha256'
    backup = missing.read_text()
    missing.unlink()
    expect('NUCLEO ausente rojo', cli('check-F0')[0] == 1)
    missing.write_text(backup)
    expect('f1 sin terminal rc2 y sin secreto', cli('f1-credenciales')[0] == 2 and secret not in cli('f1-credenciales')[1])
    for name, mode in [('f2-provision', '--plan'), ('f5-torres', '--plan'), ('f5-torres', '--plan-usuarios'),
                       ('f6-bus', '--plan'), ('f3-canales', '--plan')]:
        rc, out = cli(name, mode)
        expect(name+' '+mode+' no imprime secreto', rc == 0 and secret not in out)
    expect('F8 fallo controlado evidencia ausente rc1', cli('check-F8')[0] == 1)
    humo = state/'humo'
    humo.mkdir(mode=0o700)
    captures = state/'pane/claude_2.1.289'
    captures.mkdir(parents=True, mode=0o700)
    captures.parent.chmod(0o700)
    for name in ('idle', 'busy', 'done', 'modal', 'redraw'):
        (captures/(name+'.txt')).write_text(('idle' if name == 'done' else name)+'\n')
    etapas = []
    outcomes = dict(zip(('issue', 'plan-gate', 'codigo', 'auditoria', 'handoff', 'merge', 'Done'),
                        ('CREADA', 'GO', 'DOCS', 'GO', 'PASS', 'MERGED', 'Done')))
    receipts = {}
    initial_issue = {'data': {'issue': {'identifier':'ABC-1', 'title':'Documentar prueba',
                                      'createdAt':'2026-10-04T12:00:00Z'}}}
    done_issue = json.loads(json.dumps(initial_issue))
    done_issue['data']['issue']['state'] = {'name':'Done'}
    plan_text = '# Plan — ABC-1 · Documentar una prueba (docs/humo.md)\n\n## Contexto\n\nCambiar un fichero Markdown bajo docs/.\n'
    run_id = 'tco_1234567890_abcdef123456'
    verdict = {'run_id':run_id, 'artifact_type':'code', 'artifact_sha':'a'*40,
               'verdict':'GO', 'blocking_findings':[]}
    (humo/'veredicto-plan.txt').write_text(json.dumps(dict(verdict, artifact_type='plan',
        artifact_sha=hashlib.sha256(plan_text.encode()).hexdigest())))
    (humo/'audit-last.env').write_text('RUN_ID='+run_id+'\nSHA='+'a'*40+'\nTYP=code\nTS=2026-10-05T06:23:39Z\n')
    fixed_names = {'issue':'issue.json', 'plan-gate':'plan-normalizado.norm', 'codigo':'informe-parada.md',
                   'auditoria':'veredicto-codigo.txt', 'merge':'merge.json', 'Done':'issue-done.json'}
    raw_texts = {'issue':json.dumps(initial_issue), 'plan-gate':plan_text,
                 'codigo':'STOP-AUDIT — ABC-1 · informe pre-push\n· SHA auditado: '+'a'*40+'\n',
                 'auditoria':json.dumps(verdict), 'Done':json.dumps(done_issue),
                 'merge':json.dumps({'number':1, 'state':'MERGED', 'headRefOid':'a'*40,
                     'mergeCommit':{'oid':'b'*40}, 'body':'Closes ABC-1', 'files':[{'path':'docs/humo.md'}],
                     'statusCheckRollup':[{'context':'local-gates', 'state':'SUCCESS'}]})}
    for stage in ('issue', 'plan-gate', 'codigo', 'auditoria', 'handoff', 'merge', 'Done'):
        p = humo/(stage+'.txt')
        receipts[stage] = json.dumps({'issue':'ABC-1', 'head':'a'*40, 'resultado':outcomes[stage],
                                     'pr':1, 'evidencia':str(humo/(stage+'-original.json'))})
        p.write_text(receipts[stage])
        original = {'issue':'ABC-1', 'head':'a'*40, 'pr':1, 'resultado':outcomes[stage], 'autor':'operador-example'}
        raw = humo/(stage+'-raw.json')
        raw.write_text(raw_texts.get(stage, json.dumps(original)))
        if stage in fixed_names:
            (humo/fixed_names[stage]).write_bytes(raw.read_bytes())
        aux_names = {'plan-gate':['veredicto-plan.txt'], 'auditoria':['audit-last.env']}.get(stage, [])
        original['auxiliares'] = {name:hashlib.sha256((humo/name).read_bytes()).hexdigest() for name in aux_names}
        original.update(artefacto=str(raw), sha256=hashlib.sha256(raw.read_bytes()).hexdigest())
        if stage == 'handoff':
            original.update(comando='verify-handoff.sh', rc=0, estado_pr='DRAFT', pr_estable=True)
        original_path = humo/(stage+'-original.json')
        if stage == 'handoff':
            original_path = humo/('handoff-ABC-1-pr1-'+'a'*40+'-1.json')
            receipts[stage] = json.dumps({'issue':'ABC-1', 'head':'a'*40, 'resultado':'PASS',
                                         'pr':1, 'evidencia':str(original_path)})
            p.write_text(receipts[stage])
        original_path.write_text(json.dumps(original))
        original_path.chmod(0o600)
        etapas.append({'etapa':stage, 'archivo':p.name, 'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
    cycle = {'issue':'ABC-1', 'pr':1, 'head':'a'*40, 'merge':'b'*40, 'etapas':etapas}
    (humo/'ciclo.json').write_text(json.dumps(cycle))
    (humo/'Done.json').write_text(json.dumps({'data': {'issue': {'identifier':'ABC-1', 'state':{'name':'Done'}}}}))
    expect('F8 ciclo íntegro y remoto doble verde', cli('check-F8')[0] == 0)
    expect('checks ajenos rojos y pendientes no bloquean', cli('check-F8', extra={
        'DOBLE_CHECKS_AJENOS':json.dumps([{'name':'workflow-propio', 'conclusion':'FAILURE'},
                                       {'context':'revision-app', 'state':'PENDING'}])})[0] == 0 and
           'workflow-propio estado=FAILURE' in LAST and 'revision-app estado=PENDING' in LAST)
    expect('local-gates rojo cierra F8', cli('check-F8', extra={'DOBLE_LOCAL_STATE':'FAILURE'})[0] == 1)
    for mutated in (dict(cycle, agregado=True), dict(cycle, issue='OTRO-1'), dict(cycle, pr=0)):
        (humo/'ciclo.json').write_text(json.dumps(mutated))
        cli('check-F8')
    (humo/'ciclo.json').write_text(json.dumps(cycle))
    cli('check-F8', extra={'DOBLE_PR_STATE':'OPEN'})
    cli('check-F8', extra={'DOBLE_PR_FILE':'src/codigo.py'})
    original_plan = humo/'plan-gate-original.json'
    saved_plan = original_plan.read_text()
    original_plan.write_text('')
    cli('check-F8')
    original_plan.write_text(saved_plan)
    handoff_record = humo/('handoff-ABC-1-pr1-'+'a'*40+'-1.json')
    saved_handoff = handoff_record.read_text()
    failed_handoff = handoff_record.with_name(handoff_record.name.replace('-1.json', '-2.json'))
    failed_handoff.write_text(json.dumps(dict(json.loads(saved_handoff), rc=1, resultado='FAIL')))
    failed_handoff.chmod(0o600)
    expect('F8 check conserva verde aunque exista otro intento fallido', cli('check-F8')[0] == 0)
    moved_handoff = handoff_record.with_suffix('.guardado')
    handoff_record.rename(moved_handoff)
    expect('F8 check exige verde del head fusionado', cli('check-F8')[0] == 1 and 'no hay intento verde' in LAST)
    moved_handoff.rename(handoff_record)
    for key, value in (('rc', 1), ('estado_pr', 'MERGED'), ('head', 'c'*40), ('pr', 2), ('issue', 'ABC-2')):
        bad = json.loads(saved_handoff)
        bad[key] = value
        handoff_record.write_text(json.dumps(bad))
        expect('F8 rechaza registro handoff con '+key+' distinto', cli('check-F8')[0] == 1)
    handoff_record.write_text(saved_handoff)
    real_capture_bytes = {n:(captures/(n+'.txt')).read_bytes() for n in ('idle', 'busy', 'modal', 'redraw')}
    for n in real_capture_bytes:
        (captures/(n+'.txt')).write_bytes((PACKAGE/'skills/talent-channel-operation/tests/fixtures/pane/synthetic_0.0.0'/(n+'.txt')).read_bytes())
    expect('rechaza juego sintético renombrado como CLI instalado', cli('check-F8')[0] == 1)
    for n, content in real_capture_bytes.items():
        (captures/(n+'.txt')).write_bytes(content)
    origin = humo/'plan-gate-original.json'
    origin.rename(humo/'guardado.json')
    expect('rechaza procedencia inexistente con hash correcto', cli('check-F8')[0] == 1)
    (humo/'guardado.json').rename(origin)
    raw = humo/'plan-gate-raw.json'
    raw.rename(humo/'raw-guardado.json')
    expect('rechaza registro sin artefacto original real', cli('check-F8')[0] == 1)
    (humo/'raw-guardado.json').rename(raw)
    expect('exige local-gates por nombre', cli('check-F8', extra={'DOBLE_STATUS':'otro-verde'})[0] == 1)
    expect('exige vínculo PR issue', cli('check-F8', extra={'DOBLE_PR_BODY':'Closes ABC-2'})[0] == 1)
    (captures/'busy.txt').unlink()
    expect('captura real ausente rojo', cli('check-F8')[0] == 1)
    (captures/'busy.txt').write_text('idle\n')
    expect('captura mal clasificada rojo', cli('check-F8')[0] == 1)
    (captures/'busy.txt').write_text('busy\n')
    for n, stage in enumerate(etapas):
        altered = dict(cycle, etapas=etapas[:n]+etapas[n+1:])
        (humo/'ciclo.json').write_text(json.dumps(altered))
        expect('falta '+stage['etapa']+' rojo', cli('check-F8')[0] == 1)
    (humo/'ciclo.json').write_text(json.dumps(cycle))
    (humo/'auditoria.txt').write_text('mutación')
    expect('evidencia alterada rojo', cli('check-F8')[0] == 1)
    (humo/'auditoria.txt').write_text(receipts['auditoria'])
    wrong = json.loads(receipts['plan-gate'])
    wrong['resultado'] = 'NO-GO'
    (humo/'plan-gate.txt').write_text(json.dumps(wrong))
    changed = json.loads(json.dumps(cycle))
    changed['etapas'][1]['sha256'] = hashlib.sha256((humo/'plan-gate.txt').read_bytes()).hexdigest()
    (humo/'ciclo.json').write_text(json.dumps(changed))
    expect('plan NO-GO con hash correcto rojo', cli('check-F8')[0] == 1)
    (humo/'plan-gate.txt').write_text(receipts['plan-gate'])
    (humo/'ciclo.json').write_text(json.dumps(cycle))
    expect('consulta remota fallida rojo', cli('check-F8', extra={'DOBLE_FALLO':'gh'})[0] == 1)
    expect('Linear no verificable rojo', cli('check-F8', extra={'DOBLE_FALLO':'curl'})[0] == 1)
    helper_env = {'F8_ISSUE':'ABC-1', 'F8_PR':'1'}
    (humo/'ciclo.json').unlink()
    (humo/'issue.json').rename(humo/'issue-guardada.json')
    expect('ciclo rechaza etapas sin originales ni recibos', cli('f8-ciclo', extra=helper_env)[0] == 1)
    (humo/'issue-guardada.json').rename(humo/'issue.json')
    outside_issue = tmp/'artefacto-ajeno.txt'
    outside_issue.write_text('ABC-2 trabajo de otro ciclo\n')
    expect('recibo rechaza artefacto de otra issue', cli('f8-recibo', 'issue', outside_issue, 'operador', extra=helper_env)[0] == 1)
    for stage in ('issue', 'plan-gate', 'codigo', 'auditoria', 'handoff', 'merge', 'Done'):
        source = handoff_record if stage == 'handoff' else humo/(stage+'-raw.json')
        expect('recibo desde original '+stage, cli('f8-recibo', stage, source, 'operador', extra=helper_env)[0] == 0)
    expect('ciclo íntegro desde ayudantes', cli('f8-ciclo', extra=helper_env)[0] == 0)
    expect('check-F8 acepta recibos calculados', cli('check-F8')[0] == 0)
    built_cycle = (humo/'ciclo.json').read_bytes()
    missing_receipt = humo/'codigo-recibo.json'
    missing_receipt.rename(humo/'codigo-guardado.json')
    missing_original = humo/'informe-parada.md'
    missing_original.rename(humo/'informe-guardado.md')
    expect('ciclo rechaza una etapa ausente', cli('f8-ciclo', extra=helper_env)[0] == 1)
    (humo/'informe-guardado.md').rename(missing_original)
    (humo/'codigo-guardado.json').rename(missing_receipt)
    artifact = humo/'codigo-artefacto.txt'
    original_artifact = artifact.read_bytes()
    artifact.write_text('ABC-1 original alterado\n')
    expect('ciclo rechaza hash de original alterado', cli('f8-ciclo', extra=helper_env)[0] == 1)
    artifact.write_bytes(original_artifact)
    expect('ciclo idempotente conserva índice', cli('f8-ciclo', extra=helper_env)[0] == 0 and
           (humo/'ciclo.json').read_bytes() == built_cycle)
    for n in range(9):
        rc, out = cli('estado', 'avanzar', 'F'+str(n))
        expect('cadena avanza con check F'+str(n)+(' con alias posterior a F5' if n > 5 else ''),
               rc == 0 and (n <= 5 or not alias_trace.exists()))
        if n == 5:
            channel_settings.write_text(json.dumps({'model':'sonnet'}))
            rc_alias, out_alias = cli('check-F5')
            expect('F5 ya avanzada: alias haría rojo al repetir su check',
                   rc == 0 and rc_alias == 1 and 'verify.sh completo FAIL' in out_alias and alias_trace.exists())
            alias_trace.unlink()
    channel_settings.write_text('{}')
    expect('avance F0 no repite batería', (state/'f0-bateria/ejecuciones').read_text().splitlines() ==
           ['ejecucion', 'ejecucion'])
    rc, out = cli('estado', 'siguiente')
    expect('reanuda COMPLETO y declara certificación pendiente', rc == 0 and out.startswith('COMPLETO\n') and 'PENDIENTE' in out)
    expect('cadena íntegra tras nueve fases', cli('estado', 'verificar')[0] == 0)
    expect('reabrir F3 invalida 3..8', cli('estado', 'reabrir', 'F3')[0] == 0 and cli('estado', 'siguiente') == (0, 'F3\n'))
    rc, out = cli('estado', 'avanzar', 'F3', extra={'DOBLE_FALLO':'gh'})
    expect('check actual rojo no avanza', rc == 1 and cli('estado', 'siguiente') == (0, 'F3\n'))
    events = state/'fases.tsv'
    saved = events.read_text() if events.exists() else ''
    events.write_text(saved.replace('VERDE', 'ROJO', 1))
    expect('cadena editada detectada', cli('estado', 'verificar')[0] == 1)
    events.write_text(saved)
    expect('cadena restaurada verde', cli('estado', 'verificar')[0] == 0)
    expect('STOP se sella', cli('estado', 'stop', 'F3')[0] == 0)
    expect('STOP impide reanudación', cli('estado', 'siguiente')[0] == 1)
    expect('STOP impide reabrir', cli('estado', 'reabrir', 'F3')[0] == 1)
    expect('STOP impide avanzar', cli('estado', 'avanzar', 'F3')[0] == 1)
    expect('STOP conserva cadena válida', cli('estado', 'verificar')[0] == 0)
    rc, out = cli('recolectar', 'F3')
    report = state/'recoleccion-F3.txt'
    expect('recolector privado sin secretos', rc == 0 and report.is_file() and
           report.stat().st_mode & 0o777 == 0o600 and secret not in report.read_text())
    for label, name, linked, expected_rc in (
            ('regular', 'humo/adjunto.txt', False, 0),
            ('escape', '../escape.txt', False, 1),
            ('enlace', 'humo/enlace', True, 1)):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w') as archive:
            entry = tarfile.TarInfo(name)
            if linked:
                entry.type = tarfile.SYMTYPE
                entry.linkname = '/fixture-inexistente'
                archive.addfile(entry)
            else:
                content = b'ABC-1 evidencia durable\n'
                entry.size = len(content)
                archive.addfile(entry, io.BytesIO(content))
        p = subprocess.run(['/bin/bash', str(scripts/'f8-importar.sh')], env=env, input=buffer.getvalue(),
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        expect('F8 importación '+label+' rc correcto', p.returncode == expected_rc)
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w') as archive:
        entry = tarfile.TarInfo('humo/nuevo-original.txt')
        entry.size = 6
        archive.addfile(entry, io.BytesIO(b'ABC-1\n'))
        link = tarfile.TarInfo('humo/nuevo-enlace.txt')
        link.type, link.linkname = tarfile.SYMTYPE, 'nuevo-original.txt'
        archive.addfile(link)
    before = {str(p):p.read_bytes() for p in state.rglob('*') if p.is_file()}
    p = subprocess.run(['/bin/bash', str(scripts/'f8-importar.sh')], env=env, input=buffer.getvalue(),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    expect('F8 enlace resoluble rechazado con diagnóstico de tipo', p.returncode == 1 and
           b'enlace o tipo no permitido' in p.stderr)
    expect('F8 enlace resoluble deja cero escrituras', before ==
           {str(p):p.read_bytes() for p in state.rglob('*') if p.is_file()})
    docs = [pkg/'CLAUDE.md', pkg/'EMPIEZA-AQUI.md', *sorted((pkg/'instalacion/fases').glob('F*.md'))]
    expect('lint documentos íntegros', cli('lint-md', *docs)[0] == 0)
    expect('lint sin argumentos revisa todas las guías', cli('lint-md')[0] == 0)
    expect('lint sin argumentos recorre las guías publicadas', cli('lint-md')[0] == 0)
    for phase, mutation, expected in (
            ('F5', lambda s: s.replace('done\n```', 'done\nbash "$CLON/.claude/skills/talent-channels/scripts/verify.sh"\n```'), 'verify sin entorno'),
            ('F8', lambda s: s.replace('PKG=/srv/fabrica/talent-factory\n', '', 1), 'PKG'),
            ('F8', lambda s: s.replace('<!-- terminal: C1 -->\n```bash\nPAR=',
                                      '<!-- terminal: actor -->\n```bash\nPKG=/srv/fabrica/talent-factory\nCLON=/srv/producto\nPAR='), 'EVIDENCIAS')):
        guide = tmp/(phase+'.md')
        guide.write_text(mutation((pkg/'instalacion/fases'/(phase+'.md')).read_text()))
        rc, out = cli('lint-md', guide)
        expect('guía terminal aislada rechaza '+expected, rc == 1 and expected in out)
    expect('guía F0 incluye receta de gh para Ubuntu 24.04',
           'Ubuntu 24.04' in (pkg/'instalacion/fases/F0.md').read_text() and
           'sudo apt-get install gh' in (pkg/'instalacion/fases/F0.md').read_text())
    newrow = tmp/'F5.md'
    newrow.write_text((pkg/'instalacion/fases/F5.md').read_text().replace('## Al terminar',
                     '| diagnóstico nuevo sin caso | Reparar. |\n\n## Al terminar'))
    rc, out = cli('lint-md', newrow)
    expect('lint exige caso para cada fila de remediación', rc == 1 and 'fila sin caso F5' in out)
    aviso = tmp/'F4.md'
    aviso.write_text((pkg/'instalacion/fases/F4.md').read_text().replace('AVISO:', 'FALLO:'))
    expect('lint distingue fila informativa', cli('lint-md', aviso)[0] == 1 and 'clase aviso/fallo' in LAST)
    badmd = tmp/'F0.md'
    badmd.write_text('# vacío\n')
    expect('lint detecta secciones ausentes', cli('lint-md', badmd)[0] == 1)
    for command in ('bash "$PKG/instalacion/scripts/estado.sh siguiente"',
                    'bash "$PKG/instalacion/scripts/inexistente.sh"',
                    'bash "$PKG/instalacion/scripts/estado.sh" inventado',
                    'bash "$PKG/instalacion/scripts/estado.sh" siguiente\necho "',
                    'if true; then\necho incompleto'):
        badmd = tmp/'comandos.md'
        badmd.write_text('```bash\n'+command+'\n```\n')
        expect('lint rechaza comando inválido '+command, cli('lint-md', badmd)[0] == 1)
    expect('instrucción una pregunta y cuestionario real', 'Una pregunta por turno' in (pkg/'CLAUDE.md').read_text() and
           'cuestionario.sh' in (pkg/'CLAUDE.md').read_text())

    # Dobles de procesos/usuarios para las rutas privilegiadas. Todo filesystem es fixture.
    spec = importlib.util.spec_from_file_location('montaje_fixture', scripts/'fases.py')
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    ownhome = tmp/'propietario-real'
    ownhome.mkdir()
    real_owner = pwd.getpwuid(os.getuid())
    captured = []
    def capture_seed(args, **_):
        captured.append(args)
        raise RuntimeError('orden capturada')
    with patch.object(mod, 'run', capture_seed):
        try:
            mod.seed({'answers': {'cuser': real_owner.pw_name}}, 'fixture')
        except RuntimeError:
            pass
    seed_script = captured[0][6]
    seedhome = tmp/'nucleo-real'
    result = subprocess.run(['/bin/bash', '-c', seed_script, '_', str(seedhome), real_owner.pw_name],
                            capture_output=True)
    expect('núcleo nuevo propietario y 0755 reales', result.returncode == 0 and
           seedhome.stat().st_uid == os.getuid() and seedhome.stat().st_mode & 0o777 == 0o755)
    (seedhome/'conservar').write_text('dato')
    result = subprocess.run(['/bin/bash', '-c', seed_script, '_', str(seedhome), 'root'], capture_output=True)
    expect('núcleo ajeno real se conserva antes de limpiar', result.returncode != 0 and
           (seedhome/'conservar').read_text() == 'dato' and seedhome.stat().st_uid == os.getuid())
    seedlink = tmp/'nucleo-enlace'
    seedlink.symlink_to(seedhome, target_is_directory=True)
    result = subprocess.run(['/bin/bash', '-c', seed_script, '_', str(seedlink), real_owner.pw_name], capture_output=True)
    expect('núcleo enlazado no retira contenido', result.returncode != 0 and
           (seedhome/'conservar').read_text() == 'dato')
    with patch.object(mod.pwd, 'getpwnam', lambda _: real_owner):
        mod.role_directory(ownhome, ownhome/'.local/state/talent-ceo', 'actor')
        expect('creación cadena con stat real propietario y modos', all(
            p.stat().st_uid == os.getuid() and p.stat().st_mode & 0o777 == mode
            for p, mode in ((ownhome/'.local', 0o755), (ownhome/'.local/state', 0o755),
                            (ownhome/'.local/state/talent-ceo', 0o700))))
        (ownhome/'.local').chmod(0o750)
        mod.role_directory(ownhome, ownhome/'.local/state/talent-ceo', 'actor')
        expect('padre existente conserva modo legítimo', (ownhome/'.local').stat().st_mode & 0o777 == 0o750)
        (ownhome/'enlace').symlink_to(ownhome/'.local', target_is_directory=True)
        rejected = False
        try:
            mod.role_directory(ownhome, ownhome/'enlace/estado', 'actor')
        except mod.Error:
            rejected = True
        expect('creación rechaza enlace sin seguirlo', rejected and not (ownhome/'.local/estado').exists())
    with patch.object(mod.pwd, 'getpwnam', lambda _: SimpleNamespace(pw_uid=os.getuid()+1, pw_gid=os.getgid())):
        rejected = False
        before = ownhome.stat()
        try:
            mod.role_directory(ownhome, ownhome/'ajeno/nuevo', 'actor')
        except mod.Error:
            rejected = True
        expect('dueño ajeno real no se adjudica ni crea', rejected and not (ownhome/'ajeno').exists() and
               ownhome.stat().st_uid == before.st_uid and ownhome.stat().st_mode == before.st_mode)
    sys.modules['fases'] = mod
    sys.path.insert(0, str(scripts))
    auth_home = tmp/'auth-home'
    auth_home.mkdir()
    auth_bin = tmp/'auth-bin'
    auth_bin.mkdir()
    stub(auth_bin/'coderabbit', '[ "$*" = "auth status" ] || exit 9\nexit "${AUTH_RC:-0}"\n')
    (auth_bin/'coderabbit').chmod(0o755)
    auth_env = dict(os.environ, HOME=str(auth_home), PATH=str(auth_bin)+':'+os.environ['PATH'])
    auth_source = auth_home/'fixture.env'
    auth_source.write_text('CODERABBIT_API_KEY=revision-sintetica\n')
    auth_source.chmod(0o600)
    auth_script = PACKAGE/'skills/talent-channels/scripts/coderabbit-auth.sh'
    auth = subprocess.run(['bash', str(auth_script), str(auth_source)], env=auth_env, capture_output=True)
    expect('autenticación por método compartido sin salida secreta', auth.returncode == 0 and not auth.stdout and
           b'revision-sintetica' not in auth.stderr)
    expect('fichero CLI 0600 y directorio 0700', (auth_home/'.coderabbit/auth.json').stat().st_mode & 0o777 == 0o600 and
           (auth_home/'.coderabbit').stat().st_mode & 0o777 == 0o700)
    auth = subprocess.run(['bash', str(auth_script), str(auth_source)], env=dict(auth_env, AUTH_RC='1'), capture_output=True)
    expect('estado CLI rojo no acredita autenticación', auth.returncode != 0)
    auth_source.write_text('CODERABBIT_API_KEY=\n')
    auth = subprocess.run(['bash', str(auth_script), str(auth_source)], env=auth_env, capture_output=True)
    expect('clave vacía rechazada', auth.returncode != 0)
    authorities = home/'.local/share/fabrica/ejemplo/receipts/autoridades.txt'
    authorities.parent.mkdir(parents=True, exist_ok=True)
    authorities.write_text('id-inválido')
    c_authority = dict(home=home, project='ejemplo', clon=clon)
    try:
        mod.parity_env(c_authority)
    except mod.Error as exc:
        observar('F4', exc.rc, str(exc))
    authorities.unlink()
    authorities.symlink_to(tmp/'autoridad-inexistente')
    try:
        mod.parity_env(c_authority)
    except mod.Error as exc:
        observar('F4', exc.rc, str(exc))
    authorities.unlink()
    prep_fixture = tmp/'preparacion-real'
    prep_fixture.mkdir()
    shutil.copyfile(PACKAGE/'skills/talent-channel-operation/scripts/preparar-sesiones.sh', prep_fixture/'preparar-sesiones.sh')
    stub(prep_fixture/'dispatch.sh',
         'TCO_DEV_CARRILES=11; TCO_CUSER=actor; TCO_TMUX=v; TCO_DEV_CLI=claude; TCO_AUDIT_CLI=claude\n'
         'tco_require_agents() { :; }; tco_container() { echo canal-fixture; }; tco_repo_path() { echo /fixture/producto; }\n'
         'tco_lock_acquire() { :; }; tco_lock_release() { :; }; incus() { return 1; }\n'
         'tco_die() { echo "$*" >&2; exit 1; }\n')
    preparation = subprocess.run(['/bin/bash', str(prep_fixture/'preparar-sesiones.sh'), '--ejecutar', '11'],
                                 env=os.environ.copy(), capture_output=True, text=True)
    observar('F5', preparation.returncode, preparation.stdout+preparation.stderr)
    # La guarda real se ejecuta con uid efectivo no privilegiado; clientes confinados.
    with patch.object(mod, 'run', respuesta_estricta('')):
        rejected = False
        try:
            mod.privileged()
        except mod.Error as exc:
            rejected = exc.rc == 2
        expect('guarda real rechaza ejecución sin privilegios', rejected)
    with patch.object(mod.os, 'getuid', lambda: 0):
        for operation in (lambda: mod.check('F0'), lambda: mod.prepare([])):
            rejected = False
            try:
                operation()
            except mod.Error as exc:
                rejected = exc.rc == 2 and 'usuario normal' in str(exc)
                observar('F0', exc.rc, str(exc))
            expect('root rechazado antes de herramientas/cuestionario', rejected)
    rc, out = cli('preparar', '--respuestas', answers, '--home', home, '--clon', tmp/'otro-nombre')
    expect('preparar rechaza clon de nombre distinto antes de F0', rc == 2 and 'nombre del clon' in out)
    answers.write_text(text.replace('repo_rama=main', 'repo_rama=develop'))
    before_context = (state/'contexto.conf').read_bytes()
    rc, out = cli('preparar', '--respuestas', answers, '--home', home, '--clon', clon)
    expect('preparar rechaza develop con receta y sin escrituras', rc == 2 and
           'requiere main' in out and 'no renombra' in out and (state/'contexto.conf').read_bytes() == before_context)
    answers.write_text(text)
    calls, containers, sessions = [], set(), set()
    power, marks, completed = {}, {}, {}
    built = set()
    container_storage = tmp/'contenedores'
    real_process = subprocess.run
    filesystem_env = os.environ.copy()
    cron_state = []
    a = dict(line.split('=', 1) for line in text.splitlines())
    c = dict(answers=a, home=home, clon=clon, project='ejemplo', env=envfile, escrow=escrow,
             bus=projecthome/'bus', manifest=pkg/'manifiestos/ejemplo.conf', profile=pkg/'manifiestos/ejemplo.perfil.tsv')

    def account(user):
        return SimpleNamespace(pw_name=user, pw_uid=os.getuid(), pw_gid=os.getgid(), pw_dir=str(actorhomes/user))

    def fake_run(args, **kw):
        args = list(map(str, args))
        validar_orden(args)
        calls.append((args, kw))
        if args[:2] == ['gh', 'api'] and any('/labels?' in arg for arg in args):
            return '[]\n[{"name":"cr-review"}]\n'
        if 'getent' in args:
            user = args[-1]
            return user+':x:0:0:actor:'+str(actorhomes/user)+':/bin/bash\n'
        if len(args) >= 2 and args[-2] == 'cat' and args[-1].endswith(('/runtime.conf', '.perfil.tsv')):
            return Path(args[-1]).read_text()
        if '--only' in args and args[args.index('--only')+1] == 'golden':
            containers.add('golden-ejemplo')
            power['golden-ejemplo'] = 'RUNNING'
            built.add('golden-ejemplo')
        if '--only' in args and args[args.index('--only')+1] == 'clone':
            for channel in mod.channels(c):
                containers.add(channel)
                power[channel] = 'RUNNING'
        if args[:2] == ['incus', 'list']:
            return ''.join(name+','+power[name]+'\n' for name in sorted(containers))
        if args[:2] == ['incus', 'copy']:
            if args[-1] in containers or power.get(args[2]) != 'STOPPED':
                raise mod.Error('copy inválido')
            containers.add(args[-1])
            power[args[-1]] = 'STOPPED'
        if args[:2] in (['incus', 'start'], ['incus', 'stop']):
            desired = 'RUNNING' if args[1] == 'start' else 'STOPPED'
            if args[2] not in containers or power[args[2]] == desired:
                raise mod.Error('estado previo inválido')
            power[args[2]] = desired
        if args[:3] == ['incus', 'config', 'get']:
            if args[4] == 'user.fabrica.base-completa':
                return 'yes' if args[3] in built else ''
            return completed.get(args[3], '')
        if args[:3] == ['incus', 'config', 'set'] and args[4] == 'user.fabrica.terminada':
            completed[args[3]] = args[5]
        if args[:2] == ['incus', 'exec'] and '.sembrado' in args[-1]:
            marks[args[2]] = args[-2]
        if args[:2] == ['incus', 'exec'] and any('find "$1" -mindepth' in word for word in args):
            local = container_storage/args[2]
            if local.is_dir():
                for path in local.iterdir():
                    if path.name != '.git':
                        if path.is_dir() and not path.is_symlink():
                            shutil.rmtree(path)
                        else:
                            path.unlink()
        if args[:2] == ['incus', 'exec'] and any('git -C "$1" init' in word for word in args):
            script = next(word for word in args if 'git -C "$1" init' in word)
            local = container_storage/args[2]
            result = real_process(['/bin/bash', '-c', script, '_', str(local)], env=filesystem_env,
                                  stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode:
                raise mod.Error('snapshot git del núcleo falló')
        if args[:2] == ['incus', 'delete']:
            if power.get(args[2]) != 'STOPPED':
                raise mod.Error('delete encendido')
            containers.remove(args[2])
            power.pop(args[2])
            marks.pop(args[2], None)
            completed.pop(args[2], None)
            built.discard(args[2])
        if 'new-session' in args:
            sessions.add(args[args.index('-s')+1])
        if 'bus-sellar.sh' in ' '.join(args):
            c['bus'].write_text('sello neutro de bootstrap\n')
        if '--crontab' in args:
            return '07,22,37,52 * * * * '+args[args.index('--comando')+1]+'\n'
        if 'modelos-rol.sh' in ' '.join(args) or args[-1] == '--linea':
            command = args
            user = ceo
            if args[0] == 'sudo':
                user = args[args.index('-u')+1]
                command = args[args.index('--')+1:]
            model_env = dict(os.environ, HOME=str(actorhomes/user))
            model_env.update(kw.get('env') or {})
            result = real_process(command, env=model_env, text=True, capture_output=True)
            if result.returncode:
                raise mod.Error(result.stderr)
            return result.stdout
        if args[0] == 'jq':
            result = real_process([shutil.which('jq', path=filesystem_env['PATH']), *args[1:]],
                                  env=filesystem_env, text=True, capture_output=True, check=True)
            return result.stdout
        return ''

    def fake_process(args, **kw):
        validar_orden(args)
        args = list(map(str, args))
        calls.append((args, kw))
        rc, out, err = 0, '', ''
        if args[:2] == ['incus', 'info']:
            rc = 0 if args[-1] in containers else 1
        elif args[:3] == ['incus', 'file', 'pull']:
            name = args[3].split('/')[0]
            rc, out = (0, marks[name]) if name in marks else (1, '')
        elif args[:2] == ['incus', 'exec'] and 'tar' in args:
            with tarfile.open(fileobj=kw['stdin'], mode='r:') as archive:
                for member in archive.getmembers():
                    require_safe = member.isfile() and not Path(member.name).is_absolute() and '..' not in Path(member.name).parts
                    if not require_safe:
                        return SimpleNamespace(returncode=1, stdout='', stderr='archivo inseguro')
                    dest = container_storage/args[2]/member.name
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.write_bytes(archive.extractfile(member).read())
        elif 'incus' in args and 'exec' in args and any('sha256sum -c' in word for word in args):
            container = args[args.index('exec')+1]
            for row in kw['input'].decode().splitlines():
                digest, name = row.split('  ', 1)
                dest = container_storage/container/name
                if not dest.is_file() or hashlib.sha256(dest.read_bytes()).hexdigest() != digest:
                    rc = 1
        elif 'has-session' in args:
            rc = 0 if args[-1] in sessions else 1
        elif args[-2:] == ['crontab', '-l']:
            rc = 0 if cron_state else 1
            out = ''.join(cron_state)
            err = '' if cron_state else 'no crontab for actor'
        elif args[-2:] == ['crontab', '-']:
            cron_state[:] = [kw['input']]
        return SimpleNamespace(returncode=rc, stdout=out, stderr=err)

    etc = tmp/'sudoers'
    etc.mkdir()
    real_path = Path

    def mapped_path(value):
        return etc if str(value) == '/etc/sudoers.d' else real_path(value)

    with patch.dict(os.environ, env), patch.object(mod, 'run', fake_run), \
            patch.object(mod.subprocess, 'run', fake_process), \
            patch.object(mod.pwd, 'getpwnam', account), patch.object(mod, 'Path', mapped_path), \
            patch('grp.getgrnam', lambda _: SimpleNamespace(gr_gid=os.getgid())):
        for label, operation in (
                ('F2', lambda: mod.provision(c, '--ejecutar')),
                ('F3', lambda: mod.channel_env(c, False)),
                ('F5', lambda: mod.infrastructure(c, 'f5-torres', False)),
                ('F6', lambda: mod.infrastructure(c, 'f6-bus', False))):
            calls.clear()
            rejected = False
            try:
                operation()
            except mod.Error as exc:
                rejected = exc.rc == 2
            expect(label+' guarda real rechaza antes de clientes', rejected and not calls)
        calls.clear()

    with patch.dict(os.environ, env), patch.object(mod, 'run', fake_run), \
            patch.object(mod.subprocess, 'run', fake_process), patch.object(mod, 'privileged', lambda: None), \
            patch.object(mod.pwd, 'getpwnam', account), patch.object(mod, 'Path', mapped_path), \
            patch('grp.getgrnam', lambda _: SimpleNamespace(gr_gid=os.getgid())):
        mod.provision(c, '--plan')
        expect('plan F2 no ejecuta clientes ni escribe', not calls)
        mod.provision(c, '--ejecutar')
        mod.provision(c, '--ejecutar')
        goldens = [args for args, _ in calls if '--only' in args and args[args.index('--only')+1] == 'golden']
        expect('contrato unitario F2 idempotencia con provision sustituido', len(goldens) == 1)
        expect('contrato unitario F2 entorno cerrado sin motor remoto', all(kw.get('env', {}).get('TF_REPO_URL', '') == '' for _, kw in calls))
        expect('contrato unitario F2 no secretos en argv', all(secret not in ' '.join(args) for args, _ in calls))
        for label, mark in [('corte tras construir', False), ('corte tras sembrar', True)]:
            containers.clear()
            power.clear()
            marks.clear()
            completed.clear()
            built.clear()
            containers.add('golden-ejemplo')
            power['golden-ejemplo'] = 'RUNNING'
            built.add('golden-ejemplo')
            if mark:
                marks['golden-ejemplo'] = mod.seed_fingerprint()
            calls.clear()
            mod.provision(c, '--ejecutar')
            mod.provision(c, '--ejecutar')
            expect('contrato unitario F2 reanuda '+label, completed.get('golden-ejemplo') == mod.seed_fingerprint() and
                   power['golden-ejemplo'] == 'STOPPED' and not any('--only' in args and
                   args[args.index('--only')+1] == 'golden' for args, _ in calls))
        containers.clear()
        power.clear()
        completed.clear()
        built.clear()
        containers.add('golden-ejemplo')
        power['golden-ejemplo'] = 'RUNNING'
        rejected = False
        calls.clear()
        try:
            mod.provision(c, '--ejecutar')
        except mod.Error as exc:
            rejected = 'construcción sin terminar' in str(exc)
            observar('F2', exc.rc, str(exc))
        expect('contrato unitario F2 corte dentro de construcción exige recuperación sin sembrar ni clonar', rejected and
               not completed and not any('--only' in args and args[-1] == 'clone' for args, _ in calls))
        for label, initial, done in [('completa', ['golden-ejemplo'], True),
                                     ('nombre ajeno', ['golden-otro'], False),
                                     ('canal clonado', ['golden-ejemplo', 'vibe-channel-11'], False)]:
            containers.clear()
            power.clear()
            marks.clear()
            completed.clear()
            containers.update(initial)
            power.update({name:'RUNNING' for name in initial})
            if done:
                completed['golden-ejemplo'] = mod.seed_fingerprint()
            rejected = False
            before = dict(power)
            try:
                mod.provision(c, '--recuperar')
            except mod.Error as exc:
                rejected = True
                observar('F2', exc.rc, str(exc))
            expect('contrato unitario F2 recuperación rechaza '+label, rejected and power == before)
        containers.clear()
        power.clear()
        completed.clear()
        containers.add('golden-ejemplo')
        power['golden-ejemplo'] = 'RUNNING'
        mod.provision(c, '--plan-recuperar')
        expect('contrato unitario F2 recuperación plan preserva plantilla', 'golden-ejemplo' in containers)
        mod.provision(c, '--recuperar')
        expect('contrato unitario F2 recuperación borra solo incompleta', not containers)
        mod.provision(c, '--ejecutar')
        expect('contrato unitario F2 recuperación con provision sustituido', completed.get('golden-ejemplo') == mod.seed_fingerprint())
        calls.clear()
        mod.provision(c, '--verificar')
        expected_argv = ['sudo', '-n', 'env', '-i', *[k+'='+v for k, v in mod.closed_env(c).items()],
                         'bash', str(pkg/'skills/talent-channels/scripts/verify.sh'), '--etapa', 'creado']
        expect('contrato unitario F2 argv exactos sudo env cerrado', calls[0][0] == expected_argv)
        calls.clear()
        mod.infrastructure(c, 'f5-torres', True, users_only=True)
        expect('plan usuarios no ejecuta mutaciones', not calls)
        mod.infrastructure(c, 'f5-torres', False, users_only=True)
        expect('usuarios solo identidades adjudicadas', all(args[-1] in [ceo, 'ejemplo-c1', 'ejemplo-m1', 'ejemplo-incus']
               for args, _ in calls if args[0] == 'usermod'))
        expect('C1 M1 operador mismo grupo operacional', [args for args, _ in calls if args[:3] == ['usermod', '-aG', 'incus-admin']] ==
               [['usermod', '-aG', 'incus-admin', user] for user in ('ejemplo-incus', 'ejemplo-c1', 'ejemplo-m1')])
        calls.clear()
        with patch.dict(os.environ, DOBLE_FALLO='claude'):
            try:
                mod.infrastructure(c, 'f5-torres', False)
                rejected = False
            except mod.Error:
                rejected = True
        expect('resolución real fallida impide lanzar todas las torres', rejected and
               not any('new-session' in args for args, _ in calls))
        calls.clear()
        initial_modes = {}
        for _, user, _ in mod.roles(c):
            h = actorhomes/user
            for relative, mode in (('.local', 0o775), ('.local/state', 0o771),
                                   ('.config', 0o771), ('.claude', 0o775)):
                p = h/relative
                os.chown(p, -1, os.getgid())
                p.chmod(mode)
                initial_modes[p] = (mode, p.stat().st_uid, p.stat().st_gid)
        corrected = io.StringIO()
        with contextlib.redirect_stdout(corrected):
            mod.infrastructure(c, 'f5-torres', False)
        expect('F5 corrige disposición real de tres roles y conserva dueño/grupo', all(
            p.stat().st_mode & 0o7777 == (0o700 if p.name == '.claude' else mode & ~0o020) and
            (p.stat().st_uid, p.stat().st_gid) == (uid, gid)
            for p, (mode, uid, gid) in initial_modes.items()))
        expect('F5 informa una vez cada directorio corregido', all(
            corrected.getvalue().splitlines().count('directorio de rol corregido: ruta='+str(p)+
                ' modo anterior='+format(mode, '04o')+' modo nuevo='+format(mode & ~0o020, '04o')) == 1
            for p, (mode, _, _) in initial_modes.items()))
        mod.infrastructure(c, 'f5-torres', False)
        expect('contrato unitario F5 idempotente tres sesiones nuevas en total', len([args for args, _ in calls if 'new-session' in args]) == 3)
        expect('M1 arranca en su clon propio con escritura', any('new-session' in args and
               args[args.index('-c')+1] == str(actorhomes/'ejemplo-m1/producto') for args, _ in calls))
        expect('C1 arranca en su clon propio', any('new-session' in args and
               args[args.index('-c')+1] == str(actorhomes/'ejemplo-c1/producto') for args, _ in calls))
        expect('torres primer uso privado conserva claves', all(
               json.loads((actorhomes/user/'.claude.json').read_text()).get('hasCompletedOnboarding') is True and
               json.loads((actorhomes/user/'.claude.json').read_text()).get('preferencia') == 'conservada' and
               (actorhomes/user/'.claude.json').stat().st_mode & 0o777 == 0o600 for _, user, _ in mod.roles(c)))
        expect('F5 conserva perfil generado antes de F4', c['profile'].read_text() == public['manifiestos/ejemplo.perfil.tsv']
               and all((mod.role_clone(c, role)/'manifiestos'/c['profile'].name).read_text() ==
                       public['manifiestos/ejemplo.perfil.tsv'] for role, _, _ in mod.roles(c)))
        rules = (etc/'fabrica-ejemplo').read_text()
        (etc/'fabrica-ejemplo').chmod(0o600)
        (etc/'fabrica-ejemplo').write_text('reglas-distintas\n')
        try:
            mod.infrastructure(c, 'f5-torres', False)
        except mod.Error as exc:
            observar('F5', exc.rc, str(exc))
        (etc/'fabrica-ejemplo').write_text(rules)
        (etc/'fabrica-ejemplo').chmod(0o440)
        expect('sudoers exacto sin ALL de comandos', 'NOPASSWD: ALL' not in rules and 'leer-acreditacion.sh' in rules and
               'ALL=(root) NOPASSWD:' in rules and 'verify.sh --etapa acreditado' in rules and 'TCO_MODELOS_REGISTRO=' in rules.replace('\\=', '='))
        expect('sudoers permite lecturas exactas de estado y perfil por rol', all(
            '('+user+') NOPASSWD: '+shutil.which('cat')+' '+str(path) in rules
            for role, user, _ in mod.roles(c) if role != 'CEO'
            for path in (actorhomes/user/'.config/talent-factory/runtime.conf',
                         actorhomes/user/'producto/manifiestos/ejemplo.perfil.tsv')))
        expect('sudoers auditor pane exacto', 'v:.1' in rules.replace('\\:', ':'))
        calls.clear()
        with patch('acreditacion.configure_host_git'):
            mod.channel_env(c, False)
        transfers = [args for args, _ in calls if 'push-carril-env.sh' in ' '.join(args)]
        expect('F3 camino del paquete solo perfiles de canal', [args[-1] for args in transfers] ==
               mod.channels(c) and not (escrow/'env/runner-ejemplo.env').exists())
        expect('F3 escrow por canal 0600 sin CodeRabbit', all(
            (escrow/'env'/(channel+'.env')).stat().st_mode & 0o777 == 0o600 and
            'CODERABBIT_API_KEY' not in (escrow/'env'/(channel+'.env')).read_text()
            for channel in mod.channels(c)))
        for _, user, _ in mod.roles(c):
            (actorhomes/user/'.local').chmod(0o775)
            (actorhomes/user/'.local/state').chmod(0o771)
        corrected = io.StringIO()
        with contextlib.redirect_stdout(corrected):
            mod.infrastructure(c, 'f6-bus', False)
        expect('F6 prepara padres reales antes del bus e informa seis correcciones', all(
            (actorhomes/user/'.local').stat().st_mode & 0o7777 == 0o755 and
            (actorhomes/user/'.local/state').stat().st_mode & 0o7777 == 0o751
            for _, user, _ in mod.roles(c)) and
            corrected.getvalue().count('directorio de rol corregido:') == 6)
        expect('check-F6 verde tras preparación real F5/F6', cli('check-F6')[0] == 0)
        first_bus = c['bus'].read_bytes()
        first_cron = list(cron_state)
        mod.infrastructure(c, 'f6-bus', False)
        expect('contrato unitario F6 no trunca bus al reejecutar', c['bus'].read_bytes() == first_bus and first_bus)
        expect('contrato unitario F6 cron no duplicado', cron_state == first_cron)
        expect('contrato unitario F6 bus y lock grupo 0660', c['bus'].stat().st_mode & 0o777 == 0o660 and
                c['bus'].with_name('bus.lock').stat().st_mode & 0o777 == 0o660)
        # Reanudar con padres heredados de root; los demás stat y el sello son reales.
        migrated = []
        legacy = {actorhomes/user/'.local' for _, user, _ in mod.roles(c)}
        original_stat = real_path.stat
        def legacy_stat(path, *args, **kwargs):
            info = original_stat(path, *args, **kwargs)
            if path in legacy:
                values = list(info)
                values[4] = 0
                return os.stat_result(values)
            return info
        def migrate(path, uid, gid):
            if path in legacy:
                legacy.remove(path)
                migrated.append(path)
        sealed = actorhomes/ceo/'.local/state/talent-ceo/acreditacion/CEO.estado'
        sealed.parent.mkdir(exist_ok=True)
        sealed.write_bytes(b'ACREDITADO\n')
        with patch.object(real_path, 'stat', legacy_stat), patch.object(mod.os, 'chown', migrate):
            mod.infrastructure(c, 'f6-bus', False)
        expect('F6 reanudación migra padres root sintéticos y conserva sello real',
               not legacy and len(migrated) == 3 and sealed.read_bytes() == b'ACREDITADO\n')
        expect('F6 no trunca bus al reejecutar', c['bus'].read_bytes() == first_bus and first_bus)
        expect('F6 cron no duplicado', cron_state == first_cron)
        expect('F6 bus y lock grupo 0660', c['bus'].stat().st_mode & 0o777 == 0o660 and
               c['bus'].with_name('bus.lock').stat().st_mode & 0o777 == 0o660)
        launched = []
        c1home = actorhomes/'ejemplo-c1'
        role_env = c1home/'ejemplo/.env.local'
        with patch.object(mod, 'Path', real_path), patch.object(real_path, 'home', lambda: c1home), \
                patch.object(mod.os, 'execvpe', lambda *args: launched.append(args)), \
                patch.dict(os.environ, HOME=str(c1home)):
            mod.start_actor(['C1', str(role_env), str(c['bus']), str(c['manifest'])])
        expect('integración C1 enlaza entorno escrito por F5 desde su clon propio', launched[-1][2]['TA_OPERATION_ENV'] == str(role_env) and
               role_env != mod.role_clone(c, 'C1')/'.env.local' and 'LINEAR_API_KEY' not in launched[-1][2])
        calls.clear()
        mod.infrastructure(c, 'f5-torres', False)
        resolved = [args for args, _ in calls if '--resolver' in args]
        expect('F5 acredita y resuelve exactamente los tres roles bajo su propio usuario',
               {args[args.index('-u')+1] if '-u' in args else a['usuario_ceo'] for args in resolved} ==
               {a['usuario_ceo'], a['usuario_c1'], a['usuario_m1']} and
               len(resolved) == 3 and
               len([args for args, _ in calls if 'claude-capacidad.sh' in ' '.join(args)]) == 3)
        calls.clear()
        mod.infrastructure(c, 'f6-bus', False)
        emitters = [args for args, _ in calls if '--linea' in args]
        expect('modelos F6 instala cron real por usuario conservando entradas', len(emitters) == 3 and
               all(any('TA_ROL='+role in args for args in emitters) for role in ('CEO', 'C1', 'M1')) and
               not [args for args, kw in calls if args[-2:] == ['crontab', '-']])

    # Consumidores REALES en clon instalado; solo GitHub tiene doble de lectura.
    realenv = os.environ.copy()
    realenv.update(GIT_AUTHOR_NAME='Prueba', GIT_AUTHOR_EMAIL='prueba@example.invalid',
                   GIT_COMMITTER_NAME='Prueba', GIT_COMMITTER_EMAIL='prueba@example.invalid')
    api_bin = tmp/'api-bin'
    api_bin.mkdir()
    for fixture in ('gh_contrato.py', 'gh-2.45.0.json'):
        shutil.copyfile(PACKAGE/'tests/fixtures/instalacion'/fixture, api_bin/fixture)
    gh_header = '#!/usr/bin/python3\nimport json,sys\nfrom gh_contrato import validar\nvalidar(sys.argv[1:])\n'
    protection = {'required_status_checks': {'strict':True, 'checks':[{'context':'local-gates'}]},
                  'required_pull_request_reviews': {'required_approving_review_count':0, 'dismiss_stale_reviews':True,
                      'require_code_owner_reviews':False, 'require_last_push_approval':False}, 'restrictions':None}
    for k, v in {'enforce_admins':False, 'required_linear_history':True, 'allow_force_pushes':False,
                 'allow_deletions':False, 'block_creations':False, 'required_conversation_resolution':True}.items():
        protection[k] = {'enabled':v}
    settings = {'allow_squash_merge':True, 'allow_merge_commit':True, 'allow_rebase_merge':True, 'delete_branch_on_merge':False}
    gh_body = (gh_header+
               'p='+repr(protection)+'\ns='+repr(settings)+'\n'
               'print(json.dumps([{"name":"cr-review"}] if any("/labels?" in a for a in sys.argv) else [] if "/rules/branches/" in sys.argv[-1] else p if sys.argv[-1].endswith("/protection") else s))\n')
    (api_bin/'gh').write_text(gh_body)
    (api_bin/'gh').chmod(0o755)
    realenv['PATH'] = str(api_bin)+':'+os.environ['PATH']
    for arguments in (['git', 'init', '-q', '-b', 'main', str(clon)],
                      ['git', '-C', str(clon), 'remote', 'add', 'origin', a['repo_url']]):
        subprocess.run(arguments, env=realenv, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    sys.path.insert(0, str(scripts))
    sys.modules['fases'] = mod
    (clon/'scripts/verify-handoff.sh').unlink()
    shutil.copytree(PACKAGE/'skills/talent-repo-onboarding', clon/'.claude/skills/talent-repo-onboarding', dirs_exist_ok=True)
    (clon/'.claude/skills/talent-issue-craft').mkdir(exist_ok=True)
    (clon/'CLAUDE.md').write_text('Reglas previas del producto\n')
    (clon/'.claude/settings.json').write_text('{"language":"es","hooks":{"Stop":[]}}\n')
    (clon/'.coderabbit.yaml').write_text('language: es\nreviews:\n    profile: assertive\n    auto_review:\n        drafts: true\n')
    (clon/'scripts/draft-handoff.sh').write_text('#!/usr/bin/env bash\necho gate-original-producto\n')
    with patch.dict(os.environ, realenv, clear=True):
        mod.onboarding(c, True)
        expect('F4 plan no crea equivalentes ni canónicos', not (clon/'.githooks').exists())
        for linked_name in ('scripts', '.github'):
            exterior = tmp/('exterior-'+linked_name.replace('.', ''))
            exterior.mkdir()
            (exterior/'draft-handoff.sh').write_text('contenido exterior previo\n')
            destination = clon/linked_name
            backup = clon/(linked_name+'-guardado')
            if destination.exists():
                destination.rename(backup)
            destination.symlink_to(exterior, target_is_directory=True)
            before = {str(p):p.read_bytes() for p in exterior.rglob('*') if p.is_file()}
            for plan in (True, False):
                rejected = False
                try:
                    mod.onboarding(c, plan)
                except mod.Error as exc:
                    rejected = 'destino enlazado' in str(exc)
                expect('F4 confina '+linked_name+' plan='+str(plan), rejected and
                       before == {str(p):p.read_bytes() for p in exterior.rglob('*') if p.is_file()})
            destination.unlink()
            if backup.exists():
                backup.rename(destination)
        mod.onboarding(c)
        profile = clon/'docs/reference/issue-craft-perfil-ejemplo.md'
        expect('F4 genera validador declarado antes del commit',
               (clon/a['validador_rama']).read_bytes() == (pkg/'scripts/github/validar-rama-pr.sh').read_bytes())
        expect('F4 genera perfil desde respuestas sin siembra', profile.is_file() and
               a['repo_url'] in profile.read_text() and a['linear_clave'] in profile.read_text() and
               'pendientes de completar por el equipo' in profile.read_text())
        profile.write_text('Nota propia del equipo\n'+profile.read_text())
        before_files = {str(p.relative_to(clon)):p.read_bytes() for p in clon.rglob('*') if p.is_file() and '.git' not in p.parts}
        mod.onboarding(c)
        after_files = {str(p.relative_to(clon)):p.read_bytes() for p in clon.rglob('*') if p.is_file() and '.git' not in p.parts}
        expect('F4 onboarding real idempotente', before_files == after_files)
        expect('F4 perfil fusionado conserva nota del equipo', profile.read_text().startswith('Nota propia'))
        expect('F4 fusiona reglas y conserva settings previos', (clon/'CLAUDE.md').read_text().startswith('Reglas previas') and
               json.loads((clon/'.claude/settings.json').read_text())['language'] == 'es')
        coordination = 'manifiestos/anexo-coordinacion-'+c['project']+'.md'
        expect('F4 monta anexo de coordinación fuera del núcleo con referencia obligatoria',
               'TF_RUNNERS=runner-'+c['project'] in (clon/coordination).read_text() and
               coordination in (clon/'CLAUDE.md').read_text() and coordination in (clon/'AGENTS.md').read_text() and
               not (clon/'.claude/skills/talent-coordination/references'/('anexo-'+c['project']+'.md')).exists())
        expect('F4 fusiona YAML conservando opciones ajenas', 'profile: assertive' in (clon/'.coderabbit.yaml').read_text() and
               'drafts: false' in (clon/'.coderabbit.yaml').read_text())
        expect('F4 conserva código anterior y exige gates nuevos', 'gate-original-producto' in (clon/'scripts/draft-handoff.sh').read_text() and
               '# fabrica:original:inicio' in (clon/'scripts/draft-handoff.sh').read_text() and
               "bash -c true" in (clon/'scripts/draft-handoff.sh').read_text())
        subprocess.run(['git', '-C', str(clon), 'add', '.'], env=realenv, check=True)
        verifier = clon/'.claude/skills/talent-repo-onboarding/scripts/verify-repo-parity.sh'
        parityenv = dict(realenv, TF_LINEAR_TEAM_KEY='ABC', **mod.parity_env(c))
        p = subprocess.run(['bash', str(verifier), str(clon)], env=parityenv, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        LAST = p.stdout
        expect('F4 verificador real instalado duras verdes manuales rc3', p.returncode == 3 and
               'Canon: paquete' in p.stdout and 'sin receipt' in p.stdout)
        headers = ['Qué hace', 'Decisiones y porqués', 'Invariantes sellados por el code-audit',
                   'Superficies tocadas y clasificación', 'Migraciones', 'Archivos calientes',
                   'Verificación local ejecutada', 'Qué NO tocar / trampas', 'Bloque machine-readable']
        handoff = dict(schema_version=2, build='validado', issues=['ABC-1'], head_sha='a'*40,
                       branch='docs/humo', sensitive=False, destructive=False, surfaces=[], migration_slots=[])
        comment = '## HANDOFF\n'+'\n'.join('### '+h+'\nContenido de prueba.' for h in headers)+\
                  '\n```json\n'+json.dumps(handoff)+'\n```\n'
        pr = dict(number=1, state='OPEN', isDraft=True, headRefOid='a'*40, headRefName='docs/humo',
                  body='Closes ABC-1', comments=[dict(body=comment)])
        gh_original = (api_bin/'gh').read_text()
        (api_bin/'gh').write_text(gh_header+'print(json.dumps('+repr(pr)+'))\n')
        record_state = tmp/'handoff-estado'
        with patch.object(mod, 'STATE', record_state):
            recorded_path = mod.record_handoff(c, ['1', 'ABC-1'])
            recorded = json.loads(recorded_path.read_text())
            expect('F8 conserva verificador real en borrador con binding', recorded['rc'] == 0 and
                   recorded['estado_pr'] == 'DRAFT' and recorded['head'] == 'a'*40 and
                   recorded['pr'] == 1 and recorded['issue'] == 'ABC-1')
            expect('F8 conserva salida real del verificador', '[verify-handoff]' in
                   Path(recorded['artefacto']).read_text())
            first_bytes = recorded_path.read_bytes()
            with patch.object(mod.subprocess, 'run', respuesta_estricta(SimpleNamespace(returncode=1, stdout='FAIL ABC-1'))):
                with patch.object(mod, 'run', respuesta_estricta(json.dumps(pr))):
                    try:
                        mod.record_handoff(c, ['1', 'ABC-1'])
                    except mod.Error:
                        pass
            attempts = list((record_state/'humo').glob('*.json'))
            expect('F8 conserva intento fallido sin alterar el verde', len(attempts) == 2 and
                   recorded_path.read_bytes() == first_bytes and
                   mod.selected_handoff('ABC-1', 1, 'a'*40) == recorded_path)
            with patch.object(mod.subprocess, 'run', respuesta_estricta(SimpleNamespace(returncode=0, stdout='PASS ABC-1'))):
                with patch.object(mod, 'run', respuesta_estricta(json.dumps(pr))):
                    retry = mod.record_handoff(c, ['1', 'ABC-1'])
            expect('F8 reintento tras fallo crea otro registro verde', retry != recorded_path and
                   mod.selected_handoff('ABC-1', 1, 'a'*40) == retry and len(list((record_state/'humo').glob('*.json'))) == 3)
            other_head_rejected = False
            try:
                mod.selected_handoff('ABC-1', 1, 'c'*40)
            except mod.Error:
                other_head_rejected = True
            expect('F8 verde anterior no acredita head nuevo', other_head_rejected)
            pr['headRefOid'] = 'c'*40
            with patch.object(mod.subprocess, 'run', respuesta_estricta(SimpleNamespace(returncode=0, stdout='PASS ABC-1'))):
                with patch.object(mod, 'run', respuesta_estricta(json.dumps(pr))):
                    new_head = mod.record_handoff(c, ['1', 'ABC-1'])
            expect('F8 head nuevo requiere y conserva verificación propia',
                   mod.selected_handoff('ABC-1', 1, 'c'*40) == new_head and recorded_path.read_bytes() == first_bytes)
            pr['isDraft'] = False
            pr['state'] = 'MERGED'
            (api_bin/'gh').write_text(gh_header+'print(json.dumps('+repr(pr)+'))\n')
            before = recorded_path.read_bytes()
            rejected = False
            try:
                mod.record_handoff(c, ['1', 'ABC-1'])
            except mod.Error as exc:
                rejected = 'borrador' in str(exc)
            expect('F8 rechaza volver a verificar fusionado y conserva registro', rejected and
                   recorded_path.read_bytes() == before)
        (api_bin/'gh').write_text(gh_original)
        subprocess.run(['git','-C',str(clon),'commit','-q','-m','Fixture de producto'], env=realenv, check=True)
        subprocess.run(['git','-C',str(clon),'switch','-q','-c','docs/fixture'], env=realenv, check=True)
        draft = clon/'scripts/draft-handoff.sh'
        p = subprocess.run(['bash',str(draft)], cwd=clon, env=realenv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        LAST = p.stdout.decode()
        expect('F4 draft fusionado ejecuta gates reales antes de sentinel', p.returncode == 0 and (clon/'.claude/.draft-handoff').is_file())
        draft.write_text(draft.read_text().replace('bash -c true', 'bash -c false'))
        subprocess.run(['git','-C',str(clon),'add',str(draft)], env=realenv, check=True)
        subprocess.run(['git','-C',str(clon),'commit','-q','-m','Gate rojo en fixture'], env=realenv, check=True)
        p = subprocess.run(['bash',str(draft)], cwd=clon, env=realenv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        expect('F4 draft fusionado gate rojo elimina sentinel', p.returncode != 0 and not (clon/'.claude/.draft-handoff').exists())
        (pkg/'scripts/verify-handoff.sh').write_text((pkg/'scripts/verify-handoff.sh').read_text()+'# deriva\n')
        p = subprocess.run(['bash', str(verifier), str(clon)], env=parityenv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        expect('F4 canon real detecta deriva bytes', p.returncode == 1)
        # Dispatch REAL: identidad neutral por entorno, config runtime conservada.
        dispatchenv = dict(realenv, SECRET_DIR=str(home/'.config/talent-channel-operation'),
                           TCO_TF_MANIFEST=str(pkg/'manifiestos/ejemplo.conf'),
                           TCO_MODELOS_REGISTRO=str(actorhomes/'ejemplo-c1/.config/talent-channel-operation/modelos.conf'),
                           TCO_REPO_DIR='producto', TCO_REPO_SLUG='org-example/producto', TCO_REPO_STACK='ninguno',
                           TCO_ANEXO_FILE='references/anexo-ejemplo.md', TCO_HOST_ENV_REL='ejemplo/.env.local',
                           TCO_LINEAR_INPROGRESS_STATE=a['linear_inprogress_uuid'],
                           TCO_LINEAR_INREVIEW_STATE=a['linear_inreview_uuid'])
        dispatch = PACKAGE/'skills/talent-channel-operation/scripts/dispatch.sh'
        p = subprocess.run(['bash', str(dispatch), '--dry-run', '11', 'ABC-1'], env=dispatchenv,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        LAST = p.stdout.decode()
        expect('F8 dispatch real acepta número de carril', p.returncode == 0 and b'vibe-channel-11' in p.stdout)
        p = subprocess.run(['bash', str(dispatch), '--dry-run', 'vibe-channel-11', 'ABC-1'], env=dispatchenv,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        expect('F8 dispatch real rechaza nombre completo', p.returncode == 1 and b'carril invalido' in p.stdout)

    import proteccion
    api_calls = []

    def protection_run(args, **kw):
        validar_orden(args)
        api_calls.append(list(args))
        return json.dumps([] if '/rules/branches/' in args[-1] else protection if args[-1].endswith('/protection') else settings)

    def protection_process(args, **kw):
        validar_orden(args)
        api_calls.append((list(args), kw.get('input')))
        return SimpleNamespace(returncode=0, stdout=json.dumps(protection), stderr='')

    import rulesets
    with patch.object(proteccion, 'config', lambda: c), patch.object(proteccion, 'run', protection_run), \
            patch.object(rulesets, 'run', protection_run), \
            patch.object(proteccion.subprocess, 'run', protection_process):
        with patch.object(sys, 'argv', ['proteccion.py', '--plan']):
            proteccion.main()
        expect('F4 protección plan solo lecturas', all('--method' not in (item[0] if isinstance(item, tuple) else item)
                                                      for item in api_calls))
        api_calls.clear()
        with patch.object(sys, 'argv', ['proteccion.py', '--ejecutar']):
            proteccion.main()
        writes = [item for item in api_calls if isinstance(item, tuple) and '--method' in item[0]]
        expect('F4 protección aplica argv y cuerpos exactos', writes == [
            (['gh','api','--method','PUT','repos/org-example/producto/branches/main/protection','--input','-'], json.dumps(proteccion.BODY)),
            (['gh','api','--method','PATCH','repos/org-example/producto','--input','-'], json.dumps(proteccion.SETTINGS))])
        expect('F4 protección relee ambos endpoints tras escritura', api_calls[-2:] == [
            ['gh','api','repos/org-example/producto/branches/main/protection'], ['gh','api','repos/org-example/producto']])
    expect('F4 protección comparación rechaza drift', not proteccion.matches({'strict':False}, {'strict':True}))

    # Generador y cuestionario reales: no fabricar sus manifiestos, ledger ni agents.conf.
    integration = tmp/'integracion'
    shutil.copytree(PACKAGE, integration, ignore=shutil.ignore_patterns('.git', '__pycache__', 'estado', 'generado'))
    integration_home = tmp/'home-integracion'
    integration_home.mkdir()
    integration_state = integration/'instalacion/estado'
    integration_state.mkdir(mode=0o700)
    integration_answers = integration_state/'respuestas.resp'
    integration_answers.write_text(text.replace('proyecto=ejemplo', 'proyecto=prueba'))
    integration_answers.chmod(0o600)
    linear = integration/'instalacion/generado/linear-consulta.json'
    integration_env = os.environ.copy()
    integration_bin = tmp/'integracion-bin'
    integration_bin.mkdir()
    for fixture in ('gh_contrato.py', 'gh-2.45.0.json'):
        shutil.copyfile(PACKAGE/'tests/fixtures/instalacion'/fixture, integration_bin/fixture)
    for tool in ('getent', 'id', 'gh', 'curl'):
        shutil.copyfile(PACKAGE/'tests/fixtures/instalacion/cliente.py', integration_bin/tool)
        (integration_bin/tool).chmod(0o755)
    integration_env.update(HOME=str(integration_home), DOBLE_HOME=str(actorhomes),
                           DOBLE_GRUPOS='fabrica-prueba incus-admin',
                           PATH=str(integration_bin)+':'+os.environ['PATH'])
    # Ejecutar el shell de la guía; sustituir únicamente el transporte de su proceso Python.
    stub(integration_bin/'python3',
         'if [[ "$1" == */instalacion/instalacion.py && "${2:-}" == linear ]]; then\n'
         '  shift 2\n  exec '+shlex.quote(sys.executable)+' '+
         shlex.quote(str(integration/'instalacion/tests/linear_api.py'))+' "$@"\nfi\n'
         'exec '+shlex.quote(sys.executable)+' "$@"\n')
    (integration_bin/'python3').chmod(0o755)

    def real_cli(script, *arguments):
        global LAST
        p = subprocess.run(['bash', str(integration/'instalacion'/script), *map(str, arguments)],
                           env=integration_env, stdin=subprocess.DEVNULL, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
        LAST = p.stdout+p.stderr
        observar_orden(nombre=script, args=arguments, rc=p.returncode, salida=LAST)
        return p.returncode

    expect('integración cuestionario real completo', real_cli('cuestionario.sh', '--respuestas', integration_answers, 'siguiente') == 0 and LAST.strip() == 'COMPLETO')
    common = ['--respuestas', integration_answers, '--salida', integration, '--home', integration_home]
    expect('integración generador real solo env', real_cli('generar-instancia.sh', *common, '--solo-env') == 0)
    consultation_rc = real_cli('consultar-estados-linear.sh', '--equipo', 'ABC', '--out', linear)
    expect('integración consulta CLI sin fixture y paginada', consultation_rc == 0 and
           len(json.loads(linear.read_text())['labels']) == 230)
    destination = integration/'instalacion/generado/linear-instancia.json'
    destination.write_bytes(linear.read_bytes())
    expect('integración ruta antigua ROJA rc3', real_cli('generar-instancia.sh', *common,
           '--linear-config', destination) == 3)
    destination.unlink()
    expect('integración generador real completo', real_cli('generar-instancia.sh', *common, '--linear-config', linear) == 0)

    battery_safety_contracts(PACKAGE, tmp, expect, observar)
    battery_canary_contracts(PACKAGE, tmp, expect, observar)
    battery_canary_diagnostic(PACKAGE, tmp, expect, observar)
    battery_nohup_canaries(PACKAGE, tmp, expect)
    battery_cleanup_failures(PACKAGE, tmp, expect, observar)

    # La entrada de fases es real; solo el hijo de larga duración se sustituye.
    for outcome in ('verde', 'rojo', 'timeout'):
        disposable = tmp/('bateria-'+outcome)
        shutil.copytree(PACKAGE, disposable, ignore=shutil.ignore_patterns('.git', '__pycache__', 'estado', 'generado'))
        trace = tmp/('cwd-'+outcome)
        temporary_parent = tmp/('temporales-'+outcome)
        temporary_parent.mkdir(mode=0o700)
        ledger_hash = hashlib.sha256((PACKAGE/'ledger/cuentas.json').read_bytes()).hexdigest()
        child = ('pwd > '+shlex.quote(str(trace))+'\n'
                 'python3 - <<\'PY\'\n'
                 'import hashlib\nfrom pathlib import Path\n'
                 'assert hashlib.sha256(Path("ledger/cuentas.json").read_bytes()).hexdigest() == '+repr(ledger_hash)+'\n'
                 'for name in ("manifiestos/prueba.conf", "manifiestos/prueba.perfil.tsv", '
                 '"runner-identity.map", "manifiestos/runner-identity.map", "instalacion/estado", '
                 '"instalacion/generado", ".env.local"):\n'
                 '    assert not Path(name).exists(), name\n'
                 'assert not Path(".git").exists()\nPY\n'
                 '[ $? = 0 ] || exit 1\n')
        child += ('sleep 3\n' if outcome == 'timeout' else
                  'echo "RESULTADO: PASS=1 FAIL=0 SKIP=0 TOTAL=1"\n' if outcome == 'verde' else
                  'echo "RESULTADO: PASS=0 FAIL=1 SKIP=0 TOTAL=1"\nexit 1\n')
        stub(disposable/'scripts/run-all-suites.sh', child)
        phase_source = disposable/'instalacion/scripts/fases.py'
        phase_text = phase_source.read_text().replace(*SIN_PREFLIGHT)
        if outcome == 'timeout':
            phase_text = simulacion_timeout('F0 desechable', phase_text)
        phase_source.write_text(phase_text)
        def disposable_cli(name, *arguments):
            global LAST
            result = subprocess.run(['bash', str(disposable/'instalacion'/name), *map(str, arguments)],
                                    env=dict(integration_env, TMPDIR=str(temporary_parent)),
                                    capture_output=True, text=True, timeout=120)
            LAST = result.stdout+result.stderr
            print('E45bz '+outcome+' '+name+' rc='+str(result.returncode))
            return result.returncode
        expect('F0 desechable sella '+outcome, disposable_cli('scripts/manifiesto-nucleo.sh', '--generar') == 0)
        disposable_home = tmp/('hogar-bateria-'+outcome)
        expect('F0 desechable genera instancia real '+outcome,
               disposable_cli('generar-instancia.sh', '--respuestas', integration_answers,
                              '--salida', disposable, '--home', disposable_home, '--linear-config', linear) == 0)
        (disposable/'instalacion/estado').mkdir(mode=0o700, exist_ok=True)
        for name in ('runner-identity.map', 'instalacion/estado/x', 'instalacion/generado/x', '.env.local'):
            path = disposable/name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('dato sintético')
        rc = disposable_cli('scripts/f0-bateria.sh')
        expect('F0 desechable instancia aislada '+outcome,
               rc == (0 if outcome == 'verde' else 1) and trace.exists() and
               str(disposable) != trace.read_text().strip())
        expect('F0 desechable limpieza '+outcome,
               trace.exists() and not Path(trace.read_text().strip()).exists() and not list(temporary_parent.iterdir()))
        result_receipt = disposable/'instalacion/estado/f0-bateria.json'
        data = json.loads(result_receipt.read_text()) if result_receipt.is_file() else {}
        expect('F0 desechable conserva resultado real '+outcome,
               data.get('rc') == {'verde':0, 'rojo':1, 'timeout':124}[outcome] and
               data.get('FAIL') == {'verde':0, 'rojo':1, 'timeout':None}[outcome])
        if outcome == 'verde':
            for name in ('README.md', 'manifiestos/ejemplo.conf'):
                target = disposable/name
                saved = target.read_bytes()
                target.write_bytes(saved+b'alterado\n')
                trace.unlink(missing_ok=True)
                rc = disposable_cli('scripts/f0-bateria.sh')
                observar('F0', rc, LAST)
                expect('F0 distribución alterada '+name, rc == 1 and name in LAST and not trace.exists())
                target.unlink()
                rc = disposable_cli('scripts/f0-bateria.sh')
                expect('F0 distribución ausente y limpieza '+name, rc == 1 and name in LAST and
                       not trace.exists() and not list(temporary_parent.iterdir()))
                target.write_bytes(saved)
    distribution = pkg/'instalacion/DISTRIBUCION.sha256'
    expect('F0 manifiesto distribución pertenece al núcleo', distribution.is_file() and
           '  instalacion/DISTRIBUCION.sha256\n' in (pkg/'instalacion/NUCLEO.sha256').read_text())
    if distribution.is_file():
        saved = distribution.read_bytes()
        distribution.write_bytes(saved+b'alterado\n')
        expect('F0 manifiesto distribución alterado rojo', cli('verificar-nucleo', '--en', pkg)[0] == 1)
        distribution.write_bytes(saved)
    else:
        expect('F0 manifiesto distribución alterado rojo', False)
    # La reproducibilidad se mide en distribución limpia, antes de adjudicarla.
    reproducible = tmp/'reproducible'
    shutil.copytree(PACKAGE, reproducible, ignore=shutil.ignore_patterns('.git', '__pycache__', 'estado', 'generado'))
    def regenerate():
        return subprocess.run(['bash', str(reproducible/'instalacion/scripts/manifiesto-nucleo.sh'), '--generar'],
                              capture_output=True).returncode
    (reproducible/'instalacion/DISTRIBUCION.sha256').write_text('alterado\n')
    first_rc = regenerate()
    manifests = ('NUCLEO.sha256', 'DISTRIBUCION.sha256')
    first = [(reproducible/'instalacion'/name).read_bytes() if (reproducible/'instalacion'/name).exists() else None
             for name in manifests]
    expect('F0 ambos manifiestos reproducibles', first_rc == 0 and regenerate() == 0 and all(first) and
           first == [(reproducible/'instalacion'/name).read_bytes() for name in manifests] and
           hashlib.sha256((reproducible/'README.md').read_bytes()).hexdigest()+'  README.md\n' in
           (reproducible/'instalacion/DISTRIBUCION.sha256').read_text())
    seed = PACKAGE/'instalacion/distribucion/ledger-cuentas.json'
    expect('F0 ejemplo de ledger íntegro en núcleo', seed.is_file() and seed.read_bytes() ==
           (PACKAGE/'ledger/cuentas.json').read_bytes() and hashlib.sha256(seed.read_bytes()).hexdigest() ==
           generator.EXAMPLES['ledger/cuentas.json'])
    def generated_digest():
        return [(str(p.relative_to(root)), p.read_bytes()) for root in (integration, integration_home)
                for p in sorted(root.rglob('*')) if p.is_file()]
    before_repeat = generated_digest()
    expect('integración repetición sin forzar ni cambios', real_cli('generar-instancia.sh', *common,
           '--linear-config', linear) == 0 and generated_digest() == before_repeat)
    generated_linear = destination.read_bytes()
    destination.write_bytes(generated_linear+b' ')
    expect('integración destino editado conserva rc3', real_cli('generar-instancia.sh', *common,
           '--linear-config', linear) == 3 and destination.read_bytes() == generated_linear+b' ')
    destination.write_bytes(generated_linear)
    destination.write_text('{"contenido":"ajeno"}\n')
    expect('integración destino ajeno conserva rc3', real_cli('generar-instancia.sh', *common,
           '--linear-config', linear) == 3 and destination.read_text() == '{"contenido":"ajeno"}\n')
    destination.write_bytes(generated_linear)
    (integration_state/'contexto.conf').write_text('respuestas='+str(integration_answers)+'\nhome='+str(integration_home)+'\nclon='+str(clon)+'\n')
    operational = integration_home/'prueba/.env.local'
    # Solo las credenciales siguen siendo dobles; el generador ya creó la estructura.
    operational.write_text('GITHUB_TOKEN='+secret+'\nLINEAR_API_KEY='+secret+'\nCODERABBIT_API_KEY='+secret+'\n')
    operational.chmod(0o600)
    integration_escrow = integration_home/'.config/talent-channels'
    integration_escrow.mkdir(exist_ok=True, mode=0o700)
    for name in ('git-bootstrap-token', 'cuser-pass'):
        (integration_escrow/name).write_text(secret)
        (integration_escrow/name).chmod(0o600)
    expect('integración check F1 sobre salida real', real_cli('scripts/check-F1.sh') == 0 and secret not in LAST and 'Traceback' not in LAST)

    import producto
    realistic_yaml = ('language: es\nreviews:\n  path_instructions:\n    - path: "**/*.sh"\n'
                      '      instructions: |\n        **Requiere deploy** y *texto*\n'
                      '  auto_review:\n    ignore_title_keywords: ["WIP", "*skip*"] # comentario\n')
    expect('YAML Markdown bloques globs listas comentarios', 'drafts: false' in producto.merge_yaml(realistic_yaml))
    disabled_yaml = 'reviews:\n  request_changes_workflow: true\n  auto_review:\n    enabled: false\n    drafts: false\n'
    expect('onboarding conserva revisión automática desactivada', producto.merge_yaml(disabled_yaml) == disabled_yaml)
    import etiquetas
    label_calls, present_labels = [], set()
    def label_client(args, **kw):
        validar_orden(args)
        label_calls.append(args)
        if args[:2] == ['gh', 'api']:
            return json.dumps([{'name':name} for name in sorted(present_labels)])
        present_labels.add('cr-review')
        return ''
    with patch.object(etiquetas, 'run', label_client):
        etiquetas.ensure_review_label(c, False)
        etiquetas.ensure_review_label(c, False)
    expect('crea etiqueta una sola vez al faltar', len([args for args in label_calls if args[:3] == ['gh', 'label', 'create']]) == 1)
    with patch.object(etiquetas, 'run', lambda *args, **kw: (_ for _ in ()).throw(mod.Error('API rechazada'))):
        try:
            etiquetas.ensure_review_label(c, False)
            rejected = False
        except mod.Error:
            rejected = True
    expect('consulta fallida nunca autoriza etiqueta', rejected)
    policy_clone = tmp/'producto-politica'
    (policy_clone/'.github/workflows').mkdir(parents=True)
    (policy_clone/'.github/workflows/propio.yml').write_text('on: pull_request\n')
    policy_c = dict(c, clon=policy_clone)
    output = io.StringIO()
    with patch('sys.stdout', output):
        mod.repository_policy(policy_c, False)
    expect('YAML ausente registra aviso y workflows sin crearlo', not (policy_clone/'.coderabbit.yaml').exists() and
           'aceptar el gasto de cupo' in output.getvalue() and 'propio.yml' in output.getvalue() and
           json.loads((mod.STATE/'politica-repositorio.json').read_text())['auto_review'] == 'activa-o-no-acreditada')
    (policy_clone/'.coderabbit.yaml').write_text(disabled_yaml)
    mod.repository_policy(policy_c, False)
    expect('política desactivada permanece intacta y se registra', (policy_clone/'.coderabbit.yaml').read_text() == disabled_yaml and
           json.loads((mod.STATE/'politica-repositorio.json').read_text())['auto_review'] == 'desactivada')
    real_alias = 'reviews:\n  path_instructions: *instrucciones\n'
    rejected = False
    try:
        producto.merge_yaml(real_alias)
    except mod.Error as exc:
        rejected = 'fusión humana' in str(exc)
        observar('F4', exc.rc, str(exc))
    expect('YAML alias real detiene', rejected)
    human_merge = real_alias+'  request_changes_workflow: true\n  auto_review:\n    enabled: true\n    drafts: false\n'
    expect('YAML fusión humana correcta se acepta tal cual', producto.merge_yaml(human_merge) == human_merge)
    for syntax in ('reviews: {request_changes_workflow: true, auto_review: {enabled: true, drafts: false}}\n',
                   'policy: &policy\n  request_changes_workflow: true\n  auto_review:\n    enabled: true\n    drafts: false\nreviews: *policy\n',
                   'policy: &policy\n  enabled: true\n  drafts: false\nreviews:\n  request_changes_workflow: true\n  auto_review:\n    <<: *policy\n'):
        expect('YAML fusión humana mapa flujo ancla alias o herencia', producto.merge_yaml(syntax) == syntax)
    code = 'from fases import run; run(["python3", "-c", "import sys; sys.exit(7 if sys.stdin.read() else 0)"])'
    inherited = subprocess.run([sys.executable, '-c', code], input='datos-heredados\n', text=True,
                               env=dict(env, PYTHONPATH=str(scripts)), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    expect('ejecutor cierra stdin aunque el padre tenga datos', inherited.returncode == 0)
    rc, out = cli('f4-onboarding', '--aceptar-canon', '../ajeno')
    expect('error de producto limpio y rc conservado', rc == 2 and 'falla aceptar-canon' in out and 'Traceback' not in out)
    rc, out = cli('f4-proteccion', '--desconocido')
    expect('error de protección limpio y rc conservado', rc == 2 and 'falla uso' in out and 'Traceback' not in out)
    imported = subprocess.run(['/bin/bash', str(scripts/'f8-importar.sh')], input='tar-inválido', text=True,
                              env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    expect('error de importación limpio', imported.returncode == 1 and 'falla importación' in imported.stderr and 'Traceback' not in imported.stderr)
    for mode, diagnostic in [('stat', 'login Claude ausente o modo: CEO'), ('gh', 'gh sin sesión: CEO'),
                             ('coderabbit', 'CodeRabbit CLI ausente: M1')]:
        rc, out = cli('check-F3', extra={'DOBLE_FALLO':mode})
        expect('F3 auxiliar rc distinto de cero '+mode, rc == 1 and diagnostic in out and 'Traceback' not in out)

    with patch.dict(os.environ, realenv, clear=True):
        # El ensayo de handoff anterior sustituyó su verificador por un doble.
        # Restaurar el canon mediante el onboarding real con aceptación explícita.
        canonical_paths = [line.split('\t')[0] for line in
                           (pkg/'skills/talent-repo-onboarding/assets/canon-paquete.tsv').read_text().splitlines()
                           if line and not line.startswith('#')]
        mod.onboarding(c, accepted=canonical_paths)
        changed = clon/'scripts/github/validar-rama-pr.sh'
        old_canon = changed.read_bytes()
        changed.write_text('#!/usr/bin/env bash\necho contrato-previo\n')
        bad_yaml = clon/'.coderabbit.yaml'
        old_yaml = bad_yaml.read_text()
        bad_yaml.write_text(real_alias)
        before = {str(p):p.read_bytes() for p in clon.rglob('*') if p.is_file()}
        output = io.StringIO()
        rejected = False
        with patch('sys.stdout', output):
            try:
                mod.onboarding(c)
            except mod.Error as exc:
                rejected = 'canon existente distinto' in str(exc) and 'fusión humana' in str(exc)
                observar('F4', exc.rc, str(exc))
        expect('onboarding todos los conflictos y cero escrituras', rejected and before ==
               {str(p):p.read_bytes() for p in clon.rglob('*') if p.is_file()})
        expect('onboarding plan muestra diff canon', 'contrato-previo' in output.getvalue() and 'canon/scripts/' in output.getvalue())
        bad_yaml.write_text(old_yaml)
        mod.onboarding(c, accepted=['scripts/github/validar-rama-pr.sh'])
        expect('onboarding acepta sustitución canónica explícita', changed.read_bytes() == old_canon)
        settings = clon/'.claude/settings.json'
        old_settings = settings.read_bytes()
        settings.write_text('[]\n')
        for directory in ('scripts', '.github'):
            (clon/directory).rename(clon/(directory+'-guardado'))
            (clon/directory).symlink_to(clon/(directory+'-guardado'), target_is_directory=True)
        before = {str(p):p.read_bytes() for p in clon.rglob('*') if p.is_file()}
        try:
            mod.onboarding(c)
            diagnostic = ''
        except mod.Error as exc:
            diagnostic = str(exc)
            observar('F4', exc.rc, str(exc))
        expect('onboarding agrega enlaces y JSON inválido sin escribir',
               'destino enlazado en clon: scripts/' in diagnostic and
               'destino enlazado en clon: .github/' in diagnostic and
               'settings inválidos: objeto requerido' in diagnostic and before ==
               {str(p):p.read_bytes() for p in clon.rglob('*') if p.is_file()})
        for directory in ('scripts', '.github'):
            (clon/directory).unlink()
            (clon/(directory+'-guardado')).rename(clon/directory)
        settings.write_bytes(old_settings)
        for rel, directory, expected in [('destino-fixture', True, 'destino no regular'),
                                          ('padre-fixture/hijo', False, 'padre no directorio')]:
            fixture = clon/rel if directory else clon/'padre-fixture'
            fixture.mkdir() if directory else fixture.write_text('contenido conservado\n')
            try:
                producto.clone_destination(clon, rel)
                diagnostic = ''
            except mod.Error as exc:
                diagnostic = str(exc)
                observar('F4', exc.rc, str(exc))
            expect('onboarding rechaza '+expected, expected in diagnostic)
            fixture.rmdir() if directory else fixture.unlink()
        gitignore = clon/'.gitignore'
        old_ignore = gitignore.read_text()
        contract = [line.split('\t')[0] for line in (pkg/'skills/talent-repo-onboarding/assets/canon-paquete.tsv').read_text().splitlines()
                    if line and not line.startswith('#')]
        for pattern in ('lib/', 'scripts/', '*.sh'):
            gitignore.write_text(pattern+'\n'+old_ignore)
            mod.onboarding(c)
            first_ignore = gitignore.read_bytes()
            mod.onboarding(c)
            expect('gitignore excepción idempotente '+pattern, first_ignore == gitignore.read_bytes())
            subprocess.run(['git', '-C', str(clon), 'rm', '--cached', '-r', '--ignore-unmatch', 'scripts', '.githooks'],
                           env=realenv, check=True, stdout=subprocess.PIPE)
            subprocess.run(['git', '-C', str(clon), 'add', 'scripts', '.githooks'], env=realenv, check=True)
            indexed = subprocess.run(['git', '-C', str(clon), 'ls-files'], env=realenv, check=True,
                                     text=True, stdout=subprocess.PIPE).stdout.splitlines()
            expect('gitignore contrato indexado con git real '+pattern, set(contract) <= set(indexed))
        gitignore.write_text(old_ignore)

    for rule, diagnostic in [({'type':'required_status_checks', 'parameters': {'required_status_checks':[{'context':'ajeno'}]}}, 'checks ajenos'),
                             ({'type':'pull_request', 'parameters': {'required_approving_review_count':1}}, 'aprobaciones de revisión')]:
        with patch.object(rulesets, 'run', respuesta_estricta(json.dumps([rule]))):
            rejected = False
            try:
                rulesets.effective_rules(c)
            except mod.Error as exc:
                rejected = diagnostic in str(exc)
                observar('F4', exc.rc, str(exc))
            expect('ruleset detiene '+diagnostic, rejected)

    from ensayo_f3_f7 import casos
    with patch.object(rulesets, 'run', lambda *args, **kw: (_ for _ in ()).throw(mod.Error(kw['diagnostic']))):
        try:
            rulesets.effective_rules(c)
        except mod.Error as exc:
            observar('F4', exc.rc, str(exc))
    import proteccion
    with patch.object(proteccion, 'config', lambda: c), patch.object(rulesets, 'effective_rules'), \
            patch.object(proteccion, 'run', respuesta_estricta('{}')), \
            patch.object(proteccion.subprocess, 'run', respuesta_estricta(SimpleNamespace(returncode=0, stdout='{}'))), \
            patch.object(sys, 'argv', ['f4-proteccion', '--ejecutar']):
        try:
            proteccion.main()
        except mod.Error as exc:
            observar('F4', exc.rc, str(exc))
    casos(PACKAGE, tmp, expect)
    runner_profile = subprocess.run(['python3', str(PACKAGE/'tests/test-runner-provision.py')],
                                    capture_output=True, text=True, timeout=180)
    expect('runner perfil real con git y herramientas de usuario dobladas', runner_profile.returncode == 0)
    if runner_profile.returncode:
        print(runner_profile.stdout+runner_profile.stderr)
    for regression in ('test-instalacion-gates.py', 'test-instalacion-doctor.py'):
        result = subprocess.run(['python3', str(PACKAGE/'tests'/regression)],
                                capture_output=True, text=True, timeout=300)
        expect(regression+' motor real', result.returncode == 0)
        if result.returncode:
            print(result.stdout+result.stderr)
    model_spec = importlib.util.spec_from_file_location('modelos_montaje', PACKAGE/'tests/modelos-montaje.py')
    model_module = importlib.util.module_from_spec(model_spec)
    model_spec.loader.exec_module(model_module)
    model_module.casos(PACKAGE, tmp, expect)
    sys.path.insert(0, str(PACKAGE/'instalacion/tests'))
    import linear_api
    for name, good, rc, output in linear_api.cases():
        expect('contrato Linear '+name, good)
        observar('F1', rc, output)
    # Sus 66 comprobaciones seriales superan 180 s; cada consumidor conserva su propio tope.
    etapas = subprocess.run(['python3', str(PACKAGE/'skills/talent-channels/tests/verify-etapas.py')],
                            capture_output=True, text=True, timeout=600)
    expect('F2 y etapas de canales con consumidores reales', etapas.returncode == 0)
    if etapas.returncode:
        print(etapas.stdout+etapas.stderr)
    # El tope de test-supervision.sh se comprueba estático (issue 9010): la suite real tarda unos 13 min.
    # Medida 800 s en Ubuntu 26.04; el tope debe dar al menos el doble.
    tope_supervision = re.search(r'test-supervision\.sh.*?timeout=(\d+)',
                                 (PACKAGE/'tests/remediaciones.py').read_text(), re.S)
    expect('tope de la supervisión cubre dos veces los 800 s medidos en 26.04',
           tope_supervision is not None and int(tope_supervision.group(1)) >= 2*800)
    # Topes de la batería (issue 9010, medidas de H5): máximo medido 6445 s x 1,5, redondeado a 5 min = 9900 s.
    # Una sola constante con nombre; la usan la espera, el mensaje y la fase (constante + 300).
    fases_texto = (PACKAGE/'instalacion/scripts/fases.py').read_text()
    tope_bateria = re.search(r'^BATTERY_TIMEOUT = (\d+)$', fases_texto, re.M)
    expect('tope de la batería: una sola constante con nombre y al menos 9900 s',
           len(TOPE_BATERIA.findall(fases_texto)) == 1 and tope_bateria is not None and int(tope_bateria.group(1)) >= 9900)
    expect('tope de la batería: la espera usa la constante',
           'battery_wait(process, timeout=BATTERY_TIMEOUT)' in fases_texto)
    expect('tope de la batería: el mensaje de timeout usa la constante',
           'timeout de {BATTERY_TIMEOUT} segundos' in fases_texto)
    expect('tope de la fase F0 es el de la batería + 300',
           "timeout=BATTERY_TIMEOUT + 300 if phase == 'F0' else 600" in fases_texto)
    expect('simulación de timeout cambia solo el valor de la constante',
           simular_timeout('a\nBATTERY_TIMEOUT = 9900\nb\n', 7) == 'a\nBATTERY_TIMEOUT = 7\nb\n')
    for nombre, texto in (('sin tope', 'a\nTIMEOUT = 9900\n'), ('dos topes', 'BATTERY_TIMEOUT = 1\nBATTERY_TIMEOUT = 2\n')):
        try:
            simular_timeout(texto)
            rojo = False
        except ValueError as error:
            rojo = 'BATTERY_TIMEOUT' in str(error)
        expect('simulación de timeout da ROJO con '+nombre, rojo)
    comprobar(PACKAGE, tmp, expect)
    cierre = subprocess.run(['python3', str(PACKAGE/'tests/test-acreditacion-cierre.py')],
                            capture_output=True, text=True, timeout=90)
    expect('cierre de revisión acreditación y guías', cierre.returncode == 0)
    if cierre.returncode:
        print(cierre.stdout+cierre.stderr)

TOTAL_ESPERADO = 1312
if PASS+FAIL != TOTAL_ESPERADO:
    print('FAIL conteo: ejecutados='+str(PASS+FAIL)+' esperados='+str(TOTAL_ESPERADO))
    FAIL += 1
print('PASS='+str(PASS)+' FAIL='+str(FAIL)+' esperados='+str(TOTAL_ESPERADO))
sys.exit(1 if FAIL else 0)
