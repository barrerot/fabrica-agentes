"""Regresiones del ensayo con productores reales y secretos sintéticos."""
import copy
import io
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent/'fixtures/instalacion'))
from gh_contrato import validar_orden
from remediaciones import observar, observar_orden


def casos(package, tmp, expect):
    import fases
    import acreditacion
    import proteccion
    actual = json.loads((package/'tests/fixtures/instalacion/proteccion-releida.json').read_text())
    expect('protección respuesta real sin restrictions pasa', proteccion.matches(actual, proteccion.BODY))
    for key, bad in [('required_status_checks', {'strict':True, 'checks':[]}),
                     ('restrictions', {'users':[{'login':'ajeno'}]}), ('enforce_admins', {'enabled':True}),
                     ('required_linear_history', {'enabled':False})]:
        changed = copy.deepcopy(actual)
        changed[key] = bad
        expect('protección drift no se oculta '+key, not proteccion.matches(changed, proteccion.BODY))

    actorhome = tmp/'inicio-actor'
    actorhome.mkdir()
    token = 'token-sintetico-privado'
    envfile = actorhome/'operacional'
    envfile.write_text('GITHUB_TOKEN=git-sintetico\nLINEAR_API_KEY=linear-sintetica\nCODERABBIT_API_KEY=cr-sintetica\n')
    envfile.chmod(0o600)
    (actorhome/'.claude').mkdir()
    login = actorhome/'.claude/.credentials.json'
    login.write_text('{}')
    login.chmod(0o600)
    tokenfile = actorhome/'.claude_token.env'
    tokenfile.write_text('export CLAUDE_CODE_OAUTH_TOKEN='+token+'\n')
    tokenfile.chmod(0o600)
    configuration = fases.station_file(actorhome)
    configuration.parent.mkdir(parents=True)
    (configuration.parent/'runtime.conf').write_text('export TA_BUS_STATE_DIR='+str(actorhome/'.local/state/talent-ceo')+'\n'
        'export TA_BUS='+str(actorhome/'bus')+'\nexport TA_BUS_LOCK='+str(actorhome/'bus.lock')+'\n')
    configuration.write_text('TF_STATION_HOST=host-example\nTF_CLONE=/srv/producto\nTF_MANIFEST=/srv/instancia.conf\n'
        'TF_SLUG=org-example/producto\nTF_RUNNER_USER=runner\nTF_RUNNER_REPO=/home/runner/repo\nTF_RUNNERS=runner-ejemplo\n')
    model_bin = actorhome/'model-bin'
    model_bin.mkdir()
    shutil.copyfile(package/'tests/fixtures/instalacion/cliente.py', model_bin/'claude')
    (model_bin/'claude').chmod(0o755)
    model_env = dict(os.environ, HOME=str(actorhome), PATH=str(model_bin)+':'+os.environ['PATH'])
    subprocess.run(['bash', str(fases.ROOT/'instalacion/scripts/modelos-rol.sh'), '--resolver'],
                   env=model_env, capture_output=True, check=True)
    executions = []
    with patch.object(fases.Path, 'home', lambda: actorhome), patch.object(fases.os, 'execvpe',
              lambda *args: executions.append(args)), patch.dict(os.environ,
              HOME=str(actorhome), PATH=model_env['PATH'], GITHUB_TOKEN='heredado', GH_TOKEN='heredado', LINEAR_API_KEY='heredada',
              CODERABBIT_API_KEY='heredada', CLAUDE_CODE_OAUTH_TOKEN='heredado'):
        fases.start_actor(['M1', str(envfile), str(actorhome/'bus'), str(actorhome/'manifiesto')])
        captured = executions[-1][2]
        expect('M1 carga configuración pública de gates', captured.get('TF_CLONE') == '/srv/producto' and
               captured.get('TF_RUNNER_REPO') == '/home/runner/repo')
        expect('torre solo exporta credencial de Claude', captured.get('CLAUDE_CODE_OAUTH_TOKEN') == token and
               not {'GITHUB_TOKEN', 'GH_TOKEN', 'LINEAR_API_KEY', 'CODERABBIT_API_KEY'} & captured.keys())
        expect('bootstrap C1 usa entorno del rol fuera del clon sin exportar clave', captured.get('TA_OPERATION_ENV') == str(envfile) and
               'TA_OPERATION_ENV:-$REPO_ROOT/.env.local' in
               (package/'skills/talent-coordination/references/01-bootstrap-y-puesto-de-mando.md').read_text())
        fases.start_actor(['CEO', str(envfile), str(actorhome/'bus'), str(actorhome/'manifiesto')])
        expect('modelos CEO usa Opus del registro real', executions[-1][1][-2:] == ['--model', '-'.join(('claude', 'opus', '6-2'))])
        fases.start_actor(['M1', str(envfile), str(actorhome/'bus'), str(actorhome/'manifiesto')])
        expect('modelos merge usa Sonnet del registro real', executions[-1][1][-2:] == ['--model', '-'.join(('claude', 'sonnet', '6-2'))])
        tokenfile.unlink()
        fases.start_actor(['CEO', str(envfile), str(actorhome/'bus'), str(actorhome/'manifiesto')])
        expect('torre login no hereda token ni secretos', 'CLAUDE_CODE_OAUTH_TOKEN' not in executions[-1][2])
        login.unlink()
        try:
            fases.start_actor(['C1', str(envfile), str(actorhome/'bus'), str(actorhome/'manifiesto')])
            rejected = False
        except fases.Error:
            rejected = True
        expect('torre sin login ni token falla cerrada', rejected and len(executions) == 4)

    # Comprobar el consumidor real con ambos modos y ficheros privados.
    binpath = actorhome/'bin'
    binpath.mkdir()
    cli = binpath/'claude'
    cli.write_text("#!/bin/bash\nprintf '%s\\n' '{\"is_error\":false,\"subtype\":\"success\",\"result\":\"Ready when you are. What would you like to work on?\"}'\n")
    cli.chmod(0o755)
    environment = dict(os.environ, HOME=str(actorhome), PATH=str(binpath)+':'+os.environ['PATH'])
    probe = package/'instalacion/scripts/claude-capacidad.sh'
    def capacity():
        return subprocess.run(['bash', str(probe)], env=environment, capture_output=True, text=True)
    tokenfile.write_text('export CLAUDE_CODE_OAUTH_TOKEN='+token+'\n')
    tokenfile.chmod(0o600)
    result = capacity()
    expect('capacidad token real no imprime valores ni respuesta', result.returncode == 0 and not result.stdout and token not in result.stderr)
    tokenfile.chmod(0o644)
    expect('capacidad token modo inseguro rojo', capacity().returncode != 0)
    tokenfile.unlink()
    login.write_text('{}')
    login.chmod(0o600)
    expect('capacidad login real verde', capacity().returncode == 0)
    cli.write_text("#!/bin/bash\nprintf '%s\\n' '{\"is_error\":false,\"subtype\":\"success\",\"result\":\"respuesta distinta\"}'\n")
    expect('capacidad invierte respuesta distinta de OK: ahora verde', capacity().returncode == 0)
    cli.write_text("#!/bin/bash\nprintf '%s\\n' '{\"is_error\":true,\"subtype\":\"error_during_execution\",\"result\":\"fallo\"}'\n")
    expect('capacidad CLI rechazado rojo', capacity().returncode != 0)
    cli.write_text('#!/bin/bash\nexit 7\n')
    expect('capacidad auxiliar rc no cero rojo', capacity().returncode != 0)

    # Lectura oculta por alias; la contraseña no aparece en stdout.
    escrow = actorhome/'escrow'
    escrow.mkdir(mode=0o700)
    c = {'answers': {'claude_auth':'token', 'pozos_alias':'cuenta-a,cuenta-b'}, 'escrow':escrow}
    output = io.StringIO()
    with patch.object(acreditacion.sys, 'stdin', SimpleNamespace(isatty=lambda: True)), \
            patch.object(acreditacion.getpass, 'getpass', lambda _: token), patch('sys.stdout', output):
        acreditacion.read_tokens(c)
    expect('lector oculto guarda todos los alias 0600', all((escrow/'tokens'/(alias+'.token')).stat().st_mode & 0o777 == 0o600
           for alias in ('cuenta-a', 'cuenta-b')) and token not in output.getvalue())
    with patch.object(acreditacion.sys, 'stdin', SimpleNamespace(isatty=lambda: False)):
        try:
            acreditacion.read_tokens(c)
            rejected = False
        except fases.Error as exc:
            rejected = exc.rc == 2 and 'lectura oculta requiere terminal' in str(exc)
        expect('lector token sin terminal no lee', rejected)
    tokenroot = actorhome/'raiz-token'
    (tokenroot/'ledger').mkdir(parents=True)
    (tokenroot/'ledger/cuentas.json').write_text('{"pozos":{"p1":{"cuenta":"cuenta-a"}}}')
    c.update(project='ejemplo', clon=Path('/fixture/producto'), manifest=tokenroot/'manifiestos/ejemplo.conf')
    (escrow/'channel-profiles.list').write_text('vibe-channel-11=produccion\nvibe-channel-12=produccion\nrunner-ejemplo=runner\n')
    c['answers'].update(usuario_ceo='ceo', usuario_c1='c1', usuario_m1='m1', usuario_incus='operador-incus', cuser='usuario-canal',
                        repo_url='https://github.com/org-example/producto.git')
    deliveries = []
    with patch.object(acreditacion, 'ROOT', tokenroot), patch.object(acreditacion, 'privileged'), \
            patch.object(fases, 'channels', lambda _: ['vibe-channel-11', 'vibe-channel-12']), \
            patch.object(acreditacion, 'wells', lambda _: ['p1']), \
            patch.object(acreditacion, 'user_home', lambda _: actorhome), \
            patch.object(acreditacion.pwd, 'getpwnam', lambda _: SimpleNamespace(pw_uid=os.getuid())), \
            patch.object(acreditacion, 'input_command', lambda argv, data, diagnostic:
                         (validar_orden(argv), deliveries.append((argv, data)))[1]):
        acreditacion.install_tokens(c, True)
        expect('distribución token plan sin mutaciones', not deliveries)
        acreditacion.install_tokens(c, False)
        expect('distribución token roles canales pozo sin runner', len(deliveries) == 6 and
               not any('runner-ejemplo' in argv for argv, _ in deliveries) and
               all(payload == token.encode() and token not in ' '.join(map(str, argv)) for argv, payload in deliveries))
        expect('distribución reutiliza token_env_write sin relanzamiento', all('token_env_write' in ' '.join(map(str, argv)) and
               not any(word in ' '.join(map(str, argv)) for word in ('kill ', 'tmux ', '--continue')) for argv, _ in deliveries))
        deliveries.clear()
        (escrow/'channel-profiles.list').write_text('vibe-channel-11=runner\nvibe-channel-12=produccion\nrunner-ejemplo=runner\n')
        acreditacion.install_tokens(c, False)
        expect('reparto excluye perfil runner aunque tenga nombre de canal', len(deliveries) == 5 and
               not any('vibe-channel-11' in argv for argv, _ in deliveries))
        deliveries.clear()
        (escrow/'channel-profiles.list').write_text('vibe-channel-11=produccion\nvibe-channel-12=produccion\nrunner-ejemplo=runner\n')
        probes = []
        with patch.object(fases, 'actor', lambda user, argv, **kw: (validar_orden(argv), probes.append(argv))[1]):
            fases.runner_preflight(c)
        expect('F2 usa sonda de runner autorizable sin shell arbitrario', len(probes) == 1 and
               Path(probes[0][1]).name == 'verificar-runner.sh' and
               probes[0][2:] == ['runner-ejemplo', c['answers']['repo_url'], 'F2', str(c['manifest'])])
        (escrow/'tokens/cuenta-b.token').chmod(0o644)
        try:
            acreditacion.install_tokens(c, False)
            rejected = False
        except fases.Error:
            rejected = True
        expect('distribución token preflight impide escribir ante modo inseguro', rejected and not deliveries)
        (escrow/'tokens/cuenta-b.token').chmod(0o600)

    cr_calls = []
    host_calls = []
    with patch.object(acreditacion, 'secret_values', lambda _: {'GITHUB_TOKEN':token}), \
            patch.object(acreditacion, 'input_command', lambda argv, data, diagnostic:
                         (validar_orden(argv), host_calls.append((argv, data)))[1]), \
            patch.object(acreditacion, 'actor', lambda user, argv, **kw: (validar_orden(argv), host_calls.append((user, argv)))[1]):
        acreditacion.configure_host_git(c)
        expect('git host configura ayudante en los tres roles', host_calls[1::2] ==
               [(user, ['gh', 'auth', 'setup-git']) for user in ('ceo', 'c1', 'm1')] and
               all(payload == token.encode() and token not in ' '.join(argv) for argv, payload in host_calls[::2]))
    with patch.object(acreditacion, 'secret_values', lambda _: {'GITHUB_TOKEN':token}), \
            patch.object(acreditacion, 'input_command', lambda argv, *args, **kw: validar_orden(argv)), \
            patch.object(acreditacion, 'actor', lambda *args, **kw: (_ for _ in ()).throw(fases.Error(kw['diagnostic']))):
        try:
            acreditacion.configure_host_git(c)
            rejected = False
        except fases.Error as exc:
            rejected = str(exc) == 'git sin autenticación: ceo'
        expect('git host ayudante fallido conserva diagnóstico y rechazo', rejected)

    def cr_run(args, **kw):
        validar_orden(args)
        cr_calls.append(args)
        if args[:2] == ['uname', '-m']:
            return 'x86_64\n'
        if args[0] == 'curl':
            Path(args[-1]).write_bytes(b'artefacto-alterado')
        return ''
    with patch.object(acreditacion, 'ROOT', package), patch.object(acreditacion, 'run', cr_run), patch.object(acreditacion, 'privileged'):
        acreditacion.coderabbit(c, True)
        expect('CodeRabbit plan sin descarga ni instalación', all(args[0] == 'uname' for args in cr_calls))
        try:
            acreditacion.coderabbit(c, False)
            rejected = False
        except fases.Error as exc:
            rejected = 'sha256 distinto' in str(exc)
        expect('CodeRabbit sha256 rojo impide instalación', rejected and not any(args[0] == 'install' for args in cr_calls))
    expect('CodeRabbit host y plantilla comparten fuente', 'coderabbit-pin.conf' in
           (package/'skills/talent-channels/scripts/02-golden.sh').read_text() and 'CR_CLI_VERSION="' not in
           (package/'skills/talent-channels/scripts/02-golden.sh').read_text())

    # Hook generado anclado, ejecutado desde un subdirectorio con el CLI de Bash real.
    product = actorhome/'producto'
    (product/'scripts').mkdir(parents=True)
    (product/'subdirectorio').mkdir()
    (product/'scripts/check-push-audit.sh').write_text('#!/bin/bash\nprintf hook-anclado\n')
    settings = json.loads((package/'instalacion/plantillas/producto/settings.json.tmpl').read_text())
    command = settings['hooks']['PreToolUse'][1]['hooks'][0]['command']
    result = subprocess.run(['bash', '-c', command], cwd=product/'subdirectorio',
                            env=dict(os.environ, CLAUDE_PROJECT_DIR=str(product)), capture_output=True, text=True)
    expect('hook desde subdirectorio resuelve raíz del proyecto', result.returncode == 0 and result.stdout == 'hook-anclado')
    configuration.write_text(configuration.read_text()+'TF_NO_PERMITIDA=valor\n')
    try:
        fases.read_station(configuration)
        rejected = False
    except fases.Error:
        rejected = True
    expect('configuración estación rechaza claves adicionales', rejected)
    _integracion(package, tmp, expect)


