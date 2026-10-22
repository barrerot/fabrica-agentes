#!/usr/bin/python3
"""Infraestructura externa con estado; ejecuta los consumidores del paquete sin reemplazarlos."""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time

base = Path(os.environ.get('INFRA_BASE', str(Path(sys.argv[0]).resolve().parent.parent)))
tool, args = Path(sys.argv[0]).name, sys.argv[1:]
database = base/'infra.json'
data = json.loads(database.read_text())
user = os.environ.get('INFRA_USER', next((u for u, h in data['homes'].items() if h == os.environ.get('HOME')), data['ceo']))
container = os.environ.get('INFRA_CONTAINER', '')


def save():
    database.write_text(json.dumps(data))


def done(value='', rc=0):
    if value:
        print(value)
    sys.exit(rc)


def home_for(name):
    if container:
        root = base/'contenedores'/container
        return root/'root' if name == 'root' else root/'home'/name
    return Path(data['homes'][name])


def session_key(name):
    return (container or user)+':'+name.lstrip('=').split(':')[0]


def mapped(value, root):
    value = value.replace(str(base), '__INFRA_BASE__')
    value = re.sub(r'(?<![A-Za-z0-9_./-])/(?:home|etc|var|root)(?![A-Za-z0-9_.-])',
                   lambda match: str(root)+match[0], value)
    return value.replace('/tmp/tc_tokens.bashrc', str(root)+'/tmp/tc_tokens.bashrc').replace(
        '/tmp/tmp.', str(root)+'/tmp/tmp.').replace('__INFRA_BASE__', str(base))


if tool == 'sudo':
    if args and args[0] == '-l':
        done(rc=1)
    if args == ['--version']:
        done('Sudo version 1.9.15p5')
    selected = user
    while args:
        if args[0] == '-u':
            selected, args = args[1], args[2:]
        elif args[0] in ('-H', '-n', '--'):
            args = args[1:]
        else:
            break
    if not container:
        # NSS del ensayo adjudica homes temporales a los usuarios del perfil público.
        args = [arg.replace('/home/'+name+'/', directory+'/')
                if arg.startswith(('TA_BUS_STATE_DIR=/home/'+name+'/', '/home/'+name+'/')) else arg
                for arg in args for name, directory in [(selected, str(home_for(selected)))]]
    if os.environ.get('INFRA_ENFORCE_READONLY') == '1' and selected != user:
        signature = str(shutil.which(args[0]))+' '+' '.join(args[1:])
        prefix = user+' ALL=('+selected+') NOPASSWD: '
        allowed = []
        for rule in (base/'sudoers'/('fabrica-'+data['project'])).read_text().splitlines():
            if rule.startswith(prefix):
                allowed.append(re.sub(r'\\([\\,:=#])', r'\1', rule[len(prefix):]))
        if signature not in allowed:
            print('sudo: consulta no autorizada por el montaje', file=sys.stderr)
            done(rc=1)
    os.environ.update(HOME=str(home_for(selected)), INFRA_USER=selected)
    if args[:2] == ['env', '-i']:
        # El consumidor conserva su entorno cerrado; solo el transporte externo se confina.
        values = {}
        args = args[2:]
        while args and '=' in args[0]:
            key, value = args.pop(0).split('=', 1)
            values[key] = value
        values.update(PATH=str(base/'bin')+':'+values.get('PATH', '/usr/bin:/bin'),
                      INFRA_BASE=str(base), INFRA_USER=selected, INFRA_ROOT='1')
        os.execvpe(args[0], args, values)
    os.execvp(args[0], args)
elif tool == 'id':
    if args == ['-un']:
        done(user)
    if '-u' in args:
        done(str(0 if os.environ.get('INFRA_ROOT') == '1' else os.getuid()))
    done('fabrica-'+data['project']+' incus-admin docker')
elif tool == 'getent':
    name = args[-1]
    if args[0] == 'group':
        done(name+':x:'+str(os.getgid())+':')
    done(name+':x:'+str(os.getuid())+':'+str(os.getgid())+':actor:'+str(home_for(name))+':/bin/bash')
elif tool == 'stat':
    path = Path(args[-1])
    if not path.exists():
        os.execv('/usr/bin/stat', ['stat', *args])
    fmt = args[args.index('-c')+1]
    owner = user
    if container and 'home' in path.parts:
        owner = path.parts[path.parts.index('home')+1]
    for name, home in data['homes'].items():
        if path == Path(home) or Path(home) in path.parents:
            owner = name
            break
    kind = 'directory' if path.is_dir() else 'regular file'
    fmt = fmt.replace('%U', owner).replace('%F', kind)
    os.execv('/usr/bin/stat', ['stat', '-c', fmt, str(path)])
elif tool in ('find', 'install'):
    # Identidades externas sintéticas; las operaciones y los permisos siguen siendo reales.
    for index, value in enumerate(args[:-1]):
        if value in ('-user', '-o', '-g') and args[index+1] in (data['cuser'], 'runner', *data['homes']):
            if args[index+1] != 'root':
                args[index+1] = str(os.getgid() if value == '-g' else os.getuid())
    os.execv('/usr/bin/'+tool, [tool, *args])
