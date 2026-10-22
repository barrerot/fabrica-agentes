#!/usr/bin/python3
"""Clientes neutros del montaje: nunca acceden a servicios ni sesiones reales."""
import json
import os
from pathlib import Path
import sys
import subprocess

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
if tool in ('gh', 'sudo', 'incus'):
    from gh_contrato import validar_orden
    try:
        validar_orden([tool, *args])
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
bad = os.environ.get('DOBLE_FALLO', '')
base = Path(os.environ.get('DOBLE_HOME', '/fixture-inexistente'))
if bad == tool:
    sys.exit(1)
if tool == 'incus' and os.environ.get('DOBLE_INCUS_OPERACION') and any(
        os.environ['DOBLE_INCUS_OPERACION'] in arg for arg in args) and (
        not os.environ.get('DOBLE_INCUS_CONTENEDOR') or args[1] == os.environ['DOBLE_INCUS_CONTENEDOR']):
    sys.exit(1)
if tool == 'sudo' and args == ['--version']:
    # Doble de sudo-rs (Ubuntu 25.10 en adelante) o del sudo clásico.
    print('sudo-rs 0.2.8' if os.environ.get('DOBLE_SUDO_RS') else 'Sudo version 1.9.15p5')
elif tool == 'sudo':
    selected = None
    while args:
        if args[0] == '-u':
            selected = args[1]
            args = args[2:]
        elif args[0] in ('-n', '-H', '--'):
            args = args[1:]
        else:
            break
    if selected:
        os.environ['HOME'] = str(base/selected)
    os.execvp(args[0], args)
elif tool == 'uname':
    print('Linux')
elif tool == 'locale':
    print('\n'.join(os.environ.get('DOBLE_LOCALES', 'C C.utf8 POSIX en_US.utf8 en_GB.utf8').split()))
elif tool == 'free':
    print('Mem: '+str(int(os.environ.get('DOBLE_RAM', '16'))*1024**3)+' 0 0')
elif tool == 'df':
    print('Avail\n'+str(int(os.environ.get('DOBLE_DISCO', '500'))*1024**3))
elif tool == 'claude':
    if '-p' in args:
        mode = os.environ.get('DOBLE_CAPACIDAD', '')
        if mode == 'timeout':
            import time
            time.sleep(2)
        if mode == 'vacia':
            sys.exit(0)
        if mode == 'invalida':
            print('JSON inválido')
            sys.exit(0)
        result = {'is_error': False, 'subtype': 'success',
                  'result': 'Ready when you are. What would you like to work on?'}
        if mode in ('auth', 'limite', 'otro'):
            result.update(is_error=True, subtype='error_during_execution', result={
                'auth': 'Invalid OAuth token. Please login.',
                'limite': "You've hit your usage limit. Try again later.",
                'otro': 'Error interno sintético'}[mode])
        if mode == 'sin-subtype':
            result.pop('subtype')
        if mode == 'result-vacio':
            result['result'] = ''
        if mode == 'result-numero':
            result['result'] = 123
        if '--model' in args:
            family = args[args.index('--model')+1]
            result['modelUsage'] = {'-'.join(('claude', family, os.environ.get('DOBLE_MODELO_VERSION', '6-2'))): {}}
        if mode in ('error-success', 'success-error', 'two-success'):
            error = dict(result, is_error=True, subtype='error_during_execution', result='quota')
            documents = {'error-success': (error, result), 'success-error': (result, error),
                         'two-success': (result, result)}[mode]
            for document in documents:
                print(json.dumps(document))
        elif mode == 'list':
            print(json.dumps([result]))
        else:
            print(json.dumps(result))
        if mode in ('rc', 'rc-ok'):
            sys.exit(7)
    else:
        print(os.environ.get('DOBLE_VERSION', '2.1.289'))
elif tool == 'timeout':
    if os.environ.get('DOBLE_CAPACIDAD') == 'timeout':
        args[0] = '0.1'
    os.execv('/usr/bin/timeout', ['timeout', *args])
elif tool == 'coderabbit':
    if args == ['auth', 'status'] and os.environ.get('DOBLE_CR_AUTH'):
        sys.exit(1)
    print('1.0.0')
elif tool == 'getent':
    user = args[-1]
    if args[0] == 'group':
        print(user+':x:'+str(os.getgid())+':')
    else:
        print(user+':x:'+str(os.getuid())+':'+str(os.getgid())+':actor:'+str(base/user)+':/bin/bash')
