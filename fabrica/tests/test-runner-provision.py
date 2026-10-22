"""Perfil real con herramientas de usuarios dobladas y repositorio git real."""
import os
from pathlib import Path
import subprocess
import tempfile

package = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='runner-perfil-') as directory:
    root = Path(directory)
    homes = root/'home'
    gates = homes/'runner'
    gates.mkdir(parents=True)
    (homes/'canal').mkdir()
    (root/'root').mkdir()
    rules = root/'sudoers'
    rules.mkdir()
    (rules/'90-canal').write_text('canal ALL=(ALL) NOPASSWD:ALL\n')
    binpath = root/'bin'
    binpath.mkdir()
    shim = binpath/'cliente'
    shim.write_text('''#!/usr/bin/python3
import os,sys
from pathlib import Path
tool=Path(sys.argv[0]).name
args=sys.argv[1:]
root=Path(os.environ['RUNNER_FIXTURE'])
if tool == 'id':
    if args[0] == '-nG':
        print('docker' if (root/('sin-sudo-'+args[-1])).exists() else 'sudo docker')
    else:
        sys.exit(0 if (root/'usuario-creado').exists() else 1)
elif tool == 'useradd':
    (root/'usuario-creado').touch()
elif tool == 'usermod':
    (root/'docker-declarado').write_text(' '.join(args))
elif tool == 'gpasswd':
    (root/('sin-sudo-'+args[1])).touch()
elif tool == 'getent':
    print('runner:x:1001:1001:fixture:'+str(root/'home/runner')+':/bin/bash')
elif tool == 'sudo':
    if '-l' in args:
        sys.exit(1)
    while args and args[0] != 'git':
        args=args[2:] if args[0] == '-u' else args[1:]
    os.execvp(args[0], args)
''')
    shim.chmod(0o755)
    for name in ('id', 'useradd', 'usermod', 'gpasswd', 'getent', 'sudo'):
        (binpath/name).symlink_to(shim)
    repo = gates/'repo'
    script = root/'perfil.sh'
    script.write_text((package/'instalacion/scripts/runner-perfil.sh').read_text().replace(
        '/etc/sudoers.d', str(rules)).replace('/home/runner/repo', str(repo)))
    env = dict(os.environ, PATH=str(binpath)+':'+os.environ['PATH'], HOME=str(gates),
               RUNNER_FIXTURE=str(root), PF_HOME_ROOTS=str(root/'root')+' '+str(homes)+'/*',
               GIT_CONFIG_SYSTEM='/dev/null', GIT_CONFIG_GLOBAL='/dev/null')
    def run():
        return subprocess.run(['bash', str(script), 'canal', str(package), 'https://github.com/org-example/producto.git'], env=env,
                              capture_output=True, text=True, timeout=60)
    for _ in range(2):
        result = run()
        assert result.returncode == 0 and 'LIMPIO' in result.stdout, result.stdout+result.stderr
    assert (root/'usuario-creado').exists() and (root/'docker-declarado').read_text() == '-aG docker runner'
    assert (root/'sin-sudo-runner').exists() and (root/'sin-sudo-canal').exists()
    assert not (rules/'90-canal').exists() and (repo/'.git').is_dir()
    token = homes/'canal/.claude_token.env'
    token.write_text('valor-sintetico')
    result = run()
    assert result.returncode == 3 and 'SUCIO:' in result.stdout and 'valor-sintetico' not in result.stdout
    token.unlink()
    assert run().returncode == 0
    assert subprocess.check_output(['git', '-C', str(repo), 'remote', 'get-url', 'origin'], env=env, text=True).strip() == 'https://github.com/org-example/producto.git'
    manifest = root/'manifest.conf'
    manifest.write_text('TF_GATE_IDS="docs"\nTF_REPO_URL="https://github.com/org-example/producto.git"\n')
    def correspondence():
        return subprocess.run(['bash', str(package/'scripts/run-local-gates.sh'), str(repo),
                               '--gate', 'docs', '--manifest', str(manifest)],
                              env=dict(env, TF_CHECK_REPO_ONLY='1'), capture_output=True, text=True)
    assert correspondence().returncode == 0
    subprocess.check_call(['git', '-C', str(repo), 'remote', 'set-url', 'origin', 'https://example.invalid/otro'], env=env)
    assert run().returncode != 0
    result = correspondence()
    assert result.returncode == 2 and 'no corresponden' in result.stderr
    subprocess.check_call(['git', '-C', str(repo), 'remote', 'set-url', 'origin', 'https://github.com/org-example/producto.git'], env=env)
    subprocess.check_call(['git', '-C', str(repo), 'remote', 'add', 'otro', 'https://example.invalid/otro'], env=env)
    assert run().returncode != 0
print('runner-perfil: PASS=8 FAIL=0 (provisión, idempotencia, credencial, restauración, origin, motor rojo/verde y remoto adicional)')