elif tool == 'crontab':
    if args == ['-l']:
        if user not in data['crons']:
            print('no crontab for '+user, file=sys.stderr)
        done(data['crons'].get(user, '').rstrip('\n'), 0 if user in data['crons'] else 1)
    if args == ['-']:
        data['crons'][user] = sys.stdin.read()
        save()
        done()
    done(rc=2)
elif tool == 'claude':
    if '-p' in args:
        family = args[args.index('--model')+1] if '--model' in args else 'sonnet'
        done(json.dumps({'is_error': False, 'subtype': 'success',
                         'result': 'Ready when you are. What would you like to work on?',
                         'modelUsage': {'claude-'+family+'-6-2': {}}}))
    if '--model' in args:
        for key, session in data['sessions'].items():
            if key.startswith(user+':'):
                session['panes']['0'] = {'exe': 'claude', 'model': 'Opus' if 'opus' in args[args.index('--model')+1] else 'Sonnet'}
        save()
    done('2.1.289')
elif tool == 'gh':
    from gh_contrato import validar
    try:
        validar(args)
    except ValueError as exc:
        done(str(exc), 1)
    if args[:2] == ['auth', 'status']:
        done()
    done('gh: consulta no implementada', 2)
elif tool == 'hostname':
    done(container)
elif tool == 'coderabbit':
    if args[:2] == ['auth', 'status']:
        done(rc=0 if (Path(os.environ['HOME'])/'.coderabbit/auth.json').is_file() else 1)
    done('1.0.0')
elif tool == 'git':
    real = data['git']
    if args and args[0] == 'clone':
        destination = args[-1]
        result = subprocess.run([real, 'clone', '-q', data['source'], destination])
        if result.returncode == 0:
            subprocess.run([real, '-C', destination, 'remote', 'set-url', 'origin', data['url']], check=True)
        done(rc=result.returncode)
    if 'ls-remote' in args:
        done(subprocess.check_output([real, 'ls-remote', data['source']], text=True).strip())
    if 'pull' in args:
        index = args.index('pull')
        os.execv(real, [real, *args[:index], 'pull', '--ff-only', data['source'], 'main'])
    os.execv(real, [real, *args])
elif tool == 'tmux':
    target = args[args.index('-t')+1] if '-t' in args else ''
    key = session_key(target)
    if args[0] == 'new-session':
        name = args[args.index('-s')+1]
        key = session_key(name)
        data['sessions'][key] = {'created': int(time.time()), 'pid': 4000+len(data['sessions'])*10,
                                  'alternate': 0, 'panes': {}}
        save()
        if not container:
            # El lanzador del paquete se ejecuta; solo el proveedor final está doblado.
            done(rc=subprocess.run(['bash', '-c', args[-1]], env=os.environ).returncode)
        done()
    if args[0] in ('set-option', 'set', 'split-window'):
        done()
    session = data['sessions'].get(key)
    if args[0] == 'has-session':
        done(rc=0 if session else 1)
    if not session:
        done(rc=1)
    pane = target.split('.')[-1] if '.' in target else '0'
    if args[0] == 'send-keys':
        command = args[args.index('-t')+2]
        session['panes'][pane] = {'exe': 'codex' if 'codex' in command else 'claude',
                                 'model': 'Opus' if 'opus' in command else 'Sonnet'}
        save()
        done()
    if args[0] in ('display-message', 'list-panes'):
        fmt = args[-1]
        done(fmt.replace('#{pane_pid}', str(session['pid'])).replace('#{alternate_on}', str(session['alternate']))
             .replace('#{session_created}', str(session['created'])))
    if args[0] == 'capture-pane':
        model = session['panes'].get(pane, {}).get('model', 'Opus' if key.endswith(':ceo') else 'Sonnet')
        done('['+model+' 6.2] ctx: 12%')
    done(rc=2)
elif tool == 'ps':
    done('\n'.join(str(s['pid'])+' 1 bash\n'+str(s['pid']+1)+' '+str(s['pid'])+' claude'
                   for key, s in data['sessions'].items() if key.split(':')[0] in data['homes']))
elif tool == 'systemctl':
    service = args[-1]
    key = (container or 'host')+':'+service
    if args[0] in ('is-enabled', 'is-active'):
        done('active', 0 if data['services'].get(key, False) else 1)
    if args[0] in ('enable', 'disable', 'stop'):
        data['services'][key] = args[0] == 'enable'
        save()
    done()
elif tool == 'tailscale':
    done(rc=1 if args[:1] == ['ip'] else 0)
elif tool == 'df':
    done('Avail\n500G')
elif tool in ('apt-get', 'usermod', 'gpasswd', 'chpasswd', 'chown', 'visudo', 'npm', 'corepack', 'ssh-keygen', 'dbus-uuidgen'):
    done()
elif tool == 'useradd':
    home_for(args[-1]).mkdir(parents=True, exist_ok=True)
    done()
elif tool == 'node':
    done('v24.0.0')
elif tool == 'codex':
    done('1.0.0')