elif tool == 'id':
    print(os.getuid() if args == ['-u'] else os.environ.get('DOBLE_GRUPOS', 'fabrica-ejemplo incus-admin'))
elif tool == 'git':
    if os.environ.get('DOBLE_GIT_OPERACION') in args:
        sys.exit(1)
    if 'status' in args:
        print(os.environ.get('DOBLE_GIT_SUCIO', ''), end='')
    elif args[:3] == ['config', '--global', '--get']:
        if os.environ.get('DOBLE_SIN_IDENTIDAD') == args[-1]:
            sys.exit(1)
        print('operador-example' if args[-1] == 'user.name' else 'operador@example.invalid')
    else:
        print(os.environ.get('DOBLE_ORIGIN', 'https://github.com/org-example/producto.git'))
elif tool == 'tmux':
    if 'has-session' in args and os.environ.get('DOBLE_TMUX_SESION') in args:
        sys.exit(1)
    if args[0] == 'display-message':
        print(os.environ.get('DOBLE_RENDERER', '0'))
    elif args[0] == 'capture-pane':
        family = 'Opus' if args[-1] == 'ceo' else 'Sonnet'
        print(os.environ.get('DOBLE_AVISO') or ('pantalla pendiente' if os.environ.get('DOBLE_SIN_CTX') else
              '['+family+' '+os.environ.get('DOBLE_ETIQUETA_VERSION', '6.2')+'] ctx: 12%'))
elif tool == 'crontab':
    if not os.environ.get('DOBLE_SIN_CRON_TABLAS'):
        print('07,22,37,52 * * * * env TA_BUS_STATE_DIR='+os.environ['DOBLE_CEO_STATE']+' bash /fixture/cron-tablas.sh CRON')
    if os.environ.get('DOBLE_PKG') and not os.environ.get('DOBLE_SIN_CRON_MODELOS'):
        home = Path.home()
        role = {'ejemplo-c1':'C1', 'ejemplo-m1':'M1'}.get(home.name, 'CEO')
        pkg = Path(os.environ['DOBLE_PKG'])
        env = dict(os.environ, TA_ROL=role, TA_BUS=os.environ['DOBLE_CEO_HOME']+'/ejemplo/bus',
                   TA_PERFIL=str((Path(os.environ['DOBLE_CLON']) if role == 'CEO' else home/'producto')/'manifiestos/ejemplo.perfil.tsv'))
        emitted = subprocess.check_output(['bash', str(pkg/'skills/talent-ceo/scripts/cron-modelos.sh'), '--linea'], env=env, text=True)
        print(emitted.replace(' TA_ROL=', ' TA_BUS_STATE_DIR='+str(home/'.local/state/talent-ceo')+' TA_ROL=', 1), end='')
elif tool == 'stat':
    if args[:2] in (['-c', '%u'], ['-c', '%a'], ['-c', '%F']):
        os.execv('/usr/bin/stat', ['stat', *args])
    p = Path(args[-1])
    if p.is_dir():
        print(p.relative_to(base).parts[0] if args[1] == '%U' else oct(p.stat().st_mode & 0o777)[2:]+':'+p.relative_to(base).parts[0]+':directory')
    elif p.is_file():
        user = p.relative_to(base).parts[0]
        if args[1] == '%a:%u':
            print(oct(p.stat().st_mode & 0o777)[2:]+':'+str(os.getuid()))
        else:
            print((oct(p.stat().st_mode & 0o777)[2:]+':' if args[1] == '%a:%U:%F' else '')+user+':regular file')
    else:
        sys.exit(1)
elif tool == 'test':
    if os.environ.get('DOBLE_ACCESO') and args[0] in ('-r', '-w') and Path(args[-1]).name.startswith('bus'):
        sys.exit(1)
    os.execv('/usr/bin/test', ['test', *args])
