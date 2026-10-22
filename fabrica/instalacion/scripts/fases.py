#!/usr/bin/env python3
"""Montaje por fases: lecturas cerradas, checks sin reparación y estado encadenado."""
import argparse
import contextlib
import ctypes
import fcntl
import fnmatch
import getpass
import hashlib
import json
import os
from pathlib import Path
import pwd
import grp
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import tarfile
import difflib
import time
from datetime import datetime, timezone

# Los auxiliares importan esta misma instancia, también al invocar el CLI.
if __name__ == '__main__':
    sys.modules['fases'] = sys.modules[__name__]

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'instalacion/scripts'))
from nucleo import exclusions, excluded
os.environ['LC_ALL'] = 'C'
STATE = ROOT / 'instalacion/estado'
HEX = re.compile(r'[0-9a-f]{64}')
ZERO = '0' * 64
MAIN_HELP = ('Esta versión requiere main como rama principal. La persona debe decidir '
             'si renombra la rama por defecto del repositorio y después registrar repo_rama=main; '
             'el instalador no renombra ramas automáticamente.')
ROOT_HELP = ('No instalar como root. Cree un usuario normal: adduser instalador; '
             'usermod -aG sudo instalador; chown -R instalador:instalador /srv/fabrica; '
             'abra una sesión de instalador y reabra el asistente en /srv/fabrica.')
TREES = ('skills', 'scripts', 'githooks', 'plantillas', 'tests', 'instalacion')
# Tope de la batería de F0, en segundos: UNA constante; la usan la espera, su mensaje y el tope de la fase.
# Medida mayor 6445 s (Ubuntu 26.04, 4 núcleos, 15-oct-2026) x 1,5 = 9667,5, redondeada a 5 min.
BATTERY_TIMEOUT = 9900


class Error(Exception):
    def __init__(self, message, rc=1):
        super().__init__(message)
        self.rc = rc


def require(ok, message, rc=1):
    if not ok:
        raise Error(message, rc)


def regular(path, private=False, owner=None):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), 'pieza ausente o enlace: ' + path.name)
    if private:
        require(stat.S_IMODE(path.stat().st_mode) == 0o600, 'modo 0600: ' + path.name)
        require(path.stat().st_uid == (os.getuid() if owner is None else owner), 'propietario: ' + path.name)
    return path


def safe_dir(path):
    path = Path(path)
    for parent in (path, *path.parents):
        require(not parent.is_symlink(), 'directorio enlazado: ' + path.name, 2)
    if path.exists():
        require(path.is_dir() and path.stat().st_uid == os.getuid(), 'directorio ajeno: ' + path.name, 2)
        require(stat.S_IMODE(path.stat().st_mode) == 0o700, 'directorio modo 0700: ' + path.name, 2)
    else:
        path.mkdir(parents=True, mode=0o700)
        path.chmod(0o700)


def write(path, data, mode=0o600):
    path = Path(path)
    require(not any(p.is_symlink() for p in (path, *path.parents)),
            'destino enlazado: ' + path.name, 2)
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def role_directory(home, directory, user, mode=0o700):
    """Prepara componentes propios y del administrador, sin recursividad."""
    home, directory = Path(home), Path(directory)
    require(directory.is_relative_to(home) and directory != home,
            'directorio fuera del home del rol', 2)
    owner = pwd.getpwnam(user)
    require(not any(path.is_symlink() for path in (home, *home.parents)),
            'home de rol enlazado', 2)
    chain = [home]
    for part in directory.relative_to(home).parts:
        chain.append(chain[-1]/part)
    corrections = {}
    # Validar todos los destinos existentes antes de crear o restringir ninguno.
    for path in chain:
        correction = 'sudo chown -- '+shlex.quote(user)+' '+shlex.quote(str(path))+' && sudo chmod go-w -- '+shlex.quote(str(path))
        observed = path.lstat() if path.exists() or path.is_symlink() else None
        if observed and stat.S_ISLNK(observed.st_mode):
            correction = 'unlink -- '+shlex.quote(str(path))+'; restaurar un directorio real en esa ruta'
        detail = (' ruta='+str(path)+' propietario='+str(observed.st_uid)+
                  ' modo='+format(stat.S_IMODE(observed.st_mode), '04o')+'; corrección: '+correction) if observed else ''
        require(not path.is_symlink(), 'directorio de rol enlazado:'+detail+
                '; retirar el enlace sin seguirlo y restaurar un directorio real antes de corregir', 2)
        if path.exists():
            info = path.stat()
            detail = (' ruta='+str(path)+' propietario='+str(info.st_uid)+
                      ' modo='+format(stat.S_IMODE(info.st_mode), '04o')+'; corrección: '+correction)
            administrator = path != home and info.st_uid != owner.pw_uid and info.st_uid in (0, os.geteuid())
            require(path.is_dir() and (info.st_uid == owner.pw_uid or administrator),
                    'directorio de rol ajeno:'+detail, 2)
            observed_mode = stat.S_IMODE(info.st_mode)
            correctable = (path != home and info.st_uid == owner.pw_uid and
                           not observed_mode & 0o002 and observed_mode & 0o020 and
                           info.st_gid == owner.pw_gid)
            require(administrator or not observed_mode & 0o022 or correctable,
                    'directorio de rol escribible por terceros:'+detail, 2)
            if correctable:
                corrections[path] = info
    for path in chain[1:]:
        if path in corrections:
            observed = corrections[path]
            fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
            try:
                current = os.fstat(fd)
                require((current.st_dev, current.st_ino, current.st_uid, current.st_gid, current.st_mode) ==
                        (observed.st_dev, observed.st_ino, observed.st_uid, observed.st_gid, observed.st_mode),
                        'directorio de rol cambiado durante preparación: '+str(path), 2)
                previous_mode = stat.S_IMODE(observed.st_mode)
                new_mode = previous_mode & ~0o020
                os.fchmod(fd, new_mode)
            finally:
                os.close(fd)
            print('directorio de rol corregido: ruta='+str(path)+' modo anterior='+
                  format(previous_mode, '04o')+' modo nuevo='+format(new_mode, '04o'))
        elif not path.exists():
            path.mkdir(mode=mode if path == directory else 0o755)
            os.chown(path, owner.pw_uid, owner.pw_gid)
            path.chmod(mode if path == directory else 0o755)
        elif path.stat().st_uid in (0, os.geteuid()) and path.stat().st_uid != owner.pw_uid:
            previous_mode = stat.S_IMODE(path.stat().st_mode)
            os.chown(path, owner.pw_uid, owner.pw_gid)
            path.chmod(previous_mode & ~0o022)
    directory.chmod(mode)


def role_file(path, user):
    """No sustituir un fichero preexistente de otro propietario."""
    path = Path(path)
    require(not path.is_symlink(), 'fichero de rol enlazado: '+path.name, 2)
    if path.exists():
        regular(path)
        require(path.stat().st_uid == pwd.getpwnam(user).pw_uid, 'fichero de rol ajeno: '+path.name, 2)


def pairs(path, quoted=False, exports=False):
    result = {}
    for line in regular(path).read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        if exports and line.startswith('export '):
            line = line[7:]
        m = re.fullmatch(r'([A-Za-z_][A-Za-z0-9_]*)=(.*)', line)
        require(m and m[1] not in result, 'configuración inválida: ' + path.name, 2)
        key, value = m.groups()
        if quoted and len(value) >= 2 and value[0] == value[-1] == '"':
            value = value[1:-1]
        require(not any(c in value for c in '\x00\r\n`$\\'), 'configuración no literal: ' + path.name, 2)
        result[key] = value
    return result


def execute(args, **kwargs):
    """Toda orden directa conserva destino y argumentos seguros ante timeout o ausencia."""
    try:
        return subprocess.run(args, **kwargs)
    except (OSError, subprocess.TimeoutExpired):
        raise Error("comando no verificable; "+command_context(args, kwargs.get("cwd"))) from None