elif tool == 'curl':
    # El proveedor de paquetes no descarga ni accede a la red.
    if '-o' in args:
        target = Path(args[args.index('-o')+1])
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text('artefacto-sintetico\n')
    done()
elif tool == 'incus':
    op = args[0]
    containers = data['containers']
    if op == 'query':
        match = re.fullmatch(r'/1.0/instances/([^/]+)/files\?path=(/home/[^/]+(?:/\.(?:claude|codex))?)', args[1])
        if not match or match[1] not in containers:
            done(rc=1)
        directory = base/'contenedores'/match[1]/match[2].lstrip('/')
        if not directory.is_dir():
            done(rc=1)
        done(json.dumps(sorted(path.name for path in directory.iterdir())))
    if op == 'info':
        done(rc=0 if args[1] in containers else 1)
    if op == 'list':
        names = sorted(containers)
        query = next((a for a in args[1:] if a.startswith('^')), '')
        if query:
            names = [n for n in names if re.search(query, n)]
        columns = args[args.index('-c')+1] if '-c' in args else 'ns'
        done('\n'.join(containers[n]['power'] if columns == 's' else n if columns == 'n' else n+','+containers[n]['power'] for n in names))
    if op == 'launch':
        name = args[2]
        containers[name] = {'power': 'RUNNING', 'config': {}}
        root = base/'contenedores'/name
        for rel in ('root', 'home/'+data['cuser']+'/.claude', 'home/'+data['cuser']+'/.codex', 'home/runner', 'etc/sudoers.d', 'etc/apt/apt.conf.d',
                    'etc/apt/sources.list.d', 'etc/default', 'etc/ssh', 'etc/systemd/system', 'var/lib/tailscale', 'tmp'):
            (root/rel).mkdir(parents=True, exist_ok=True)
        save()
        done()
    if op == 'copy':
        source, name = args[1:3]
        if containers[source]['power'] != 'STOPPED' or name in containers:
            done(rc=1)
        shutil.copytree(base/'contenedores'/source, base/'contenedores'/name)
        containers[name] = {'power': 'STOPPED', 'config': dict(containers[source]['config'])}
        save()
        done()
    if op in ('start', 'stop', 'restart'):
        containers[args[1]]['power'] = 'STOPPED' if op == 'stop' else 'RUNNING'
        save()
        done()
    if op == 'config':
        action, name, key = args[1:4]
        if action == 'get':
            done(containers[name]['config'].get(key, ''))
        containers[name]['config'][key.split('=')[0]] = args[4] if len(args) > 4 else key.split('=', 1)[1]
        save()
        done()
    if op in ('storage', 'network'):
        done('driver: btrfs' if op == 'storage' else 'name: incusbr0')
    if op == 'file':
        action = args[1]
        remote = args[3] if action == 'push' else args[2]
        name, path = remote.split('/', 1)
        target = base/'contenedores'/name/path
        if action == 'push':
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(args[2], target)
        elif target.exists():
            if args[3] == '-':
                done(target.read_text().rstrip('\n'))
            shutil.copyfile(target, args[3])
        else:
            done(rc=1)
        done()
    if op == 'exec':
        name = args[1]
        if name not in containers or containers[name]['power'] != 'RUNNING':
            done(rc=1)
        root = base/'contenedores'/name
        command = args[args.index('--')+1:]
        selected = 'root'
        if command[:2] == ['su', '-']:
            selected = command[2]
            command = ['bash', '-c', *command[4:]]
        joined = ' '.join(command)
        if '/dev/tcp/' in joined or 'ping -c' in joined:
            done()
        if 'cli.coderabbit.ai/releases/' in joined:
            # Operación externa Incus/proveedor: registrar instalación, sin ejecutar descarga.
            containers[name]['config']['provider.coderabbit'] = '1.0.0'
            save()
            done('CodeRabbit CLI: 1.0.0')
        if 'declared=' in joined and '/proc/' in joined:
            words = shlex.split(command[2])
            pid = int(words[-3])
            session = next((s for k, s in data['sessions'].items() if k.startswith(name+':') and s['pid'] == pid), None)
            if not session:
                done(rc=1)
            done('\n'.join(sorted({p['exe'] for p in session['panes'].values()})))
        if command == ['hostname']:
            done(name)
        os.environ.update(INFRA_CONTAINER=name, INFRA_USER=selected, HOME=str(root/'root' if selected == 'root' else root/'home'/selected), INFRA_ROOT='1',
                          PF_HOME_ROOTS=str(root)+'/root '+str(root)+'/home/*')
        Path(os.environ['HOME']).mkdir(parents=True, exist_ok=True)
        command = [mapped(a, root) for a in command]
        if command[:2] == ['mktemp', '-d']:
            result = subprocess.run(command, capture_output=True, text=True)
            if result.returncode:
                done(result.stderr, result.returncode)
            done('/'+str(Path(result.stdout.strip()).relative_to(root)))
        if command[:2] == ['bash', '-lc']:
            command[1] = '-c'
        os.execvp(command[0], command)
    done('incus: operación no implementada '+op, 2)
else:
    done('infra: cliente no implementado '+tool, 2)
