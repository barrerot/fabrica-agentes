"""Órdenes reales de modelos; proveedor y transporte confinados a fixtures."""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import shutil
from unittest.mock import patch
from remediaciones import observar


def casos(package, tmp, expect):
    root = tmp/'modelos-reales'
    root.mkdir()
    bindir = root/'bin'
    bindir.mkdir()
    shell = bindir/'bash'
    shell.write_text('#!/bin/bash\nif [ "${1:-}" = -lc ]; then shift; exec /bin/bash -c "$@"; fi\nexec /bin/bash "$@"\n')
    shell.chmod(0o755)
    provider = bindir/'claude'
    provider.write_text('''#!/usr/bin/env bash
if [ "$1" = --version ]; then echo 2.1.289; exit 0; fi
family=''
while [ $# -gt 0 ]; do
  if [ "$1" = --model ]; then family="$2"; shift; fi
  shift
done
[ "${PROVEEDOR_FALLA:-}" != si ] || { echo fallo-proveedor >&2; exit 1; }
printf '{"is_error":false,"subtype":"success","result":"Ready when you are. What would you like to work on?","modelUsage":{"%s-%s-%s":{}}}\\n' claude "$family" "${VERSION_PRUEBA:-6-2-beta}"
''')
    provider.chmod(0o755)
    transport = bindir/'incus'
    transport.write_text('''#!/usr/bin/env bash
shift 2
[ "$1" = -- ] && shift
shift 4
HOME="$CANAL_HOME" bash -c "$1" "${@:2}"
''')
    transport.chmod(0o755)
    tmux = bindir/'tmux'
    tmux.write_text('#!/usr/bin/env bash\nprintf "[%s] ctx: 12%%\\n" "$ETIQUETA_PRUEBA"\n')
    tmux.chmod(0o755)
    spec = importlib.util.spec_from_file_location('montaje_modelos', package/'instalacion/scripts/fases.py')
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    script = package/'instalacion/scripts/modelos-rol.sh'
    skills = package/'skills'
    envbase = dict(os.environ, PATH=str(bindir)+':'+os.environ['PATH'])
    environments = {}
    for role in ('CEO', 'C1', 'M1'):
        home = root/role.lower()
        (home/'.claude').mkdir(parents=True)
        (home/'.claude/.credentials.json').write_text('{}')
        (home/'.claude/.credentials.json').chmod(0o600)
        (home/'operacional').write_text('GITHUB_TOKEN=sintetico\nLINEAR_API_KEY=sintetica\nCODERABBIT_API_KEY=sintetica\n')
        (home/'operacional').chmod(0o600)
        (home/'.config/talent-factory').mkdir(parents=True)
        (home/'.config/talent-factory/runtime.conf').write_text('export TA_BUS_STATE_DIR='+str(home/'.local/state/talent-ceo')+'\n'
            'export TA_BUS='+str(root/'bus')+'\nexport TA_BUS_LOCK='+str(root/'bus.lock')+'\n')
        (home/'.config/talent-factory/station.conf').write_text(
            'TF_STATION_HOST=host-example\nTF_CLONE=/srv/producto\nTF_MANIFEST=/srv/instancia.conf\n'
            'TF_SLUG=org-example/producto\nTF_RUNNER_USER=runner\nTF_RUNNER_REPO=/home/runner/repo\nTF_RUNNERS=runner-ejemplo\n')
        env = dict(envbase, HOME=str(home))
        environments[role] = env
        result = subprocess.run(['bash', str(script), '--resolver'], env=env, capture_output=True, text=True)
        expect('registro real resuelto por usuario '+role, result.returncode == 0 and
               (home/'.config/talent-channel-operation/modelos.conf').stat().st_mode & 0o777 == 0o600)
        expected = '-'.join(('claude', 'opus' if role == 'CEO' else 'sonnet', '6-2-beta'))
        executions = []
        with patch.dict(os.environ, env, clear=True), patch.object(mod.Path, 'home', lambda: home), \
                patch.object(mod.os, 'execvpe', lambda *args: executions.append(args)):
            mod.start_actor([role, str(home/'operacional'), str(root/'bus'), str(root/'manifest')])
        expect('torre consume ID completo del usuario '+role, executions[0][1][-2:] == ['--model', expected])
        result = subprocess.run(['bash', str(script), '--verificar', role, role.lower()],
                                env=dict(env, ETIQUETA_PRUEBA=('Opus' if role == 'CEO' else 'Sonnet')+' 6.2'),
                                capture_output=True, text=True)
        expect('torre real vigente acreditada '+role, result.returncode == 0)
    home = Path(environments['C1']['HOME'])
    registry = home/'.config/talent-channel-operation/modelos.conf'
    saved = registry.read_bytes()
    registry.unlink()
    executions = []
    with patch.dict(os.environ, environments['C1'], clear=True), patch.object(mod.Path, 'home', lambda: home), \
            patch.object(mod.os, 'execvpe', lambda *args: executions.append(args)):
        try:
            mod.start_actor(['C1', str(home/'operacional'), str(root/'bus'), str(root/'manifest')])
            failed = False
        except mod.Error as exc:
            failed = True
            observar('F5', exc.rc, str(exc))
    expect('registro retirado antes de lanzar cierra sin CLI ni modelo vacío', failed and not executions)
    registry.write_bytes(saved)
    result = subprocess.run(['bash', str(script), '--resolver'], env=dict(environments['C1'], PROVEEDOR_FALLA='si'),
                            capture_output=True, text=True)
    expect('resolución fallida conserva registro y causa del resolutor', result.returncode == 1 and
           'ERROR resolviendo' in result.stderr and registry.read_bytes() == saved)
    observar('F5', result.returncode, result.stderr)
    channel = root/'canal'
    channel.mkdir()
    result = subprocess.run(['bash', str(skills/'talent-channel-operation/scripts/preparar-modelo-canal.sh'),
                             'canal-example', 'operador'], env=dict(environments['C1'], CANAL_HOME=str(channel)),
                            capture_output=True, text=True)
    expect('preparación real del canal usa registro de coordinador', result.returncode == 0 and
           json.loads((channel/'.claude/settings.json').read_text())['model'] == '-'.join(('claude', 'sonnet', '6-2-beta')))
    # Cron real ejecutado sin flota; el bus y su perfil son fixtures, no servicios.
    home = Path(environments['M1']['HOME'])
    (home/'.config/talent-channel-operation/agents.conf').write_text('TCO_DEV_CARRILES=""\nTCO_AUDIT_CARRILES=""\n')
    bus = root/'bus'
    bus.touch()
    profile = root/'perfil.tsv'
    profile.write_text('tipo\tid\tmaquina\tcontenedor\tsesion\tatributos\n'
        'maquina\thost\t-\t-\t-\tacceso=local\nceo\tCEO\thost\t-\tninguna\troles=ceo\n'
        'bus\tbus\thost\t-\t-\tpath='+str(bus)+';lectores=CEO\n')
    manifest = root/'instancia.conf'
    manifest.write_text('TF_PROJECT="example"\nTF_REPO_URL="https://example.invalid/org/producto"\n')
    env = dict(environments['M1'], TA_ROL='CEO', TA_BUS=str(bus), TA_PERFIL=str(profile),
               TA_BUS_STATE_DIR=str(home/'.local/state/talent-ceo'), HOST_HOME=str(home),
               TCO_DEV_CARRILES='', TCO_AUDIT_CARRILES='', TCO_REPO_DIR='producto', TCO_REPO_SLUG='org/producto',
               TCO_REPO_STACK='ninguno', TCO_ANEXO_FILE='references/anexo-example.md',
               TCO_HOST_ENV_REL='producto/operacional', TCO_TF_MANIFEST=str(manifest),
               TCO_LINEAR_INPROGRESS_STATE='00000000-0000-4000-8000-000000000001',
               TCO_LINEAR_INREVIEW_STATE='00000000-0000-4000-8000-000000000002')
    cron = subprocess.run(['bash', str(skills/'talent-ceo/scripts/cron-modelos.sh'), '--linea'],
                          env=env, capture_output=True, text=True)
    expect('cron real emite shell y línea semanal', cron.returncode == 0 and cron.stdout.startswith('SHELL=/bin/bash\n17 3 * * 0 '))
    command = cron.stdout.splitlines()[1].split(' ', 5)[5]
    result = subprocess.run(['bash', '-c', command], env=dict(env, VERSION_PRUEBA='6-3-beta'), capture_output=True, text=True)
    expect('orden semanal real actualiza registro', result.returncode == 0 and
           '-'.join(('claude', 'sonnet', '6-3-beta')) in (home/'.config/talent-channel-operation/modelos.conf').read_text())
    doctor = (skills/'talent-ceo/scripts/doctor.sh').read_text()
    function = re.search(r'^check_modelo_actor\(\).*?^}', doctor, re.M | re.S)[0]
    probe = root/'doctor-modelo.sh'
    probe.write_text('''#!/usr/bin/env bash
. "$SKILLS/talent-channel-operation/scripts/lib-modelos.sh"
como() { shift; COMO_RC=0; COMO_OUT="$("$@")" || COMO_RC=$?; }
ok() { echo OK; }; noverif() { printf 'NOVERIF %s\\n' "$1"; exit 1; }; falla() { printf 'FALLA %s\\n' "$1"; exit 1; }
'''+function+'\ncheck_modelo_actor estacion M1 operador "[Sonnet 6.2]"\n')
    result = subprocess.run(['bash', str(probe)], env=dict(env, SKILLS=str(skills)), capture_output=True, text=True)
    expect('doctor real señala torre pendiente tras actualización', result.returncode == 1 and 'FALLA modelo' in result.stdout)
    observar('F7', result.returncode, result.stdout)
    result = subprocess.run(['bash', '-c', '. "$1"; tco_modelos_config; test "$TCO_AUDIT_MODEL_ARGS" = "$2"',
                             '_', str(skills/'talent-channel-operation/scripts/lib-modelos.sh'), '--model modelo-neutral'],
                            env=dict(env, TCO_AUDIT_CLI='codex', TCO_AUDIT_MODEL_ARGS='--model modelo-neutral'),
                            capture_output=True, text=True)
    expect('auditor de otro proveedor conserva argumentos con librería real', result.returncode == 0)
    clone = root/'clon'
    shutil.copytree(skills/'talent-channel-operation', clone/'.claude/skills/talent-channel-operation')
    captures = root/'capturas'
    shutil.copytree(skills/'talent-channel-operation/tests/fixtures/pane/claude_2.1.289', captures)
    result = subprocess.run(['bash', str(package/'instalacion/scripts/calibrar-pane.sh'), str(clone), str(captures)],
                            env=env, capture_output=True, text=True)
    expect('calibración del instalador acredita cinco capturas con clasificador real', result.returncode == 0)
    done = captures/'done.txt'
    saved = done.read_bytes()
    done.unlink()
    result = subprocess.run(['bash', str(package/'instalacion/scripts/calibrar-pane.sh'), str(clone), str(captures)],
                            env=env, capture_output=True, text=True)
    expect('captura done ausente cierra calibración', result.returncode == 1 and 'falla captura ausente: done' in result.stderr)
    if result.returncode != 1:
        print(result.stdout+result.stderr)
    done.write_bytes(saved)
    # Solo dobles del transporte y del proceso del proveedor. Capturador real intacto.
    transport.write_text('''#!/usr/bin/env bash
case "$*" in
  *display-message*) echo 123 ;;
  *'bash -c'*) echo claude ;;
  *'capture-pane'*) cat "$PANE_REAL" ;;
  *'--version'*) echo 2.1.289 ;;
  *) exit 1 ;;
esac
''')
    output = root/'capturas-nuevas'
    result = subprocess.run(['bash', str(package/'instalacion/scripts/capturar-done.sh'), str(clone), '11', 'v:.0'],
                            env=dict(env, TCO_FIXTURE_DIR=str(output), TCO_DEV_CLI='claude', TCO_AUDIT_CLI='codex',
                                     TCO_PANE_CLI_VERSION_CMD='claude --version',
                                     PANE_REAL=str(done)), capture_output=True, text=True)
    expect('captura done reutiliza capturador real y conserva turno terminado', result.returncode == 0 and
           (output/'claude_2.1.289/done.txt').read_bytes() == saved)
    if result.returncode:
        print(result.stdout+result.stderr)
