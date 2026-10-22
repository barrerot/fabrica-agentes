"""Plan y reparto de gates con un runner; el ejecutor de gates es doble y no acredita sus checks."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

package = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='seal-opcional-') as directory:
    root = Path(directory)
    repo = root/'producto'
    repo.mkdir()
    motor = root/'motor'
    (motor/'scripts/lib').mkdir(parents=True)
    shutil.copyfile(package/'scripts/lib/runner-identity.sh', motor/'scripts/lib/runner-identity.sh')
    log = root/'gates.log'
    (motor/'scripts/run-gate-sealed.sh').write_text('#!/bin/bash\nprintf "%s\\n" "$1" >> "$GATES_LOG"\n')
    bindir = root/'bin'
    bindir.mkdir()
    (bindir/'incus').write_text('#!/bin/bash\n[ "$1" != list ] || printf "runner-ejemplo,RUNNING\\n"\n')
    (bindir/'incus').chmod(0o755)
    manifest = root/'instancia.conf'
    (root/'runner-identity.map').write_text('host-example=host-example\n')
    env = dict(os.environ, PATH=str(bindir)+':'+os.environ['PATH'], GATES_LOG=str(log),
               TF_ROOT=str(motor), TF_CLONE=str(repo), TF_MANIFEST=str(manifest), TF_SLUG='org-example/producto',
               TF_STATION_HOST='host-example', TF_RUNNERS='runner-ejemplo', TF_QUIET_GATES='',
               GIT_AUTHOR_NAME='Operador', GIT_AUTHOR_EMAIL='operador@example.invalid',
               GIT_COMMITTER_NAME='Operador', GIT_COMMITTER_EMAIL='operador@example.invalid')
    env.pop('TF_RUNNER_IDENTITY_MAP', None)
    def git(*args):
        return subprocess.check_output(['git', '-C', str(repo), *args], env=env, text=True).strip()
    git('init', '-q', '-b', 'main')
    registry = repo/'ci/registro.json'
    registry.parent.mkdir()
    registry.write_text(json.dumps({'families': {'web': {'shards': [{'id':'uno', 'specs':['prueba']}]}}}))
    git('add', '.')
    git('commit', '-qm', 'Registro de prueba')
    sha = git('rev-parse', 'HEAD')
    # El working tree no sustituye al contenido certificado.
    registry.write_text('{}')
    def invoke(mode, extra):
        manifest.write_text('TF_GATE_IDS="lint test"\n'+extra)
        log.unlink(missing_ok=True)
        result = subprocess.run(['bash', str(package/'scripts/seal-suite.sh'), mode,
                                 '1', sha, sha, 'opcional'], env=env, capture_output=True, text=True, timeout=60)
        print(mode+' claves='+str(len(extra.splitlines()))+' rc='+str(result.returncode))
        return result, log.read_text().splitlines() if log.exists() else []
    for mode in ('--plan', '--no-post'):
        result, executed = invoke(mode, '')
        assert result.returncode == 0, result.stdout+result.stderr
        assert '2/2 verdes' in result.stdout or 'total gates: 2' in result.stdout
        assert executed == ([] if mode == '--plan' else ['lint', 'test'])
        result, executed = invoke(mode, 'TF_SHARDS_REGISTRY="ci/registro.json"\nTF_E2E_FAMILIES="web"\n')
        assert result.returncode == 0, result.stdout+result.stderr
        assert '3/3 verdes' in result.stdout or 'total gates: 3' in result.stdout
        assert executed == ([] if mode == '--plan' else ['lint', 'test', 'web:uno'])
        for extra in ('TF_SHARDS_REGISTRY="ci/registro.json"\n', 'TF_E2E_FAMILIES="web"\n'):
            result, executed = invoke(mode, extra)
            assert result.returncode == 2 and 'solo UNA' in result.stderr and not executed
    for extra in ('TF_GATE_IDS="test"\n', 'TF_SHARDS_REGISTRY=ci/registro.json\n'):
        result, executed = invoke('--plan', extra)
        assert result.returncode == 2 and not executed
    print('seal-e2e-opcional: PASS=10 FAIL=0 (plan/reparto, e2e opcional y manifiestos inválidos; gates doblados)')
