#!/usr/bin/env python3
"""Recorrido F8 con código real y dobles de las cuatro interfaces externas."""
import io
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

PACKAGE = Path(__file__).resolve().parents[2]
PASS = FAIL = 0


def expect(label, condition, output=''):
    global PASS, FAIL
    if condition:
        PASS += 1
        print('PASS '+label, flush=True)
    else:
        FAIL += 1
        print('FAIL '+label+' '+output[:600], flush=True)


with tempfile.TemporaryDirectory(prefix='f8-secuencia-') as td:
    t = Path(td)
    pkg = t/'paquete'
    shutil.copytree(PACKAGE, pkg, ignore=shutil.ignore_patterns('.git', 'estado', 'generado', '__pycache__'))
    state = pkg/'instalacion/estado'
    state.mkdir(mode=0o700)
    home = t/'hogar'
    home.mkdir(mode=0o700)
    clone = t/'producto'
    clone.mkdir()
    shutil.copytree(pkg/'scripts', clone/'scripts')
    shutil.copytree(pkg/'skills/talent-channel-operation', clone/'.claude/skills/talent-channel-operation')
    subprocess.run(['git', 'init', '-q', str(clone)], check=True)
    manifest = clone/'.claude/tf-manifest.conf'
    manifest.write_text('TF_LINEAR_TEAM_KEY="ABC"\nTF_SENSITIVE_SURFACES="auth credenciales"\n')
    answers = (pkg/'instalacion/tests/fixtures/minima.resp').read_text()
    user = pwd.getpwuid(os.getuid()).pw_name
    answers = answers.replace('usuario_ceo=operador', 'usuario_ceo='+user).replace('usuario_incus=ejemplo-incus', 'usuario_incus='+user)
    (state/'respuestas.resp').write_text(answers)
    (state/'contexto.conf').write_text('respuestas='+str(state/'respuestas.resp')+'\nhome='+str(home)+'\nclon='+str(clone)+'\n')
    envdir = home/'ejemplo'
    envdir.mkdir(mode=0o700)
    (envdir/'.env.local').write_text('LINEAR_API_KEY=secreto-sintetico-reservado\n')
    (envdir/'.env.local').chmod(0o600)
    escrow = home/'.config/talent-channels'
    escrow.mkdir(parents=True, mode=0o700)
    conf = home/'.config/talent-channel-operation/agents.conf'
    conf.parent.mkdir(mode=0o700)
    conf.write_text('TCO_DEV_CLI="claude"\nTCO_AUDIT_CLI="claude"\n')
    conf.chmod(0o600)
    binpath = t/'bin'
    binpath.mkdir()
    head = 'a'*40
    headers = ['Qué hace', 'Decisiones y porqués', 'Invariantes sellados por el code-audit',
               'Superficies tocadas y clasificación', 'Migraciones', 'Archivos calientes',
               'Verificación local ejecutada', 'Qué NO tocar / trampas', 'Bloque machine-readable']
    handoff = dict(schema_version=2, build='validado', issues=['ABC-1'], head_sha=head,
                   branch='docs/humo', sensitive=False, destructive=False, surfaces=[], migration_slots=[])
    comment = '## HANDOFF\n'+'\n'.join('### '+h+'\nTexto de prueba.' for h in headers)+'\n```json\n'+json.dumps(handoff)+'\n```\n'
    pr = dict(number=1, state='OPEN', isDraft=True, headRefOid=head, headRefName='docs/humo',
              mergeCommit={'oid':'b'*40}, body='Closes ABC-1', comments=[{'body':comment}],
              files=[{'path':'docs/humo.md'}], statusCheckRollup=[{'name':'local-gates', 'conclusion':'SUCCESS'},
                  {'name':'revision-opcional', 'conclusion':None, 'status':'IN_PROGRESS'}])
    pr_path = t/'pr.json'
    pr_path.write_text(json.dumps(pr))
    external = '''#!/usr/bin/env python3
import json,os,sys,stat,subprocess
from pathlib import Path
tool=Path(sys.argv[0]).name
args=sys.argv[1:]
if os.environ.get('F8_FAIL')==tool: sys.exit(7)
if tool=='gh':
    if args[:2]==['pr','view']: print(Path(os.environ['F8_PR_DATA']).read_text())
    else: print(json.dumps({'sha':'a'*40,'statuses':[{'context':'local-gates','state':'success'}]}))
elif tool=='curl':
    assert 'secreto-sintetico-reservado' not in ' '.join(args)
    p=Path(args[args.index('--header')+1][1:])
    assert stat.S_IMODE(p.stat().st_mode)==0o600
    assert p.parent==Path(os.environ['F8_ESCROW'])
    if os.environ.get('F8_LINEAR_ERRORS'):
        print(json.dumps({'errors':[{'message':'Consulta rechazada'}]}))
        sys.exit(0)
    print(json.dumps({'data':{'issue':{'identifier':os.environ.get('F8_LINEAR_ISSUE','ABC-1'),
      'title':os.environ.get('F8_LINEAR_TITLE','Cambio de documentación'),
      'createdAt':os.environ.get('F8_LINEAR_CREATED','2026-10-04T12:00:00Z'),
      'state':{'name':os.environ.get('F8_LINEAR_STATE','Todo')}}}}))
elif tool=='incus':
    command=' '.join(args)
    if 'display-message' in command: print('101')
    elif 'bash -c' in command: print('claude')
    elif '--version' in command: print('9.8.7')
    elif 'capture-pane' in command: subprocess.run(['tmux','capture-pane'],check=True)
    else: sys.exit(2)
elif tool=='tmux':
    print(Path(os.environ['F8_SCREEN']).read_text())
'''
    for name in ('gh', 'curl', 'incus', 'tmux'):
        path = binpath/name
        path.write_text(external)
        path.chmod(0o755)
    screen = t/'screen.txt'
    captures = home/'evidencias-fabrica/ejemplo/pane'
    evidence = home/'evidencias-fabrica/ejemplo/humo'
    evidence.mkdir(parents=True, mode=0o700)
    runtime = dict(os.environ, HOME=str(home), HOST_HOME=str(home), SECRET_DIR=str(conf.parent),
                   PATH=str(binpath)+':'+os.environ['PATH'], F8_PR_DATA=str(pr_path), F8_ESCROW=str(escrow),
                   F8_SCREEN=str(screen), F8_ISSUE='ABC-1', F8_PR='1', TCO_FIXTURE_DIR=str(captures),
                   TCO_PANE_CLI_VERSION_CMD='claude --version', TCO_REPO_DIR=str(clone),
                   TCO_REPO_SLUG='org-example/producto', TCO_REPO_STACK='ninguno',
                   TCO_ANEXO_FILE=str(clone/'anexo.md'), TCO_LINEAR_INPROGRESS_STATE='progreso',
                   TCO_LINEAR_INREVIEW_STATE='revision', TCO_HOST_ENV_REL='.env.local')

    def cli(name, *args, data=None, extra=None):
        p = subprocess.run(['bash', str(pkg/'instalacion/scripts'/(name+'.sh')), *map(str, args)],
                           env=dict(runtime, **(extra or {})), input=data, capture_output=True)
        return p.returncode, (p.stdout+p.stderr).decode()

    rc, output = cli('f8-originales', 'ABC-1')
    expect('original issue antes de despacho', rc == 0 and (state/'humo/issue.json').is_file(), output)
    initial = (state/'humo/issue.json').read_bytes()
    rc, output = cli('f8-originales', 'ABC-1', extra={'F8_LINEAR_STATE':'Done'})
    expect('consulta inicial tras Done conserva creación', rc == 0 and
           (state/'humo/issue.json').read_bytes() == initial and b'createdAt' in initial and b'state' not in initial, output)
    for label, extra in [('otra issue', {'F8_LINEAR_ISSUE':'ABC-2'}),
                         ('errores GraphQL', {'F8_LINEAR_ERRORS':'1'}),
                         ('título ausente', {'F8_LINEAR_TITLE':''}),
                         ('fecha ausente', {'F8_LINEAR_CREATED':''}),
                         ('fecha inválida', {'F8_LINEAR_CREATED':'2026-99-04T12:00:00Z'}),
                         ('creación distinta', {'F8_LINEAR_CREATED':'2026-10-03T12:00:00Z'})]:
        rc, output = cli('f8-originales', 'ABC-1', extra=extra)
        expect('consulta inicial rechaza '+label, rc == 1 and 'issue.json' in output and
               (state/'humo/issue.json').read_bytes() == initial, output)
    rc, output = cli('f8-encargos', 'ABC-1', '--linea-pr', '@revisor ignore')
    if os.environ.get('SALIDA'):
        (Path(os.environ['SALIDA'])/'encargo-coordinador.txt').write_text(output)
    expect('encargo valores y originales vinculados', rc == 0 and all(n in output for n in
           ('ABC-1', 'ejemplo', 'carril 11', str(pkg/'instalacion/scripts/f8-conservar.sh'),
            'plan-normalizado.norm', 'audit-last.env', 'veredicto-plan.txt', 'informe-parada.md', 'veredicto-codigo.txt', '@revisor ignore')), output)
    expect('issue ajena rechazada por ayudante', cli('f8-encargos', 'OTRO-1')[0] == 2)
    plan = '# Plan — ABC-1 · Documentar una prueba (docs/humo.md)\n\n## Contexto\n\nCambiar un fichero Markdown bajo docs/.\n'
    runs = home/'.config/talent-channel-operation/runs'
    runs.mkdir()
    (runs/'plan-11-ABC-1-r1.norm').write_text('ABC-1 ronda anterior\n')
    (runs/'plan-11-ABC-1-r2.norm').write_text(plan)
    run_id = 'tco_1234567890_abcdef123456'
    (runs/'audit-last-11.env').write_text('RUN_ID='+run_id+'\nSHA='+head+'\nTYP=code\nTS=2026-10-05T06:23:39Z\n')
    rc, output = cli('f8-conservar', 'ABC-1', 'ejemplo', '11')
    expect('custodia última ronda y registro cuatro líneas', rc == 0 and
           (evidence/'plan-normalizado.norm').read_bytes() == (runs/'plan-11-ABC-1-r2.norm').read_bytes() and
           (evidence/'audit-last.env').read_bytes() == (runs/'audit-last-11.env').read_bytes(), output)
    digest = hashlib.sha256(plan.encode()).hexdigest()
    (evidence/'veredicto-plan.txt').write_text('{"run_id":"tco_1234567800_abcdef123456","artifact_type":"plan","artifact_sha":"'+digest[:28]+'\n  '+digest[28:]+'","verdict":"GO","blocking_findings":[]}\n')
    (evidence/'informe-parada.md').write_text('STOP-AUDIT — ABC-1 · informe pre-push\n· SHA auditado: '+head+'\n')
    # Caso neutralizado de p61: SHA cortado por el ancho del panel.
    verdict = '{"run_id":"tco_1234567890_abcdef123456","artifact_type":"code","artifact_sha":"'+head[:28]+'\n  '+head[28:]+'","verdict":"GO","blocking_findings":[]}\n'
    (evidence/'veredicto-codigo.txt').write_text(verdict)
    (evidence/'watch-stop.log').write_text('')
    rc, output = cli('f8-handoff', '1', 'ABC-1')
    expect('verificador real antes de merge', rc == 0 and 'rc=0' in output, output)
    rc, output = cli('f8-encargos', 'ABC-1', '1')
    if os.environ.get('SALIDA'):
        (Path(os.environ['SALIDA'])/'encargo-estacion.txt').write_text(output)
    expect('encargo estación con PR', rc == 0 and 'PR 1' in output and 'Done' in output, output)
    pr.update(state='MERGED', isDraft=False)
    pr_path.write_text(json.dumps(pr))
    expect('originales antes de Done rechazan', cli('f8-originales', 'ABC-1', '1')[0] == 1)
    (state/'humo/issue.json').unlink()
    rc, output = cli('f8-originales', 'ABC-1', '1', extra={'F8_LINEAR_STATE':'Done'})
    expect('originales fusion y Done recuperan consulta omitida', rc == 0 and
           (state/'humo/merge.json').is_file() and (state/'humo/issue.json').read_bytes() == initial, output)
    expect('cabecera temporal eliminada', not list(escrow.iterdir()))
    expect('fallo Linear diagnosticado', cli('f8-originales', 'ABC-1', '1', extra={'F8_FAIL':'curl'})[0] == 1)
    expect('cabecera eliminada tras fallo', not list(escrow.iterdir()))
    synthetic = pkg/'skills/talent-channel-operation/tests/fixtures/pane/synthetic_0.0.0'
    screens = {n:(synthetic/(n+'.txt')).read_text().replace('salida previa del agente (fixture SINTETICO, no es una captura real)', 'Pantalla del doble de terminal') for n in ('idle','busy','modal')}
    for name in ('idle','modal','busy','done','redraw'):
        screen.write_text(screens['idle' if name in ('done','redraw') else name])
        if name == 'done':
            rc, output = cli('capturar-done', clone, '11', 'v:.0')
        else:
            rc, output = cli('f8-capturas', clone, '11', 'v:.0', name)
        expect('captura clasifica '+name, rc == 0 and (captures/'claude_9.8.7'/(name+'.txt')).is_file(), output)
    screen.write_text(screens['idle'])
    rc, output = cli('f8-capturas', clone, '11', 'v:.0', 'busy', '--repetir')
    expect('busy reposo descartada conserva anterior', rc == 1 and 'clasificación' in output and
           (captures/'claude_9.8.7/busy.txt').read_text() == screens['busy'], output)
    expect('repetición requiere opción', cli('f8-capturas', clone, '11', 'v:.0', 'idle')[0] == 1)
    rc, output = cli('f8-capturas', clone, '11', 'v:.0', 'idle', '--repetir')
    expect('repetición válida conserva rechazada', rc == 0 and list((captures/'claude_9.8.7').glob('idle.rechazada.*')), output)
    rc, output = cli('capturar-done', clone, '11', 'v:.0', '--repetir', extra={'TCO_PANE_CLI_VERSION_CMD':''})
    expect('done falta versión explica variable', rc == 1 and 'TCO_PANE_CLI_VERSION_CMD' in output and 'falta: busy.txt' not in output, output)
    coordinator_home = t/'hogar-coordinador'
    coordinator_conf = coordinator_home/'.config/talent-channel-operation/agents.conf'
    coordinator_conf.parent.mkdir(parents=True, mode=0o700)
    coordinator_conf.write_text('TCO_DEV_CLI="claude"\n')
    coordinator_conf.chmod(0o600)
    rc, output = cli('calibrar-pane', clone, captures/'claude_9.8.7', '--registrar', extra={'HOME':str(coordinator_home)})
    expect('calibración C1 por orden', rc == 0 and 'claude:9.8.7' in coordinator_conf.read_text() and 'CALIBRATED' not in conf.read_text(), output)

    def archive(entries=None):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w') as tar:
            if entries is None:
                tar.add(evidence, arcname='humo')
                tar.add(captures, arcname='pane')
            else:
                for name, content, kind in entries:
                    entry = tarfile.TarInfo(name)
                    if kind == 'link':
                        entry.type = tarfile.SYMTYPE
                        entry.linkname = 'plan-aprobado.md'
                        tar.addfile(entry)
                    else:
                        entry.size = len(content)
                        tar.addfile(entry, io.BytesIO(content))
        return buffer.getvalue()

    rc, output = cli('f8-importar', data=archive())
    expect('importación tolera incidental vacío nombrado', rc == 0 and 'watch-stop.log (nombre incidental)' in output and not (state/'humo/watch-stop.log').exists(), output)
    for name, content, kind in [('humo/plan-normalizado.norm', b'', 'file'), ('../escape', b'X', 'file'),
                                ('humo/incidental', b'', 'link'), ('humo/plan-normalizado.norm', b'ABC-2', 'file')]:
        before = (state/'humo/plan-normalizado.norm').read_bytes()
        rc, output = cli('f8-importar', data=archive([(name, content, kind)]))
        expect('importación rechaza con fichero '+name+' '+kind, rc == 1 and name in output and
               before == (state/'humo/plan-normalizado.norm').read_bytes(), output)
    imported = state/'pane/claude_9.8.7'
    (imported/'busy.txt').write_text(screens['idle'])
    rc, output = cli('f8-importar', '--repetir-capturas', data=archive())
    expect('reimportación corrige captura con juego clasificado', rc == 0 and (imported/'busy.txt').read_text() == screens['busy'], output)
    rc, output = cli('calibrar-pane', clone, imported, '--registrar')
    expect('calibración instalador por orden', rc == 0, output)
    missing = state/'humo/veredicto-plan.txt'
    saved = missing.read_bytes()
    missing.unlink()
    rc, output = cli('f8-ciclo')
    expect('ciclo nombra veredicto plan ausente', rc == 1 and 'plan-gate' in output and 'veredicto-plan.txt' in output, output)
    missing.write_bytes(saved)
    rc, output = cli('f8-ciclo')
    expect('siete recibos automáticos desde originales fijos', rc == 0 and
           len(list((state/'humo').glob('*-recibo.json'))) == 7, output)
    rc, output = cli('check-F8', extra={'F8_LINEAR_STATE':'Done'})
    expect('secuencia check F8 real verde', rc == 0 and 'verde F8' in output, output)
    expect('ciclo idempotente', cli('f8-ciclo')[0] == 0)
    baseline = t/'reserva-humo'
    shutil.copytree(state/'humo', baseline)
    sys.path.insert(0, str(pkg/'instalacion/scripts'))
    from originales import verdicts, approval
    from fases import Error
    code_obj = dict(run_id=run_id, artifact_type='code', artifact_sha=head,
                    verdict='GO', blocking_findings=[])
    plan_obj = dict(code_obj, artifact_type='plan', artifact_sha=digest)
    for typ, obj in [('code', code_obj), ('plan', plan_obj)]:
        canonical = json.dumps(obj)
        for newline in ('\n', '\r\n'):
            failures = []
            for cut in range(1, len(canonical)):
                wrapped = 'Prosa del auditor.'+newline+'  '+canonical[:cut]+newline+'  '+canonical[cut:]+newline+'Fin del panel.'
                try:
                    same = verdicts(wrapped) == [obj]
                    approval(wrapped, typ, obj['artifact_sha'], 'ABC-1', run_id if typ == 'code' else None)
                except Error:
                    same = False
                if not same:
                    failures.append(cut)
            expect('cada corte JSON '+typ+' '+repr(newline), not failures, str(failures))

    def restore_positive():
        shutil.rmtree(state/'humo')
        shutil.copytree(baseline, state/'humo')

    prose_plan = plan+'\nAnte NO-GO se detiene la ejecución.\n'
    positives = [
        ('plan prosa NO-GO', 'plan-gate', {'plan-normalizado.norm':prose_plan,
            'veredicto-plan.txt':json.dumps(dict(plan_obj, artifact_sha=hashlib.sha256(prose_plan.encode()).hexdigest()))}),
        ('auditor prosa NO-GO', 'auditoria', {'veredicto-codigo.txt':'Se corrigió el NO-GO anterior.\n'+verdict}),
        ('code ronda rechazada anterior', 'auditoria', {'veredicto-codigo.txt':
            json.dumps(dict(code_obj, run_id='anterior', artifact_sha='c'*40, verdict='NO-GO'))+'\n'+verdict}),
        ('plan ronda rechazada anterior', 'plan-gate', {'veredicto-plan.txt':
            json.dumps(dict(plan_obj, artifact_sha='c'*64, verdict='NO-GO'))+'\n'+json.dumps(plan_obj)}),
        ('plan ronda anterior de code completa', 'plan-gate', {'veredicto-plan.txt':
            json.dumps(dict(code_obj, run_id='anterior-code', artifact_sha='c'*40, verdict='NO-GO'))+
            '\n'+json.dumps(plan_obj)}),
        ('code otro tipo anterior', 'auditoria', {'veredicto-codigo.txt':
            json.dumps(dict(plan_obj, run_id='anterior', verdict='NO-GO'))+'\n'+verdict}),
        ('code clave partida', 'auditoria', {'veredicto-codigo.txt':verdict.replace('artifact_type', 'artifact_\n  type')}),
        ('code run partido', 'auditoria', {'veredicto-codigo.txt':verdict.replace(run_id, run_id[:16]+'\n  '+run_id[16:])}),
        ('code CRLF', 'auditoria', {'veredicto-codigo.txt':json.dumps(code_obj)+'\r\n'}),
        ('plan CRLF', 'plan-gate', {'plan-normalizado.norm':plan.replace('\n', '\r\n'),
            'veredicto-plan.txt':json.dumps(dict(plan_obj, artifact_sha=hashlib.sha256(plan.replace('\n', '\r\n').encode()).hexdigest()))+'\r\n'}),
        ('code repetido idéntico', 'auditoria', {'veredicto-codigo.txt':verdict+verdict}),
        ('plan varias aprobaciones compatibles', 'plan-gate', {'veredicto-plan.txt':
            json.dumps(plan_obj)+json.dumps(dict(plan_obj, run_id='segunda-aprobacion'))}),
        ('code fragmento ilegible ajeno', 'auditoria', {'veredicto-codigo.txt':
            json.dumps(dict(code_obj, run_id='anterior', verdict='NO-GO')).replace('"verdict":', '"verdict":"NO-GO","verdict":')+'\n'+verdict}),
        ('plan fragmento ilegible ajeno', 'plan-gate', {'veredicto-plan.txt':
            json.dumps(dict(plan_obj, artifact_sha='c'*64, verdict='NO-GO')).replace('"verdict":', '"verdict":"NO-GO","verdict":')+'\n'+json.dumps(plan_obj)}),
        ('code llaves en prosa', 'auditoria', {'veredicto-codigo.txt':'Prosa { sin JSON.\n'+verdict+'\nOtra { llave.'}),
        ('plan llaves en prosa', 'plan-gate', {'veredicto-plan.txt':'Prosa { sin JSON.\n'+json.dumps(plan_obj)}),
        ('plan rechazo ajeno con objetos bloqueantes', 'plan-gate', {'veredicto-plan.txt':
            json.dumps(dict(plan_obj, artifact_sha='c'*64, verdict='NO-GO', blocking_findings=[plan_obj]))+'\n'+json.dumps(plan_obj)}),
        ('code rechazo ajeno con objetos bloqueantes', 'auditoria', {'veredicto-codigo.txt':
            json.dumps(dict(code_obj, run_id='anterior', verdict='NO-GO', blocking_findings=[code_obj]))+'\n'+verdict}),
    ]
    for typ, obj, stage in [('plan', plan_obj, 'plan-gate'), ('code', code_obj, 'auditoria')]:
        name = 'veredicto-plan.txt' if typ == 'plan' else 'veredicto-codigo.txt'
        key, other = ('artifact_sha', 'c'*64) if typ == 'plan' else ('run_id', 'anterior')
        positives.extend([
            (typ+' lista ajena demostrable', stage, {name:json.dumps([dict(obj, **{key:other})])+json.dumps(obj)}),
            (typ+' llaves de prosa no JSON', stage, {name:'{x} { tal } código citado { return 1; }\n'+json.dumps(obj)}),
            (typ+' prosa variada y verdict como valor', stage, {name:
                '[ ] [x] [guía](https://example.invalid) literal `{}` '+
                json.dumps({'nota':'verdict'})+'\n'+json.dumps(obj)}),
            (typ+' ronda anterior cortada por panel', stage, {name:
                json.dumps(dict(obj, verdict='NO-GO', **{key:other})).replace(
                    'artifact_type', 'artifact_\n  type')+'\n'+json.dumps(obj)}),
            ('R7-01 '+typ+' clave escapada ajena completa', stage, {name:
                json.dumps(dict(obj, verdict='NO-GO', **{key:other})).replace(
                    '"verdict"', r'"\u0076erdict"')+'\n'+json.dumps(obj)}),
        ])
        for label, prose in [
            ('regex', r'Veredicto: GO. La expresión regular `\[` reconoce el delimitador de apertura.'),
            ('token', 'El token `[` abre una lista.'),
            ('rangos', 'rangos [0, 5)'),
            ('tarea', '[x]'),
            ('numero', '[1] seguido de texto'),
            ('enlace', '[texto](https://example.invalid)'),
            ('pila fallida', '{"nota": [x],}'),
        ]:
            positives.append(('R5-01 '+typ+' '+label, stage, {name:prose+'\n'+json.dumps(obj)}))
    for label, stage, changes in positives:
        for name, content in changes.items():
            (state/'humo'/name).write_bytes(content.encode())
        provenance = state/'humo'/(stage+'-procedencia.json')
        row = json.loads(provenance.read_text())
        fixed = state/'humo'/('plan-normalizado.norm' if stage == 'plan-gate' else 'veredicto-codigo.txt')
        Path(row['artefacto']).write_bytes(fixed.read_bytes())
        row['sha256'] = hashlib.sha256(fixed.read_bytes()).hexdigest()
        row['auxiliares'] = {n:hashlib.sha256((state/'humo'/n).read_bytes()).hexdigest() for n in row['auxiliares']}
        provenance.write_text(json.dumps(row))
        checked = cli('check-F8', extra={'F8_LINEAR_STATE':'Done'})
        for suffix in ('-recibo.json', '-procedencia.json', '-artefacto.txt'):
            (state/'humo'/(stage+suffix)).unlink()
        (state/'humo/ciclo.json').unlink()
        received = cli('f8-recibo', stage, fixed, 'operador')
        built = cli('f8-ciclo')
        expect('positivo tres consumidores '+label, all(r[0] == 0 for r in (checked, received, built)),
               str((checked, received, built)))
        saved = state/'humo'/(stage+'-artefacto.txt')
        expect('bytes conservados '+label, saved.is_file() and saved.read_bytes() == fixed.read_bytes())
        expect('check generado '+label, cli('check-F8', extra={'F8_LINEAR_STATE':'Done'})[0] == 0)
        restore_positive()
    variants = [
        ('code dentro de objeto exterior', 'auditoria', 'veredicto-codigo.txt', json.dumps({'respuesta':code_obj})),
        ('plan dentro de objeto exterior', 'plan-gate', 'veredicto-plan.txt', json.dumps({'respuesta':plan_obj})),
        ('ejemplo sin auditor', 'auditoria', 'veredicto-codigo.txt', json.dumps({'artifact_sha':head,'verdict':'GO'})),
        ('tipo plan bloqueante', 'auditoria', 'veredicto-codigo.txt', json.dumps(dict(run_id=run_id, artifact_type='plan',artifact_sha=head,verdict='GO',blocking_findings=[{'severity':'BLOCKER'}]))),
        ('auditor otra issue', 'auditoria', 'veredicto-codigo.txt', verdict.replace('"verdict"', '"issue":"ABC-2","verdict"')),
        ('plan rechazado', 'plan-gate', 'plan-normalizado.norm', 'ABC-1\nVeredicto NO-GO\n'),
        ('veredicto plan ajeno', 'plan-gate', 'veredicto-plan.txt', 'ABC-2 auditoría GO\n'),
        ('plan otro digest', 'plan-gate', 'veredicto-plan.txt', (state/'humo/veredicto-plan.txt').read_text().replace(digest[:28], 'c'*28)),
        ('issue ajena con referencia', 'issue', 'issue.json', json.dumps({'data':{'issue':{'identifier':'ABC-2','title':'Relacionado con ABC-1','createdAt':'2026-10-04T12:00:00Z'}}})),
        ('registro ausente', 'auditoria', 'audit-last.env', None),
        ('registro otro run', 'auditoria', 'audit-last.env', (state/'humo/audit-last.env').read_text().replace(run_id, 'otro-run')),
        ('registro otro head', 'auditoria', 'audit-last.env', (state/'humo/audit-last.env').read_text().replace(head, 'c'*40)),
        ('registro tipo plan', 'auditoria', 'audit-last.env', (state/'humo/audit-last.env').read_text().replace('TYP=code', 'TYP=plan')),
        ('code bloqueante', 'auditoria', 'veredicto-codigo.txt', verdict.replace('"blocking_findings":[]', '"blocking_findings":[{"severity":"BLOCKER"}]')),
        ('code vigente contradictorio', 'auditoria', 'veredicto-codigo.txt', verdict+verdict.replace('"GO"', '"NO-GO"')),
        ('plan vigente contradictorio', 'plan-gate', 'veredicto-plan.txt', json.dumps(plan_obj)+json.dumps(dict(plan_obj, verdict='NO-GO'))),
        ('plan vigente bloqueante', 'plan-gate', 'veredicto-plan.txt', json.dumps(dict(plan_obj, blocking_findings=[{'severity':'BLOCKER'}]))),
        ('code clave repetida', 'auditoria', 'veredicto-codigo.txt', json.dumps(code_obj).replace('"verdict":', '"verdict":"GO","verdict":')),
        ('code JSON incompleto', 'auditoria', 'veredicto-codigo.txt', json.dumps(code_obj)[:-1]),
        ('code bloqueantes con GO anidado', 'auditoria', 'veredicto-codigo.txt',
            json.dumps(dict(code_obj, blocking_findings=[code_obj]))),
        ('informe otro commit', 'codigo', 'informe-parada.md', (state/'humo/informe-parada.md').read_text().replace(head, 'c'*40)),
        ('merge otra fusión', 'merge', 'merge.json', json.dumps(dict(pr, mergeCommit={'oid':'c'*40}))),
        ('informe sin cabecera', 'codigo', 'informe-parada.md', 'ABC-1 '+head),
        ('merge otro PR', 'merge', 'merge.json', json.dumps(dict(pr, number=2))),
        ('Done otro estado', 'Done', 'issue-done.json', (state/'humo/issue-done.json').read_text().replace('Done', 'Todo')),
    ]
    for label, stage, name, content in variants:
        path = state/'humo'/name
        if content is None:
            path.unlink()
        else:
            path.write_text(content)
        check = cli('check-F8', extra={'F8_LINEAR_STATE':'Done'})
        for suffix in ('-recibo.json', '-procedencia.json', '-artefacto.txt'):
            (state/'humo'/(stage+suffix)).unlink(missing_ok=True)
        (state/'humo/ciclo.json').unlink()
        cycle_result = cli('f8-ciclo')
        expect('variante roja '+label, check[0] == 1 and cycle_result[0] == 1, str((check, cycle_result)))
        shutil.rmtree(state/'humo')
        shutil.copytree(baseline, state/'humo')
        expect('restauración verde '+label, cli('check-F8', extra={'F8_LINEAR_STATE':'Done'})[0] == 0)
    # Reproducciones con sellos coherentes: el rojo debe ser semántico en los tres consumidores.
    reproductions = [
        ('R3-01 plan rechazo cortado GO antiguo', 'plan-gate', json.dumps(plan_obj)+'\n'+
            json.dumps(dict(plan_obj, run_id='rechazo-vigente', verdict='NO-GO'))[:-1]),
        ('R3-01 code rechazo cortado', 'auditoria', json.dumps(code_obj)+'\n'+
            json.dumps(dict(code_obj, verdict='NO-GO'))[:-1]),
        ('R3-01 duplicado rechazo con GO', 'plan-gate', json.dumps(plan_obj)+'\n'+
            json.dumps(dict(plan_obj, verdict='NO-GO')).replace('"verdict":', '"verdict":"GO","verdict":')),
        ('R3-02 code ejemplo anidado', 'auditoria', json.dumps({
            'nota':'No se ejecutó auditoría. Ejemplo de plantilla únicamente.', 'ejemplo':code_obj})),
        ('R3-02 plan ejemplo anidado', 'plan-gate', json.dumps({
            'nota':'No se aprobó el plan. Ejemplo de plantilla únicamente.', 'ejemplo':plan_obj})),
        ('ilegible sin vínculo completo', 'plan-gate', json.dumps(plan_obj)+'\n{"verdict":"NO-GO",'),
        ('ilegible run sin comilla final', 'auditoria', json.dumps(code_obj)+'\n{"verdict":"NO-GO","run_id":"anterior'),
        ('ilegible hash truncado', 'plan-gate', json.dumps(plan_obj)+'\n{"verdict":"NO-GO","artifact_sha":"'+('c'*63)+'"'),
        ('ilegible antes de aprobación', 'plan-gate', json.dumps(dict(plan_obj, verdict='NO-GO'))[:-1]+'\n'+json.dumps(plan_obj)),
    ]
    for typ, obj, stage in [('plan', plan_obj, 'plan-gate'), ('code', code_obj, 'auditoria')]:
        go = json.dumps(obj)
        rejection = dict(obj, verdict='NO-GO')
        key, other = ('artifact_sha', 'c'*64) if typ == 'plan' else ('run_id', 'anterior')
        repeated_links = [(key, other)]
        if typ == 'plan':
            repeated_links.append(('artifact_type', 'otro'))
        for link_key, foreign in repeated_links:
            for order, values in [('vigente-ajeno', [obj[link_key], foreign]),
                                  ('ajeno-vigente', [foreign, obj[link_key]])]:
                repeated = json.dumps(rejection).replace(
                    json.dumps(link_key)+': '+json.dumps(obj[link_key]),
                    ', '.join(json.dumps(link_key)+': '+json.dumps(value) for value in values))
                reproductions.append(('R8-01 '+typ+' '+link_key+' '+order, stage, repeated+'\n'+go))
        for label, note in [('vacio', {}), ('nota', {'a':1})]:
            for place in ('antes', 'despues'):
                bad = dict(nota=note, **rejection) if place == 'antes' else dict(rejection, nota=note)
                reproductions.append(('R4-01 '+typ+' '+label+' '+place, stage, go+'\n'+json.dumps(bad)[:-1]))
        reproductions.extend([
            ('R7-01 '+typ+' clave Unicode rechazo', stage,
                json.dumps(rejection).replace('"verdict"', r'"\u0076erdict"')+'\n'+go),
            ('R7-01 '+typ+' clave totalmente escapada rechazo', stage,
                json.dumps(rejection).replace('"verdict"',
                    r'"\u0076\u0065\u0072\u0064\u0069\u0063\u0074"')+'\n'+go),
            ('R7-02 '+typ+' contenedor repetido GO', stage,
                '{"x":0,"x":1,"ejemplo":'+go+'}'),
            ('lista vigente '+typ, stage, json.dumps([obj])),
            ('lista vigente tras GO '+typ, stage, go+'\n'+json.dumps([obj])),
            ('lista vigente con espacios '+typ, stage, '[ \n '+go+']'),
            ('lista vigente sin cierre con espacios '+typ, stage, '[ \n '+go),
            ('residuo verdict '+typ, stage, go+'\n"verdict":"NO-GO"'),
            ('ilegible ajeno sin cierre '+typ, stage, json.dumps(dict(rejection, **{key:other}))[:-1]+'\n'+go),
            (typ+' veredicto anidado en objeto legible', stage,
                json.dumps({'ejemplo':rejection})+go),
            ('portador NO-GO en objeto ajeno '+typ, stage,
                json.dumps(dict(obj, **{key:other}, ejemplo=rejection))+go),
            ('portador NO-GO lista en prosa '+typ, stage,
                'Prosa [ '+json.dumps(rejection)+' ] fin.\n'+go),
            ('portador GO seguido de ejemplo NO-GO '+typ, stage,
                go+json.dumps({'ejemplo':rejection})),
            ('lista escalar GO solo '+typ, stage, json.dumps([0, obj])),
        ])
        for scalar in (0, 'texto'):
            for label, bad in [('directo', rejection), ('anidado', {'x':rejection})]:
                reproductions.append(('R6-01 '+typ+' '+repr(scalar)+' '+label, stage,
                                      json.dumps([scalar, bad, obj])))
    for label, stage, content in reproductions:
        fixed = state/'humo'/('veredicto-codigo.txt' if stage == 'auditoria' else 'plan-normalizado.norm')
        (state/'humo'/('veredicto-codigo.txt' if stage == 'auditoria' else 'veredicto-plan.txt')).write_text(content)
        provenance = state/'humo'/(stage+'-procedencia.json')
        row = json.loads(provenance.read_text())
        (state/'humo'/(stage+'-artefacto.txt')).write_bytes(fixed.read_bytes())
        row['sha256'] = hashlib.sha256(fixed.read_bytes()).hexdigest()
        row['auxiliares'] = {n:hashlib.sha256((state/'humo'/n).read_bytes()).hexdigest() for n in row['auxiliares']}
        provenance.write_text(json.dumps(row))
        checked = cli('check-F8', extra={'F8_LINEAR_STATE':'Done'})
        for suffix in ('-recibo.json', '-procedencia.json', '-artefacto.txt'):
            (state/'humo'/(stage+suffix)).unlink()
        (state/'humo/ciclo.json').unlink()
        received = cli('f8-recibo', stage, fixed, 'operador')
        built = cli('f8-ciclo')
        print('REPRODUCCION '+label+' rc='+str([r[0] for r in (checked, received, built)]), flush=True)
        for result in (checked, received, built):
            print(result[1], flush=True)
        expected = ('veredicto sin vínculo' if label.startswith('R3-02') else
                    'veredicto contradictorio' if label.startswith(('R7-01', 'R6-01', 'portador NO-GO',
                    'portador GO seguido', 'plan veredicto anidado', 'code veredicto anidado')) else
                    'veredicto ilegible')
        expect('rojo tres consumidores '+label, all(r[0] == 1 and expected in r[1]
               for r in (checked, received, built)), str((checked, received, built)))
        restore_positive()
        expect('restauración verde '+label, cli('check-F8', extra={'F8_LINEAR_STATE':'Done'})[0] == 0)
    # Solo acredita el objeto que coincide con el registro; otro GO compatible no lo sustituye.
    multiple = verdict.replace(run_id, 'tco_1234567800_abcdef123456')+verdict
    (state/'humo/veredicto-codigo.txt').write_text(multiple)
    for suffix in ('-recibo.json', '-procedencia.json', '-artefacto.txt'):
        (state/'humo'/('auditoria'+suffix)).unlink()
    (state/'humo/ciclo.json').unlink()
    expect('varios objetos seleccionan registro vigente', cli('f8-ciclo')[0] == 0 and
           cli('check-F8', extra={'F8_LINEAR_STATE':'Done'})[0] == 0)
    shutil.rmtree(state/'humo')
    shutil.copytree(baseline, state/'humo')
    for name in ('merge.json', 'issue-done.json'):
        (state/'humo'/name).unlink()
    rc, output = cli('f8-originales', 'ABC-1', '1', extra={'F8_LINEAR_STATE':'Done', 'F8_LINEAR_TITLE':'Título corregido'})
    expect('título mutable conserva inicial y final', rc == 0 and (state/'humo/issue.json').read_bytes() == initial and
           json.loads((state/'humo/issue-done.json').read_text())['data']['issue']['title'] == 'Título corregido', output)
    for key in ('number', 'state', 'headRefOid', 'mergeCommit', 'body', 'files', 'statusCheckRollup'):
        for name in ('merge.json', 'issue-done.json'):
            (state/'humo'/name).unlink(missing_ok=True)
        changed = dict(pr)
        del changed[key]
        pr_path.write_text(json.dumps(changed))
        rc, output = cli('f8-originales', 'ABC-1', '1', extra={'F8_LINEAR_STATE':'Done'})
        expect('respuesta parcial sin escritura '+key, rc == 1 and 'merge.json' in output and key in output and
               not (state/'humo/merge.json').exists() and not (state/'humo/issue-done.json').exists(), output)
        changed[key] = None
        pr_path.write_text(json.dumps(changed))
        rc, output = cli('f8-originales', 'ABC-1', '1', extra={'F8_LINEAR_STATE':'Done'})
        expect('tipo inválido sin escritura '+key, rc == 1 and 'merge.json' in output and key in output and
               not (state/'humo/merge.json').exists() and not (state/'humo/issue-done.json').exists(), output)
    pr_path.write_text(json.dumps(pr))
    shutil.rmtree(state/'humo')
    shutil.copytree(baseline, state/'humo')
    curl_saved = (binpath/'curl').read_bytes()
    for identifier in (None, '', 7):
        row = dict(title='Documento', createdAt='2026-10-04T12:00:00Z', state={'name':'Done'})
        if identifier is not None:
            row['identifier'] = identifier
        payload = json.dumps({'data':{'issue':row}})
        (binpath/'curl').write_text('#!/usr/bin/env python3\nprint('+repr(payload)+')\n')
        for name in ('merge.json', 'issue-done.json'):
            (state/'humo'/name).unlink(missing_ok=True)
        rc, output = cli('f8-originales', 'ABC-1', '1')
        expect('Linear identifier parcial '+repr(identifier), rc == 1 and 'data.issue.identifier' in output and
               not (state/'humo/merge.json').exists() and not (state/'humo/issue-done.json').exists(), output)
        restore_positive()
    (binpath/'curl').write_bytes(curl_saved)
    for key in ('headRefOid', 'state', 'mergeCommit', 'body'):
        for invalid in ('ausente', 'tipo'):
            for suffix in ('-recibo.json', '-procedencia.json', '-artefacto.txt'):
                (state/'humo'/('issue'+suffix)).unlink(missing_ok=True)
            changed = dict(pr)
            if invalid == 'ausente':
                del changed[key]
            else:
                changed[key] = None
            pr_path.write_text(json.dumps(changed))
            rc, output = cli('f8-recibo', 'issue', state/'humo/issue.json', 'operador')
            expect('consulta parcial de recibo sin escritura '+key+' '+invalid,
                   rc == 1 and key in output and 'issue.json' in output and
                   not any((state/'humo'/('issue'+s)).exists() for s in
                           ('-recibo.json', '-procedencia.json', '-artefacto.txt')), output)
            shutil.rmtree(state/'humo')
            shutil.copytree(baseline, state/'humo')
    pr_path.write_text(json.dumps(pr))
    # Mismo artefacto evaluado por recibo y check; recalcular digest no oculta un rojo.
    artifact = state/'humo/auditoria-artefacto.txt'
    provenance = state/'humo/auditoria-procedencia.json'
    original_record = provenance.read_bytes()
    import hashlib
    for label, bad in [('otro commit', verdict.replace(head[:28], 'b'*28)),
                       ('NO-GO', verdict.replace('"GO"', '"NO-GO"')),
                       ('SHA truncado', verdict.replace(head[28:], head[28:-1]))]:
        source = t/'veredicto.txt'
        source.write_text(bad)
        rc, output = cli('f8-recibo', 'auditoria', source, 'auditor')
        expect('recibo rechaza '+label, rc == 1 and 'auditoria' in output and str(source) in output, output)
        artifact.write_text(bad)
        (state/'humo/veredicto-codigo.txt').write_text(bad)
        record = json.loads(original_record)
        record['sha256'] = hashlib.sha256(artifact.read_bytes()).hexdigest()
        provenance.write_text(json.dumps(record))
        expect('check rechaza '+label+' aun con digest correcto', cli('check-F8', extra={'F8_LINEAR_STATE':'Done'})[0] == 1)
    artifact.write_text(verdict)
    (state/'humo/veredicto-codigo.txt').write_text(verdict)
    provenance.write_bytes(original_record)
    expect('verde después de revertir mutaciones', cli('check-F8', extra={'F8_LINEAR_STATE':'Done'})[0] == 0)
    (imported/'busy.txt').write_text(screens['idle'])
    before = conf.read_bytes()
    rc, output = cli('calibrar-pane', clone, imported, '--registrar')
    expect('calibración roja no escribe registro', rc == 1 and conf.read_bytes() == before, output)
    rc, output = cli('f8-importar', '--repetir-capturas', data=archive([
        ('pane/claude_9.8.7/busy.txt', screens['idle'].encode(), 'file')]))
    expect('reimportación incompleta rechaza sin sustituir', rc == 1 and 'repetición rechazada' in output, output)
    # Lint real y orden documentado; cada CLI citado también se ejercita arriba.
    guide = pkg/'instalacion/fases/F8.md'
    rc, output = cli('lint-md', guide)
    expect('guía comandos y modos existentes', rc == 0, output)
    sequence = re.findall(r'^\d+\. \*\*Persona', guide.read_text(), re.M)
    expect('guía secuencia única once pasos', len(sequence) == 11 and [int(s.split('.')[0]) for s in sequence] == list(range(1,12)))
    commands = re.findall(r'\bbash "\$PKG/instalacion/scripts/([^"\n]+)\.sh"', guide.read_text())
    expect('guía órdenes en el orden ejercitado', commands == [
        'f8-originales', 'f8-encargos', 'f8-conservar', 'f8-handoff', 'f8-encargos', 'f8-originales',
        'f8-capturas', 'f8-capturas', 'f8-capturas', 'capturar-done', 'f8-capturas',
        'calibrar-pane', 'f8-importar', 'calibrar-pane', 'f8-ciclo', 'check-F8'])
    text = guide.read_text()
    expect('guía reposo y ocupado medidos', 'teclear /clear' in text and 'Ctrl+L' not in text and
           'python3 -c "import time; time.sleep(40)"' in text and '6 segundos' in text)
    expect('guía acceso canal y desacople conservan sesión',
           '''incus exec "$CONTENEDOR" -- su - "$CUSER" -c 'tmux attach -t v' '''.strip() in text and
           'usuario_incus=' in text and 'cuser=' in text and 'Ctrl-b d' in text)

TOTAL_ESPERADO = 378
expect('conteo permanente', PASS+FAIL == TOTAL_ESPERADO, str(PASS+FAIL))
print(f'RESULTADO: PASS={PASS} FAIL={FAIL} TOTAL={PASS+FAIL}')
raise SystemExit(1 if FAIL else 0)
