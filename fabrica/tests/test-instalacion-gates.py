"""Topología mínima con motor real; dobles de transporte, API y red Git."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys
from unittest.mock import patch

package = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='montaje-gates-') as directory:
    root = Path(directory)
    station = root/'producto'
    runner = root/'runner/repo'
    station.mkdir()
    runner.mkdir(parents=True)
    bindir = root/'bin'
    bindir.mkdir()
    real_git = shutil.which('git')
    shim = bindir/'cliente'
    shim.write_text('''#!/usr/bin/python3
import json, os, shutil, subprocess, sys
from pathlib import Path
a = sys.argv[1:]
tool = Path(sys.argv[0]).name
r = Path(os.environ['GATES_FIXTURE'])
if tool == 'git':
    if 'fetch' in a and 'origin' in a:
        sys.exit(0)
    if 'ls-remote' in a:
        print(os.environ['GATES_BASE']+'\\trefs/heads/main')
        sys.exit(0)
    os.execv(os.environ['REAL_GIT'], ['git', *a])
if tool == 'gh':
    if a[:2] == ['pr', 'view']:
        print(json.dumps({'headRefOid':os.environ['GATES_HEAD'], 'headRefName':'docs/abc-1-humo',
                          'baseRefName':'main', 'author':{'login':'operador'}, 'mergeable':'MERGEABLE'}))
    elif 'POST' in a:
        (r/'publicado').write_text(' '.join(a))
    else:
        print('success')
    sys.exit(0)
if tool == 'tee':
    if os.environ.get('GATES_FILE_LIMIT') == '1':
        import resource
        limit = (r/'lg-montaje/journal.jsonl').stat().st_size + 40
        resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit))
    if os.environ.get('GATES_SEAL_UNREADABLE') == '1':
        sys.stdin.buffer.read()
        sys.exit(subprocess.run(['/usr/bin/tee', *a], input=b'{').returncode)
    os.execv('/usr/bin/tee', ['tee', *a])
if tool != 'incus':
    sys.exit(97)
def translated(s):
    return s.replace('/home/runner/repo', str(r/'runner/repo')).replace('/tmp/lg-', str(r/'tmp/lg-')).replace('/tmp/tmp.', str(r/'tmp/tmp.'))
if a[0] == 'list':
    print('runner-ejemplo,RUNNING')
elif a[:2] == ['file', 'push']:
    src, dst = a[-2:]
    dst = translated(dst.removeprefix('runner-ejemplo'))
    Path(dst).parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
elif a[:2] == ['file', 'pull']:
    if os.environ.get('GATES_PULL_FAIL') == '1':
        Path(a[-1]).write_text('{"receipt":')
        sys.exit(1)
    shutil.copyfile(translated(a[-2].removeprefix('runner-ejemplo')), a[-1])
elif a[0] == 'exec':
    cmd = [translated(s) for s in a[a.index('--')+1:]]
    env = dict(os.environ, HOME=str(r/'runner'), PF_HOME_ROOTS=str(r/'runner'), TMPDIR=str(r/'tmp'))
    if cmd[:2] == ['mktemp', '-d']:
        result = subprocess.run(cmd, env=env, capture_output=True, text=True)
        if result.returncode:
            sys.exit(result.returncode)
        print(result.stdout.strip().replace(str(r/'tmp')+'/', '/tmp/'))
        sys.exit(0)
    if os.environ.get('GATES_EARLY') == '1':
        env['TF_CHECK_REPO_ONLY'] = '1'
    if os.environ.get('GATES_NO_RECEIPT') == '1' and any(s.endswith('.run-local-gates.sh') for s in cmd):
        sys.exit(0)
    if cmd[:1] == ['id']:
        print(os.getuid() if '-u' in cmd else os.getgid())
        sys.exit(0)
    if cmd[:1] == ['sudo']:
        cmd = cmd[1:]
        while cmd and cmd[0] in ('-H', '-u'):
            cmd = cmd[2:] if cmd[0] == '-u' else cmd[1:]
    if os.environ.get('GATES_REPLAY') and cmd[:1] == ['bash'] and any(s.endswith('.run-local-gates.sh') for s in cmd):
        # Dato ajeno devuelto por el transporte; el lanzador real recoge y sella sus bytes.
        shutil.copyfile(os.environ['GATES_REPLAY'], cmd[cmd.index('--receipt')+1])
        sys.exit(0)
    if cmd[:2] == ['bash', '-c'] and ('lg_preflight()' in cmd[2] or 'sudo -H -u runner env' in cmd[2]):
        # El transporte simula la tabla de usuarios del contenedor, no el preflight.
        cmd[2] = ("getent() { printf 'runner:x:1000:1000:fixture:%s:/bin/bash\\n' \\\"$HOME\\\"; }; "
                  "id() { echo docker; }; sudo() { [ \\\"$1\\\" != -l ] || return 1; "
                  "while [ $# -gt 0 ]; do case \\\"$1\\\" in -H) shift;; -u) shift 2;; *) break;; esac; done; \\\"$@\\\"; }; "+cmd[2])
    sys.exit(subprocess.run(cmd, env=env).returncode)
else:
    sys.exit(98)
''')
    shim.chmod(0o755)
    for tool in ('incus', 'gh', 'git', 'tee'):
        (bindir/tool).symlink_to(shim)
    (root/'tmp').mkdir()
    env = dict(os.environ, PATH=str(bindir)+':'+os.environ['PATH'], GATES_FIXTURE=str(root), REAL_GIT=real_git,
               GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null',
               GIT_AUTHOR_NAME='Operador', GIT_AUTHOR_EMAIL='operador@example.invalid',
               GIT_COMMITTER_NAME='Operador', GIT_COMMITTER_EMAIL='operador@example.invalid')
    def git(repo, *args):
        return subprocess.check_output([real_git, '-C', str(repo), *args], env=env, text=True).strip()
    for repo in (station, runner):
        git(repo, 'init', '-q', '-b', 'main')
        git(repo, 'remote', 'add', 'origin', 'https://github.com/org-example/producto.git')
    validator = station/'scripts/validar-rama.sh'
    validator.parent.mkdir(parents=True)
    shutil.copyfile(package/'scripts/github/validar-rama-pr.sh', validator)
    docs = station/'docs/humo.md'
    docs.parent.mkdir()
    docs.write_text('Documento inicial\n')
    git(station, 'add', '.')
    git(station, 'commit', '-qm', 'Contrato inicial')
    base = git(station, 'rev-parse', 'HEAD')
    git(station, 'update-ref', 'refs/remotes/origin/main', base)
    git(station, 'checkout', '-qb', 'docs/abc-1-humo')
    docs.write_text('Documento actualizado\n')
    git(station, 'add', '.')
    git(station, 'commit', '-qm', 'Actualizar documento')
    head = git(station, 'rev-parse', 'HEAD')
    spec = importlib.util.spec_from_file_location('generador', package/'instalacion/instalacion.py')
    gen = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gen)
    answers = dict(line.split('=', 1) for line in (package/'instalacion/tests/fixtures/minima.resp').read_text().splitlines())
    answers.update(canales_n='1', gates_ids='docs',
                   gate_cmd_docs='test -s docs/humo.md && printf x >> '+str(root/'ejecuciones'), instalar_cmd='true')
    answers.pop('gate_cmd_humo', None)
    generated = gen.render(answers, root/'motor', root/'ceo')
    manifest = root/'motor/manifiestos/ejemplo.conf'
    manifest.parent.mkdir(parents=True)
    for rel in ('manifiestos/ejemplo.conf', 'manifiestos/runner-identity.map'):
        (root/'motor'/rel).write_text(generated[rel])
    env.update(TF_ROOT=str(package), TF_CLONE=str(station), TF_MANIFEST=str(manifest),
               TF_SLUG='org-example/producto', TF_STATION_HOST=answers['host_nombre'], TF_RUNNERS='runner-ejemplo',
               TF_RUNNER_USER='runner', TF_RUNNER_REPO='/home/runner/repo', TF_SEAL_REC_ROOT=str(root),
               LG_MANIFEST_DIR=str(manifest.parent), GATES_BASE=base, GATES_HEAD=head)
    env.pop('TF_RUNNER_IDENTITY_MAP', None)
    env.pop('TF_CHECK_REPO_ONLY', None)
    probe = ['bash', str(package/'instalacion/scripts/verificar-runner.sh'), 'runner-ejemplo',
             answers['repo_url'], 'F5', str(manifest)]
    result = subprocess.run(probe, env=env, capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stdout+result.stderr
    result = subprocess.run(probe, env=dict(env, GITHUB_TOKEN='valor-sintetico'), capture_output=True, text=True, timeout=60)
    assert result.returncode != 0 and 'runner entorno con credencial: GITHUB_TOKEN' in result.stderr
    assert 'valor-sintetico' not in result.stdout+result.stderr
    def suite(*flags):
        result = subprocess.run(['bash', str(package/'scripts/seal-suite.sh'), *flags,
                                 '1', head, 'origin/main', 'montaje'], env=env, capture_output=True, text=True, timeout=90)
        print(result.stdout+result.stderr)
        return result
    assert suite('--plan').returncode == 0
    result = suite()
    assert result.returncode == 0, result.stdout+result.stderr
    receipt = json.loads((root/'lg-montaje/docs.json').read_text())
    assert receipt['result'] == 'PASS' and receipt['sha'] == head and receipt['assignment'] == 'sealed'
    assert (root/'lg-montaje/journal.jsonl').is_file()
    assert 'state=success' in (root/'publicado').read_text()
    assert not git(station, 'status', '--porcelain', '--untracked-files=no')
    direct = ['bash', str(package/'scripts/run-gate-sealed.sh'), 'docs',
              '--runner', 'runner-ejemplo', '--runner-user', 'runner',
              '--runner-repo', '/home/runner/repo', '--repo', str(station),
              '--run-group', 'montaje', '--sha', head, '--base', 'origin/main',
              '--manifest', str(manifest), '--receipts', str(root/'lg-montaje'),
              '--pr', '1', '--repo-slug', 'org-example/producto']
    receipt_path = root/'lg-montaje/docs.json'
    remote_receipt = root/'tmp/lg-montaje-docs.receipt.json'
    journal = root/'lg-montaje/journal.jsonl'
    def aggregate():
        (root/'publicado').unlink(missing_ok=True)
        result = subprocess.run(['bash', str(package/'scripts/post-local-gates.sh'), 'montaje',
                                 'org-example/producto', '1', '--receipts', str(root/'lg-montaje'),
                                 '--manifest', str(manifest), '--repo', str(station)],
                                env=env, capture_output=True, text=True, timeout=90)
        print('agregación rc='+str(result.returncode)+'\n'+result.stdout+result.stderr)
        return result

    def evidence():
        return {path: path.read_bytes() for path in
                (receipt_path, remote_receipt, journal, root/'ejecuciones')}

    # (a) Cada componente divergente se devuelve al lanzador real para su sellado.
    # No se fabrica el journal: así no basta el rechazo por digest de receipt alterado.
    original = evidence()
    foreign = root/'receipt-ajeno.json'
    divergences = (
        ('gate', 'gate_id', 'otro', 'SIN procedencia sellada'),
        ('commit', 'sha', base, 'sha != head del PR'),
        ('manifiesto', 'manifest_digest', '0'*64, 'manifest_digest != manifiesto vigente'),
        ('base', 'base_sha', head, 'base_sha != merge-base actual'),
        ('asignación', 'assignment', 'inline', 'solo receipts de asignación SELLADA'),
        ('grupo', 'run_group', 'otro', 'run_group ajeno'),
    )
    for component, field, value, diagnostic in divergences:
        candidate = json.loads(original[receipt_path])
        candidate[field] = value
        foreign.write_text(json.dumps(candidate))
        rejected = subprocess.run(direct, env=dict(env, GATES_REPLAY=str(foreign)),
                                  capture_output=True, text=True, timeout=90)
        assert rejected.returncode == 0, rejected.stdout+rejected.stderr
        assert receipt_path.read_bytes() == foreign.read_bytes()
        assert (root/'ejecuciones').read_bytes() == original[root/'ejecuciones']
        post = aggregate()
        assert post.returncode == 2 and diagnostic in post.stderr and not (root/'publicado').exists(), \
            'cláusula a: '+component+'\n'+post.stdout+post.stderr
        for path, content in original.items():
            path.write_bytes(content)
        assert aggregate().returncode == 0 and 'state=success' in (root/'publicado').read_text()
        print('contrato-a: '+component+' rechazado; control legítimo aceptado')
    # Receipt válido sin sellado: conserva sus bytes, retira solo su respaldo del fixture.
    journal.write_text('')
    post = aggregate()
    assert post.returncode == 2 and not (root/'publicado').exists(), \
        'cláusula a: receipt sin sellado aceptado\n'+post.stdout+post.stderr
    journal.write_bytes(original[journal])
    assert aggregate().returncode == 0
    print('contrato-a: receipt sin sellado rechazado; control legítimo aceptado')

    # (b) G2 comparte expresamente el destino de G1: rechazo real antes de ejecutar.
    other_group = direct.copy()
    other_group[other_group.index('--run-group')+1] = 'otro'
    # (c) Reintento de exactamente T: el rechazo no invalida la evidencia anterior de T.
    for clause, command in (('b', other_group), ('c', direct)):
        previous = evidence()
        (root/'publicado').unlink(missing_ok=True)
        dirty = root/'runner/.netrc'
        dirty.touch()  # Fichero vacío sintético; no contiene ni se lee ninguna credencial.
        try:
            rejected = subprocess.run(command, env=env, capture_output=True, text=True, timeout=90)
            print('contrato-'+clause+': preflight rc='+str(rejected.returncode)+'\n'+
                  rejected.stdout+rejected.stderr)
            assert rejected.returncode == 2 and 'PREFLIGHT' in rejected.stderr and 'SUCIO' in rejected.stderr
            assert not (root/'publicado').exists()
            assert all(path.is_file() and path.read_bytes() == content for path, content in previous.items()), \
                'cláusula '+clause+': evidencia previa borrada o alterada tras rechazo del preflight'
        finally:
            dirty.unlink()
        post = aggregate()
        assert post.returncode == 0 and 'state=success' in (root/'publicado').read_text(), \
            'cláusula '+clause+': evidencia legítima previa rechazada\n'+post.stdout+post.stderr
        assert evidence() == previous, 'cláusula '+clause+': agregación alteró evidencia o ejecutó el gate'
        print('contrato-'+clause+': evidencia original intacta y aceptada sin ejecución nueva')

    # Rechazo del motor después del preflight: mismo destino, otro grupo y misma tupla.
    for clause, command in (('b', other_group), ('c', direct)):
        previous = evidence()
        rejected = subprocess.run(command, env=dict(env, GATES_EARLY='1'),
                                  capture_output=True, text=True, timeout=90)
        print('contrato-'+clause+': motor rc='+str(rejected.returncode)+'\n'+rejected.stdout+rejected.stderr)
        assert rejected.returncode == 2 and 'LIMPIO' in rejected.stdout
        assert 'TF_CHECK_REPO_ONLY no permite una corrida sellada' in rejected.stderr
        retained = previous if clause == 'b' else {p: b for p, b in previous.items() if p != remote_receipt}
        assert all(path.is_file() and path.read_bytes() == content for path, content in retained.items()), \
            'cláusula '+clause+': evidencia local previa alterada tras rechazo del motor'
        assert aggregate().returncode == 0
        assert all(path.read_bytes() == content for path, content in retained.items())
        assert not list(receipt_path.parent.glob('.docs.*')), 'temporal de receipt sin limpiar'

    # B02: pérdida accidental de escritura del journal, con motor y lanzador reales.
    previous_receipt, previous_journal = receipt_path.read_bytes(), journal.read_bytes()
    journal.chmod(0o400)
    try:
        rejected = subprocess.run(other_group, env=env, capture_output=True, text=True, timeout=90)
    finally:
        journal.chmod(0o600)
    print('contrato-b02: sellado rc='+str(rejected.returncode)+'\n'+rejected.stdout+rejected.stderr)
    assert rejected.returncode == 2 and 'no pude sellar en el journal' in rejected.stderr
    assert 'LIMPIO' in rejected.stdout and 'PASS' in rejected.stdout
    assert journal.read_bytes() == previous_journal
    assert receipt_path.read_bytes() == previous_receipt, 'B02: fallo de sellado destruye evidencia local previa'
    assert not list(receipt_path.parent.glob('.docs.*')), 'B02: temporal de receipt sin limpiar'
    assert aggregate().returncode == 0, 'B02: agregador rechaza G1 tras fallo de sellado'

    # B03: append parcial auténtico por límite del fichero, sin sustituir el escritor.
    previous_receipt, previous_journal = receipt_path.read_bytes(), journal.read_bytes()
    rejected = subprocess.run(other_group, env=dict(env, GATES_FILE_LIMIT='1'),
                              capture_output=True, text=True, timeout=90)
    print('contrato-b03: append parcial rc='+str(rejected.returncode)+'\n'+rejected.stdout+rejected.stderr)
    assert rejected.returncode == 2 and 'no pude sellar en el journal' in rejected.stderr
    assert receipt_path.read_bytes() == previous_receipt, 'B03: append parcial destruye G1'
    assert journal.read_bytes().startswith(previous_journal)
    assert len(journal.read_bytes()) == len(previous_journal)+40
    assert not journal.read_bytes().endswith(b'\n')
    assert aggregate().returncode == 0, 'B03: G1 deja de ser agregable tras append parcial'
    second = subprocess.run(other_group, env=env, capture_output=True, text=True, timeout=90)
    assert second.returncode == 0, second.stdout+second.stderr
    assert json.loads(receipt_path.read_bytes())['run_group'] == 'otro'
    post = subprocess.run(['bash', str(package/'scripts/post-local-gates.sh'), 'otro',
                          'org-example/producto', '1', '--receipts', str(receipt_path.parent),
                          '--manifest', str(manifest), '--repo', str(station)],
                         env=env, capture_output=True, text=True, timeout=90)
    assert post.returncode == 0, 'B03: receipt promovido sin sello legible\n'+post.stdout+post.stderr
    assert not list(receipt_path.parent.glob('.docs.*'))
    receipt_path.write_bytes(previous_receipt)
    journal.write_bytes(b'{linea rota\n'+previous_journal)
    assert aggregate().returncode == 0, 'B03: línea rota inicial oculta entrada válida'
    journal.write_bytes(previous_journal)
    # Un escritor con rc 0 y entrada ilegible tampoco autoriza la promoción.
    local_unreadable = direct.copy()
    local_unreadable.insert(3, '--unsafe-local')
    for command in (other_group, local_unreadable):
        rejected = subprocess.run(command, env=dict(env, GATES_SEAL_UNREADABLE='1'),
                                  capture_output=True, text=True, timeout=90)
        assert rejected.returncode == 2 and 'sello no recuperable' in rejected.stderr, \
            'B03: sello ilegible autoriza promoción\n'+rejected.stdout+rejected.stderr
        assert receipt_path.read_bytes() == previous_receipt
        assert not list(receipt_path.parent.glob('.docs.*'))
        assert aggregate().returncode == 0
        journal.write_bytes(previous_journal)
    print('contrato-b03: recuperación, lectura tolerante y promoción protegida en ambos caminos')
    # La lista cerrada no permite añadir una biblioteca: ambas consultas son idénticas.
    queries = []
    for name in ('run-gate-sealed.sh', 'post-local-gates.sh'):
        source = (package/'scripts'/name).read_text()
        queries.append(source.split('journal_entry() {', 1)[1].split('\n}', 1)[0])
    assert queries[0] == queries[1], 'B03: consultas de procedencia divergentes'

    for flag in ('GATES_EARLY', 'GATES_NO_RECEIPT', 'GATES_PULL_FAIL'):
        executions = (root/'ejecuciones').read_bytes()
        previous_receipt = receipt_path.read_bytes()
        previous_journal = journal.read_bytes()
        (root/'publicado').unlink()
        rejected = subprocess.run(direct, env=dict(env, **{flag:'1'}), capture_output=True, text=True, timeout=90)
        print('repetición rechazada '+flag+' rc='+str(rejected.returncode)+'\n'+rejected.stdout+rejected.stderr)
        assert rejected.returncode != 0
        if flag == 'GATES_EARLY':
            assert 'TF_CHECK_REPO_ONLY no permite una corrida sellada' in rejected.stderr
        if flag != 'GATES_PULL_FAIL':
            assert (root/'ejecuciones').read_bytes() == executions
            assert not remote_receipt.exists()
        else:
            assert 'pull (receipt) del runner falló' in rejected.stderr
        assert receipt_path.read_bytes() == previous_receipt
        assert not list(receipt_path.parent.glob('.docs.*')), 'temporal de receipt sin limpiar'
        assert journal.read_bytes() == previous_journal
        post = subprocess.run(['bash', str(package/'scripts/post-local-gates.sh'), 'montaje',
                               'org-example/producto', '1', '--receipts', str(root/'lg-montaje'),
                               '--manifest', str(manifest), '--repo', str(station)],
                              env=env, capture_output=True, text=True, timeout=90)
        assert post.returncode == 0 and (root/'publicado').exists(), post.stdout+post.stderr
        restored = subprocess.run(direct, env=env, capture_output=True, text=True, timeout=90)
        assert restored.returncode == 0, restored.stdout+restored.stderr
        assert (root/'ejecuciones').read_bytes() != executions and receipt_path.exists()
        # Recuperar publicación legítima para el siguiente intento.
        assert suite().returncode == 0
    # Diagnóstico local: rechazo conserva evidencia; éxito conserva la marca no agregable.
    local = direct.copy()
    local.insert(3, '--unsafe-local')
    previous_receipt, previous_journal = receipt_path.read_bytes(), journal.read_bytes()
    executions = (root/'ejecuciones').read_bytes()
    rejected = subprocess.run(local, env=dict(env, TF_CHECK_REPO_ONLY='1'),
                              capture_output=True, text=True, timeout=90)
    assert rejected.returncode == 2 and 'TF_CHECK_REPO_ONLY no permite una corrida sellada' in rejected.stderr
    assert receipt_path.read_bytes() == previous_receipt and journal.read_bytes() == previous_journal
    assert (root/'ejecuciones').read_bytes() == executions
    assert aggregate().returncode == 0
    result = subprocess.run(local, env=env, capture_output=True, text=True, timeout=90)
    assert result.returncode == 0, result.stdout+result.stderr
    assert json.loads(journal.read_text().splitlines()[-1])['isolation'] == 'station-local'
    assert aggregate().returncode == 2 and not (root/'publicado').exists()
    assert not list(receipt_path.parent.glob('.docs.*')), 'temporal de receipt sin limpiar'

    # Bx: agregador real, PR disjunto y avance de un insumo; append tras línea incompleta.
    with manifest.open('a') as stream:
        stream.write('\nTF_INERCIA_POR_INSUMO="1"\n')
    inputs = root/'insumos.conf'
    inputs.write_text('TF_INPUTS_UNIVERSAL="package.json"\nTF_INPUTS_docs="src/**"\n')
    env['LG_INSUMOS_CONF'] = str(inputs)
    assert suite().returncode == 0
    previous_receipt, previous_journal = receipt_path.read_bytes(), journal.read_bytes()
    rejected = subprocess.run(other_group, env=dict(env, GATES_FILE_LIMIT='1'),
                              capture_output=True, text=True, timeout=90)
    assert rejected.returncode == 2 and 'no pude sellar en el journal' in rejected.stderr
    assert receipt_path.read_bytes() == previous_receipt
    assert journal.read_bytes().startswith(previous_journal)
    assert len(journal.read_bytes()) == len(previous_journal)+40
    git(station, 'checkout', '-q', 'main')
    source_file = station/'src/insumo.txt'
    source_file.parent.mkdir()
    source_file.write_text('Avance disjunto del documento del PR\n')
    git(station, 'add', '.')
    git(station, 'commit', '-qm', 'Avanzar insumo del gate')
    current_base = git(station, 'rev-parse', 'HEAD')
    git(station, 'update-ref', 'refs/remotes/origin/main', current_base)
    git(station, 'checkout', '-q', 'docs/abc-1-humo')
    env['GATES_BASE'] = current_base
    previous_journal = journal.read_bytes()
    previous_receipt = receipt_path.read_bytes()
    executions = (root/'ejecuciones').read_bytes()
    post = aggregate()
    assert post.returncode == 0 and 'CONSERVADO por inercia' in post.stdout, post.stdout+post.stderr
    assert receipt_path.read_bytes() == previous_receipt and (root/'ejecuciones').read_bytes() == executions
    before_reject = journal.read_bytes()
    rejected = subprocess.run(other_group, env=dict(env, GATES_EARLY='1'),
                              capture_output=True, text=True, timeout=90)
    assert rejected.returncode == 2 and 'TF_CHECK_REPO_ONLY no permite una corrida sellada' in rejected.stderr
    assert receipt_path.read_bytes() == previous_receipt and journal.read_bytes() == before_reject
    second = aggregate()
    print('contrato-o01: primera agregación='+str(post.returncode)+' segunda='+str(second.returncode))
    assert second.returncode == 0 and 'CONSERVADO por inercia' in second.stdout, \
        'O01: segunda agregación pierde el sello tras la observación de inercia\n'+second.stdout+second.stderr
    assert receipt_path.read_bytes() == previous_receipt and (root/'ejecuciones').read_bytes() == executions
    print('contrato-o01: segunda agregación del mismo grupo aceptada tras rechazo real del motor')
    aggregator_source = (package/'scripts/post-local-gates.sh').read_text()
    query = aggregator_source.split('journal_entry() {', 1)[1].split('\n}', 1)[0]
    receipt_sha = subprocess.check_output(['sha256sum', str(receipt_path)], text=True).split()[0]
    lookup = subprocess.run(['bash', '-c', 'set -euo pipefail\njournal_entry() {'+query+
                             '\n}\njournal_entry "$1" "$2" "$3" "$4"', '_',
                             receipt_sha, 'montaje', 'docs', str(journal)],
                            env=env, capture_output=True, text=True, timeout=30)
    assert lookup.returncode == 0, lookup.stderr
    seal_entry = json.loads(lookup.stdout)
    assert 'kind' not in seal_entry and seal_entry['assignment_sha256'], 'O01: procedencia sin sello'
    entry = json.loads(journal.read_text().splitlines()[-1])
    assert entry.get('kind') == 'inercia-por-insumo', 'Bx: observación de inercia no recuperable'
    assert entry['base_tip_receipt'] == base and entry['base_tip_actual'] == current_base
    assert entry['churn_hit'] == 'src/insumo.txt'
    assert journal.read_bytes().startswith(previous_journal+b'\n'), 'Bx: append sin separar la línea incompleta'
    assert journal.read_bytes().endswith(b'\n')
    print('contrato-bx: inercia tras línea incompleta recuperable; evidencia previa intacta')

    # Se compara el bloque completo bajo flock, incluidos los argumentos del journal.
    writers = []
    for name in ('run-gate-sealed.sh', 'post-local-gates.sh'):
        source = (package/'scripts'/name).read_text()
        writers.append(source.split('| flock -x "$JOURNAL.lock"', 1)[1].split('\\\n', 1)[0])
    assert writers[0] == writers[1], 'Bx: bloques de escritura del journal divergentes'
    print('contrato-bx: bloques bajo flock idénticos')
    sys.path.insert(0, str(package/'instalacion/scripts'))
    import fases
    with patch.object(fases, 'user_home', lambda user: root/user):
        settings = fases.station_settings(dict(answers=answers, project='ejemplo', clon=station, manifest=manifest))
    from instalacion_coherencia import comprobar, mutantes
    comprobar(generated, 'ejemplo', settings)
    mutantes(generated, 'ejemplo', settings)
    clones = {}
    for role in ('CEO', 'C1', 'M1'):
        clone = root/role
        clone.mkdir()
        git(clone, 'init', '-q', '-b', 'main')
        (clone/'contrato').write_text('contrato confirmado\n')
        git(clone, 'add', '.')
        git(clone, 'commit', '-qm', 'Contrato')
        (clone/'estado-sin-seguimiento').write_text('estado local\n')
        clones[role] = clone
    def actor(user, args, **kwargs):
        return subprocess.check_output(list(map(str, args)), env=env, text=True)
    with patch.object(fases, 'roles', lambda c: [(r, r, r) for r in clones]), \
            patch.object(fases, 'role_clone', lambda c, r: clones[r]), patch.object(fases, 'actor', actor):
        fases.clean_role_clones({})
        for role, clone in clones.items():
            (clone/'contrato').write_text('contrato modificado\n')
            try:
                fases.clean_role_clones({})
            except fases.Error as exc:
                assert 'clon con cambios seguidos: '+role in str(exc)
            else:
                raise AssertionError('clon sucio aceptado: '+role)
            (clone/'contrato').write_text('contrato confirmado\n')
    print('montaje-gates: PASS=40 FAIL=0 (39 casos previos; O01: segunda agregación tras inercia y rechazo real)')