def _integracion(package, tmp, expect):
    base = tmp/'ensayo-integro'
    pkg, home, product = base/'paquete', base/'hogar', base/'producto'
    shutil.copytree(package, pkg, ignore=shutil.ignore_patterns('.git', '__pycache__', 'estado', 'generado'))
    home.mkdir()
    product.mkdir()
    env = dict(os.environ, HOME=str(home), GIT_AUTHOR_NAME='Operador', GIT_AUTHOR_EMAIL='operador@example.invalid',
               GIT_COMMITTER_NAME='Operador', GIT_COMMITTER_EMAIL='operador@example.invalid')
    # Clientes externos doblados; el montaje y Git conservan su recorrido real.
    bindir = base/'bin'
    bindir.mkdir()
    for fixture in ('gh_contrato.py', 'gh-2.45.0.json'):
        shutil.copyfile(package/'tests/fixtures/instalacion'/fixture, bindir/fixture)
    protection = json.loads((package/'tests/fixtures/instalacion/proteccion-releida.json').read_text())
    (bindir/'gh').write_text('#!/usr/bin/python3\nimport json,sys\nfrom gh_contrato import validar\nvalidar(sys.argv[1:])\np='+repr(protection)+'\n'
        's={"allow_squash_merge":True,"allow_merge_commit":True,"allow_rebase_merge":True,"delete_branch_on_merge":False}\n'
        'print(json.dumps([{"name":"cr-review"}] if any("/labels?" in a for a in sys.argv) else [] if "/rules/branches/" in sys.argv[-1] else p if sys.argv[-1].endswith("/protection") else s))\n')
    (bindir/'gh').chmod(0o755)
    (bindir/'coderabbit').write_text('#!/bin/bash\nprintf "1.0.0\\n"\n')
    (bindir/'coderabbit').chmod(0o755)
    env['PATH'] = str(bindir)+':'+os.environ['PATH']
    def command(*args):
        return subprocess.run(list(map(str, args)), env=env, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=180)
    def install(script, *args):
        result = command('bash', pkg/'instalacion'/script, *args)
        observar_orden(script, args, result.returncode, result.stdout+result.stderr)
        if result.returncode:
            print(result.stdout+result.stderr)
        return result
    answers = base/'respuestas.resp'
    values = (pkg/'instalacion/tests/fixtures/minima.resp').read_text().replace('usuario_ceo=operador',
                     'usuario_ceo='+pwd.getpwuid(os.getuid()).pw_name).replace('proyecto=ejemplo', 'proyecto=prueba')
    answers.write_text(values)
    common = ['--respuestas', answers, '--salida', pkg, '--home', home]
    expect('integración íntegra cuestionario', install('cuestionario.sh', '--respuestas', answers, 'siguiente').stdout.strip() == 'COMPLETO')
    expect('integración íntegra primera generación env', install('generar-instancia.sh', *common, '--solo-env').returncode == 0)
    expect('integración íntegra primera generación sin forzar', install('generar-instancia.sh', *common,
           '--linear-config', pkg/'instalacion/tests/fixtures/linear.json').returncode == 0)
    generated_ledger = pkg/'ledger/cuentas.json'
    ledger_bytes = generated_ledger.read_bytes()
    generated_ledger.write_text('{}\n')
    install('generar-instancia.sh', *common, '--linear-config', pkg/'instalacion/tests/fixtures/linear.json')
    generated_ledger.write_bytes(ledger_bytes)
    answers.write_text(values.replace('repo_rama=main', 'repo_rama=develop'))
    install('generar-instancia.sh', *common, '--linear-config', pkg/'instalacion/tests/fixtures/linear.json')
    answers.write_text(values)
    command('git', 'init', '-q', '-b', 'main', product)
    command('git', '-C', product, 'remote', 'add', 'origin', 'https://github.com/org-example/producto.git')
    for member in ('propio', 'skill-creator'):
        (product/'.claude/skills'/member).mkdir(parents=True)
        (product/'.claude/skills'/member/'SKILL.md').write_text('# Skill previo\n')
    for rel in ('CLAUDE.md', 'AGENTS.md', '.github/PULL_REQUEST_TEMPLATE.md'):
        path = product/rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('Instrucciones previas del producto\n')
    (product/'.coderabbit.yaml').write_text('language: es\nreviews:\n  path_instructions:\n    - path: "**/*.sh"\n      instructions: |\n        **Requiere prueba** y *revisión*\n')
    (product/'.gitignore').write_text('lib/\n')
    previous = product/'scripts/github/validar-rama-pr.sh'
    previous.parent.mkdir(parents=True)
    previous.write_text('#!/bin/bash\necho regla-previa\n')
    command('git', '-C', product, 'add', '.')
    command('git', '-C', product, 'commit', '-qm', 'Producto previo')
    adjud = ['--salida', pkg, '--home', home, '--destino', product]
    expect('integración íntegra homónimo detiene', install('adjudicar-identidad.sh', *adjud).returncode == 3)
    expect('integración íntegra adjudicación real', install('adjudicar-identidad.sh', *adjud, '--sustituir-todos').returncode == 0)
    state = pkg/'instalacion/estado'
    state.mkdir(mode=0o700, exist_ok=True)
    (state/'contexto.conf').write_text('respuestas='+str(answers)+'\nhome='+str(home)+'\nclon='+str(product)+'\n')
    before = previous.read_bytes()
    expect('integración íntegra canon distinto detiene sin escribir', install('scripts/f4-onboarding.sh').returncode != 0 and previous.read_bytes() == before)
    result = install('scripts/f4-onboarding.sh', '--aceptar-canon', 'scripts/github/validar-rama-pr.sh')
    expect('integración íntegra onboarding real', result.returncode == 0)
    command('git', '-C', product, 'add', '.')
    indexed = command('git', '-C', product, 'ls-files').stdout.splitlines()
    expect('integración íntegra lib ignorado entra al índice', 'scripts/lib/handoff.sh' in indexed and 'scripts/lib/cr-finding-normalize.jq' in indexed)
    result = install('scripts/check-F4.sh')
    expect('integración íntegra check F4 consumidores reales', result.returncode == 0 and 'manuales pendientes=' in result.stdout)
    expect('integración íntegra conserva instrucciones y skill propio', all((product/rel).read_text().startswith('Instrucciones previas')
           for rel in ('CLAUDE.md', 'AGENTS.md', '.github/PULL_REQUEST_TEMPLATE.md')) and
           (product/'.claude/skills/propio/SKILL.md').read_text() == '# Skill previo\n')
    env.update(TF_MANIFEST=str(pkg/'manifiestos/prueba.conf'), TA_PERFIL=str(product/'manifiestos/prueba.perfil.tsv'),
               TA_BUS=str(home/'prueba/bus'), TA_BUS_LOCK=str(home/'prueba/bus.lock'))
    result = command('bash', product/'.claude/skills/talent-ceo/scripts/doctor.sh')
    observar('F7', result.returncode, result.stdout+result.stderr)
    print('Doctor real con configuración generada: rc='+str(result.returncode)+'\n'+result.stdout+result.stderr)
    expect('F7 doctor real conserva rechazo sin infraestructura', result.returncode != 0 and
           ('PRECOND' in result.stdout+result.stderr or 'FALLA' in result.stdout+result.stderr))
