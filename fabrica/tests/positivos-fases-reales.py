#!/usr/bin/env python3
"""Generación y montaje con consumidores íntegros e infraestructura externa con estado."""
import importlib.util
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys
import tempfile
import traceback
from types import SimpleNamespace
from unittest.mock import patch

PACKAGE = Path(__file__).resolve().parents[1]
PASS = FAIL = 0
os.umask(0o022)


def expect(label, condition):
    global PASS, FAIL
    if condition:
        PASS += 1
        print('PASS '+label, flush=True)
    else:
        FAIL += 1
        print('FAIL '+label, flush=True)


def recorrido(base):
    pkg, home, product = base/'paquete', base/'actores/ceo', base/'producto'
    shutil.copytree(PACKAGE, pkg, ignore=shutil.ignore_patterns('.git', '__pycache__', 'estado', 'generado'))
    home.mkdir(parents=True)
    product.mkdir()
    ceo = pwd.getpwuid(os.getuid()).pw_name
    homes = {ceo: str(home), 'ejemplo-c1': str(base/'actores/ejemplo-c1'),
             'ejemplo-m1': str(base/'actores/ejemplo-m1'), 'ejemplo-incus': str(base/'actores/ejemplo-incus')}
    homes['root'] = str(base/'actores/root')
    Path(homes['root']).mkdir()
    bindir = base/'bin'
    bindir.mkdir()
    for name in ('incus', 'tmux', 'sudo', 'getent', 'id', 'stat', 'crontab', 'claude', 'codex', 'coderabbit',
                 'ps', 'git', 'gh', 'hostname', 'systemctl', 'tailscale', 'df', 'apt-get', 'usermod', 'useradd', 'gpasswd',
                 'chpasswd', 'chown', 'visudo', 'npm', 'corepack', 'ssh-keygen', 'dbus-uuidgen', 'node', 'curl', 'find', 'install'):
        shutil.copyfile(PACKAGE/'tests/fixtures/instalacion/infra-real.py', bindir/name)
        (bindir/name).chmod(0o755)
    for fixture in ('gh_contrato.py', 'gh-2.45.0.json'):
        shutil.copyfile(PACKAGE/'tests/fixtures/instalacion'/fixture, bindir/fixture)
    original_env = os.environ.copy()
    env = dict(original_env, HOME=str(home), PATH=str(bindir)+':'+original_env['PATH'], INFRA_BASE=str(base),
               INFRA_USER=ceo, GIT_AUTHOR_NAME='Operador', GIT_AUTHOR_EMAIL='operador@example.invalid',
               GIT_COMMITTER_NAME='Operador', GIT_COMMITTER_EMAIL='operador@example.invalid')
    for key in ('TA_PERFIL', 'TF_MANIFEST', 'SECRET_DIR', 'XDG_RUNTIME_DIR', 'TA_BUS_STATE_DIR', 'TCO_HOST_ENV', 'HOST_HOME'):
        env.pop(key, None)
    answers = base/'respuestas.resp'
    text = (pkg/'instalacion/tests/fixtures/minima.resp').read_text().replace('usuario_ceo=operador', 'usuario_ceo='+ceo).replace('proyecto=ejemplo', 'proyecto=prueba')
    answers.write_text(text)
    data = dict(ceo=ceo, cuser='operador', project='prueba', homes=homes, containers={}, sessions={}, crons={},
                services={'host:incus-forward.service': True, 'host:incus-startup.service': True},
                git=shutil.which('git'), source=str(product), url='https://github.com/org-example/producto.git')
    (base/'infra.json').write_text(json.dumps(data))
    # Las cuentas externas dobladas también rigen el productor Python real.
    # El consumidor conserva su código; solo se sustituye la consulta del SO.
    python_accounts = base/'cuentas-python'
    python_accounts.mkdir()
    (python_accounts/'sitecustomize.py').write_text("""import json
import os
from pathlib import Path
import pwd
from types import SimpleNamespace
original = pwd.getpwnam
homes = json.loads((Path(os.environ['INFRA_BASE'])/'infra.json').read_text())['homes']
def account(name):
    if name not in homes:
        return original(name)
    return SimpleNamespace(pw_name=name, pw_uid=os.getuid(), pw_gid=os.getgid(), pw_dir=homes[name])
pwd.getpwnam = account
""")
    env['PYTHONPATH'] = str(python_accounts)

    def command(label, *args, extra=None, cwd=None):
        result = subprocess.run(list(map(str, args)), env=dict(env, **(extra or {})), cwd=cwd,
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=180)
        print('CONSUMIDOR '+label+' rc='+str(result.returncode)+'\n'+result.stdout+result.stderr, flush=True)
        return result

    def install(label, script, *args):
        return command(label, 'bash', pkg/'instalacion'/script, *args)

    command('git local inicial', 'git', 'init', '-q', '-b', 'main', product)
    (product/'README.md').write_text('Producto de prueba\n')
    command('git local índice', 'git', '-C', product, 'add', '.')
    command('git local commit', 'git', '-C', product, 'commit', '-qm', 'Producto inicial')
    command('git origin declarado', 'git', '-C', product, 'remote', 'add', 'origin', data['url'])
    common = ['--respuestas', answers, '--salida', pkg, '--home', home]
    result = install('generador env real', 'generar-instancia.sh', *common, '--solo-env')
    expect('productor real de env', result.returncode == 0)
    result = install('generador real', 'generar-instancia.sh', *common, '--linear-config', pkg/'instalacion/tests/fixtures/linear.json')
    expect('productor real de configuración', result.returncode == 0)
    result = install('adjudicación real', 'adjudicar-identidad.sh', '--salida', pkg, '--home', home, '--destino', product)
    expect('adjudicación real sin sustituir consumidores', result.returncode == 0)
    if result.returncode:
        print('PRECOND: adjudicación roja; no se acredita montaje ni se reemplaza su validador', flush=True)
        return
    state = pkg/'instalacion/estado'
    state.mkdir(mode=0o700, exist_ok=True)
    (state/'contexto.conf').write_text('respuestas='+str(answers)+'\nhome='+str(home)+'\nclon='+str(product)+'\n')
    sys.path.insert(0, str(pkg/'instalacion/scripts'))
    spec = importlib.util.spec_from_file_location('fases_positivos', pkg/'instalacion/scripts/fases.py')
    fases = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fases)
    a = dict(line.split('=', 1) for line in text.splitlines())
    c = dict(answers=a, home=home, clon=product, project='prueba', env=home/'prueba/.env.local',
             escrow=home/'.config/talent-channels', bus=home/'prueba/bus',
             manifest=pkg/'manifiestos/prueba.conf', profile=pkg/'manifiestos/prueba.perfil.tsv')
    # Credenciales exclusivamente sintéticas para el proveedor doblado.
    c['env'].write_text('GITHUB_TOKEN=git-sintetico\nLINEAR_API_KEY=linear-sintetica\nCODERABBIT_API_KEY=cr-sintetica\n')
    c['env'].chmod(0o600)
    c['escrow'].mkdir(parents=True, mode=0o700, exist_ok=True)
    for name in ('git-bootstrap-token', 'cuser-pass'):
        path = c['escrow']/name
        path.write_text('valor-sintetico\n')
        path.chmod(0o600)
    for role, user, _ in fases.roles(c):
        h = Path(homes[user])
        (h/'.claude').mkdir(parents=True, exist_ok=True)
        (h/'.claude/.credentials.json').write_text('{}\n')
        (h/'.claude/.credentials.json').chmod(0o600)
        if role != 'CEO':
            own = h/'producto'
            command('clon local '+role, 'git', 'clone', data['url'], own)
            shutil.copytree(product/'.claude', own/'.claude')
            shutil.copytree(product/'manifiestos', own/'manifiestos')
    for role, user, _ in fases.roles(c):
        own = product if role == 'CEO' else Path(homes[user])/'producto'
        command('confirmar F4 '+role, 'git', '-C', own, 'add', '.')
        command('commit F4 '+role, 'git', '-C', own, 'commit', '-qm', 'Montaje del producto')
    # El operador de contenedores no necesita cuenta Claude ni registro propio.
    operator_home = Path(homes[a['usuario_incus']])
    sudoers = base/'sudoers'
    sudoers.mkdir()
    real_path = Path

    def account(name):
        return SimpleNamespace(pw_name=name, pw_uid=os.getuid(), pw_gid=os.getgid(), pw_dir=homes[name])

    def mapped_path(value):
        return sudoers if str(value) == '/etc/sudoers.d' else real_path(value)

    def operation(label, callback):
        try:
            callback()
            expect(label, True)
            return True
        except (fases.Error, subprocess.SubprocessError) as exc:
            print('DIAGNÓSTICO '+label+': '+str(exc), flush=True)
            expect(label, False)
            return False

    def mutation(label, script, callback, diagnostic='97'):
        original = script.read_bytes()
        tracked_clone = next((parent for parent in script.parents if (parent/'.git').is_dir()), None)
        def confirm_mutation():
            if tracked_clone:
                command('índice del ensayo '+label, 'git', '-C', tracked_clone, 'add', script)
                command('commit del ensayo '+label, 'git', '-C', tracked_clone, 'commit', '-qm', 'Consumidor del ensayo')
        try:
            script.write_text('#!/usr/bin/env bash\necho CONSUMIDOR-MUTADO >&2\nexit 97\n')
            confirm_mutation()
            try:
                result = callback()
                rejected = result is not None and result.returncode != 0 and (
                    result.returncode == 97 or diagnostic in result.stdout+result.stderr)
            except fases.Error as exc:
                print('CONSUMIDOR '+label+' mutado: '+str(exc), flush=True)
                rejected = 'rc=97' in str(exc)
            expect('mutación real '+label+' rechazada por su consumidor', rejected)
        finally:
            script.write_bytes(original)
            confirm_mutation()

    # Solo se sustituyen cuentas, privilegios y su ruta de sudoers; run/execute/actor son reales.
    with patch.dict(os.environ, env, clear=True), patch.object(fases, 'privileged', lambda: None), \
            patch.object(fases.pwd, 'getpwnam', account), patch.object(fases, 'Path', mapped_path), \
            patch('grp.getgrnam', lambda _: SimpleNamespace(gr_gid=os.getgid())):
        command('registro real del mando', 'bash', pkg/'instalacion/scripts/modelos-rol.sh', '--resolver')
        fases.core_generate()
        closed = fases.closed_env(c)
        # El PATH confinado conserva únicamente clientes externos doblados.
        closed.update(PATH=env['PATH'], INFRA_BASE=str(base), INFRA_USER=ceo, INFRA_ROOT='1',
                      GIT_AUTHOR_NAME='Operador', GIT_AUTHOR_EMAIL='operador@example.invalid',
                      GIT_COMMITTER_NAME='Operador', GIT_COMMITTER_EMAIL='operador@example.invalid')
        golden = 'golden-prueba'
        result = command('golden real vía provision --only', 'bash', pkg/'skills/talent-channels/scripts/provision.sh',
                         '--local-only', '--only', 'golden', extra=closed)
        expect('montaje golden real con Incus externo', result.returncode == 0)
        if result.returncode:
            return
        operation('siembra real y comprobación del núcleo', lambda: (fases.seed(c, golden), fases.container_core(c, golden)))
        command('parada golden', 'incus', 'stop', golden)
        result = command('clonado real vía provision --only', 'bash', pkg/'skills/talent-channels/scripts/provision.sh',
                         '--local-only', '--only', 'clone', extra=closed)
        expect('montaje clonado real con Incus externo', result.returncode == 0)
        for name in ('runner-prueba', 'p1', 'p2'):
            command('copia externa '+name, 'incus', 'copy', golden, name)
            command('arranque externo '+name, 'incus', 'start', name)
        result = command('perfil runner real', 'incus', 'exec', 'runner-prueba', '--', 'bash', '-c',
                         (pkg/'instalacion/scripts/runner-perfil.sh').read_text(), '_', 'operador', '/home/operador/motor-paquete', data['url'])
        expect('perfil runner real limpio', result.returncode == 0 and 'LIMPIO' in result.stdout)
        (c['escrow']/'channel-profiles.list').write_text('vibe-channel-11=produccion\nvibe-channel-12=produccion\nrunner-prueba=runner\n')
        # Verificación íntegra: no se usa scope identity ni se aplica un modelo artificial.
        result = command('F2 verify real creado', 'bash', pkg/'skills/talent-channels/scripts/verify.sh', '--etapa', 'creado', extra=closed)
        expect('positivo F2 verify real sobre golden y clones', result.returncode == 0)
        mutation('verify', pkg/'skills/talent-channels/scripts/verify.sh',
                 lambda: command('F2 verify mutado', 'bash', pkg/'skills/talent-channels/scripts/verify.sh', '--etapa', 'creado', extra=closed))
        # La restauración vuelve a ejecutar la etapa de F2, sin registro ni modelo artificial.
        result = command('F2 verify restaurado', 'bash', pkg/'skills/talent-channels/scripts/verify.sh', '--etapa', 'creado', extra=closed)
        expect('positivo F2 verify real restaurado', result.returncode == 0)
        for role, user, _ in fases.roles(c):
            operation('resolver real '+role, lambda user=user: fases.actor(user, ['bash', pkg/'instalacion/scripts/modelos-rol.sh', '--resolver']))
        operation('montaje real F5 usuarios/sesiones', lambda: fases.infrastructure(c, 'f5-torres', False))
        expect('operador sin registro ni acreditación Claude tras F5',
               not any((operator_home/path).exists() for path in
                       ('.config/talent-channel-operation/modelos.conf', '.claude/.credentials.json', '.claude_token.env')))
        rules_text = (sudoers/('fabrica-'+c['project'])).read_text()
        expect('sudoers no permite leer modelos como operador',
               not any('ALL=('+a['usuario_incus']+')' in line and 'lib-modelos.sh' in line
                       for line in rules_text.splitlines()))
        parser = shutil.which('visudo', path=original_env['PATH'])
        if parser:
            result = command('parser sudoers del SO', parser, '-c', '-f', sudoers/('fabrica-'+c['project']))
            expect('sudoers del montaje válido para el parser real', result.returncode == 0)
        else:
            print('LÍMITE: visudo del SO no disponible; parser externo no acreditado', flush=True)
        for channel in ('11', '12'):
            operation('preparar-modelo real '+channel, lambda channel=channel: fases.actor(a['usuario_c1'],
                      ['bash', pkg/'skills/talent-channel-operation/scripts/preparar-modelo-canal.sh', 'vibe-channel-'+channel, 'operador']))
            operation('preparar-sesiones real '+channel, lambda channel=channel: fases.actor(a['usuario_c1'],
                      ['bash', Path(homes[a['usuario_c1']])/'producto/.claude/skills/talent-channel-operation/scripts/preparar-sesiones.sh', '--ejecutar', channel]))
        result = install('check F5 real', 'scripts/check-F5.sh')
        expect('positivo F5 consumidores reales sesiones y plan', result.returncode == 0)
        mutation('preparar-sesiones', Path(homes[a['usuario_c1']])/'producto/.claude/skills/talent-channel-operation/scripts/preparar-sesiones.sh',
                 lambda: install('F5 preparar-sesiones mutado', 'scripts/check-F5.sh'))
        mutation('seal-suite --plan', pkg/'scripts/seal-suite.sh',
                 lambda: install('F5 seal-suite mutado', 'scripts/check-F5.sh'),
                 diagnostic='seal-suite plan no resuelve estación/runner')
        result = install('F5 tras restaurar consumidores', 'scripts/check-F5.sh')
        expect('F5 verde tras restaurar consumidores reales', result.returncode == 0)
        ceoscripts = product/'.claude/skills/talent-ceo/scripts'
        for consumer in ('bus-sellar', 'bus-leer', 'tablas-cron'):
            mutation(consumer, ceoscripts/(consumer+'.sh'), lambda: fases.infrastructure(c, 'f6-bus', False))
            # Repetir el montaje desde un bus vacío para alcanzar bus-sellar; solo datos del ensayo.
            if c['bus'].exists():
                c['bus'].write_bytes(b'')
        operation('montaje real F6 bus lectores y cron', lambda: fases.infrastructure(c, 'f6-bus', False))
        result = install('check F6 real', 'scripts/check-F6.sh')
        expect('positivo F6 consumidores reales bus y cron', result.returncode == 0)
        for role, user, _ in fases.roles(c):
            actor_env = ['env', 'TA_BUS_STATE_DIR='+str(Path(homes[user])/'.local/state/talent-ceo'),
                         'TA_BUS='+str(c['bus']), 'TA_BUS_LOCK='+str(c['bus'].with_name('bus.lock')),
                         'TA_PERFIL='+str(c['profile'])]
            ceoscripts = product/'.claude/skills/talent-ceo/scripts'
            def acreditar(role=role, user=user, actor_env=actor_env):
                fases.actor(user, [*actor_env, 'bash', ceoscripts/'reacreditar.sh', '--rol', role, '--iniciar'])
                nonce = (Path(homes[user])/'.local/state/talent-ceo/acreditacion'/(role+'.nonce')).read_text().strip()
                fases.actor(user, [*actor_env, 'bash', ceoscripts/'bus-sellar.sh', '--rol', role,
                                   '--marcador', 'ACRED-'+role+'-'+nonce])
                fases.actor(user, [*actor_env, 'bash', ceoscripts/'reacreditar.sh', '--rol', role, '--verificar'])
            operation('acreditación real posterior al arranque '+role, acreditar)
        runtime = fases.runtime(c)
        # Doctor se limita a las consultas exactas escritas por el montaje, sin sudo libre.
        runtime['INFRA_ENFORCE_READONLY'] = '1'
        env['INFRA_ENFORCE_READONLY'] = '1'
        result = command('doctor real completo', 'bash', product/'.claude/skills/talent-ceo/scripts/doctor.sh', extra=runtime)
        expect('positivo F7 doctor real rc0 y PUERTA ABIERTA', result.returncode == 0 and 'PUERTA ABIERTA' in result.stdout)
        expect('F7 verde sin registro ni credencial del operador', result.returncode == 0 and
               not any((operator_home/path).exists() for path in
                       ('.config/talent-channel-operation/modelos.conf', '.claude/.credentials.json', '.claude_token.env')))
        result = install('check F7 real', 'scripts/check-F7.sh')
        expect('positivo F7 check invoca doctor real', result.returncode == 0)
        mutation('doctor', ceoscripts/'doctor.sh', lambda: install('F7 doctor mutado', 'scripts/check-F7.sh'))
        result = install('F7 tras restaurar doctor', 'scripts/check-F7.sh')
        expect('F7 verde tras restaurar doctor real', result.returncode == 0)
        snapshot = (base/'infra.json').read_bytes()
        external = json.loads(snapshot)
        external['containers']['vibe-channel-11']['power'] = 'STOPPED'
        (base/'infra.json').write_text(json.dumps(external))
        result = command('doctor contenedor parado', 'bash', ceoscripts/'doctor.sh', extra=runtime)
        expect('doctor real rechaza contenedor parado', result.returncode == 1 and 'FALLA canal 11' in result.stdout)
        (base/'infra.json').write_bytes(snapshot)
        rules = sudoers/('fabrica-'+c['project'])
        original_rules = rules.read_bytes()
        rules.chmod(0o600)
        rules.write_text('')
        rules.chmod(0o440)
        result = command('doctor consultas no autorizadas', 'bash', ceoscripts/'doctor.sh', extra=runtime)
        expect('doctor real rechaza sudo sin autorización', result.returncode == 1 and 'NOVERIF' in result.stdout)
        rules.chmod(0o600)
        rules.write_bytes(original_rules)
        rules.chmod(0o440)
        result = command('doctor recursos y permisos restaurados', 'bash', ceoscripts/'doctor.sh', extra=runtime)
        expect('doctor real verde tras restaurar recursos y consultas', result.returncode == 0 and 'PUERTA ABIERTA' in result.stdout)


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='positivos-reales-') as directory:
        try:
            recorrido(Path(directory))
        except Exception as exc:
            print('DIAGNÓSTICO recorrido real: '+repr(exc), flush=True)
            for frame in traceback.extract_tb(exc.__traceback__):
                print('UBICACIÓN '+frame.filename+':'+str(frame.lineno), flush=True)
            expect('recorrido real completa sus consumidores', False)
    print('positivos-reales: PASS='+str(PASS)+' FAIL='+str(FAIL), flush=True)
    sys.exit(1 if FAIL else 0)
