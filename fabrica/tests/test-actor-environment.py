"""El arranque real conserva solo la credencial requerida por Claude."""
import os
from pathlib import Path
import sys
import tempfile
import subprocess
import shutil
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'instalacion/scripts'))
import fases

with tempfile.TemporaryDirectory(prefix='actor-env-') as directory:
    home = Path(directory)
    operational = home/'operacional'
    operational.write_text('GITHUB_TOKEN=git-sintetico\nLINEAR_API_KEY=linear-sintetica\nCODERABBIT_API_KEY=cr-sintetica\n')
    operational.chmod(0o600)
    (home/'.claude').mkdir()
    login = home/'.claude/.credentials.json'
    login.write_text('{}')
    login.chmod(0o600)
    token = home/'.claude_token.env'
    token.write_text('export CLAUDE_CODE_OAUTH_TOKEN=token-sintetico\n')
    token.chmod(0o600)
    configuration = fases.station_file(home)
    configuration.parent.mkdir(parents=True)
    configuration.write_text('TF_STATION_HOST=host-example\nTF_CLONE=/srv/producto\nTF_MANIFEST=/srv/instancia.conf\n'
        'TF_SLUG=org-example/producto\nTF_RUNNER_USER=runner\nTF_RUNNER_REPO=/home/runner/repo\nTF_RUNNERS=runner-ejemplo\n')
    (configuration.parent/'runtime.conf').write_text('export TA_BUS_STATE_DIR='+str(home/'.local/state/talent-ceo')+'\n'
        'export TA_BUS='+str(home/'bus')+'\nexport TA_BUS_LOCK='+str(home/'bus.lock')+'\n')
    bindir = home/'bin'
    bindir.mkdir()
    shutil.copyfile(fases.ROOT/'tests/fixtures/instalacion/cliente.py', bindir/'claude')
    (bindir/'claude').chmod(0o755)
    environment = dict(os.environ, HOME=str(home), PATH=str(bindir)+':'+os.environ['PATH'])
    subprocess.run(['bash', str(fases.ROOT/'instalacion/scripts/modelos-rol.sh'), '--resolver'],
                   env=environment, capture_output=True, check=True)
    executions = []
    with patch.object(fases.Path, 'home', lambda: home), patch.object(fases.os, 'execvpe',
            lambda *args: executions.append(args)), patch.dict(os.environ,
            HOME=str(home), PATH=environment['PATH'], GITHUB_TOKEN='heredado', GH_TOKEN='heredado', LINEAR_API_KEY='heredada',
            CODERABBIT_API_KEY='heredada', CLAUDE_CODE_OAUTH_TOKEN='heredado', SECRETO_AJENO='heredado'):
        for role in ('CEO', 'C1', 'M1'):
            fases.start_actor([role, str(operational), str(home/'bus'), str(home/'manifiesto')])
            environment = executions[-1][2]
            assert {key:environment[key] for key in ('TA_BUS_STATE_DIR', 'TA_BUS', 'TA_BUS_LOCK')} == {
                'TA_BUS_STATE_DIR':str(home/'.local/state/talent-ceo'),
                'TA_BUS':str(home/'bus'), 'TA_BUS_LOCK':str(home/'bus.lock')}
            assert environment.get('CLAUDE_CODE_OAUTH_TOKEN') == 'token-sintetico'
            assert not {'GITHUB_TOKEN', 'GH_TOKEN', 'LINEAR_API_KEY', 'CODERABBIT_API_KEY', 'SECRETO_AJENO'} & environment.keys()
            if role == 'M1':
                assert environment['TF_STATION_HOST'] == 'host-example' and environment['TF_RUNNER_USER'] == 'runner'
        token.unlink()
        fases.start_actor(['CEO', str(operational), str(home/'bus'), str(home/'manifiesto')])
        assert 'CLAUDE_CODE_OAUTH_TOKEN' not in executions[-1][2]
        login.unlink()
        try:
            fases.start_actor(['C1', str(operational), str(home/'bus'), str(home/'manifiesto')])
        except fases.Error:
            pass
        else:
            raise AssertionError('arranque sin acreditación aceptado')
        assert len(executions) == 4
print('RESULTADO: PASS=5 FAIL=0 (tres roles, login y rechazo sin credencial)')