def run(args, *, env=None, capture=True, timeout=90, cwd=None, diagnostic=None, relay_errors=False):
    context = command_context(args, cwd)
    try:
        p = subprocess.run([str(a) for a in args], env=env, cwd=cwd, text=True, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE if capture else None,
                           stderr=subprocess.PIPE if capture else None, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        raise Error((diagnostic or 'comando no verificable')+'; '+context) from None
    if p.returncode and capture and relay_errors and p.stderr:
        print(p.stderr, end='', file=sys.stderr)
    require(p.returncode == 0, (diagnostic or 'comando')+' rc='+str(p.returncode)+ '; '+context)
    return p.stdout or ''


def command_context(args, cwd=None):
    # Nunca mostrar cuerpos, cabeceras, código de shell ni asignaciones secretas.
    words, hide = [], False
    for value in map(str, args):
        if hide:
            words.append('[reservado]')
            hide = False
        elif re.search(r'(?i)(token|password|api.?key|secret|authorization)=', value):
            words.append(value.split('=', 1)[0]+'=[reservado]')
        else:
            words.append(value)
            hide = value in ('-c', '--data', '--data-binary', '--header', '-H', '--api-key', '--password', '--token')
    destination = 'local'
    raw = list(map(str, args))
    if '-u' in raw and raw[0] == 'sudo':
        destination = 'usuario '+raw[raw.index('-u')+1]
    if 'incus' in raw and 'exec' in raw:
        destination += ' contenedor '+raw[raw.index('exec')+1]
    return 'orden='+shlex.join(words)+' destino='+destination+(' cwd='+str(cwd) if cwd else '')


def config():
    c = pairs(STATE / 'contexto.conf')
    require(set(c) == {'respuestas', 'home', 'clon'}, 'contexto incompleto', 2)
    for value in c.values():
        require(re.fullmatch(r'/[A-Za-z0-9_./-]+', value) and '..' not in Path(value).parts,
                'ruta de contexto inválida', 2)
    a = pairs(Path(c['respuestas']))
    require(a.get('repo_rama') == 'main', MAIN_HELP, 2)
    for k in ('proyecto', 'repo_url', 'repo_rama', 'usuario_ceo', 'usuario_c1', 'usuario_m1',
              'usuario_incus', 'maquina_n', 'canales_n', 'pool_gib', 'cuser', 'codex', 'supabase'):
        require(k in a, 'respuesta ausente: ' + k, 2)
    # No sustituye la validación del cuestionario: se exige su cierre real.
    out = run(['bash', ROOT/'instalacion/cuestionario.sh', '--respuestas', c['respuestas'], 'siguiente'],
              diagnostic='cuestionario pendiente: revisar respuestas registradas')
    require(out.strip() == 'COMPLETO', 'cuestionario pendiente', 2)
    require(a['orq'] == a['pm'] == 'no', 'ORQ/PM requieren ampliación posterior', 2)
    require(a['codex'] != 'si' or a['codex_n'] == '1', 'auditor Codex: una cuenta MOVE', 2)
    c.update(answers=a, project=a['proyecto'])
    c['home'] = Path(c['home'])
    c['clon'] = Path(c['clon'])
    require(c['clon'].name == a['repo_url'].removesuffix('.git').rstrip('/').split('/')[-1],
            'nombre del clon distinto del repositorio; corrija --clon antes de F0', 2)
    c['env'] = c['home']/a['proyecto']/'.env.local'
    c['escrow'] = c['home']/'.config/talent-channels'
    c['manifest'] = ROOT/'manifiestos'/ (a['proyecto']+'.conf')
    c['profile'] = ROOT/'manifiestos'/ (a['proyecto']+'.perfil.tsv')
    c['bus'] = c['home']/a['proyecto']/'bus'
    return c


def roles(c):
    a = c['answers']
    return [('CEO', a['usuario_ceo'], 'ceo'), ('C1', a['usuario_c1'], 'torre-c1'),
            ('M1', a['usuario_m1'], 'm1')]


def declared_bus_state(c, role, content=None):
    data = regular(c['profile']).read_text() if content is None else content
    rows = [line.split('\t') for line in data.splitlines()
            if line and not line.startswith('#')]
    found = [row for row in rows if len(row) == 6 and row[1] == role]
    require(len(found) == 1, 'estado_bus: rol ausente o duplicado: '+role)
    attrs = dict(item.split('=', 1) for item in found[0][5].split(';') if '=' in item)
    state = attrs.get('estado_bus', '')
    require(state.startswith('/') and state.endswith('/.local/state/talent-ceo'),
            'estado_bus inválido: '+role)
    return state


def check_bus_states(c, runtime_config=True, clones=True):
    regenerate = shlex.join(['bash', str(ROOT/'instalacion/generar-instancia.sh'),
                            '--respuestas', str(c.get('respuestas', STATE/'respuestas.resp')), '--salida', str(ROOT),
                            '--home', str(c['home'])])
    for role, user, _ in roles(c):
        expected = declared_bus_state(c, role)
        actual = str(user_home(user)/'.local/state/talent-ceo')
        remedy = '; reabrir F1 y regenerar: '+regenerate+'; revisar diferencias y confirmar F4'
        require(expected == actual, 'estado_bus distinto: '+role+' perfil='+expected+' cuenta='+actual+remedy)
        if clones:
            clone_profile = role_clone(c, role)/'manifiestos'/c['profile'].name
            clone_state = declared_bus_state(c, role, actor(user, ['cat', clone_profile],
                                            diagnostic='clon propio de estación ausente: '+role+'; perfil ausente'))
            require(clone_state == expected,
                    'estado_bus distinto: '+role+' perfil='+expected+' clon='+clone_state+remedy)
        if runtime_config:
            public = user_home(user)/'.config/talent-factory/runtime.conf'
            content = actor(user, ['cat', public], diagnostic='configuración bus ausente: '+role)
            state_text = content.strip()
            if state_text.startswith('export '):
                # El runtime completo de la línea exige sus tres campos exactos.
                require(content == actor_runtime_text(user_home(user), c['bus']),
                        'configuración bus distinta: '+role+remedy)
                state_text = 'TA_BUS_STATE_DIR='+actual
            match = re.fullmatch(r'TA_BUS_STATE_DIR=(/[A-Za-z0-9_./-]+)', state_text)
            observed = match[1] if match else '(formato inválido)'
            require(match and observed == expected,
                    'estado_bus distinto: '+role+' perfil='+expected+' runtime='+observed+remedy)


def role_clone(c, role):
    return c['clon'] if role == 'CEO' else user_home(c['answers']['usuario_'+role.lower()])/c['clon'].name


def station_clone(c):
    return role_clone(c, 'M1')


def station_settings(c):
    return {'TF_STATION_HOST': c['answers']['host_nombre'], 'TF_CLONE': str(station_clone(c)),
            'TF_MANIFEST': str(c['manifest']), 'TF_SLUG': c['answers']['repo_url'].split('github.com/', 1)[1].removesuffix('.git'),
            'TF_RUNNER_USER': 'runner', 'TF_RUNNER_REPO': '/home/runner/repo',
            'TF_RUNNERS': 'runner-'+c['project']}


def station_file(home):
    return home/'.config/talent-factory/station.conf'


def read_station(path):
    return parse_station(regular(path).read_text())


def parse_station(content):
    values = {}
    for line in content.splitlines():
        match = re.fullmatch(r'(TF_[A-Z_]+)=([A-Za-z0-9_./-]+)', line)
        require(match and match[1] not in values, 'configuración estación inválida')
        values[match[1]] = match[2]
    require(set(values) == {'TF_STATION_HOST', 'TF_CLONE', 'TF_MANIFEST', 'TF_SLUG',
                           'TF_RUNNER_USER', 'TF_RUNNER_REPO', 'TF_RUNNERS'}, 'configuración estación incompleta')
    return values


def user_home(user):
    # getent respeta NSS y puede contrastarse con dobles sin crear usuarios reales.
    fields = run(['getent', 'passwd', user], diagnostic='usuario ausente o no verificable: '+user).strip().split(':')
    require(len(fields) == 7 and fields[0] == user and fields[5].startswith('/'),
            'usuario ausente o no verificable: '+user)
    return Path(fields[5])


def channels(c):
    a = c['answers']
    return ['vibe-channel-'+a['maquina_n']+str(i) for i in range(1, int(a['canales_n'])+1)]


def credential_channels(c):
    # Autoridad declarada; nunca inferir el perfil del nombre ni de sus secretos.
    profiles = {}
    for line in regular(c['escrow']/'channel-profiles.list').read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        name, separator, profile = line.partition('=')
        require(separator and name not in profiles and profile in ('produccion', 'mergeador', 'piloto', 'runner'),
                'perfil de contenedor inválido', 2)
        profiles[name] = profile
    targets = channels(c)+['runner-'+c['project']]
    require(all(name in profiles for name in targets), 'perfil de contenedor no declarado', 2)
    require(profiles['runner-'+c['project']] == 'runner', 'perfil de gates debe ser runner', 2)
    return [name for name in targets if profiles[name] != 'runner']


def runner_preflight(c):
    require('runner-'+c['project'] not in credential_channels(c), 'perfil runner no declarado')
    actor(c['answers']['usuario_incus'], runner_query(c, 'F2'), diagnostic='runner preflight sucio', relay_errors=True)


def runner_repository_check(c):
    actor(c['answers']['usuario_incus'], runner_query(c, 'F5'), diagnostic='runner correspondencia del motor fallida', relay_errors=True)


def runner_query(c, phase):
    return ['bash', str(ROOT/'instalacion/scripts/verificar-runner.sh'), 'runner-'+c['project'],
            c['answers']['repo_url'], phase, str(c['manifest'])]


def clean_role_clones(c):
    for role, user, _ in roles(c):
        dirty = actor(user, ['git', '-C', role_clone(c, role), 'status', '--porcelain', '--untracked-files=no'],
                      diagnostic='limpieza del clon no verificable: '+role).strip()
        require(not dirty, 'clon con cambios seguidos: '+role)


def wells(c):
    ledger = json.loads(regular(ROOT/'ledger/cuentas.json').read_text())
    values = ledger.get('pozos')
    require(isinstance(values, dict) and values, 'ledger: pozos ausentes')
    require(all(re.fullmatch(r'[a-z][a-z0-9-]{0,31}', key) for key in values), 'ledger: pozo inválido')
    require(set(row.get('cuenta') for row in values.values()) == set(c['answers']['pozos_alias'].split(',')),
            'ledger: alias de pozos distintos')
    return sorted(values)


def actor(user, args, **kw):
    kw['diagnostic'] = (kw.get('diagnostic') or 'consulta de actor fallida')+' (usuario '+user+')'
    if user == pwd.getpwuid(os.getuid()).pw_name:
        return run(args, **kw)
    return run(['sudo', '-n', '-H', '-u', user, '--', *args], **kw)


def runtime(c):
    env = os.environ.copy()
    env.update(TA_BUS=str(c['bus']), TF_MANIFEST=str(c['manifest']),
               TA_BUS_STATE_DIR=declared_bus_state(c, 'CEO'),
               TA_BUS_LOCK=str(c['bus'].with_name('bus.lock')),
               TCO_TF_MANIFEST=str(c['manifest']), TA_PERFIL=str(c['clon']/'manifiestos'/c['profile'].name))
    return env


@contextlib.contextmanager
def lock():
    safe_dir(STATE)
    path = STATE/'fases.lock'
    require(not path.is_symlink(), 'lock enlazado', 2)
    with path.open('a') as f:
        os.chmod(path, 0o600)
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def history():
    p = STATE/'fases.tsv'
    if not p.exists():
        return [], ZERO, set(), False
    regular(p, True)
    previous, green, stopped, rows = ZERO, set(), False, []
    for n, line in enumerate(p.read_text().splitlines(), 1):
        fields = line.split('\t')
        require(len(fields) == 6, 'cadena rota: fila ' + str(n))
        seq, timestamp, phase, event, prior, digest = fields
        payload = '\t'.join(fields[:5])
        require(seq == str(n) and prior == previous and
                hashlib.sha256(payload.encode()).hexdigest() == digest,
                'cadena rota: fila ' + str(n))
        require(re.fullmatch(r'F[0-8]', phase) and event in ('VERDE', 'REABRIR', 'STOP-SAFEGUARD'),
                'evento inválido: fila ' + str(n))
        try:
            datetime.strptime(timestamp, '%Y-%m-%dT%H:%M:%SZ')
        except ValueError:
            raise Error('fecha inválida en cadena') from None
        idx = int(phase[1])
        if event == 'VERDE':
            require(not stopped and idx == len(green) and phase not in green,
                    'secuencia inválida: ' + phase)
            green.add(phase)
        elif event == 'REABRIR':
            require(not stopped and idx <= len(green), 'reapertura inválida')
            green = {f for f in green if int(f[1]) < idx}
        else:
            require(not stopped and idx == len(green), 'STOP fuera de fase pendiente')
            stopped = True
        rows.append(line)
        previous = digest
    return rows, previous, green, stopped


def append_event(phase, event, rows, previous):
    timestamp = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    payload = '\t'.join((str(len(rows)+1), timestamp, phase, event, previous))
    p = STATE/'fases.tsv'
    require(not p.is_symlink(), 'estado enlazado', 2)
    with p.open('a') as f:
        os.chmod(p, 0o600)
        f.write(payload+'\t'+hashlib.sha256(payload.encode()).hexdigest()+'\n')
        f.flush()
        os.fsync(f.fileno())


def phase_id(value):
    require(re.fullmatch(r'F[0-8]', value or ''), 'fase inválida', 2)
    return value


def state(args):
    require(args and args[0] in ('siguiente', 'verificar', 'avanzar', 'reabrir', 'stop'), 'uso estado', 2)
    op = args[0]
    require(len(args) == (1 if op in ('siguiente', 'verificar') else 2), 'argumentos estado', 2)
    with lock():
        rows, prior, green, stopped = history()
        if op == 'verificar':
            print('cadena íntegra; eventos='+str(len(rows)))
            return
        require(not stopped, 'STOP-SAFEGUARD: ayuda humana requerida')
        if op == 'siguiente':
            print('COMPLETO' if len(green) == 9 else 'F'+str(len(green)))
            if len(green) == 9:
                print('Fábrica operativa; certificación del repo PENDIENTE: DESPUES-certificacion.md', file=sys.stderr)
            return
        phase = phase_id(args[1])
        idx = int(phase[1])
        if op in ('avanzar', 'stop'):
            require(idx == len(green), 'fase previa pendiente: '+phase)
        else:
            require(idx <= len(green), 'reapertura fuera de secuencia')
        if op == 'avanzar':
            # Ejecuta la entrada literal que usa también la persona; no hay checks alternativos.
            run(['bash', ROOT/'instalacion/scripts'/('check-'+phase+'.sh')], capture=False,
                timeout=BATTERY_TIMEOUT + 300 if phase == 'F0' else 600)
        append_event(phase, {'avanzar':'VERDE', 'reabrir':'REABRIR', 'stop':'STOP-SAFEGUARD'}[op], rows, prior)
        print(phase+' '+op)


def core_paths(base):
    paths = []
    rules = exclusions(ROOT)
    for name in TREES:
        tree = base/name
        require(tree.is_dir() and not tree.is_symlink(), 'núcleo: árbol ausente '+name)
        for p in tree.rglob('*'):
            rel = p.relative_to(base)
            if excluded(rel, rules):
                continue
            if str(rel) == 'instalacion/NUCLEO.sha256':
                continue
            require(not p.is_symlink(), 'núcleo: enlace '+str(rel))
            if p.is_file():
                paths.append(rel.as_posix())
    for name in ('CLAUDE.md', 'EMPIEZA-AQUI.md'):
        regular(base/name)
        paths.append(name)
    return sorted(paths)


def core_generate():
    core = set(core_paths(ROOT))
    distribution = []
    for path in ROOT.rglob('*'):
        rel = path.relative_to(ROOT)
        name = rel.as_posix()
        if excluded(rel, ['.git/', 'instalacion/estado/', 'instalacion/generado/', '.env.local']):
            continue
        if name in core or name in ('instalacion/NUCLEO.sha256', 'instalacion/DISTRIBUCION.sha256'):
            continue
        require(not path.is_symlink(), 'distribución: enlace '+name)
        if path.is_file():
            distribution.append(name)
    text = ''.join(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()+'  '+name+'\n'
                   for name in sorted(distribution))
    write(ROOT/'instalacion/DISTRIBUCION.sha256', text, 0o644)
    text = ''.join(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()+'  '+name+'\n'
                   for name in core_paths(ROOT))
    write(ROOT/'instalacion/NUCLEO.sha256', text, 0o644)
    print('núcleo generado: '+str(len(text.splitlines()))+' ficheros')


def manifest_entries(manifest, label):
    manifest = regular(manifest)
    expected = {}
    for line in manifest.read_text().splitlines():
        m = re.fullmatch(r'([0-9a-f]{64})  ([A-Za-z0-9_./@+-]+)', line)
        require(m is not None, label+': manifiesto inválido')
        digest, name = m.groups()
        require(not name.startswith('/') and '..' not in Path(name).parts and name not in expected,
                label+': ruta inválida')
        expected[name] = digest
    return expected


def core_verify(base):
    expected = manifest_entries(ROOT/'instalacion/NUCLEO.sha256', 'núcleo')
    require(expected and set(expected) == set(core_paths(base)), 'núcleo: inventario distinto')
    for name, digest in expected.items():
        require(hashlib.sha256(regular(base/name).read_bytes()).hexdigest() == digest,
                'núcleo: hash distinto '+name)


def container_core(c, container):
    core_verify(ROOT)
    a = c['answers']
    destination = '/home/'+a['cuser']+'/motor-paquete'
    # Usa el manifiesto HOST como autoridad: nunca el manifiesto sustituido del contenedor.
    script = 'cd "$1" && sha256sum -c -'
    payload = regular(ROOT/'instalacion/NUCLEO.sha256').read_bytes()
    cmd = ['sudo', '-n', '-H', '-u', a['usuario_incus'], 'incus', 'exec', container, '--',
           'bash', '-c', script, '_', destination]
    try:
        p = subprocess.run(cmd, input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        raise Error('núcleo no verificable en '+container+'; '+command_context(cmd)) from None
    require(p.returncode == 0, 'núcleo: hash distinto o ausente en '+container+'; '+command_context(cmd))


def battery_counts(text):
    # Una fila roja puede reproducir el resumen de su hijo en la cola del log.
    # Solo el último RESULTADO es el del agregado; si está mal formado es rojo.
    summaries = re.findall(r'^RESULTADO:.*$', text, re.M)
    require(summaries, 'batería: resumen final ausente')
    summary = re.fullmatch(r'RESULTADO: PASS=(\d+) FAIL=(\d+) SKIP=(\d+) TOTAL=(\d+)', summaries[-1])
    require(summary, 'batería: resumen final inválido')
    passed, failed, skipped, total = map(int, summary.groups())
    require(total > 0 and passed+failed+skipped == total, 'batería: contadores incoherentes')
    return dict(PASS=passed, FAIL=failed, SKIP=skipped)


def battery_tree(base):
    """Lista blanca sellada; únicamente el ledger adjudicado se reconstruye."""
    core = manifest_entries(ROOT/'instalacion/NUCLEO.sha256', 'núcleo')
    distribution = manifest_entries(ROOT/'instalacion/DISTRIBUCION.sha256', 'distribución')
    require(distribution, 'distribución: manifiesto vacío')
    require(not set(core).intersection(distribution) and
            not {'instalacion/NUCLEO.sha256', 'instalacion/DISTRIBUCION.sha256'}.intersection(distribution),
            'distribución: inventario inválido')
    for name, digest in {**core, **distribution}.items():
        source = ROOT/name
        if name == 'ledger/cuentas.json':
            source = ROOT/'instalacion/distribucion/ledger-cuentas.json'
        diagnostic = 'distribución: restaurar desde el ZIP íntegro: '+name
        require(source.is_file() and not any(p.is_symlink() for p in (source, *source.parents)), diagnostic)
        require(hashlib.sha256(source.read_bytes()).hexdigest() == digest, diagnostic)
        destination = base/name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        require(hashlib.sha256(destination.read_bytes()).hexdigest() == digest, diagnostic)
    shutil.copy2(ROOT/'instalacion/NUCLEO.sha256', base/'instalacion/NUCLEO.sha256')
    require((base/'instalacion/NUCLEO.sha256').read_bytes() ==
            (ROOT/'instalacion/NUCLEO.sha256').read_bytes(), 'núcleo: manifiesto copiado distinto')
    core_verify(base)


def battery_parent():
    """No usar la selección implícita (ni la caché) de tempfile."""
    candidate = Path(os.environ.get('TMPDIR') or '/tmp').absolute()
    diagnostic = 'batería: padre temporal enlazado'
    require(not any(p.is_symlink() for p in (candidate, *candidate.parents)), diagnostic)
    try:
        parent = candidate.resolve(strict=True)
        require(parent.is_dir(), 'batería: padre temporal no verificable')
        require(not any(p.is_symlink() for p in (parent, *parent.parents)), diagnostic)
        require(not parent.is_relative_to(ROOT.resolve()), 'batería: árbol temporal dentro de la instancia')
        for ancestor in (parent, *parent.parents):
            profiles = ancestor/'manifiestos'
            if profiles.exists():
                # Igual alcance que perfil_path: acumular candidatos hasta /.
                with os.scandir(profiles) as entries:
                    require(not any(p.name.endswith('.perfil.tsv') and p.is_file() for p in entries),
                            'batería: padre temporal con perfiles en ancestros')
        return parent
    except (OSError, RuntimeError):
        raise Error('batería: padre temporal no verificable') from None


def battery_processes(group, tree):
    """Unión de ascendencia, grupo y rutas; identidad (pid, arranque) del mismo uid."""
    snapshot = {}
    found = set()
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            if entry.stat().st_uid != os.getuid():
                continue
            fields = (entry/'stat').read_text().rsplit(')', 1)[1].split()
            pid = int(entry.name)
            identity = (pid, int(fields[19]))
            snapshot[pid] = (identity, int(fields[1]))
            if pid == os.getpid():
                continue
            if int(fields[2]) == group:
                found.add(identity)
                continue
            for name in ('cwd', 'root'):
                try:
                    path = Path(os.readlink(entry/name).removesuffix(' (deleted)'))
                except (FileNotFoundError, ProcessLookupError, PermissionError):
                    continue
                if path.is_relative_to(tree):
                    found.add(identity)
                    break
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            # No señalizar por ruta si /proc no permite acreditar su pertenencia.
            continue
    for pid, (identity, parent) in snapshot.items():
        if pid == os.getpid():
            continue
        visited = {pid}
        while parent not in visited:
            if parent in (group, os.getpid()):
                found.add(identity)
                break
            visited.add(parent)
            if parent not in snapshot:
                break
            parent = snapshot[parent][1]
    return found


def battery_identity(identity):
    """Revalidar uid y arranque inmediatamente antes de actuar sobre un PID."""
    pid, born = identity
    try:
        entry = Path('/proc')/str(pid)
        if entry.stat().st_uid != os.getuid():
            return False
        fields = (entry/'stat').read_text().rsplit(')', 1)[1].split()
        return int(fields[19]) == born
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        return False


def battery_reap(process):
    """Recoger adoptados sin bloquear ni robar a Popen el estado del agregado."""
    process.poll()
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit() or int(entry.name) == process.pid:
            continue
        try:
            fields = (entry/'stat').read_text().rsplit(')', 1)[1].split()
            if int(fields[1]) == os.getpid():
                os.waitpid(int(entry.name), os.WNOHANG)
        except (FileNotFoundError, ProcessLookupError, PermissionError, ChildProcessError):
            pass


def battery_wait(process, timeout):
    deadline = time.monotonic()+timeout
    while True:
        battery_reap(process)
        if process.returncode is not None:
            return process.returncode
        if time.monotonic() >= deadline:
            raise subprocess.TimeoutExpired(process.args, timeout)
        time.sleep(0.05)


def battery_stop(process, tree):
    def signal_tree(sig):
        candidates = battery_processes(process.pid, tree)
        for identity in candidates:
            try:
                # Ninguna señal de grupo: cada destinatario tiene identidad acreditada.
                if identity in battery_processes(process.pid, tree) and battery_identity(identity):
                    os.kill(identity[0], sig)
            except ProcessLookupError:
                pass

    def remaining():
        battery_reap(process)
        return battery_processes(process.pid, tree)

    signal_tree(signal.SIGTERM)
    deadline = time.monotonic()+1
    while remaining() and time.monotonic() < deadline:
        time.sleep(0.05)
    if remaining():
        signal_tree(signal.SIGKILL)
    deadline = time.monotonic()+5
    while remaining():
        require(time.monotonic() < deadline, 'batería: descendientes no terminados; conservar árbol temporal')
        # Cubrir nuevos hijos creados mientras se recorría /proc.
        signal_tree(signal.SIGKILL)
        time.sleep(0.05)
    process.wait()


@contextlib.contextmanager
def battery_session(tree):
    # Adoptar antes de copiar para no perder hijos que abandonen sesión y directorio.
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        previous = ctypes.c_int()
        require(libc.prctl(37, ctypes.byref(previous), 0, 0, 0) == 0 and
                libc.prctl(36, 1, 0, 0, 0) == 0, 'batería: descendientes no verificables')
    except (AttributeError, OSError):
        raise Error('batería: descendientes no verificables') from None
    processes = []
    try:
        yield processes
    finally:
        try:
            for process in processes:
                battery_stop(process, tree)
        finally:
            require(libc.prctl(36, previous.value, 0, 0, 0) == 0,
                    'batería: descendientes no verificables')


# Variables que la batería no hereda: el MISMO patrón que la sonda de verificar-runner.sh
# (una prueba de F0 exige la igualdad). Claude Code exporta CLAUDE_CODE_MESSAGING_TOKEN en cada sesión.
CREDENTIAL_ENV = ('GH_TOKEN', 'GITHUB_TOKEN', '*_TOKEN', '*_API_KEY', '*_SECRET', '*_PASSWORD',
                  'AWS_*', 'GOOGLE_APPLICATION_CREDENTIALS')
# Herramienta y paquete apt de Ubuntu 24.04/26.04 que la aporta (None: no se instala con apt).
F0_TOOLS = (('bash', 'bash'), ('python3', 'python3'), ('git', 'git'), ('jq', 'jq'), ('flock', 'util-linux'),
            ('tmux', 'tmux'), ('crontab', 'cron'), ('sudo', 'sudo'), ('visudo', 'sudo'), ('incus', 'incus'),
            ('claude', None), ('gh', 'gh'), ('shellcheck', 'shellcheck'), ('curl', 'curl'),
            ('iptables', 'iptables'), ('unzip', 'unzip'), ('node', 'nodejs'), ('npm', 'npm'),
            ('ssh', 'openssh-client'), ('ssh-keygen', 'openssh-client'), ('btrfs', 'btrfs-progs'),
            ('apt-get', 'apt'), ('free', 'procps'), ('ps', 'procps'), ('pgrep', 'procps'), ('sysctl', 'procps'),
            ('locale', 'libc-bin'), ('sed', 'sed'), ('grep', 'grep'), ('awk', 'gawk'), ('find', 'findutils'),
            ('tar', 'tar'), ('gzip', 'gzip'))
F0_LOCALES = ('en_US.utf8', 'en_GB.utf8')


def clean_environment(source):
    return {k: v for k, v in source.items() if not any(fnmatch.fnmatchcase(k, p) for p in CREDENTIAL_ENV)}


def sudo_rs(version, visudo_path):
    return 'sudo-rs' in version.lower() or str(visudo_path).startswith('/usr/lib/cargo/bin/')


def require_classic_sudo():
    """sudo-rs limita la longitud del token de las reglas exactas de F5: se exige el sudo clásico."""
    version = run(['sudo', '--version'], diagnostic='versión de sudo no verificable')
    visudo = shutil.which('visudo')
    require(not sudo_rs(version, os.path.realpath(visudo) if visudo else ''),
            'sudo-rs detectado: las reglas de F5 no son válidas con él. Vuelva al sudo clásico: '
            'sudo update-alternatives --config sudo y elija sudo.ws; visudo cambia con él; '
            'compruebe que sudo --version dice Sudo version, no sudo-rs')


def require_locales():
    have = {line.strip().lower().replace('utf-8', 'utf8')
            for line in run(['locale', '-a'], diagnostic='locales no verificables').splitlines()}
    absent = [name for name in F0_LOCALES if name.lower() not in have]
    require(not absent, 'locale ausente: '+', '.join(absent)+'; genere con: sudo apt-get install -y locales '
            '&& sudo locale-gen en_US.UTF-8 en_GB.UTF-8')


def preflight_f0():
    """Comprobaciones baratas de F0, compartidas por la batería y check('F0'): fallan en segundos."""
    absent = [(name, package) for name, package in F0_TOOLS if not shutil.which(name)]
    if absent:
        packages = list(dict.fromkeys(package for _, package in absent if package))
        hint = ('; instale con: sudo apt-get install -y '+' '.join(packages)) if packages else ''
        if any(package is None for _, package in absent):
            hint += '; claude: instale Claude Code según EMPIEZA-AQUI.md'
        raise Error('herramienta ausente: '+', '.join(name for name, _ in absent)+hint)
    require(run(['uname', '-s'], diagnostic='Linux requerido').strip() == 'Linux', 'Linux requerido')
    for key in ('user.name', 'user.email'):
        result = execute(['git', 'config', '--global', '--get', key],
                                text=True, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        require(result.returncode == 0 and result.stdout.strip(),
                'identidad Git ausente: configure git config --global '+key+
                ' para el usuario que instala')
    minima = pairs(ROOT/'instalacion/requisitos.env')
    require(re.fullmatch(r'\d+\.\d+\.\d+', minima.get('MIN_GH', '')), 'requisitos inválidos: MIN_GH')
    gh_version = re.search(r'^gh version (\d+\.\d+\.\d+)(?:\s|$)',
                           run(['gh', '--version'], diagnostic='versión de gh no verificable'), re.M)
    require(gh_version, 'versión de gh no verificable')
    require(tuple(map(int, gh_version[1].split('.'))) >= tuple(map(int, minima['MIN_GH'].split('.'))),
            'versión de gh encontrada '+gh_version[1]+'; mínima exigida '+minima['MIN_GH']+
            '. En Ubuntu 24.04: sudo apt-get install gh; compruebe gh --version')
    require_classic_sudo()
    require_locales()
    return minima


def battery_run():
    require(os.getuid() != 0, ROOT_HELP, 2)
    core_verify(ROOT)
    preflight_f0()
    started = time.monotonic()
    print('batería: duración esperable en 4 núcleos (Intel N100): unos 85 minutos en Ubuntu 24.04 y '
          'unos 105 en 26.04; menos en máquinas rápidas.', flush=True)
    digest = hashlib.sha256(regular(ROOT/'instalacion/NUCLEO.sha256').read_bytes()).hexdigest()
    with lock():
        receipt = STATE/'f0-bateria.json'
        require(not receipt.is_symlink(), 'batería: recibo enlazado', 2)
        # Un ensayo interrumpido no puede dejar válido un recibo anterior.
        receipt.unlink(missing_ok=True)
        directory = STATE/'f0-bateria'
        safe_dir(directory)
        fd, path = tempfile.mkstemp(prefix='bateria-', suffix='.log', dir=directory)
        log = Path(path)
        env = clean_environment(os.environ)
        env.update(TF_PAQUETE_ESTADO='distribucion', TF_SUITES_LOG_DIR=str(directory/log.stem))
        with os.fdopen(fd, 'w') as output:
            parent = battery_parent()
            tree = Path(tempfile.mkdtemp(prefix='f0-bateria-', dir=parent))
            stopped = False
            processes = []
            try:
                tree.chmod(0o700)
                with battery_session(tree) as processes:
                    battery_tree(tree)
                    try:
                        process = subprocess.Popen(['bash', str(tree/'scripts/run-all-suites.sh'), '--sin', 'talent-channels'],
                                                   cwd=tree, env=env, stdin=subprocess.DEVNULL, stdout=output,
                                                   stderr=subprocess.STDOUT, start_new_session=True)
                        processes.append(process)
                        rc = battery_wait(process, timeout=BATTERY_TIMEOUT)
                    except subprocess.TimeoutExpired:
                        output.write(f'\nBatería interrumpida por timeout de {BATTERY_TIMEOUT} segundos.\n')
                        rc = 124
                    except OSError:
                        output.write('\nNo se pudo iniciar la batería.\n')
                        rc = 127
                stopped = True
            finally:
                # Ante excepción de copia no hay hijo; ante fallo de terminación no borrar.
                if stopped or not processes:
                    shutil.rmtree(tree)
                    deadline = time.monotonic()+2
                    while True:
                        require(not tree.exists() and not tree.is_symlink(), 'batería: árbol temporal reapareció')
                        if time.monotonic() >= deadline:
                            break
                        time.sleep(0.05)
        text = log.read_text()
        try:
            counts = battery_counts(text)
        except Error:
            counts = dict(PASS=None, FAIL=None, SKIP=None)
        data = dict(rc=rc, fecha=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                    **counts, log=str(log), log_sha256=hashlib.sha256(log.read_bytes()).hexdigest(),
                    nucleo_sha256=digest)
        write(receipt, json.dumps(data, indent=2)+'\n')
        print('batería: duración real '+str(round(time.monotonic()-started))+' s')
        print('batería: log='+str(log)+' recibo='+str(receipt)+' rc='+str(rc))
        for line in text.splitlines():
            if re.match(r'^\s*FAIL\b', line) or line.startswith('RESULTADO:'):
                print(line)
        require(hashlib.sha256(regular(ROOT/'instalacion/NUCLEO.sha256').read_bytes()).hexdigest() == digest,
                'batería: núcleo cambió durante el ensayo; repetir f0-bateria.sh')
        require(rc == 0 and counts['FAIL'] == 0,
                'batería roja o incompleta; no continuar. Conserve el log '+str(log)+
                ' y pida ayuda con recolectar.sh F0')


def battery_receipt():
    next_step = '; ejecute bash '+str(ROOT/'instalacion/scripts/recolectar.sh')+' F0; después bash '+str(
        ROOT/'instalacion/scripts/f0-bateria.sh')
    def invalid(cause):
        raise Error('batería: recibo '+cause+next_step)
    receipt = STATE/'f0-bateria.json'
    if not receipt.exists() and not receipt.is_symlink():
        invalid('ausente')
    try:
        data = json.loads(regular(receipt, True).read_text())
        require(type(data['rc']) is int, 'recibo inválido')
        incomplete = all(data[k] is None for k in ('PASS', 'FAIL', 'SKIP'))
        require(incomplete or all(type(data[k]) is int and data[k] >= 0 for k in ('PASS', 'FAIL', 'SKIP')),
                'recibo inválido')
        require(isinstance(data['nucleo_sha256'], str) and HEX.fullmatch(data['nucleo_sha256']),
                'recibo inválido')
        date = datetime.strptime(data['fecha'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
        log = Path(data['log'])
        require(log.is_absolute() and log.parent == STATE/'f0-bateria' and
                not any(p.is_symlink() for p in log.parents), 'recibo inválido')
        regular(log, True)
        require(data['log_sha256'] == hashlib.sha256(log.read_bytes()).hexdigest(), 'recibo inválido')
        try:
            counts = battery_counts(log.read_text())
        except Error:
            require(incomplete, 'recibo inválido')
        else:
            require(not incomplete and all(data[k] == v for k, v in counts.items()), 'recibo inválido')
        core_digest = hashlib.sha256(regular(ROOT/'instalacion/NUCLEO.sha256').read_bytes()).hexdigest()
    except (Error, OSError, ValueError, KeyError, TypeError):
        invalid('inválido')
    if incomplete:
        invalid('rojo: batería incompleta (rc='+str(data['rc'])+')')
    if data['rc'] != 0 or data['FAIL'] != 0:
        invalid('rojo: '+str(data['FAIL'])+' suites fallidas (rc='+str(data['rc'])+')')
    age = (datetime.now(timezone.utc)-date).total_seconds()
    if age < 0:
        invalid('inválido: fecha futura')
    if age >= 24*3600:
        invalid('caducado')
    if data['nucleo_sha256'] != core_digest:
        invalid('de otro núcleo')
    print('batería acreditada por recibo: PASS='+str(data['PASS'])+' FAIL=0 SKIP='+str(data['SKIP'])+
          ' log='+str(log))


def check(phase):
    phase_id(phase)
    if phase == 'F0':
        require(os.getuid() != 0 and pwd.getpwuid(os.getuid()).pw_name != 'root', ROOT_HELP, 2)
        minima = preflight_f0()
        require(all(minima.get(k, '').isdigit() and int(minima[k]) > 0 for k in
                    ('MIN_RAM_GIB', 'MIN_DISCO_GIB', 'MARGEN_POOL_GIB')), 'requisitos inválidos')
        mem = run(['free', '-b'], diagnostic='RAM no verificable')
        m = re.search(r'^Mem:\s+(\d+)', mem, re.M)
        require(m, 'RAM no verificable')
        gib = int(m[1])//(1024**3)
        require(gib >= int(minima['MIN_RAM_GIB']), 'RAM menor que '+minima['MIN_RAM_GIB']+' GiB')
        disk = run(['df', '-B1', '--output=avail', '/var/lib'], diagnostic='disco no verificable').splitlines()[-1].strip()
        require(disk.isdigit(), 'disco no verificable')
        free = int(disk)//(1024**3)
        require(free >= int(minima['MIN_DISCO_GIB']), 'disco insuficiente: mínimo '+minima['MIN_DISCO_GIB']+' GiB libres')
        minfile = ROOT/'skills/talent-context/assets/claude-min-version'
        minimum = minfile.read_text().strip() if minfile.exists() else minima['MIN_CLAUDE_CODE']
        version = re.search(r'\d+\.\d+\.\d+', run(['claude', '--version'], diagnostic='versión de Claude no verificable'))
        require(version and tuple(map(int, version[0].split('.'))) >= tuple(map(int, minimum.split('.'))),
                'versión de Claude menor que '+minimum)
        core_verify(ROOT)
        c = config()
        a = c['answers']
        require(a['usuario_ceo'] == pwd.getpwuid(os.getuid()).pw_name, 'CEO debe ser quien instala')
        limit = 1 if gib < 16 else min(9, gib//8)
        require(int(a['canales_n']) <= limit, 'canales exceden RAM; máximo '+str(limit))
        require(int(a['pool_gib'])+int(minima['MARGEN_POOL_GIB']) <= free,
                'pool loop excede disco libre menos '+minima['MARGEN_POOL_GIB']+' GiB')
        print('topología: CEO+C1+M1; canales='+a['canales_n']+'; runner=1; pool=loop')
        run(['bash', ROOT/'skills/skill-creator/scripts/validate-package.sh', '--root', ROOT/'skills',
             '--estado', 'distribucion'], capture=False, timeout=600, diagnostic='validador de paquete rojo')
        battery_receipt()
    else:
        c = config()
        a = c['answers']
        if phase == 'F1':
            check_credentials(c)
            check_configuration(c)
        elif phase == 'F2':
            core_verify(ROOT)
            regular(c['manifest'])
            regular(c['profile'])
            golden = 'golden-'+c['project']
            for container, status in [(golden, 'STOPPED'), *[(ch, 'RUNNING') for ch in channels(c)],
                                      ('runner-'+c['project'], 'RUNNING'), *[(well, 'RUNNING') for well in wells(c)]]:
                out = actor(a['usuario_incus'], ['incus', 'list', '^'+container+'$', '-f', 'csv', '-c', 'ns'],
                            diagnostic='contenedor ausente o estado: '+container)
                require(out.strip() == container+','+status, 'contenedor ausente o estado: '+container)
                if status == 'RUNNING':
                    container_core(c, container)
            # verify.sh se ejecuta antes del login F3: exige ausencia de credenciales en clones.
            run(['bash', ROOT/'instalacion/scripts/f2-provision.sh', '--verificar'], capture=False, timeout=600,
                diagnostic='verify.sh FAIL')
            runner_preflight(c)
        elif phase == 'F3':
            from acreditacion import host_capacity, container_capacity
            for role, user, _ in roles(c):
                diagnostic = 'login Claude ausente o modo: '+role+' (usuario '+user+'); token o login sin capacidad'
                host_capacity(user, diagnostic)
                actor(user, ['gh', 'auth', 'status'], diagnostic='gh sin sesión: '+role+' (usuario '+user+')')
                actor(user, ['git', 'ls-remote', a['repo_url']], diagnostic='git sin autenticación: '+role+' (usuario '+user+')')
                if role == 'M1':
                    diagnostic = 'CodeRabbit CLI ausente: M1 (usuario '+user+')'
                    require(actor(user, ['coderabbit', '--version'], diagnostic=diagnostic).strip(), diagnostic)
            for ch in credential_channels(c):
                base = '/home/'+a['cuser']
                if ch in channels(c):
                    container_capacity(c, ch, 'login/env ausente o modo en canal: '+ch)
                for path in (base+'/'+c['clon'].name+'/.env.local',):
                    diagnostic = 'login/env ausente o modo en canal: '+ch+' (usuario '+a['cuser']+')'
                    out = actor(a['usuario_incus'], ['incus', 'exec', ch, '--', 'stat', '-c', '%a', path], diagnostic=diagnostic)
                    require(out.strip() == '600', diagnostic)
                actor(a['usuario_incus'], ['incus', 'exec', ch, '--', 'su', '-', a['cuser'], '-c', 'gh auth status'],
                      diagnostic='gh sin sesión: canal '+ch+' (usuario '+a['cuser']+')')
                actor(a['usuario_incus'], ['incus', 'exec', ch, '--', 'su', '-', a['cuser'], '-c',
                                         shlex.join(['git', '-C', base+'/'+c['clon'].name, 'ls-remote', 'origin'])],
                      diagnostic='git sin autenticación: canal '+ch)
            run(['bash', ROOT/'skills/talent-channels/scripts/auth-move.sh', 'status'], env=closed_env(c), diagnostic='auth-move rc')
            ledger = json.loads(regular(ROOT/'ledger/cuentas.json').read_text())
            accounts = ledger.get('cuentas')
            require(isinstance(accounts, list), 'ledger: cuentas ausentes')
            for well in wells(c):
                alias = ledger['pozos'][well]['cuenta']
                matches = [row for row in accounts if row.get('alias') == alias and row.get('tipo') == 'claude']
                require(len(matches) == 1, 'ledger: cuenta ambigua o ausente '+well)
                account = matches[0]
                if account.get('verificado'):
                    require('health-check OK' in account['verificado'] and account.get('grants_vivos'),
                            'ledger: MOVE no acreditado '+well)
                else:
                    container_capacity(c, well, 'pozo login o capacidad no acreditada: '+well)
            if a['codex'] == 'si':
                # El MOVE deja una cuenta en un único endpoint. El doctor acredita el pane en F7.
                codex = [row for row in accounts if row.get('tipo') == 'codex']
                require(len(codex) == 1 and codex[0].get('verificado') and
                        len(codex[0].get('grants_vivos', [])) == 1, 'ledger: Codex MOVE único no acreditado')
        elif phase == 'F4':
            from rulesets import effective_rules
            from etiquetas import repository_labels
            effective_rules(c)
            require('cr-review' in repository_labels(c), 'etiqueta cr-review ausente')
            require(c['clon'].is_dir(), 'clon de producto ausente')
            require(run(['git', '-C', c['clon'], 'remote', 'get-url', 'origin'], diagnostic='origin distinto').strip().removesuffix('.git') ==
                    a['repo_url'].removesuffix('.git'), 'origin distinto')
            run(['bash', c['clon']/'.claude/skills/talent-ceo/scripts/lib-perfil.sh', '--check'], env=runtime(c), diagnostic='perfil rojo')
            env = runtime(c)
            env['TF_LINEAR_TEAM_KEY'] = a['linear_clave']
            env.update(parity_env(c))
            result = execute(['bash', str(c['clon']/'.claude/skills/talent-repo-onboarding/scripts/verify-repo-parity.sh'),
                                     str(c['clon'])], env=env, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, timeout=600)
            print(result.stdout, end='')
            require(result.returncode in (0, 3), 'paridad rc '+str(result.returncode)+'; '+
                    command_context(['bash', c['clon']/'.claude/skills/talent-repo-onboarding/scripts/verify-repo-parity.sh', c['clon']]))
            pending = sorted(set(re.findall(r'MANUAL \[([^]]+)\]:.*pendiente', result.stdout) +
                                 re.findall(r'receipt ([a-z0-9-]+):', result.stdout)))
            print('manuales pendientes='+str(len(pending))+' '+','.join(pending))
            if 'A2: plan FREE' in result.stdout:
                print('pendiente procedimental: protección en privado gratuito')
            run(['bash', c['clon']/'.claude/skills/skill-creator/scripts/validate-package.sh',
                 '--root', c['clon']/'.claude/skills', '--estado', 'instancia'], capture=False, timeout=600,
                diagnostic='validación roja')
        elif phase == 'F5':
            # Un home cambiado puede dejar el clon anterior fuera de esta ruta.
            check_bus_states(c, runtime_config=False, clones=False)
            clean_role_clones(c)
            check_bus_states(c)
            for role, user, session in roles(c):
                home = user_home(user)
                actor(user, ['tmux', 'has-session', '-t', session], diagnostic='sesión ausente: '+role+' (usuario '+user+')')
                observed = actor(user, ['cat', home/'.config/talent-factory/runtime.conf'],
                                 diagnostic='configuración bus distinta: '+role)
                require(observed == actor_runtime_text(home, c['bus']), 'configuración bus distinta: '+role)
                value = actor(user, ['tmux', 'display-message', '-p', '-t', session, '#{alternate_on}'],
                              diagnostic='renderer alternativo: '+role).strip()
                require(value == '0', 'renderer alternativo: '+role)
                pane = actor(user, ['tmux', 'capture-pane', '-p', '-t', session], diagnostic='barra ctx ausente: '+role)
                require(not re.search(r'No, exit|Yes, I accept|trust this folder|trust the files', pane, re.I),
                        'sesión parada en un aviso: '+role)
                require(re.search(r'ctx:\s*\d+%', pane), 'barra ctx ausente: '+role)
                actor(user, ['bash', ROOT/'instalacion/scripts/modelos-rol.sh', '--verificar', role, session],
                      diagnostic='modelo de torre no vigente: '+role, relay_errors=True)
                actor(user, ['gh', 'auth', 'status'], diagnostic='gh sin sesión: '+role+' (usuario '+user+')')
                if role == 'M1':
                    require(actor(user, ['coderabbit', '--version'], diagnostic='CodeRabbit CLI ausente: M1').strip(),
                            'CodeRabbit CLI ausente: M1')
                    actor(user, ['coderabbit', 'auth', 'status'], diagnostic='CodeRabbit CLI sin autenticación: M1')
                if role in ('C1', 'M1'):
                    own = role_clone(c, role)
                    actor(user, ['test', '-w', own], diagnostic='clon propio de estación ausente: '+role)
                    actor(user, ['test', '-w', own/'.git'], diagnostic='clon propio de estación ausente: '+role)
                    observed = actor(user, ['stat', '-c', '%U', own], diagnostic='clon propio de estación ausente: '+role).strip()
                    require(observed == user, 'clon propio de estación ausente: '+role+'; propietario distinto')
                    require(actor(user, ['git', '-C', own, 'remote', 'get-url', 'origin'], diagnostic='origin estación distinto').strip().removesuffix('.git') ==
                            a['repo_url'].removesuffix('.git'), 'origin estación distinto')
                    actor(user, ['git', '-C', own, 'ls-remote', 'origin'], diagnostic='git sin autenticación: '+role)
            for channel in channels(c):
                actor(a['usuario_c1'], ['bash', role_clone(c, 'C1')/'.claude/skills/talent-channel-operation/scripts/preparar-sesiones.sh',
                                        '--verificar', channel.removeprefix('vibe-channel-')],
                      diagnostic='identidad/creación de panes de canal fallida: '+channel)
            station = station_file(user_home(a['usuario_m1']))
            observed = actor(a['usuario_m1'], ['stat', '-c', '%a:%U:%F', station],
                             diagnostic='configuración estación modo/propietario').strip()
            require(observed == '644:'+a['usuario_m1']+':regular file', 'configuración estación modo/propietario')
            settings = parse_station(actor(a['usuario_m1'], ['cat', station], diagnostic='configuración estación ausente'))
            require(settings == station_settings(c), 'configuración estación distinta')
            actor(a['usuario_m1'], ['bash', ROOT/'instalacion/scripts/estacion-plan.sh'],
                  diagnostic='seal-suite plan no resuelve estación/runner')
            runner_preflight(c)
            runner_repository_check(c)
            # El registro es el de C1; root necesita leer el escrow privado para identidad.
            actor('root', verify_prepared_args(c),
                  capture=False, timeout=600, diagnostic='verify.sh completo FAIL', relay_errors=True)
        elif phase == 'F6':
            check_bus_states(c, runtime_config=False, clones=False)
            clean_role_clones(c)
            check_bus_states(c)
            regular(c['bus'])
            lockfile = regular(c['bus'].with_name('bus.lock'))
            require(stat.S_IMODE(lockfile.stat().st_mode) == 0o660, 'bus lock modo 0660')
            group = run(['getent', 'group', 'fabrica-'+c['project']], diagnostic='bus grupo de fábrica ausente').strip().split(':')
            require(len(group) == 4 and group[2].isdigit(), 'bus grupo de fábrica ausente')
            gid = int(group[2])
            uid = pwd.getpwnam(a['usuario_ceo']).pw_uid
            for path in (c['bus'], lockfile):
                require(path.stat().st_uid == uid and path.stat().st_gid == gid and
                        stat.S_IMODE(path.stat().st_mode) == 0o660, 'bus propietario/grupo/modo 0660: '+path.name)
            identity = str(c['bus'].stat().st_dev)+':'+str(c['bus'].stat().st_ino)
            for role, user, _ in roles(c):
                for path in (c['bus'], lockfile):
                    for access in ('-r', '-w'):
                        actor(user, ['test', access, path], diagnostic='acceso bus rechazado: '+role+' (usuario '+user+')')
                home = user_home(user)
                directory = home/'.local/state/talent-ceo/cursores'
                for d in (directory.parent, directory):
                    actor(user, ['test', '!', '-L', d], diagnostic='estado de rol enlazado: '+role)
                for d in (home/'.local', home/'.local/state'):
                    repair = 'sudo chown -- '+shlex.quote(user)+' '+shlex.quote(str(d))+' && sudo chmod go-w -- '+shlex.quote(str(d))
                    diagnostic = 'padres de estado propios y seguros: '+role+' ruta='+str(d)+'; corrección: '+repair
                    observed = actor(user, ['stat', '-c', '%a:%U:%F', d], diagnostic=diagnostic).strip().split(':')
                    if len(observed) == 3 and observed[2] == 'symbolic link':
                        diagnostic = ('padres de estado propios y seguros: '+role+' ruta='+str(d)+
                                      '; corrección: unlink -- '+shlex.quote(str(d))+
                                      '; restaurar un directorio real sin seguir el destino')
                    require(len(observed) == 3 and observed[1:] == [user, 'directory'] and
                            re.fullmatch(r'[0-7]{3,4}', observed[0]) and not int(observed[0], 8) & 0o022,
                            diagnostic+'; propietario='+(':'.join(observed[1:2]) or 'no comprobable')+
                            ' modo='+(':'.join(observed[:1]) or 'no comprobable'))
                for d in (directory.parent, directory):
                    observed = actor(user, ['stat', '-c', '%a:%U:%F', d], diagnostic='estado/cursor 0700 propio: '+role).strip()
                    require(observed == '700:'+user+':directory', 'estado/cursor 0700 propio: '+role)
                accreditation = actor(user, ['env', 'TA_BUS_STATE_DIR='+str(directory.parent), 'bash',
                                            c['clon']/'.claude/skills/talent-ceo/scripts/leer-acreditacion.sh', role],
                                      diagnostic='lector acreditación no comprobable: '+role).strip()
                require(accreditation in ('AUSENTE', 'NO_ACREDITADO', 'ACREDITADO'),
                        'lector acreditación contenido inválido: '+role)
                cursor = directory/(role+'.cursor')
                for file in (cursor, directory/(role+'.bus')):
                    kind = actor(user, ['stat', '-c', '%U:%F', file], diagnostic='cursor enlazado o ajeno: '+role).strip()
                    require(kind == user+':regular file', 'cursor enlazado o ajeno: '+role)
                size = actor(user, ['cat', cursor], diagnostic='cursor ausente o inválido: '+role).strip()
                require(re.fullmatch(r'[0-9]{1,18}', size) and int(size) <= c['bus'].stat().st_size,
                        'cursor ausente o inválido: '+role)
                marker = actor(user, ['cat', directory/(role+'.bus')], diagnostic='cursor bus distinto: '+role).strip()
                require(marker == identity, 'cursor bus distinto: '+role)
                cron = actor(user, ['crontab', '-l'], diagnostic='cron modelos ausente: '+role)
                require(all(line in cron.splitlines() for line in model_cron(c, role, user)),
                        'cron modelos ausente o distinto: '+role)
            cron = actor(a['usuario_ceo'], ['crontab', '-l'], diagnostic='cron CRON ausente')
            minutes = run(['bash', c['clon']/'.claude/skills/talent-ceo/scripts/tablas-cron.sh', '--minutos', 'CRON'],
                          env=runtime(c), diagnostic='cron CRON ausente').strip()
            require(any(line.startswith(minutes+' ') and 'CRON' in line and 'cron-tablas.sh' in line and
                        'TA_BUS_STATE_DIR='+declared_bus_state(c, 'CEO') in line
                        for line in cron.splitlines()), 'cron CRON ausente')
            print('sello/acreditación pendiente de F7')
        elif phase == 'F7':
            run(['bash', c['clon']/'.claude/skills/talent-ceo/scripts/doctor.sh'], env=runtime(c),
                capture=False, timeout=600, diagnostic='doctor rojo; revisar categorías de F7')
        else:
            smoke(c)
    print('verde '+phase)


def secret_values(c):
    owner = pwd.getpwnam(c['answers']['usuario_ceo']).pw_uid
    p = regular(c['env'], True, owner)
    data = {}
    for line in p.read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        m = re.fullmatch(r'([A-Z][A-Z0-9_]*)=([^\r\n]*)', line)
        require(m and m[1] not in data, 'escrow: formato inválido')
        data[m[1]] = m[2]
    return data


def credential_names(c):
    return ['GITHUB_TOKEN', 'LINEAR_API_KEY', 'CODERABBIT_API_KEY'] + (
        ['SUPABASE_ACCESS_TOKEN'] if c['answers']['supabase'] == 'si' else [])


def check_credentials(c):
    values = secret_values(c)
    missing = False
    for name in credential_names(c):
        present = bool(values.get(name))
        print(name+': '+('present' if present else 'missing'))
        missing |= not present
    for name in ('git-bootstrap-token', 'cuser-pass'):
        p = regular(c['escrow']/name, True)
        require(p.stat().st_size > 0, 'escrow vacío: '+name)
    require(not missing, 'credenciales missing')
    require((c['escrow']/'git-bootstrap-token').read_text().strip() == values['GITHUB_TOKEN'],
            'git-bootstrap-token: distinto de GITHUB_TOKEN')
    validate_credentials(c, values)


def validate_credentials(c, values):
    """Lecturas remotas sin efectos; nunca incluir valores en argv ni diagnósticos."""
    slug = c['answers']['repo_url'].removesuffix('.git').split('github.com/')[1]
    env = os.environ.copy()
    env.update(GH_TOKEN=values['GITHUB_TOKEN'], GITHUB_TOKEN=values['GITHUB_TOKEN'])
    try:
        p = subprocess.run(['gh', 'api', 'repos/'+slug], env=env, stdin=subprocess.DEVNULL,
                           text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        raise Error('sin red: GITHUB_TOKEN; '+command_context(['gh', 'api', 'repos/'+slug])) from None
    if p.returncode:
        network = re.search(r'(?i)resolve|timeout|connection|network|dial tcp|no such host', p.stderr)
        raise Error(('sin red: GITHUB_TOKEN' if network else 'GITHUB_TOKEN: rechazado')+'; '+command_context(['gh', 'api', 'repos/'+slug]))
    permissions = json.loads(p.stdout).get('permissions', {})
    for permission in ('push', 'admin'):
        require(permissions.get(permission) is True, 'GITHUB_TOKEN: sin permiso '+permission+' sobre el repositorio')
    token = values['LINEAR_API_KEY']
    require(not any(x in token for x in '\r\n\x00'), 'LINEAR_API_KEY: rechazada')
    fd, header = tempfile.mkstemp(dir=c['escrow'])
    os.close(fd)
    try:
        write(Path(header), 'Authorization: '+token+'\n')
        query = 'query($key:String!){viewer{id} teams(first:1,filter:{key:{eq:$key}}){nodes{id key}}}'
        try:
            p = subprocess.run(['curl', '--silent', '--show-error', '--max-time', '30',
                                '--header', '@'+header, '--header', 'Content-Type: application/json',
                                '--data', json.dumps({'query': query, 'variables': {'key': c['answers']['linear_clave']}}), '--write-out', '\n%{http_code}',
                                'https://api.linear.app/graphql'], stdin=subprocess.DEVNULL,
                               text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=35)
        except (OSError, subprocess.TimeoutExpired):
            raise Error('sin red: LINEAR_API_KEY; orden=curl destino=local argumento=https://api.linear.app/graphql') from None
        require(p.returncode == 0, 'sin red: LINEAR_API_KEY; orden=curl destino=local argumento=https://api.linear.app/graphql')
        body, status = p.stdout.rsplit('\n', 1)
        require(status == '200', 'LINEAR_API_KEY: rechazada')
        data = json.loads(body)
        require(not data.get('errors') and data.get('data', {}).get('viewer', {}).get('id'), 'LINEAR_API_KEY: rechazada')
        teams = data.get('data', {}).get('teams', {}).get('nodes', [])
        require(any(t.get('key') == c['answers']['linear_clave'] for t in teams),
                'LINEAR_API_KEY: equipo declarado ausente')
    finally:
        Path(header).unlink(missing_ok=True)


def credentials(c):
    require(sys.stdin.isatty(), 'lectura oculta requiere terminal', 2)
    values = secret_values(c)
    for name in credential_names(c):
        if not values.get(name):
            value = getpass.getpass(name+': ')
            require(value and not any(x in value for x in '\r\n\x00'), 'credencial vacía o inválida')
            values[name] = value
    write(c['env'], ''.join(k+'='+v+'\n' for k, v in values.items()))
    safe_dir(c['escrow'])
    p = c['escrow']/'git-bootstrap-token'
    if not p.exists():
        write(p, values['GITHUB_TOKEN'])
    p = c['escrow']/'cuser-pass'
    if not p.exists():
        value = getpass.getpass('cuser-pass (contraseña Linux de los contenedores): ')
        require(value and not any(x in value for x in '\r\n\x00'), 'contraseña inválida')
        write(p, value)
    check_credentials(c)


def actor_runtime(home, bus):
    return {'TA_BUS_STATE_DIR':str(home/'.local/state/talent-ceo'),
            'TA_BUS':str(bus), 'TA_BUS_LOCK':str(Path(bus).with_name('bus.lock'))}


def actor_runtime_text(home, bus):
    return ''.join('export '+key+'='+value+'\n' for key, value in actor_runtime(home, bus).items())


def start_actor(args):
    require(len(args) == 4 and args[0] in ('CEO', 'C1', 'M1'), 'uso iniciar-actor ROL ENV BUS MANIFIESTO', 2)
    role, envfile, bus, manifest = args
    for path in (envfile, bus, manifest):
        require(re.fullmatch(r'/[A-Za-z0-9_./-]+', path), 'ruta actor inválida', 2)
    data = {}
    for line in regular(Path(envfile), True).read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        m = re.fullmatch(r'([A-Z][A-Z0-9_]*)=([^\r\n]*)', line)
        require(m and m[1] not in data, 'env actor inválido')
        data[m[1]] = m[2]
    require(data.get('GITHUB_TOKEN') and data.get('LINEAR_API_KEY'), 'env actor incompleto')
    require(role != 'M1' or data.get('CODERABBIT_API_KEY'), 'env M1 sin CodeRabbit')
    env = {k:v for k, v in os.environ.items() if k in
           ('PATH', 'HOME', 'USER', 'LOGNAME', 'SHELL', 'TERM', 'LANG', 'LC_ALL', 'TMUX', 'TMUX_PANE', 'XDG_RUNTIME_DIR')}
    tokenfile = Path.home()/'.claude_token.env'
    loginfile = Path.home()/'.claude/.credentials.json'
    if tokenfile.exists():
        regular(tokenfile, True)
        words = shlex.split(tokenfile.read_text())
        require(len(words) == 2 and words[0] == 'export' and
                words[1].startswith('CLAUDE_CODE_OAUTH_TOKEN='), 'token actor inválido')
        token = words[1].split('=', 1)[1]
        require(re.fullmatch(r'[A-Za-z0-9_.-]+', token), 'token actor inválido')
        env['CLAUDE_CODE_OAUTH_TOKEN'] = token
    else:
        regular(loginfile, True)
    env.update(IS_SANDBOX='1', CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN='1',
               TA_BUS=bus, TA_BUS_LOCK=str(Path(bus).with_name('bus.lock')), TF_MANIFEST=manifest)
    public = pairs(Path.home()/'.config/talent-factory/runtime.conf', exports=True)
    require(public == actor_runtime(Path.home(), bus), 'configuración bus distinta')
    env.update(public)
    env['TA_OPERATION_ENV'] = envfile
    if role == 'M1':
        env.update(read_station(station_file(Path.home())))
    arguments = ['claude', '--dangerously-skip-permissions']
    model = run(['bash', ROOT/'instalacion/scripts/modelos-rol.sh', '--modelo', role], env=env, relay_errors=True).strip()
    require(model, 'modelo de torre vacío: '+role)
    arguments += ['--model', model]
    os.execvpe('claude', arguments, env)


def closed_env(c):
    a = c['answers']
    env = {'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
           'HOME': str(c['home']), 'LANG': 'C.UTF-8', 'SUDO_USER': a['usuario_ceo'],
           'HOST_HOME': str(c['home']), 'HOST_USER': a['usuario_ceo'],
           'SECRET_DIR': str(c['escrow']), 'REPO_URL': a['repo_url'],
           'REPO_DIR': c['clon'].name, 'MACHINE_NUM': a['maquina_n'], 'COUNT': a['canales_n'],
           'TC_FLAG_POOL_SIZE': a['pool_gib']+'GiB', 'POOL_DISK': '', 'GOLDEN': 'golden-'+a['proyecto'],
           'POOL': 'pool-'+a['proyecto'], 'CUSER': a['cuser'], 'TC_LOCAL_ONLY': 'yes',
           'TF_REPO_URL': '', 'TF_REPO_DIR': 'motor-paquete',
           'TF_CHANNEL_GIT_NAME_TMPL': a['git_nombre_tmpl'],
           'TF_CHANNEL_GIT_EMAIL_TMPL': a['git_email_tmpl'],
           'AM_LEDGER': str(ROOT/'ledger/cuentas.json'), 'TF_ROOT': str(ROOT),
           'TF_MANIFEST': str(c['manifest'])}
    return env


def verify_prepared_args(c):
    user = c['answers']['usuario_c1']
    env = closed_env(c)
    env['TCO_MODELOS_REGISTRO'] = str(user_home(user)/'.config/talent-channel-operation/modelos.conf')
    return ['env', '-i', *[k+'='+v for k, v in env.items()],
            'bash', str(ROOT/'skills/talent-channels/scripts/verify.sh'), '--etapa', 'acreditado']


def privileged():
    require(os.geteuid() == 0, 'ejecución requiere sudo; enseñar --plan primero', 2)


def parity_env(c):
    directory = c['home']/'.local/share/fabrica'/c['project']/'receipts'
    authorities = directory/'autoridades.txt'
    require(not authorities.is_symlink(), 'autoridades: enlace no permitido')
    value = authorities.read_text().strip() if authorities.is_file() else ''
    require(not value or re.fullmatch(r'[1-9][0-9]*(,[1-9][0-9]*)*', value), 'autoridades: CSV de ids inválido')
    return {'TRO_CANON_PACKAGE_DIR': str(ROOT), 'TRO_RECEIPTS_DIR': str(directory),
            'TRO_RECEIPT_AUTHORITIES': value, 'TRO_CANON_REPO_DIR': '',
            'TRO_MANIFEST': str(c['clon']/'.claude/skills/talent-repo-onboarding/assets/parity-manifest.tsv')}


def check_configuration(c):
    # Solo configuración pública; no volcar valores del env ni credenciales.
    a = c['answers']
    manifest = pairs(c['manifest'], quoted=True)
    require(manifest.get('TF_PROJECT') == c['project'] and
            manifest.get('TF_REPO_URL') == a['repo_url'] and
            manifest.get('TF_LINEAR_TEAM_KEY') == a['linear_clave'] and
            manifest.get('TF_REPO_DIR') == c['clon'].name and manifest.get('TF_GATE_IDS') == a['gates_ids'],
            'configuración: manifiesto incoherente')
    for gate in a['gates_ids'].split():
        key = gate.replace('-', '_')
        require(manifest.get('TF_GATE_CMD_'+key) == a['gate_cmd_'+key], 'configuración: gate incoherente '+gate)
    run(['bash', ROOT/'skills/talent-ceo/scripts/lib-perfil.sh', '--check', c['profile']], diagnostic='perfil rojo')
    run(['bash', ROOT/'skills/talent-channels/scripts/validate-manifest.sh', c['manifest']], diagnostic='manifiesto rojo')
    rows = [line.split('\t') for line in c['profile'].read_text().splitlines()[1:]]
    for role, user, session in roles(c):
        declared = [row for row in rows if len(row) == 6 and row[1] == role]
        require(len(declared) == 1 and declared[0][4] == session and
                'usuario='+user in declared[0][5].split(';'), 'configuración: perfil incoherente '+role)
    declared = [row for row in rows if len(row) == 6 and row[0] == 'canal']
    require({row[3] for row in declared} == set(channels(c)) and all(
            'usuario='+a['usuario_incus'] in row[5].split(';') for row in declared),
            'configuración: perfil de canales incoherente')
    wells(c)
    ledger = json.loads((ROOT/'ledger/cuentas.json').read_text())
    require(ledger.get('coordinator_host') == a['host_nombre'], 'configuración: ledger incoherente')
    for member in ('talent-channel-operation', 'talent-orchestrator'):
        data = pairs(c['home']/'.config'/member/'agents.conf', quoted=True, exports=True)
        require(data.get('TF_MANIFEST') == str(c['manifest']) and
                data.get('TCO_DEV_CARRILES') == ' '.join(ch.removeprefix('vibe-channel-') for ch in channels(c)),
                'configuración: agents.conf incoherente '+member)
    dedicated = 'fabrica-'+c['project']
    for user in [u for _, u, _ in roles(c)]+[a['usuario_incus']]:
        user_home(user)
        groups = run(['id', '-nG', user], diagnostic='usuario sin grupo de fábrica: '+user).split()
        require(dedicated in groups, 'usuario sin grupo de fábrica: '+user)
        if user in (a['usuario_c1'], a['usuario_m1'], a['usuario_incus']):
            require('incus-admin' in groups, 'usuario sin grupo incus-admin: '+user)


def seed(c, container):
    destination = '/home/'+c['answers']['cuser']+'/motor-paquete'
    # Ruta dedicada al núcleo: retirar restos de versiones anteriores sin seguir enlaces.
    run(['incus', 'exec', container, '--', 'bash', '-c',
         'test ! -L "$1" && '
         'if test -e "$1"; then test -d "$1" && '
         'test -z "$(find "$1" ! -user "$2" -print -quit)" || exit 1; '
         'else install -d -m 755 -o "$2" -g "$2" "$1"; fi && '
         'find "$1" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf -- {} +',
         '_', destination, c['answers']['cuser']], diagnostic='núcleo preexistente ajeno o enlazado: '+container)
    # Solo el núcleo distribuido; nunca respuestas, home, ledger ni manifiestos adjudicados.
    with tempfile.TemporaryFile() as archive:
        with tarfile.open(fileobj=archive, mode='w') as tar:
            for name in core_paths(ROOT) + ['instalacion/NUCLEO.sha256']:
                tar.add(ROOT/name, arcname=name, recursive=False)
        archive.seek(0)
        p = execute(['incus', 'exec', container, '--', 'tar', '-xf', '-', '-C', destination],
                           stdin=archive, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
        require(p.returncode == 0, 'siembra del núcleo fallida: '+container+'; '+
                command_context(['incus', 'exec', container, '--', 'tar', '-xf', '-', '-C', destination]))
    run(['incus', 'exec', container, '--', 'chown', '-R', c['answers']['cuser']+':'+c['answers']['cuser'], destination])
    # verify.sh exige .git en el motor. Snapshot LOCAL del ZIP, sin remoto ni descarga.
    run(['incus', 'exec', container, '--', 'su', '-', c['answers']['cuser'], '-c',
         'git -C "$1" init -b distribucion && git -C "$1" add . && '
         '(git -C "$1" diff --cached --quiet || '
         'git -c user.name=Distribucion -c user.email=distribucion@example.invalid '
         '-c core.hooksPath=/dev/null -c commit.gpgsign=false -C "$1" commit -m "Nucleo distribuido")',
         '_', destination])


def instance_states(c):
    output = run(['incus', 'list', '-f', 'csv', '-c', 'ns'], diagnostic='provisión: estado Incus no verificable')
    states = {}
    for line in output.splitlines():
        name, status = line.split(',')
        require(name not in states and status in ('RUNNING', 'STOPPED'),
                'provisión: estado Incus no verificable')
        states[name] = status
    return states


def instance_power(c, name, status):
    current = instance_states(c).get(name)
    require(current, 'contenedor ausente o estado: '+name)
    if current != status:
        run(['incus', 'start' if status == 'RUNNING' else 'stop', name])


def seed_fingerprint():
    return hashlib.sha256(regular(ROOT/'instalacion/NUCLEO.sha256').read_bytes()).hexdigest()


def seed_marker(c, golden):
    path = '/home/'+c['answers']['cuser']+'/motor-paquete/.sembrado'
    p = execute(['incus', 'file', 'pull', golden+path, '-'], stdin=subprocess.DEVNULL,
                       text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    return p.stdout.strip() if p.returncode == 0 else ''


def no_clones(c, states):
    names = channels(c)+['runner-'+c['project'], *wells(c)]
    require(not any(n in states for n in names),
            'plantilla sin marca correcta con clones: revisar recuperación de F2; no destruir clones')


def provision(c, mode):
    require(mode in ('--plan', '--ejecutar', '--verificar', '--plan-recuperar', '--recuperar'), 'uso f2-provision', 2)
    if mode == '--plan':
        print('Root: pool btrfs loop '+c['answers']['pool_gib']+'GiB; red local; golden sin logins;')
        print('sembrar motor del ZIP por hashes; clonar '+','.join(channels(c))+' y runner-'+c['project'])
        print('Crear pozos sin login: '+','.join(wells(c)))
        print('Runner: usuario runner en docker sin sudo; retirar sudo heredado del usuario del canal; repo /home/runner/repo con origin público, sin descarga; preflight real del motor, cero credenciales.')
        print('Límites por canal: CPU='+c['answers']['canal_cpu']+' memoria='+c['answers']['canal_mem_gib']+'GiB')
        print('No formatear discos. Ejecutar disk, network, golden, clone mediante --only.')
        return
    if mode == '--verificar':
        run(['sudo', '-n', 'env', '-i', *[k+'='+v for k, v in closed_env(c).items()],
             'bash', ROOT/'skills/talent-channels/scripts/verify.sh', '--etapa', 'creado'], capture=False, timeout=600)
        return
    if mode in ('--plan-recuperar', '--recuperar'):
        if mode == '--recuperar':
            privileged()
        golden = 'golden-'+c['project']
        states = instance_states(c)
        require(golden in states, 'recuperación: plantilla de esta instalación ausente: '+golden)
        no_clones(c, states)
        complete = run(['incus', 'config', 'get', golden, 'user.fabrica.terminada'])
        require(not complete.strip(), 'recuperación: plantilla completa; no se borra')
        print('Recuperación: borrar solo '+golden+' incompleta; conservar pool, red y demás instancias. Repetir --ejecutar.')
        if mode == '--recuperar':
            instance_power(c, golden, 'STOPPED')
            run(['incus', 'delete', golden])
        return
    privileged()
    core_verify(ROOT)
    env = closed_env(c)
    entry = ROOT/'skills/talent-channels/scripts/provision.sh'
    golden = env['GOLDEN']
    for phase in ('disk', 'network'):
        run(['bash', entry, '--local-only', '--only', phase], env=env, capture=False, timeout=1800)
    if golden not in instance_states(c):
        run(['bash', entry, '--local-only', '--only', 'golden'], env=env, capture=False, timeout=3600)
    require(run(['incus', 'config', 'get', golden, 'user.fabrica.base-completa']).strip() == 'yes',
            'golden existente incompleto: construcción sin terminar; usar --plan-recuperar antes de repetir')
    if seed_marker(c, golden) != seed_fingerprint():
        no_clones(c, instance_states(c))
        instance_power(c, golden, 'RUNNING')
        seed(c, golden)
        container_core(c, golden)
        marker = '/home/'+c['answers']['cuser']+'/motor-paquete/.sembrado'
        run(['incus', 'exec', golden, '--', 'bash', '-c', 'printf "%s\\n" "$1" > "$2"', '_', seed_fingerprint(), marker])
        run(['incus', 'config', 'set', golden, 'user.fabrica.terminada', seed_fingerprint()])
    else:
        complete = run(['incus', 'config', 'get', golden, 'user.fabrica.terminada']).strip()
        if complete != seed_fingerprint():
            no_clones(c, instance_states(c))
            instance_power(c, golden, 'RUNNING')
            container_core(c, golden)
            run(['incus', 'config', 'set', golden, 'user.fabrica.terminada', seed_fingerprint()])
    instance_power(c, golden, 'STOPPED')
    run(['bash', entry, '--local-only', '--only', 'clone'], env=env, capture=False, timeout=1800)
    for channel in channels(c):
        run(['incus', 'config', 'set', channel, 'limits.cpu', c['answers']['canal_cpu']])
        run(['incus', 'config', 'set', channel, 'limits.memory', c['answers']['canal_mem_gib']+'GiB'])
    for container in ['runner-'+c['project'], *wells(c)]:
        if container not in instance_states(c):
            run(['incus', 'copy', golden, container])
        instance_power(c, container, 'RUNNING')
    script = regular(ROOT/'instalacion/scripts/runner-perfil.sh').read_text()
    run(['incus', 'exec', 'runner-'+c['project'], '--', 'bash', '-c', script, '_',
         c['answers']['cuser'], '/home/'+c['answers']['cuser']+'/motor-paquete', c['answers']['repo_url']],
        diagnostic='runner perfil no preparado')
    require(c['escrow'].is_dir() and not c['escrow'].is_symlink(), 'escrow ausente o enlazado')
    write(c['escrow']/'channel-profiles.list', ''.join(ch+'=produccion\n' for ch in channels(c))+
          'runner-'+c['project']+'=runner\n')
    owner = pwd.getpwnam(c['answers']['usuario_ceo'])
    os.chown(c['escrow']/'channel-profiles.list', owner.pw_uid, owner.pw_gid)
    # La comprobación de hashes ocurre en F2 desde la autoridad host.


def sudo_escape(text):
    for char in ('\\', ',', ':', '=', '#'):
        text = text.replace(char, '\\'+char)
    return text


def sudo_rules(c):
    ceo = c['answers']['usuario_ceo']
    base = c['clon']/'.claude/skills/talent-ceo/scripts'
    lines = []
    model_library = str(c['clon']/'.claude/skills/talent-channel-operation/scripts/lib-modelos.sh')
    model_command = '. "$1"; tco_modelo_read "$2"'
    for role, user, session in roles(c):
        queries = [['tmux', 'has-session', '-t', '='+session],
                   ['tmux', 'list-panes', '-t', '='+session+':', '-F', '#{pane_pid}'],
                   ['tmux', 'display-message', '-p', '-t', '='+session+':', '#{alternate_on}|#{session_created}'],
                   ['tmux', 'capture-pane', '-p', '-J', '-t', '='+session+':'],
                   ['tmux', 'has-session', '-t', session],
                   ['tmux', 'display-message', '-p', '-t', session, '#{alternate_on}'],
                   ['tmux', 'capture-pane', '-p', '-t', session], ['crontab', '-l'], ['gh', 'auth', 'status'],
                   ['env', 'TA_BUS_STATE_DIR='+str(user_home(user)/'.local/state/talent-ceo'), 'bash', str(base/'leer-acreditacion.sh'), role],
                   ['env', 'TA_BUS='+str(c['bus']), 'TA_PERFIL='+str(c['clon']/'manifiestos'/c['profile'].name),
                    'bash', str(base/'bus-leer.sh'), '--lector', role, '--peek']]
        home = user_home(user)
        queries.append(['cat', str(home/'.config/talent-factory/runtime.conf')])
        directory = home/'.local/state/talent-ceo/cursores'
        queries.append(['cat', str(role_clone(c, role)/'manifiestos'/c['profile'].name)])
        queries += [['stat', '-c', '%a:%U:%F', str(d)] for d in
                    (home/'.local', home/'.local/state', directory.parent, directory)]
        queries += [['test', '!', '-L', str(d)] for d in
                    (home/'.local', home/'.local/state', directory.parent, directory)]
        queries += [['cat', str(directory/(role+ext))] for ext in ('.cursor', '.bus')]
        queries += [['stat', '-c', '%U:%F', str(directory/(role+ext))] for ext in ('.cursor', '.bus')]
        queries.append(['stat', '-c', '%a:%U:%F', str(home/'.claude/.credentials.json')])
        queries.append(['bash', str(ROOT/'instalacion/scripts/claude-capacidad.sh')])
        queries.append(['bash', str(ROOT/'instalacion/scripts/modelos-rol.sh'), '--verificar', role, session])
        queries.append(['bash', '-c', model_command, '_', model_library, 'coordinador'])
        queries.append(['env', 'TA_ROL='+role, 'TA_BUS='+str(c['bus']),
                        'TA_PERFIL='+str(role_clone(c, role)/'manifiestos'/c['profile'].name),
                        'bash', str(ROOT/'skills/talent-ceo/scripts/cron-modelos.sh'), '--linea'])
        queries.append(['git', 'ls-remote', c['answers']['repo_url']])
        queries.append(['git', '-C', str(role_clone(c, role)), 'status', '--porcelain', '--untracked-files=no'])
        if role == 'M1':
            queries.append(['coderabbit', '--version'])
            queries.append(['coderabbit', 'auth', 'status'])
            queries.append(['bash', str(ROOT/'instalacion/scripts/estacion-plan.sh')])
            queries += [['cat', str(station_file(home))], ['stat', '-c', '%a:%U:%F', str(station_file(home))]]
        if role in ('C1', 'M1'):
            own = role_clone(c, role)
            queries.extend([['test', '-w', str(path)] for path in (own, own/'.git')])
            queries += [['git', '-C', str(own), 'remote', 'get-url', 'origin'],
                        ['git', '-C', str(own), 'ls-remote', 'origin'], ['stat', '-c', '%U', str(own)]]
        if user != ceo:
            queries += [['test', flag, str(path)] for path in (c['bus'], c['bus'].with_name('bus.lock'))
                        for flag in ('-r', '-w')]
            if role == 'C1':
                queries += [['bash', str(role_clone(c, 'C1')/'.claude/skills/talent-channel-operation/scripts/preparar-sesiones.sh'),
                             '--verificar', ch.removeprefix('vibe-channel-')] for ch in channels(c)]
            for query in queries:
                executable = shutil.which(query[0])
                require(executable, 'sudoers: herramienta ausente '+query[0])
                lines.append(ceo+' ALL=('+user+') NOPASSWD: '+sudo_escape(executable+' '+' '.join(query[1:])))
    query = verify_prepared_args(c)
    executable = shutil.which(query[0])
    require(executable, 'sudoers: herramienta ausente '+query[0])
    lines.append(ceo+' ALL=(root) NOPASSWD: '+sudo_escape(executable+' '+' '.join(query[1:])))
    operator = c['answers']['usuario_incus']
    incus = shutil.which('incus')
    require(incus, 'sudoers: incus ausente')
    lines.append(ceo+' ALL=('+operator+') NOPASSWD: '+incus+' list -c ns -f csv')
    for phase in ('F2', 'F5'):
        query = runner_query(c, phase)
        lines.append(ceo+' ALL=('+operator+') NOPASSWD: '+sudo_escape(shutil.which('bash')+' '+' '.join(query[1:])))
    for container in ['golden-'+c['project'], *channels(c), 'runner-'+c['project'], *wells(c)]:
        lines.append(ceo+' ALL=('+operator+') NOPASSWD: '+sudo_escape(incus+' list ^'+container+'$ -f csv -c ns'))
        if container.startswith('vibe-channel-'):
            for pane in ('v:.0', 'v:.1'):
                query = [incus, 'exec', container, '--', 'su', '-', c['answers']['cuser'], '-c',
                         "tmux capture-pane -p -t '"+pane+"' -J -S -80"]
                lines.append(ceo+' ALL=('+operator+') NOPASSWD: '+sudo_escape(' '.join(query)))
            args = [str(base/'leer-auditor.sh'), container, 'v:.1', c['answers']['cuser'],
                    'codex' if c['answers']['codex'] == 'si' else 'claude-root']
            lines.append(ceo+' ALL=('+operator+') NOPASSWD: '+sudo_escape(shutil.which('bash')+' '+' '.join(args)))
    return '\n'.join(lines)+'\n'


def onboarding(c, plan=False, accepted=()):
    require(c['clon'].is_dir(), 'clon de producto ausente')
    require(not (c['clon']/'.git').exists() or (c['clon']/'.git').is_dir(),
            'onboarding: metadatos git deben quedar dentro del clon')
    require(run(['git', '-C', c['clon'], 'remote', 'get-url', 'origin']).strip().removesuffix('.git') ==
            c['answers']['repo_url'].removesuffix('.git'), 'origin distinto')
    from producto import equivalents
    # Revisar todos los destinos antes de la primera escritura, también en el plan.
    from producto import clone_destination, equivalent_payloads
    canon = [line.split('\t') for line in
             (ROOT/'skills/talent-repo-onboarding/assets/canon-paquete.tsv').read_text().splitlines()
             if line and not line.startswith('#')]
    conflicts, pending = [], {}
    for rel in [*equivalent_payloads(c), *(prod for prod, _ in canon),
                '.claude/tf-manifest.conf', '.git/config', '.git/config.lock']:
        try:
            clone_destination(c['clon'], rel)
        except Error as exc:
            conflicts.append(str(exc))
    merged, merge_conflicts = equivalents(c, plan, collect=True)
    pending.update(merged)
    conflicts.extend(merge_conflicts)
    known_canon = {prod for prod, _ in canon}
    require(set(accepted) <= known_canon, 'aceptar-canon: ruta fuera del contrato', 2)
    # Copiar los IDÉNTICOS del mapa real; no sustituir EQUIVALENTES por los del motor.
    for line in (ROOT/'skills/talent-repo-onboarding/assets/canon-paquete.tsv').read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        prod, rel = line.split('\t')
        require('..' not in Path(prod).parts and not Path(prod).is_absolute(), 'canon: ruta inválida')
        try:
            target = clone_destination(c['clon'], prod)
        except Error as exc:
            conflicts.append(str(exc))
            continue
        print(('comprobar ' if target.exists() else 'crear ')+prod)
        content = regular(ROOT/rel).read_text()
        if target.exists():
            if target.read_bytes() != (ROOT/rel).read_bytes():
                print(''.join(difflib.unified_diff(target.read_text().splitlines(True), content.splitlines(True),
                                                  fromfile=prod, tofile='canon/'+prod)), end='')
                if prod not in accepted:
                    conflicts.append('canon existente distinto: '+prod+'; usar --aceptar-canon '+prod)
        pending[prod] = content
    validator = c['answers']['validador_rama']
    try:
        target = clone_destination(c['clon'], validator)
        if not target.exists() and validator not in pending:
            pending[validator] = regular(ROOT/'scripts/github/validar-rama-pr.sh').read_text()
    except Error as exc:
        conflicts.append(str(exc))
    # Ninguna escritura antes de resolver todas las fusiones, rutas y permisos.
    for rel in pending:
        target = clone_destination(c['clon'], rel)
        parent = next(p for p in target.parents if p.exists())
        if not os.access(parent, os.W_OK | os.X_OK) or (target.exists() and not os.access(target, os.W_OK)):
            conflicts.append('onboarding: permisos insuficientes: '+rel)
    if '.gitignore' in pending:
        try:
            pending['.gitignore'] = ignore_contract(c, pending['.gitignore'], set(pending))
        except Error as exc:
            conflicts.append(str(exc))
    try:
        parity_env(c)
    except Error as exc:
        conflicts.append(str(exc))
    require(not conflicts, '\n'.join(dict.fromkeys(conflicts)))
    from etiquetas import ensure_review_label
    ensure_review_label(c, plan)
    if plan:
        print('recibos permanentes: '+parity_env(c)['TRO_RECEIPTS_DIR'])
        repository_policy(c, True)
        return
    repository_policy(c, False)
    for rel, content in pending.items():
        target = clone_destination(c['clon'], rel)
        target.parent.mkdir(parents=True, exist_ok=True)
        write(target, content, 0o755 if rel.endswith('.sh') or rel == '.githooks/pre-push' else 0o644)
    directory = Path(parity_env(c)['TRO_RECEIPTS_DIR'])
    role_directory(c['home'], directory, c['answers']['usuario_ceo'])
    run(['bash', c['clon']/'scripts/setup-githooks.sh'], cwd=c['clon'], capture=False)
    run(['bash', ROOT/'scripts/provision-tf-manifest.sh', '--manifest', c['manifest'], '--root', c['clon']], capture=False)


def repository_policy(c, plan):
    from producto import yaml_nodes
    file = c['clon']/'.coderabbit.yaml'
    nodes = list(yaml_nodes(regular(file).read_text())) if file.exists() else []
    flags = [value for path, value, _ in nodes if path == ('reviews', 'auto_review', 'enabled')]
    disabled = flags == ['false']
    workflows = sorted(path.name for path in (c['clon']/'.github/workflows').glob('*') if path.suffix in ('.yml', '.yaml'))
    print('CodeRabbit App: '+('revisión automática desactivada en YAML' if disabled else
          'revisión automática activa o no acreditada; desactivarla en la configuración o aceptar el gasto de cupo'))
    if workflows:
        print('aviso workflows propios en PR: '+', '.join(workflows))
    if not plan:
        write(STATE/'politica-repositorio.json', json.dumps({'auto_review':'desactivada' if disabled else 'activa-o-no-acreditada',
              'workflows':workflows}, ensure_ascii=False, indent=2)+'\n')


def ignore_contract(c, text, paths):
    def ignored(path):
        p = execute(['git', '-C', str(c['clon']), 'check-ignore', '--no-index', '-q', path],
                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        require(p.returncode in (0, 1), 'gitignore: consulta no verificable; '+command_context(['git', 'check-ignore', path], c['clon']))
        return p.returncode == 0
    excluded = {p for p in paths if ignored(p)}
    if not excluded:
        return text
    directories = set()
    for path in excluded:
        for parent in Path(path).parents:
            if str(parent) != '.' and ignored(parent.as_posix()+'/'):
                directories.add(parent.as_posix())
    exceptions = []
    # Abrir de arriba abajo; mantener excluidos los hermanos fuera del contrato.
    for directory in sorted(directories, key=lambda s: (s.count('/'), s)):
        exceptions += ['!/'+directory+'/', '/'+directory+'/*']
    # Reabrir padres interiores después de las exclusiones de sus ancestros.
    for path in sorted(excluded):
        parents = [p.as_posix() for p in reversed(Path(path).parents) if str(p) != '.']
        exceptions += ['!/'+p+'/' for p in parents]
        exceptions.append('!/'+path)
    end = '# fabrica:fin'
    return text.replace(end, '\n'.join(dict.fromkeys(exceptions))+'\n'+end)


def channel_env(c, plan):
    print('Copiar env operacional 0600 con push-carril-env a canales, SIN CodeRabbit; excluir perfil runner; gh login y setup-git por rol y canal; autostart. Panes en F5.')
    if plan:
        return
    privileged()
    recipient_channels = credential_channels(c)
    values = secret_values(c)
    values.pop('CODERABBIT_API_KEY', None)
    envdir = c['escrow']/'env'
    owner = pwd.getpwnam(c['answers']['usuario_ceo'])
    role_directory(c['home'], envdir, c['answers']['usuario_ceo'])
    for ch in recipient_channels:
        role_file(envdir/(ch+'.env'), c['answers']['usuario_ceo'])
        write(envdir/(ch+'.env'), ''.join(k+'='+v+'\n' for k, v in values.items()))
        os.chown(envdir/(ch+'.env'), owner.pw_uid, owner.pw_gid)
        run(['bash', ROOT/'skills/talent-channels/scripts/push-carril-env.sh', ch],
            env=closed_env(c), timeout=600, diagnostic='env/gh/git no configurados: '+ch)
    from acreditacion import configure_host_git
    configure_host_git(c)
    run(['bash', ROOT/'skills/talent-channels/scripts/provision.sh', '--only', 'autostart', '--local-only'],
        env=closed_env(c), capture=False, timeout=600)


def model_cron(c, role, user):
    emitted = actor(user, ['env', 'TA_ROL='+role, 'TA_BUS='+str(c['bus']),
                   'TA_PERFIL='+str(role_clone(c, role)/'manifiestos'/c['profile'].name),
                   'bash', ROOT/'skills/talent-ceo/scripts/cron-modelos.sh', '--linea'],
                   diagnostic='cron modelos no emitido: '+role).splitlines()
    require(len(emitted) == 2 and emitted[0] == 'SHELL=/bin/bash' and
            emitted[1].startswith('17 3 * * 0 TA_ROL=') and emitted[1].endswith('# modelos-rodantes'),
            'cron modelos formato inválido: '+role)
    # Solo añade el estado persistente; calendario y orden provienen del skill.
    emitted[1] = emitted[1].replace(' TA_ROL=', ' '+shlex.quote(
        'TA_BUS_STATE_DIR='+str(user_home(user)/'.local/state/talent-ceo'))+' TA_ROL=', 1)
    return emitted


def infrastructure(c, op, plan, users_only=False):
    if not plan:
        privileged()
    a = c['answers']
    group = 'fabrica-'+c['project']
    if op == 'f5-torres':
        print('Usuarios distintos: '+','.join(user for _, user, _ in roles(c))+','+a['usuario_incus'])
        print('Grupo '+group+'; operador, C1 y M1 en incus-admin; equivale a administrar todos los contenedores.')
        print('C1 y M1 necesitan clones propios con escritura, incluido .git; no compartir un checkout mutable entre roles.')
        print('Grupo del home CEO '+str(c['home'])+' pasa a '+group+'; añadir solo traversal de grupo.')
        print('Los padres de paquete, clon y bus deben permitir acceso a los actores; no se amplían automáticamente.')
        if users_only:
            for role, user, _ in roles(c):
                print('Home '+role+' ('+user+'): '+str(Path(declared_bus_state(c, role)).parents[2]))
            if plan:
                return
            if execute(['getent', 'group', group], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL).returncode != 0:
                run(['groupadd', group])
            for user in [u for _, u, _ in roles(c)]+[a['usuario_incus']]:
                if execute(['id', user], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
                    role = next((r for r, u, _ in roles(c) if u == user), None)
                    home = Path(declared_bus_state(c, role)).parents[2] if role else Path('/home')/user
                    run(['useradd', '--create-home', '--home-dir', home, '--shell', '/bin/bash', user])
                run(['usermod', '-aG', group, user])
            check_bus_states(c, runtime_config=False, clones=False)
            run(['usermod', '-aG', 'incus-admin', a['usuario_incus']])
            for user in (a['usuario_c1'], a['usuario_m1']):
                run(['usermod', '-aG', 'incus-admin', user])
            import grp
            require(c['home'].is_dir() and not c['home'].is_symlink() and
                    c['home'].stat().st_uid == pwd.getpwnam(a['usuario_ceo']).pw_uid, 'home CEO ajeno')
            os.chown(c['home'], pwd.getpwnam(a['usuario_ceo']).pw_uid, grp.getgrnam(group).gr_gid)
            c['home'].chmod(stat.S_IMODE(c['home'].stat().st_mode) | 0o010)
            return
        print('Iniciar sesiones CEO=ceo C1=torre-c1 M1=m1; renderer clásico, barra ctx y confianza del cwd.')
        print('Modelos: resolver por usuario; CEO Opus vigente, C1/M1 Sonnet vigente; cron semanal.')
        print('Sudoers de consultas exactas (sin shell libre):\n'+sudo_rules(c))
        if plan:
            return
        check_bus_states(c, runtime_config=False)
        rules = sudo_rules(c)
        fd, name = tempfile.mkstemp()
        os.close(fd)
        temp = Path(name)
        try:
            write(temp, rules, 0o440)
            require_classic_sudo()
            run(['visudo', '-c', '-f', temp])
            dest = Path('/etc/sudoers.d')/('fabrica-'+c['project'])
            if dest.exists():
                require(regular(dest).read_text() == rules, 'sudoers existente distinto; revisión humana requerida')
            else:
                write(dest, rules, 0o440)
        finally:
            temp.unlink(missing_ok=True)
        for role, user, session in roles(c):
            home = Path(pwd.getpwnam(user).pw_dir)
            bus_state = home/'.local/state/talent-ceo'
            role_directory(home, bus_state, user)
            role_directory(home, home/'.claude', user)
            role_directory(home, home/'.config/talent-channel-operation', user)
            public = home/'.config/talent-factory/runtime.conf'
            role_directory(home, public.parent, user, 0o755)
            role_file(public, user)
            write(public, actor_runtime_text(home, c['bus']), 0o644)
            os.chown(public, pwd.getpwnam(user).pw_uid, pwd.getpwnam(user).pw_gid)
            workdir = role_clone(c, role)
            require(workdir.is_dir() and not workdir.is_symlink(), 'clon propio de estación ausente: '+role)
            if role in ('C1', 'M1'):
                actor(user, ['test', '-w', workdir])
                actor(user, ['test', '-w', workdir/'.git'])
            if role != 'CEO':
                envdir = home/c['project']
                role_directory(home, envdir, user)
                role_file(envdir/'.env.local', user)
                values = secret_values(c)
                if role != 'M1':
                    values.pop('CODERABBIT_API_KEY', None)
                write(envdir/'.env.local', ''.join(k+'='+v+'\n' for k, v in values.items()))
                os.chown(envdir/'.env.local', pwd.getpwnam(user).pw_uid, pwd.getpwnam(user).pw_gid)
                for kind in ('talent-channel-operation', 'talent-orchestrator'):
                    target = home/'.config'/kind
                    role_directory(home, target, user)
                    role_file(target/'agents.conf', user)
                    source = regular(c['home']/'.config'/kind/'agents.conf')
                    content = source.read_text().replace(str(c['clon']), str(workdir))
                    write(target/'agents.conf', content)
                    os.chown(target/'agents.conf', pwd.getpwnam(user).pw_uid, pwd.getpwnam(user).pw_gid)
            actor(user, ['bash', c['clon']/'.claude/skills/talent-context/scripts/install-statusline.sh'], capture=False)
            if role == 'M1':
                actor(user, ['bash', ROOT/'skills/talent-channels/scripts/coderabbit-auth.sh', home/c['project']/'.env.local'],
                      diagnostic='CodeRabbit CLI sin autenticación: M1', relay_errors=True)
                path = station_file(home)
                require(not any(parent.is_symlink() for parent in (path, *path.parents)), 'configuración estación enlazada')
                role_directory(home, path.parent, user, 0o755)
                role_file(path, user)
                write(path, ''.join(key+'='+value+'\n' for key, value in station_settings(c).items()), 0o644)
                os.chown(path, pwd.getpwnam(user).pw_uid, pwd.getpwnam(user).pw_gid)
            path = home/'.claude.json'
            role_file(path, user)
            if path.exists():
                regular(path)
            # Fusión jq, sin eliminar otras claves ni escribir credenciales.
            expression = '.hasCompletedOnboarding = true | .projects[$cwd].hasTrustDialogAccepted = true'
            command = ['jq', '--arg', 'cwd', str(workdir), expression]
            command += [str(path)] if path.exists() else ['-n']
            merged = run(command, diagnostic='baseline Claude no preparado: '+role)
            write(path, merged)
            os.chown(path, pwd.getpwnam(user).pw_uid, pwd.getpwnam(user).pw_gid)
            if role == 'M1':
                for kind in ('talent-channel-operation', 'talent-orchestrator'):
                    agentfile = home/'.config'/kind/'agents.conf'
                    content = regular(agentfile).read_text()
                    for name in ('TCO_DEV_CARRILES', 'TCO_AUDIT_CARRILES'):
                        content = re.sub(r'(?m)^(?:export )?'+name+r'=.*\n?', '', content)
                        content += name+'=""\n'
                    write(agentfile, content)
                    os.chown(agentfile, pwd.getpwnam(user).pw_uid, pwd.getpwnam(user).pw_gid)
        # Acreditar y resolver TODOS antes de crear una torre: un fallo no deja arranques parciales.
        for role, user, _ in roles(c):
            actor(user, ['bash', ROOT/'instalacion/scripts/claude-capacidad.sh'], diagnostic='Claude no acreditado: '+role)
            actor(user, ['bash', ROOT/'instalacion/scripts/modelos-rol.sh', '--resolver'], diagnostic='resolver modelos: '+role,
                  relay_errors=True)
        for role, user, session in roles(c):
            home = user_home(user)
            workdir = role_clone(c, role)
            require(actor(user, ['bash', ROOT/'instalacion/scripts/modelos-rol.sh', '--modelo', role],
                    diagnostic='registro modelos no legible: '+role, relay_errors=True).strip(),
                    'registro modelos vacío: '+role)
            existing = execute(['sudo', '-n', '-H', '-u', user, 'tmux', 'has-session', '-t', session],
                                      stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
            if not existing:
                cmd = shlex.join(['bash', str(ROOT/'instalacion/scripts/iniciar-actor.sh'), role,
                                  str(home/c['project']/'.env.local' if role != 'CEO' else c['env']),
                                  str(c['bus']), str(c['manifest'])])
                actor(user, ['tmux', 'new-session', '-d', '-s', session, '-c', workdir, cmd])
            actor(user, ['tmux', 'set-option', '-t', session, 'alternate-screen', 'off'])
    else:
        print('Crear bus compartido '+str(c['bus'])+' modo 0660 grupo '+group+'; no truncar.')
        print('Crear cursores de CEO/C1/M1 con bus-leer, estado propio 0700; conservar cron ajeno.')
        print('Añadir CRON con tablas-cron.sh y cron-tablas.sh, sin contenido del bus en salida.')
        if plan:
            return
        check_bus_states(c)
        # Preparar todos los estados antes de sellar o leer el bus al reanudar F6.
        for _, user, _ in roles(c):
            role_directory(user_home(user), user_home(user)/'.local/state/talent-ceo', user)
        require(c['bus'].parent.is_dir(), 'directorio del bus ausente')
        require(not c['bus'].is_symlink(), 'bus enlazado')
        import grp
        gid = grp.getgrnam(group).gr_gid
        if not c['bus'].exists():
            c['bus'].touch(mode=0o660)
        regular(c['bus'])
        os.chown(c['bus'], pwd.getpwnam(a['usuario_ceo']).pw_uid, gid)
        c['bus'].chmod(0o660)
        lockfile = c['bus'].with_name('bus.lock')
        require(not lockfile.is_symlink(), 'bus lock enlazado')
        if not lockfile.exists():
            lockfile.touch(mode=0o660)
        regular(lockfile)
        os.chown(lockfile, pwd.getpwnam(a['usuario_ceo']).pw_uid, gid)
        lockfile.chmod(0o660)
        # Traversal del directorio del bus: grupo dedicado, secretos siguen en 0600.
        os.chown(c['bus'].parent, pwd.getpwnam(a['usuario_ceo']).pw_uid, gid)
        c['bus'].parent.chmod(0o710)
        if c['bus'].stat().st_size == 0:
            actor(a['usuario_ceo'], ['env', 'TA_BUS_STATE_DIR='+declared_bus_state(c, 'CEO'), 'TA_BUS='+str(c['bus']),
                                    'TA_BUS_LOCK='+str(lockfile), 'bash',
                                    c['clon']/'.claude/skills/talent-ceo/scripts/bus-sellar.sh',
                                    '--rol', 'CEO', '--marcador', 'MONTAJE-F6'])
        for role, user, _ in roles(c):
            actor(user, ['env', 'TA_BUS_STATE_DIR='+str(user_home(user)/'.local/state/talent-ceo'), 'TA_BUS='+str(c['bus']), 'TA_BUS_LOCK='+str(lockfile), 'bash',
                         c['clon']/'.claude/skills/talent-ceo/scripts/bus-leer.sh', '--lector', role])
            if role != 'CEO':
                # El doctor comprueba los cursores del observador local (CEO), no los homes ajenos.
                # Mantener además los cursores propios del actor; no copiar ni falsificar posiciones.
                actor(a['usuario_ceo'], ['env', 'TA_BUS_STATE_DIR='+declared_bus_state(c, 'CEO'), 'TA_BUS='+str(c['bus']),
                                        'TA_BUS_LOCK='+str(lockfile), 'bash',
                                        c['clon']/'.claude/skills/talent-ceo/scripts/bus-leer.sh', '--lector', role])
            for line in model_cron(c, role, user):
                install_cron(user, line)
        command = shlex.join(['env', 'TA_BUS_STATE_DIR='+declared_bus_state(c, 'CEO'), 'TA_BUS='+str(c['bus']),
                              'bash', str(ROOT/'instalacion/scripts/cron-tablas.sh'), 'CRON'])
        line = run(['bash', c['clon']/'.claude/skills/talent-ceo/scripts/tablas-cron.sh', '--crontab', 'CRON',
                    '--comando', command], env=runtime(c)).strip()
        install_cron(a['usuario_ceo'], line)


def install_cron(user, line):
    p = execute(['sudo', '-n', '-H', '-u', user, 'crontab', '-l'],
                           text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    require(p.returncode == 0 or (p.returncode == 1 and 'no crontab' in p.stderr.lower()),
                'cron no legible; '+command_context(['sudo', '-u', user, 'crontab', '-l']))
    lines = p.stdout.splitlines()
    if line not in lines:
        lines.append(line)
        p = execute(['sudo', '-n', '-H', '-u', user, 'crontab', '-'],
                               input='\n'.join(lines)+'\n', text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        require(p.returncode == 0, 'instalación cron fallida; '+command_context(['sudo', '-u', user, 'crontab', '-']))


def record_handoff(c, args):
    with lock():
        return record_handoff_attempt(c, args)


def record_handoff_attempt(c, args):
    require(len(args) == 2 and re.fullmatch(r'[1-9][0-9]*', args[0]) and
            re.fullmatch(re.escape(c['answers']['linear_clave'])+r'-[1-9][0-9]*', args[1]),
            'uso f8-handoff PR ISSUE', 2)
    pr_number, issue = int(args[0]), args[1]
    slug = c['answers']['repo_url'].removesuffix('.git').split('github.com/')[1]
    pr = json.loads(run(['gh', 'pr', 'view', str(pr_number), '--repo', slug,
                         '--json', 'state,isDraft,headRefOid,body']))
    require(pr.get('state') == 'OPEN' and pr.get('isDraft') is True and
            re.fullmatch(r'[0-9a-f]{40}', pr.get('headRefOid', '')) and
            re.search(r'(?i)\b(?:closes|fixes|resolves)\s+'+re.escape(issue)+r'\b', pr.get('body', '')),
            'handoff: PR debe estar en borrador y ligar la issue')
    try:
        result = subprocess.run(['bash', str(c['clon']/'scripts/verify-handoff.sh'), str(pr_number)],
                                cwd=c['clon'], text=True, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=120)
        rc, output = result.returncode, result.stdout
    except subprocess.TimeoutExpired as exc:
        rc = 124
        output = exc.stdout or ''
        if isinstance(output, bytes):
            output = output.decode(errors='replace')
        output += '\nVerificación interrumpida por timeout.\n'
    except OSError:
        rc, output = 127, 'Verificador no ejecutable.\n'
    try:
        after = json.loads(run(['gh', 'pr', 'view', str(pr_number), '--repo', slug,
                               '--json', 'state,isDraft,headRefOid,body']))
        stable = after == pr
    except (Error, ValueError):
        stable = False
    safe_dir(STATE)
    directory = STATE/'humo'
    safe_dir(directory)
    prefix = 'handoff-'+issue+'-pr'+str(pr_number)+'-'+pr['headRefOid']+'-'
    ordinal = 1
    while any(directory.glob(prefix+str(ordinal)+'.*')):
        ordinal += 1
    raw = directory/(prefix+str(ordinal)+'.log')
    record = directory/(prefix+str(ordinal)+'.json')
    write(raw, issue+' PR '+str(pr_number)+' head '+pr['headRefOid']+'\n'+output)
    write(record, json.dumps(dict(issue=issue, pr=pr_number, head=pr['headRefOid'],
        resultado='PASS' if rc == 0 and stable else 'FAIL', autor=getpass.getuser(),
        comando='verify-handoff.sh', rc=rc, estado_pr='DRAFT', pr_estable=stable,
        artefacto=str(raw), sha256=hashlib.sha256(raw.read_bytes()).hexdigest()), indent=2)+'\n')
    print('handoff conservado: '+str(record)+' rc='+str(rc))
    require(stable, 'handoff: PR cambió o no pudo releerse; intento conservado, verificar de nuevo en borrador')
    require(rc == 0, 'handoff: verificador rojo; conservar salida y corregir; '+
            command_context(['bash', c['clon']/'scripts/verify-handoff.sh', pr_number], c['clon']))
    return record


def selected_handoff(issue, pr, head):
    prefix = 'handoff-'+issue+'-pr'+str(pr)+'-'+head+'-'
    candidates = []
    for path in (STATE/'humo').glob(prefix+'*.json'):
        ordinal = path.stem.removeprefix(prefix)
        require(re.fullmatch(r'[1-9][0-9]*', ordinal), 'humo: ordinal de handoff inválido')
        record = json.loads(regular(path, True).read_text())
        if record.get('resultado') == 'PASS' and record.get('rc') == 0:
            require(type(record.get('rc')) is int and record.get('issue') == issue and
                    type(record.get('pr')) is int and record.get('pr') == pr and record.get('head') == head and
                    record.get('estado_pr') == 'DRAFT' and record.get('pr_estable') is True and
                    record.get('comando') == 'verify-handoff.sh',
                    'humo: intento verde sin binding de borrador')
            candidates.append((int(ordinal), path))
    require(candidates, 'humo: no hay intento verde de handoff para el head fusionado')
    return max(candidates)[1]


def smoke(c):
    d = STATE/'humo'
    captures = STATE/'pane'
    dirs = list(captures.glob('*_*'))
    require(dirs, 'humo: capturas reales ausentes')
    names = ('idle', 'busy', 'done', 'modal', 'redraw')
    for directory in dirs:
        for synthetic in (ROOT/'skills/talent-channel-operation/tests/fixtures/pane').glob('synthetic_*'):
            require(not all((directory/(n+'.txt')).is_file() and
                            (directory/(n+'.txt')).read_bytes() == (synthetic/(n+'.txt')).read_bytes()
                            for n in names if n != 'done'), 'humo: capturas sintéticas del paquete')
    agents = pairs(c['home']/'.config/talent-channel-operation/agents.conf', quoted=True, exports=True)
    calibrated = set(agents.get('TCO_PANE_CALIBRATED', '').split('|'))
    required = set()
    for channel in channels(c):
        for cli in ('claude', 'codex') if c['answers']['codex'] == 'si' else ('claude',):
            version = actor(c['answers']['usuario_incus'], ['incus', 'exec', channel, '--', 'su', '-',
                            c['answers']['cuser'], '-c', cli+' --version'],
                            diagnostic='humo: versión instalada no verificable '+cli+' en '+channel)
            match = re.search(r'\d+\.\d+\.\d+', version)
            require(match, 'humo: versión instalada no verificable '+cli)
            required.add(cli+':'+match[0])
    observed = {p.name.replace('_', ':', 1) for p in dirs}
    require(required <= calibrated and required <= observed, 'humo: registro/versiones/capturas no coinciden')
    for directory in dirs:
        require(re.fullmatch(r'(claude|codex)_[0-9]+\.[0-9]+\.[0-9]+', directory.name), 'humo: versión de captura inválida')
        run(['bash', ROOT/'instalacion/scripts/calibrar-pane.sh', c['clon'], directory],
            diagnostic='humo: clasificación de capturas no verificable '+directory.name)
    data = json.loads(regular(d/'ciclo.json').read_text())
    require(set(data) == {'issue', 'pr', 'head', 'merge', 'etapas'}, 'humo: esquema incompleto')
    require(re.fullmatch(re.escape(c['answers']['linear_clave'])+r'-[1-9][0-9]*', data['issue']), 'humo: issue inválida')
    require(type(data['pr']) is int and data['pr'] > 0 and re.fullmatch(r'[0-9a-f]{40}', data['head']), 'humo: PR/head inválidos')
    chosen_handoff = selected_handoff(data['issue'], data['pr'], data['head'])
    expected = ['issue', 'plan-gate', 'codigo', 'auditoria', 'handoff', 'merge', 'Done']
    require(isinstance(data['etapas'], list) and [s.get('etapa') for s in data['etapas']] == expected,
            'humo: tramo sin evidencia')
    outcomes = dict(zip(expected, ('CREADA', 'GO', 'DOCS', 'GO', 'PASS', 'MERGED', 'Done')))
    for row in data['etapas']:
        require(set(row) == {'etapa', 'archivo', 'sha256'}, 'humo: recibo incompleto')
        name = row['archivo']
        require(re.fullmatch(r'[A-Za-z0-9_.-]+', name) and HEX.fullmatch(row['sha256']), 'humo: ruta/digest inválidos')
        p = regular(d/name)
        require(p.stat().st_size > 0 and hashlib.sha256(p.read_bytes()).hexdigest() == row['sha256'],
                'humo: evidencia vacía o hash distinto '+row['etapa'])
        receipt = json.loads(p.read_text())
        require(receipt.get('issue') == data['issue'] and receipt.get('head') == data['head'] and
                receipt.get('pr') == data['pr'] and
                receipt.get('resultado') == outcomes[row['etapa']], 'humo: resultado/head no acreditado '+row['etapa'])
        require(receipt.get('evidencia') and isinstance(receipt['evidencia'], str),
                'humo: procedencia ausente '+row['etapa'])
        original = Path(receipt['evidencia'])
        require(original.is_absolute() and original.is_relative_to(d) and '..' not in original.parts and
                not any(path.is_symlink() for path in (original, *original.parents)),
                'humo: original debe ser copia regular bajo humo '+row['etapa'])
        source = regular(original)
        require(source.stat().st_size > 0, 'humo: original vacío '+row['etapa'])
        evidence = json.loads(source.read_text())
        require(evidence.get('issue') == data['issue'] and evidence.get('pr') == data['pr'] and
                evidence.get('head') == data['head'] and evidence.get('resultado') == outcomes[row['etapa']] and
                isinstance(evidence.get('autor'), str) and evidence['autor'].strip(),
                'humo: original sin binding/aprobación '+row['etapa'])
        raw_path = Path(evidence.get('artefacto', ''))
        require(raw_path.is_absolute() and raw_path.is_relative_to(d) and '..' not in raw_path.parts and
                not any(path.is_symlink() for path in (raw_path, *raw_path.parents)),
                'humo: artefacto original debe ser copia regular bajo humo '+row['etapa'])
        raw = regular(raw_path)
        require(raw.stat().st_size > 0 and hashlib.sha256(raw.read_bytes()).hexdigest() == evidence.get('sha256'),
                'humo: artefacto original vacío/hash distinto '+row['etapa'])
        from originales import validate
        try:
            require(row['etapa'] == 'handoff' or isinstance(evidence.get('auxiliares'), dict), 'auxiliares sin sello')
            validate(raw.read_text(), row['etapa'], data['issue'], data['head'], data['pr'],
                     evidence.get('auxiliares', {}) if row['etapa'] == 'handoff' else evidence['auxiliares'], data['merge'])
        except Error as exc:
            raise Error('humo: etapa '+row['etapa']+' fichero '+str(raw)+': '+str(exc)) from None
        if row['etapa'] == 'handoff':
            require(original == chosen_handoff and evidence.get('comando') == 'verify-handoff.sh' and evidence.get('rc') == 0 and
                    evidence.get('estado_pr') == 'DRAFT',
                    'humo: resultado verify-handoff ausente')
    # Contrasta merge real, contenido limitado a docs y estado Done de la issue.
    slug = c['answers']['repo_url'].removesuffix('.git').split('github.com/')[1]
    pr = json.loads(run(['gh', 'pr', 'view', str(data['pr']), '--repo', slug, '--json',
                         'state,headRefOid,mergeCommit,files,statusCheckRollup,body'], diagnostic='consulta gh o datos ilegibles: PR'))
    require(pr['state'] == 'MERGED' and pr['headRefOid'] == data['head'] and
            pr['mergeCommit']['oid'] == data['merge'], 'humo: merge/head sin confirmar')
    require(len(pr['files']) == 1 and pr['files'][0]['path'].startswith('docs/') and
            pr['files'][0]['path'].endswith('.md'), 'humo: debe cambiar un fichero de docs')
    statuses = pr.get('statusCheckRollup') or []
    require(any(x.get('name', x.get('context')) == 'local-gates' and
                x.get('conclusion', x.get('state')) in ('SUCCESS', 'SUCCESSFUL') for x in statuses),
            'humo: gates remotos ausentes o rojos')
    for status in statuses:
        name = status.get('name', status.get('context'))
        if name != 'local-gates':
            print('aviso check ajeno: '+str(name)+' estado='+str(status.get('conclusion') or status.get('state') or status.get('status')))
    require(re.search(r'(?i)\b(?:closes|fixes|resolves)\s+'+re.escape(data['issue'])+r'\b', pr.get('body', '')),
            'humo: PR no liga la issue')
    # Consulta el status sobre el head fusionado, no un status verde de otro commit.
    current = json.loads(run(['gh', 'api', 'repos/'+slug+'/commits/'+data['head']+'/status'],
                             diagnostic='consulta gh o datos ilegibles: status'))
    require(any(x.get('context') == 'local-gates' and x.get('state') == 'success' and
                current.get('sha') == data['head'] for x in current.get('statuses', [])),
            'humo: local-gates no acreditado sobre head')
    # Consulta Linear en vivo: cabecera 0600 en el escrow, nunca token en argv.
    token = secret_values(c).get('LINEAR_API_KEY')
    require(token and not any(x in token for x in '\r\n'), 'humo: token Linear missing')
    fd, header = tempfile.mkstemp(dir=c['escrow'])
    os.close(fd)
    try:
        write(Path(header), 'Authorization: '+token+'\n')
        query = 'query($id:String!){issue(id:$id){identifier state{name}}}'
        body = run(['curl', '--fail', '--silent', '--show-error', '--max-time', '30',
                    '--header', '@'+header, '--header', 'Content-Type: application/json',
                    '--data', json.dumps({'query':query, 'variables':{'id':data['issue']}}),
                    'https://api.linear.app/graphql'], diagnostic='humo: Done sin evidencia Linear')
        done = json.loads(body)
    finally:
        Path(header).unlink(missing_ok=True)
    issue = done.get('data', {}).get('issue', {})
    require(issue.get('identifier') == data['issue'] and issue.get('state', {}).get('name') == 'Done',
            'humo: Done sin evidencia Linear')


def prepare(args):
    require(os.getuid() != 0 and pwd.getpwuid(os.getuid()).pw_name != 'root', ROOT_HELP, 2)
    p = argparse.ArgumentParser()
    p.add_argument('--respuestas', required=True)
    p.add_argument('--home', required=True)
    p.add_argument('--clon', required=True)
    ns = p.parse_args(args)
    answers = pairs(Path(ns.respuestas))
    require(answers.get('repo_rama') == 'main', MAIN_HELP, 2)
    require(Path(ns.clon).name == answers['repo_url'].removesuffix('.git').rstrip('/').split('/')[-1],
            'nombre del clon distinto del repositorio; use una ruta terminada en '+
            answers['repo_url'].removesuffix('.git').rstrip('/').split('/')[-1], 2)
    for value in vars(ns).values():
        require(re.fullmatch(r'/[A-Za-z0-9_./-]+', value) and '..' not in Path(value).parts, 'ruta absoluta requerida', 2)
    with lock():
        rows, _, _, _ = history()
        text = ''.join(k+'='+v+'\n' for k, v in vars(ns).items())
        dest = STATE/'contexto.conf'
        if dest.exists():
            require(dest.read_text() == text or not rows, 'contexto sellado: no cambiar durante montaje', 2)
        write(dest, text)
    print('contexto preparado; pendiente F0')


def lint_commands(text, name):
    # Inspección estática sin ejecución: sintaxis del bloque completo con bash -n.
    # Los envoltorios se contrastan por ruta/modo; F5–F8 ensayan también los
    # argumentos de skills con los parsers reales, sin ejecutar sus acciones.
    modes = {
        'estado': {'siguiente', 'verificar', 'avanzar', 'reabrir', 'stop'},
        'preparar': {'--respuestas'}, 'verificar-nucleo': {'--en'},
        'manifiesto-nucleo': {'--generar'}, 'f1-credenciales': {''},
        'f2-provision': {'--plan', '--ejecutar', '--verificar', '--plan-recuperar', '--recuperar'},
        'f3-canales': {'--plan', '--ejecutar'}, 'f4-onboarding': {'', '--plan', '--aceptar-canon'},
        'f3-acreditar': {'--leer', '--plan', '--ejecutar'}, 'f3-coderabbit': {'--plan', '--ejecutar'},
        'f4-proteccion': {'--plan', '--ejecutar'},
        'f5-torres': {'--plan', '--ejecutar', '--plan-usuarios', '--usuarios'},
        'f6-bus': {'--plan', '--ejecutar'}, 'cron-tablas': {'CRON'},
        'f8-importar': {'', '--repetir-capturas'}, 'f8-handoff': {'$PR'}, 'f8-recibo': set(('issue', 'plan-gate', 'codigo', 'auditoria', 'handoff', 'merge', 'Done')),
        'f8-encargos': {'$ISSUE'}, 'f8-originales': {'$ISSUE'}, 'f8-conservar': {'$ISSUE'},
        'f8-capturas': {'$CLON'}, 'calibrar-pane': {'$CLON'},
        'f8-ciclo': {''}, 'recolectar': {'$FASE', *('F'+str(n) for n in range(9))},
        'f0-bateria': {''},
        'capturar-done': {'$CLON'},
    }
    for block in re.findall(r'```(?:bash|sh)\n(.*?)```', text, re.S):
        syntax = execute(['bash', '-n'], input=block, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        require(syntax.returncode == 0, 'markdown: sintaxis bash inválida '+name)
        for line in block.replace('\\\n', ' ').splitlines():
            # También extrae bash dentro de una sustitución de comando.
            for match in re.finditer(r'\bbash\s+((?:"[^"\n]*"|[^\s]+))(.*)', line):
                try:
                    tail = match[2]
                    if tail.endswith(')"'):
                        tail = tail[:-2]
                    words = shlex.split(match[1]+tail)
                except ValueError:
                    raise Error('markdown: comando sin comillas válidas '+name) from None
                cited = words[0]
                rel = cited.removeprefix('$PKG/').removeprefix('$CLON/').removeprefix('.claude/')
                if cited.startswith('$S/'):
                    rel = 'skills/talent-ceo/scripts/'+cited[3:]
                rel = rel.replace('$FASE', 'F0')
                # draft-handoff del producto se genera desde esta plantilla.
                path = ROOT/rel
                if rel == 'scripts/draft-handoff.sh':
                    path = ROOT/'instalacion/plantillas/producto/draft-handoff.sh.tmpl'
                require(not Path(rel).is_absolute() and path.is_file(),
                        'markdown: script citado inexistente '+name+': '+cited)
                if rel.startswith('instalacion/scripts/'):
                    stem = Path(rel).stem
                    mode = words[1] if len(words) > 1 and words[1] not in ('|', '&&', ';') else ''
                    allowed = {''} if re.fullmatch(r'check-F[0-8]', stem) else modes.get(stem)
                    require(allowed is not None and mode in allowed,
                            'markdown: modo desconocido '+name+': '+stem+' '+mode)
    if re.fullmatch(r'F[5-8]\.md', name):
        from guias import check_blocks
        check_blocks(text, name)


def lint(args):
    require(args, 'lint: faltan documentos', 2)
    for name in args:
        p = regular(Path(name))
        text = p.read_text()
        require(text.strip() and text.count('```') % 2 == 0, 'markdown vacío o bloque sin cerrar: '+p.name)
        require(not re.search(r'(?m)[ \t]+$', text), 'markdown: espacios finales '+p.name)
        require(not re.search(r'(?i)PENDIENTE-|TODO\b|<comando>', text), 'markdown: marcador '+p.name)
        lint_commands(text, p.name)
        if re.fullmatch(r'F[0-8]\.md', p.name):
            for heading in ('Objetivo', 'Precondiciones', 'Pasos', 'Comprobación', 'Remediación', 'Al terminar'):
                require('## '+heading in text, 'markdown: falta '+heading+' en '+p.name)
            cases = json.loads(regular(ROOT/'tests/remediaciones.json').read_text())
            keys = [(case['fase'], case['fila']) for case in cases]
            require(len(keys) == len(set(keys)) and all(case['textos'] for case in cases),
                    'markdown: registro de remediaciones inválido')
            table = text.split('## Remediación', 1)[1].split('## Al terminar', 1)[0]
            for line in table.splitlines():
                if line.startswith('| ') and not line.startswith(('| Diagnóstico', '| Categoría')):
                    row = line.split('|')[1].strip()
                    require((p.stem, row) in keys, 'markdown: fila sin caso '+p.stem+': '+row)
                    case = next(item for item in cases if (item['fase'], item['fila']) == (p.stem, row))
                    require(('AVISO:' in line) == case['verde'], 'markdown: clase aviso/fallo distinta '+p.stem+': '+row)
    print('lint-md: verde '+str(len(args))+' documentos')


def inventory():
    c = config()
    result = {'proyecto': c['project'], 'actores': [], 'contenedores': [], 'piezas': {}}
    for name, path in (('bus', c['bus']), ('env', c['env']), ('perfil', c['profile']), ('manifiesto', c['manifest'])):
        if path.is_file() and not path.is_symlink():
            result['piezas'][name] = {'present': True, 'modo': oct(stat.S_IMODE(path.stat().st_mode)),
                                      'bytes': path.stat().st_size}
        else:
            result['piezas'][name] = {'present': False}
    for role, user, session in roles(c):
        row = {'rol': role, 'usuario': user, 'sesion': session}
        try:
            pids = actor(user, ['tmux', 'list-panes', '-t', '='+session+':', '-F', '#{pane_pid}']).splitlines()
            require(pids and all(p.isdigit() for p in pids), 'PID no verificable')
            row['pane_pid'] = pids
            row['consulta'] = 'present'
            cron = actor(user, ['crontab', '-l'])
            row['cron_entradas'] = sum(1 for line in cron.splitlines() if line and not line.startswith('#'))
        except Error:
            row['consulta'] = 'NOVERIF'
        result['actores'].append(row)
    try:
        rows = actor(c['answers']['usuario_incus'], ['incus', 'list', '-c', 'ns', '-f', 'csv'])
        wanted = set(channels(c)+['runner-'+c['project'], 'golden-'+c['project']])
        for line in rows.splitlines():
            fields = line.split(',')
            if len(fields) == 2 and fields[0] in wanted and fields[1] in ('RUNNING', 'STOPPED', 'FROZEN'):
                result['contenedores'].append({'nombre':fields[0], 'estado':fields[1]})
    except Error:
        result['contenedores'] = ['NOVERIF']
    print(json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2))


def main():
    require(len(sys.argv) >= 2, 'falta comando', 2)
    op, args = sys.argv[1], sys.argv[2:]
    if op == 'estado':
        state(args)
    elif op == 'preparar':
        prepare(args)
    elif op == 'check':
        require(len(args) == 1, 'uso check', 2)
        check(args[0])
    elif op == 'manifiesto-nucleo':
        require(args == ['--generar'], 'uso manifiesto-nucleo --generar', 2)
        core_generate()
    elif op == 'verificar-nucleo':
        require(len(args) == 2 and args[0] == '--en', 'uso verificar-nucleo --en host|ruta|contenedor', 2)
        if args[1] == 'host':
            core_verify(ROOT)
        elif Path(args[1]).is_absolute():
            core_verify(Path(args[1]))
        else:
            require(re.fullmatch(r'[a-z0-9-]+', args[1]), 'contenedor inválido', 2)
            container_core(config(), args[1])
        print('núcleo íntegro')
    elif op == 'lint-md':
        lint(args)
    elif op == 'inventario':
        require(not args, 'uso inventario', 2)
        inventory()
    elif op == 'f1-credenciales':
        require(not args, 'uso f1-credenciales sin argumentos', 2)
        credentials(config())
    elif op == 'iniciar-actor':
        start_actor(args)
    elif op in ('f8-recibo', 'f8-ciclo'):
        from recibos import receipt, cycle
        (receipt if op == 'f8-recibo' else cycle)(config(), args)
    elif op in ('f8-encargos', 'f8-originales'):
        from f8 import assignments, originals
        (assignments if op == 'f8-encargos' else originals)(config(), args)
    elif op == 'f2-provision':
        require(len(args) == 1, 'uso f2-provision --plan|--ejecutar|--verificar', 2)
        provision(config(), args[0])
    elif op == 'estacion-plan':
        require(not args, 'uso estacion-plan sin argumentos', 2)
        settings = read_station(station_file(Path.home()))
        head = run(['git', '-C', settings['TF_CLONE'], 'rev-parse', 'HEAD'], diagnostic='estación head no verificable').strip()
        env = os.environ.copy()
        env.update(settings)
        run(['bash', ROOT/'scripts/seal-suite.sh', '--plan', '1', head, head, 'montaje-plan'], env=env,
            capture=False, diagnostic='seal-suite plan no resuelve estación/runner')
    elif op == 'f3-canales':
        require(len(args) == 1 and args[0] in ('--plan', '--ejecutar'), 'uso --plan|--ejecutar', 2)
        channel_env(config(), args[0] == '--plan')
    elif op == 'f3-acreditar':
        require(len(args) == 1 and args[0] in ('--leer', '--plan', '--ejecutar'), 'uso --leer|--plan|--ejecutar', 2)
        from acreditacion import read_tokens, install_tokens
        c = config()
        if args[0] == '--leer':
            read_tokens(c)
        else:
            install_tokens(c, args[0] == '--plan')
    elif op == 'f3-coderabbit':
        require(len(args) == 1 and args[0] in ('--plan', '--ejecutar'), 'uso --plan|--ejecutar', 2)
        from acreditacion import coderabbit
        coderabbit(config(), args[0] == '--plan')
    elif op == 'f4-onboarding':
        parser = argparse.ArgumentParser()
        parser.add_argument('--plan', action='store_true')
        parser.add_argument('--aceptar-canon', action='append', default=[])
        ns = parser.parse_args(args)
        onboarding(config(), ns.plan, ns.aceptar_canon)
    elif op == 'f8-handoff':
        record_handoff(config(), args)
    elif op == 'f0-bateria':
        require(not args, 'uso f0-bateria sin argumentos', 2)
        battery_run()
    elif op == 'cron-tablas':
        require(args == ['CRON'], 'uso cron-tablas CRON', 2)
        c = config()
        base = c['clon']/'.claude/skills/talent-ceo/scripts'
        rows = ['ACTORES\tSESION\tCTX']
        for role, user, session in roles(c):
            pane = actor(user, ['tmux', 'capture-pane', '-p', '-t', session])
            ctx = re.search(r'ctx:\s*(\d+)%', pane)
            require(ctx, 'tabla: ctx no verificable '+role)
            rows.append(role+'\t'+session+'\t'+ctx[1]+'%')
        rows.append('CONTENEDORES\tESTADO')
        out = actor(c['answers']['usuario_incus'], ['incus', 'list', '-c', 'ns', '-f', 'csv'])
        observed = dict(line.split(',', 1) for line in out.splitlines() if ',' in line)
        for container in channels(c)+['runner-'+c['project']]:
            require(container in observed, 'tabla: contenedor ausente '+container)
            rows.append(container+'\t'+observed[container])
        write(STATE/'tablas.tsv', '\n'.join(rows)+'\n')
        print('tablas actualizadas')
    elif op in ('f5-torres', 'f6-bus'):
        require(len(args) == 1 and args[0] in ('--plan', '--ejecutar', '--plan-usuarios', '--usuarios'),
                'uso --plan|--ejecutar|--plan-usuarios|--usuarios', 2)
        require(op == 'f5-torres' or args[0] in ('--plan', '--ejecutar'), 'modo solo para torres', 2)
        infrastructure(config(), op, args[0] in ('--plan', '--plan-usuarios'),
                       args[0] in ('--plan-usuarios', '--usuarios'))
    else:
        raise Error('comando desconocido', 2)


if __name__ == '__main__':
    try:
        main()
    except Error as exc:
        print('falla '+str(exc), file=sys.stderr)
        sys.exit(exc.rc)
    except (OSError, ValueError, KeyError, TypeError):
        # Jamás reproducir una excepción que pueda contener contenido de un secreto.
        print('falla datos ausentes, ilegibles o formato inesperado', file=sys.stderr)
        sys.exit(1)
