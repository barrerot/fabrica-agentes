"""Recibos del ciclo sobre artefactos existentes, con rutas definitivas."""
import hashlib
import getpass
import json
import os
from pathlib import Path
import re

from fases import STATE, Error, regular, require, run, selected_handoff, write, safe_dir

OUTCOMES = dict(zip(('issue', 'plan-gate', 'codigo', 'auditoria', 'handoff', 'merge', 'Done'),
                    ('CREADA', 'GO', 'DOCS', 'GO', 'PASS', 'MERGED', 'Done')))
ORIGINALS = {'issue':'issue.json', 'plan-gate':'plan-normalizado.norm',
             'codigo':'informe-parada.md', 'auditoria':'veredicto-codigo.txt',
             'merge':'merge.json', 'Done':'issue-done.json'}


def binding(c):
    issue, number = os.environ.get('F8_ISSUE', ''), os.environ.get('F8_PR', '')
    require(re.fullmatch(re.escape(c['answers']['linear_clave'])+r'-[1-9][0-9]*', issue) and
            re.fullmatch(r'[1-9][0-9]*', number), 'recibo: declarar F8_ISSUE y F8_PR', 2)
    slug = c['answers']['repo_url'].split('github.com/', 1)[1].removesuffix('.git')
    pr = json.loads(run(['gh', 'pr', 'view', number, '--repo', slug, '--json', 'headRefOid,state,mergeCommit,body']))
    require(isinstance(pr, dict), 'recibo: PR respuesta parcial: objeto')
    for key in ('headRefOid', 'state', 'body'):
        require(isinstance(pr.get(key), str), 'recibo: PR respuesta parcial: '+key)
    require(pr['state'] in ('OPEN', 'CLOSED', 'MERGED'), 'recibo: PR state inválido')
    require('mergeCommit' in pr and (pr['mergeCommit'] is None or isinstance(pr['mergeCommit'], dict)),
            'recibo: PR respuesta parcial: mergeCommit')
    require((pr['mergeCommit'] is None and pr['state'] != 'MERGED') or
            (isinstance(pr['mergeCommit'], dict) and isinstance(pr['mergeCommit'].get('oid'), str) and
             re.fullmatch(r'[0-9a-f]{40}', pr['mergeCommit']['oid'])),
            'recibo: PR respuesta parcial: mergeCommit.oid')
    require(re.fullmatch(r'[0-9a-f]{40}', pr.get('headRefOid', '')), 'recibo: head inválido')
    require(re.search(r'(?i)\b(?:closes|fixes|resolves)\s+'+re.escape(issue)+r'\b', pr.get('body', '')),
            'recibo: PR no liga la issue')
    return {'issue':issue, 'pr':int(number), 'head':pr['headRefOid']}, pr


def immutable(path, content):
    require(not any(p.is_symlink() for p in (path, *path.parents)), 'recibo: destino enlazado '+str(path))
    if path.exists() or path.is_symlink():
        require(regular(path).read_bytes() == content, 'recibo: destino existente distinto '+str(path))
    else:
        write(path, content.decode())


def receipt(c, args):
    require(len(args) == 3 and args[0] in OUTCOMES and args[2].strip(), 'uso f8-recibo ETAPA ARTEFACTO AUTOR', 2)
    try:
        return receipt_artifact(c, args)
    except Error as exc:
        raise Error('recibo: etapa '+args[0]+' fichero '+args[1]+': '+str(exc), exc.rc) from None
    except (OSError, ValueError, KeyError, TypeError):
        raise Error('recibo: etapa '+args[0]+' fichero '+args[1]+': datos ilegibles o formato inválido') from None