elif tool == 'incus':
    if os.environ.get('DOBLE_INCUS_LLAMADAS'):
        with open(os.environ['DOBLE_INCUS_LLAMADAS'], 'a') as log:
            log.write(json.dumps(args)+'\n')
    if args[0] == 'list':
        if len(args) > 1 and args[1].startswith('^'):
            name = args[1].strip('^$')
            if name == os.environ.get('DOBLE_CONTENEDOR_AUSENTE'):
                sys.exit(0)
            print(name+(','+'STOPPED' if name.startswith('golden') else ',RUNNING'))
        else:
            print('vibe-channel-11,RUNNING\nvibe-channel-12,RUNNING\nrunner-ejemplo,RUNNING')
    elif args[0] == 'exec' and args[-3:] == ['mktemp', '-d', '/tmp/tmp.XXXXXXXXXX']:
        print(os.environ.get('DOBLE_RUNNER_TEMPORAL', '/tmp/tmp.fixture1'))
    elif args[:2] == ['file', 'push']:
        if not Path(args[2]).is_file():
            sys.exit(1)
    elif args[0] == 'exec' and 'get-url' in args:
        print(os.environ.get('DOBLE_RUNNER_ORIGIN', 'https://github.com/org-example/producto.git'))
    elif args[0] == 'exec' and args[-1] == 'remote':
        print('origin')
    elif args[0] == 'exec' and 'stat' in args:
        print('600')
    elif args[0] == 'exec' and any('claude -p' in arg for arg in args):
        print(json.dumps({'is_error': False, 'subtype': 'success',
                          'result': 'Ready when you are. What would you like to work on?'}))
    elif args[0] == 'exec' and any('--version' in arg for arg in args):
        print('2.1.289')
elif tool == 'gh':
    from gh_contrato import validar
    try:
        validar(args)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
    if args == ['--version']:
        print(os.environ.get('DOBLE_GH_VERSION', 'gh version 2.45.0 (Ubuntu)'))
        sys.exit(0)
    if os.environ.get('DOBLE_GH_LLAMADAS'):
        with open(os.environ['DOBLE_GH_LLAMADAS'], 'a') as log:
            log.write(json.dumps(args)+'\n')
    if args[:2] == ['pr', 'view']:
        print(json.dumps({'number': 1, 'state': os.environ.get('DOBLE_PR_STATE', 'MERGED'), 'headRefOid': 'a'*40, 'mergeCommit': {'oid': 'b'*40},
                          'files': [{'path': os.environ.get('DOBLE_PR_FILE', 'docs/humo.md')}],
                          'body': os.environ.get('DOBLE_PR_BODY', 'Closes ABC-1'),
                          'statusCheckRollup': [{'context':os.environ.get('DOBLE_STATUS', 'local-gates'), 'state': os.environ.get('DOBLE_LOCAL_STATE', 'SUCCESS')}]+json.loads(os.environ.get('DOBLE_CHECKS_AJENOS', '[]'))}))
    elif args[:1] == ['api']:
        if any('/labels?' in arg for arg in args):
            # Dos páginas; la etiqueta buscada solo aparece en la segunda.
            created = os.environ.get('DOBLE_GH_ETIQUETA_CREADA')
            missing = os.environ.get('DOBLE_SIN_CR_LABEL') and not (created and Path(created).exists())
            pages = [[{'name':'bug'}], [] if missing else [{'name':'cr-review'}]]
            if '--jq' in args and args[args.index('--jq')+1] == '.[].name':
                for page in pages:
                    for row in page:
                        print(row['name'])
            else:
                for page in pages:
                    print(json.dumps(page))
        elif '/rules/branches/' in args[-1]:
            print('[]')
        elif '/commits/' not in args[-1]:
            mode = os.environ.get('DOBLE_GITHUB', '')
            if mode in ('rechazado', 'red'):
                print('connection refused' if mode == 'red' else 'HTTP 401', file=sys.stderr)
                sys.exit(1)
            print(json.dumps({'permissions': {'push': mode != 'push', 'admin': mode != 'admin'}}))
        else:
            print(json.dumps({'sha': 'a'*40, 'statuses': [{'context':os.environ.get('DOBLE_STATUS', 'local-gates'),
                                                        'state':'success'}]}))
    elif args[:2] == ['label', 'create'] and os.environ.get('DOBLE_GH_ETIQUETA_CREADA'):
        Path(os.environ['DOBLE_GH_ETIQUETA_CREADA']).write_text('cr-review\n')
elif tool == 'curl':
    if '--write-out' in args:
        mode = os.environ.get('DOBLE_LINEAR', '')
        if mode == 'red':
            sys.exit(7)
        print(json.dumps({'data': {'viewer': {'id':'identidad-sintetica'},
                                  'teams': {'nodes':[{'key':'OTRO' if mode == 'equipo' else 'ABC'}]}}}))
        print('401' if mode == 'rechazada' else '200', end='')
    else:
        print(json.dumps({'data': {'issue': {'identifier':'ABC-1', 'state': {'name': 'Done'}}}}))
