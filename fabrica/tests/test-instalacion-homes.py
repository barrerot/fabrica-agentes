"""Homes adjudicados en generación, montaje y lectores reales, sin cuentas reales."""
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

package = Path(__file__).resolve().parents[1]
os.umask(0o022)
sys.path.insert(0, str(package/'instalacion/scripts'))
import fases

spec = importlib.util.spec_from_file_location('generador_homes', package/'instalacion/instalacion.py')
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)
answers = dict(line.split('=', 1) for line in
               (package/'instalacion/tests/fixtures/minima.resp').read_text().splitlines())
passed = 0
TOTAL_ESPERADO = 47

def check(condition):
    global passed
    assert condition
    passed += 1

with tempfile.TemporaryDirectory(prefix='homes-roles-') as directory:
    root = Path(directory)
    homes = {answers['usuario_'+role.lower()]: root/'cuentas'/role for role in ('CEO', 'C1', 'M1')}
    def account(user):
        return SimpleNamespace(pw_dir=str(homes[user]), pw_uid=os.getuid(), pw_gid=os.getgid())
    with patch.object(gen.pwd, 'getpwnam', account):
        generated = gen.render(answers, root/'motor', root/'datos')
    profile = root/'ejemplo.perfil.tsv'
    profile.write_text(generated['manifiestos/ejemplo.perfil.tsv'])
    c = dict(answers=answers, project=answers['proyecto'],
             home=root/'datos', profile=profile, clon=root/'producto', bus=root/'bus', manifest=root/'manifest.conf')
    check(fases.runtime(c)['TA_BUS_STATE_DIR'] ==
          str(homes[answers['usuario_ceo']]/'.local/state/talent-ceo'))
    clones = {}
    for role, user, _ in fases.roles(c):
        home = homes[user]
        (home/'.config/talent-factory').mkdir(parents=True)
        state = home/'.local/state/talent-ceo'
        (state/'acreditacion').mkdir(parents=True)
        (state/'acreditacion'/f'{role}.estado').write_text('ACREDITADO\n')
        (home/'.config/talent-factory/runtime.conf').write_text('TA_BUS_STATE_DIR='+str(state)+'\n')
        clone = root/'clones'/role
        (clone/'manifiestos').mkdir(parents=True)
        (clone/'manifiestos'/profile.name).write_bytes(profile.read_bytes())
        clones[role] = clone
        check(fases.declared_bus_state(c, role) == str(state))
        result = subprocess.run(['bash', str(package/'skills/talent-ceo/scripts/leer-acreditacion.sh'), role],
                                env=dict(os.environ, HOME=str(home), TA_BUS_STATE_DIR=fases.declared_bus_state(c, role)),
                                capture_output=True, text=True)
        check(result.returncode == 0 and result.stdout.strip() == 'ACREDITADO')
    def actor(user, argv, **kwargs):
        return subprocess.check_output(list(map(str, argv)), text=True)
    before = profile.read_bytes()
    with patch.object(fases, 'user_home', lambda user: homes[user]), \
            patch.object(fases, 'role_clone', lambda c, role: clones[role]), patch.object(fases, 'actor', actor):
        fases.check_bus_states(c)
        check(profile.read_bytes() == before)
        runtime = homes[answers['usuario_ceo']]/'.config/talent-factory/runtime.conf'
        original_runtime = runtime.read_bytes()
        runtime.write_text('TA_BUS_STATE_DIR=/otro/estado\nGITHUB_TOKEN=valor-sintetico-no-publicar\n')
        try:
            fases.check_bus_states(c)
        except fases.Error as exc:
            check('formato inválido' in str(exc) and 'valor-sintetico-no-publicar' not in str(exc))
        else:
            raise AssertionError('runtime con campos ajenos aceptado')
        runtime.write_bytes(original_runtime)
        for role, user, _ in fases.roles(c):
            runtime = homes[user]/'.config/talent-factory/runtime.conf'
            single = runtime.read_bytes()
            complete = fases.actor_runtime_text(homes[user], c['bus'])
            runtime.write_text(complete)
            fases.check_bus_states(c)
            check(profile.read_bytes() == before)
            for mutation in ('ausente', 'distinto'):
                lines = [line for line in complete.splitlines() if not line.startswith('export TA_BUS=')]
                if mutation == 'distinto':
                    lines.append('export TA_BUS=/ruta/incorrecta')
                runtime.write_text('\n'.join(lines)+'\n')
                try:
                    fases.check_bus_states(c)
                except fases.Error as exc:
                    check('configuración bus distinta: '+role in str(exc))
                else:
                    raise AssertionError('runtime completo incompleto o divergente aceptado')
            runtime.write_bytes(single)
        for role, user, _ in fases.roles(c):
            actual = homes[user]
            for target in ('cuenta', 'runtime', 'clon'):
                runtime = actual/'.config/talent-factory/runtime.conf'
                clone_profile = clones[role]/'manifiestos'/profile.name
                if target == 'cuenta':
                    homes[user] = root/'otro-home'
                elif target == 'runtime':
                    runtime.write_text('TA_BUS_STATE_DIR=/otro/estado\n')
                else:
                    clone_profile.write_text(before.decode().replace(str(actual), '/otro/home'))
                try:
                    fases.check_bus_states(c)
                except fases.Error as exc:
                    message = str(exc)
                    check(role in message and str(actual) in message and
                          ('/otro' in message or str(root/'otro-home') in message) and
                          'generar-instancia.sh' in message)
                    print('rechazo '+target+' '+role+': '+message)
                else:
                    raise AssertionError('divergencia aceptada: '+role+' '+target)
                homes[user] = actual
                runtime.write_text('TA_BUS_STATE_DIR='+str(actual/'.local/state/talent-ceo')+'\n')
                clone_profile.write_bytes(before)
                fases.check_bus_states(c)
                check(profile.read_bytes() == before)
    with patch.object(gen.pwd, 'getpwnam', side_effect=KeyError):
        absent = gen.render(answers, root/'motor', root/'ceo')
    absent_profile = absent['manifiestos/ejemplo.perfil.tsv']
    for role, user, _ in fases.roles(c):
        check('estado_bus=/home/'+user+'/.local/state/talent-ceo' in absent_profile)
    # La creación exige --home-dir incluso si useradd tiene otro default.
    profile.write_text(absent_profile)
    c['home'].mkdir(parents=True, exist_ok=True)
    calls = []
    with patch.object(fases, 'privileged'), patch.object(fases, 'check_bus_states'), \
            patch.object(fases, 'execute', return_value=SimpleNamespace(returncode=1)), \
            patch.object(fases, 'run', lambda argv, **kwargs: calls.append(list(map(str, argv)))), \
            patch.object(fases.pwd, 'getpwnam', account), \
            patch.object(fases.grp, 'getgrnam', return_value=SimpleNamespace(gr_gid=os.getgid())), \
            patch.object(fases.os, 'chown'):
        fases.infrastructure(c, 'f5-torres', False, users_only=True)
    added = [argv for argv in calls if argv[0] == 'useradd']
    check(len(added) == 4 and all(argv[argv.index('--home-dir')+1] == '/home/'+argv[-1] for argv in added))
    for line in (package/'instalacion/tests/invariants.tsv').read_text().splitlines():
        if line.startswith('#'):
            continue
        _, path, pattern = line.split('\t')
        check(re.search(pattern, (package/path).read_text()) is not None)
assert passed == TOTAL_ESPERADO, (passed, TOTAL_ESPERADO)
print(f'homes: PASS={passed} FAIL=0 esperados={TOTAL_ESPERADO}')