def receipt_artifact(c, args):
    require(len(args) == 3 and args[0] in OUTCOMES and args[2].strip(), 'uso f8-recibo ETAPA ARTEFACTO AUTOR', 2)
    stage, name, author = args
    try:
        source = regular(Path(name))
    except Error as exc:
        raise Error('recibo: etapa '+stage+' fichero '+name+': '+str(exc)) from None
    require(source.is_absolute() and not any(p.is_symlink() for p in source.parents), 'recibo: ruta original insegura')
    content = source.read_bytes()
    data, pr = binding(c)
    from originales import validate, auxiliaries
    validate(content.decode(), stage, data['issue'], data['head'], data['pr'], merge=(pr.get('mergeCommit') or {}).get('oid'))
    directory = STATE/'humo'
    safe_dir(directory)
    require(not any(p.is_symlink() for p in (directory, *directory.parents)), 'recibo: directorio inseguro')
    if stage == 'handoff':
        evidence = selected_handoff(data['issue'], data['pr'], data['head'])
        require(source == evidence, 'recibo: handoff debe ser el registro del verificador real')
    else:
        artifact = directory/(stage+'-artefacto.txt')
        evidence = directory/(stage+'-procedencia.json')
        record = dict(data, resultado=OUTCOMES[stage], autor=author, artefacto=str(artifact),
                      sha256=hashlib.sha256(content).hexdigest(), auxiliares=auxiliaries(stage))
        immutable(artifact, content)
        immutable(evidence, (json.dumps(record, ensure_ascii=False, sort_keys=True)+'\n').encode())
    receipt_path = directory/(stage+'-recibo.json')
    record = dict(data, resultado=OUTCOMES[stage], evidencia=str(evidence))
    immutable(receipt_path, (json.dumps(record, ensure_ascii=False, sort_keys=True)+'\n').encode())
    print(receipt_path)


def cycle_stage(c, data, stage, outcome, merge):
    file = STATE/'humo'/(stage+'-recibo.json')
    diagnostic_file = file
    try:
        if not file.exists() and not file.is_symlink():
            diagnostic_file = STATE/'humo'/ORIGINALS.get(stage, 'handoff-verificado.json')
            source = (selected_handoff(data['issue'], data['pr'], data['head']) if stage == 'handoff'
                      else diagnostic_file)
            receipt(c, [stage, str(source), os.environ.get('F8_AUTOR', '') or getpass.getuser()])
        record = json.loads(regular(file).read_text())
        require(all(record.get(k) == v for k, v in data.items()) and record.get('resultado') == outcome,
                'etapa de otro ciclo')
        diagnostic_file = Path(record['evidencia'])
        provenance = json.loads(regular(diagnostic_file).read_text())
        require(all(provenance.get(k) == v for k, v in data.items()) and provenance.get('resultado') == outcome,
                'procedencia de otro ciclo')
        diagnostic_file = Path(provenance['artefacto'])
        artifact = regular(diagnostic_file)
        require(hashlib.sha256(artifact.read_bytes()).hexdigest() == provenance['sha256'], 'artefacto alterado')
        from originales import validate
        validate(artifact.read_text(), stage, data['issue'], data['head'], data['pr'],
                 provenance.get('auxiliares', {}) if stage == 'handoff' else provenance.get('auxiliares'), merge)
        require(stage == 'handoff' or isinstance(provenance.get('auxiliares'), dict), 'auxiliares sin sello')
    except Error as exc:
        raise Error('recibo: etapa '+stage+' fichero '+str(diagnostic_file)+': '+str(exc), exc.rc) from None
    except (OSError, ValueError, KeyError, TypeError):
        raise Error('recibo: etapa '+stage+' fichero '+str(diagnostic_file)+': datos ilegibles o formato inválido') from None
    return {'etapa':stage, 'archivo':file.name, 'sha256':hashlib.sha256(file.read_bytes()).hexdigest()}


def cycle(c, args):
    try:
        return cycle_build(c, args)
    except Error as exc:
        raise Error('recibo: etapa ciclo fichero '+str(STATE/'humo/ciclo.json')+': '+str(exc), exc.rc) from None
    except (OSError, ValueError, KeyError, TypeError):
        raise Error('recibo: etapa ciclo fichero '+str(STATE/'humo/ciclo.json')+': datos ilegibles o formato inválido') from None


def cycle_build(c, args):
    require(not args, 'uso f8-ciclo sin argumentos', 2)
    data, pr = binding(c)
    require(pr.get('state') == 'MERGED' and re.fullmatch(r'[0-9a-f]{40}', (pr.get('mergeCommit') or {}).get('oid', '')),
            'recibo: merge no confirmado')
    rows = []
    for stage, outcome in OUTCOMES.items():
        rows.append(cycle_stage(c, data, stage, outcome, pr['mergeCommit']['oid']))
    data.update(merge=pr['mergeCommit']['oid'], etapas=rows)
    immutable(STATE/'humo/ciclo.json', (json.dumps(data, ensure_ascii=False, indent=2)+'\n').encode())
    print(STATE/'humo/ciclo.json')
