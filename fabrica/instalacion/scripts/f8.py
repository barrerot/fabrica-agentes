"""Encargos y originales públicos del ensayo; secretos únicamente en escrow."""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import shlex
import tempfile

from fases import ROOT, STATE, require, run, safe_dir, secret_values, channels, write, regular
from recibos import immutable


def arguments(c, args):
    parser = argparse.ArgumentParser()
    parser.add_argument('issue')
    parser.add_argument('pr', nargs='?')
    parser.add_argument('--linea-pr', default='')
    ns = parser.parse_args(args)
    require(re.fullmatch(re.escape(c['answers']['linear_clave'])+r'-[1-9][0-9]*', ns.issue),
            'F8: issue inválida', 2)
    require(ns.pr is None or re.fullmatch(r'[1-9][0-9]*', ns.pr), 'F8: PR inválido', 2)
    require(not any(x in ns.linea_pr for x in '\r\n\x00'), 'F8: línea PR inválida', 2)
    return ns


def assignments(c, args):
    ns = arguments(c, args)
    channel = channels(c)[0]
    lane = channel.removeprefix('vibe-channel-')
    preserve = shlex.join(['bash', str(ROOT/'instalacion/scripts/f8-conservar.sh'), ns.issue, c['project'], lane])
    if ns.pr:
        print(f'Estación de merge: consume el PR {ns.pr} de {ns.issue} en el proyecto {c["project"]}. '
              'El instalador ya conservó el handoff del borrador. Usa los gates AND de talent-merger, '
              'ejecuta una pasada del revisor y atiende su resultado. Fusiona únicamente con todos '
              'los gates verdes y el mismo head verificado. Completa la issue en Done tras la fusión. '
              'Sella hitos y bloqueos en el bus con tu identidad; ante rojo, sella y detente.')
        return
    print(f'Coordinador: lleva {ns.issue} del proyecto {c["project"]} hasta un PR en borrador con '
          f'entrega validada. Despacha tú con dispatch.sh al carril {lane} (contenedor {channel}), '
          'desde tu clon de producto y tu identidad. Código solo tras plan-gate GO. '
          'Al terminar, ejecuta '+preserve+' desde tu identidad. '
          'El ayudante conserva plan-normalizado.norm y audit-last.env sin modificar los registros del skill. '
          'Conserva íntegros, sin redactar, en $HOME/evidencias-fabrica/' + c['project'] + '/humo '
          'los otros originales de nombre fijo: '
          'veredicto-plan.txt (veredicto de su auditoría), informe-parada.md (informe de parada '
          'del desarrollador) y veredicto-codigo.txt (veredicto final de auditoría de código). '
          'El informe exige cabecera STOP-AUDIT — '+ns.issue+' y SHA auditado: seguido del head completo. Conserva ambos JSON del auditor '
          'con run_id, artifact_type, artifact_sha completo, verdict y blocking_findings, '
          'incluido el veredicto code cuyo run_id casa con audit-last.env. Valida el handoff con los gates del producto mientras '
          'el PR sigue en borrador. Devuelve su número y espera a que el instalador conserve '
          'f8-handoff. No fusiones ni retires el borrador. Sella hitos y bloqueos en el bus; '
          'ante rojo, sella y detente.')
    if ns.linea_pr:
        print('Opción declarada por la persona: incluye exactamente como última línea del cuerpo del PR:')
        print(ns.linea_pr)
    else:
        print('Opción --linea-pr no declarada: antes de retirar el borrador, la persona debe '
              'desactivar la revisión automática de la App o aceptar explícitamente el gasto adicional.')


def linear(c, issue):
    token = secret_values(c).get('LINEAR_API_KEY')
    require(token and not any(x in token for x in '\r\n'), 'originales: token Linear missing')
    safe_dir(c['escrow'])
    fd, name = tempfile.mkstemp(dir=c['escrow'])
    os.close(fd)
    try:
        write(Path(name), 'Authorization: '+token+'\n')
        body = run(['curl', '--fail', '--silent', '--show-error', '--max-time', '30',
                    '--header', '@'+name, '--header', 'Content-Type: application/json',
                    '--data', json.dumps({'query':'query($id:String!){issue(id:$id){identifier title createdAt state{name}}}',
                                          'variables':{'id':issue}}), 'https://api.linear.app/graphql'],
                   diagnostic='originales: issue.json/issue-done.json consulta Linear fallida')
        data = json.loads(body)
    finally:
        Path(name).unlink(missing_ok=True)
    require(isinstance(data, dict) and isinstance(data.get('data'), dict) and
            isinstance(data['data'].get('issue'), dict),
            'originales: issue.json/issue-done.json respuesta parcial: data.issue o errores')
    record = data['data']['issue']
    require(isinstance(record.get('identifier'), str) and record['identifier'].strip(),
            'originales: issue.json/issue-done.json respuesta parcial: data.issue.identifier')
    require(not data.get('errors') and record.get('identifier') == issue,
            'originales: issue.json/issue-done.json respuesta de otra issue o errores')
    initial_issue(record)
    require(isinstance(record.get('state'), dict) and isinstance(record['state'].get('name'), str) and
            record['state']['name'].strip(), 'originales: issue.json/issue-done.json respuesta parcial: state.name')
    return body, data['data']['issue']


def initial_issue(issue):
    require(isinstance(issue.get('title'), str) and issue['title'].strip() and
            isinstance(issue.get('createdAt'), str) and
            re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})', issue['createdAt']),
            'originales: etapa issue fichero issue.json respuesta parcial: título/fecha de creación')
    try:
        datetime.fromisoformat(issue['createdAt'].replace('Z', '+00:00'))
    except ValueError:
        require(False, 'originales: etapa issue fichero issue.json fecha de creación inválida')
    return {key: issue[key] for key in ('identifier', 'title', 'createdAt')}


def save_initial(directory, issue):
    # La creación se acredita independientemente del estado al consultar.
    path = directory/'issue.json'
    identity = initial_issue(issue)
    if path.exists() or path.is_symlink():
        old = json.loads(regular(path).read_text())
        prior = initial_issue((old.get('data') or {}).get('issue') or {})
        require(all(prior[key] == identity[key] for key in ('identifier', 'createdAt')),
                'originales: etapa issue fichero issue.json consulta inicial distinta')
    else:
        immutable(path, (json.dumps({'data': {'issue': identity}}, ensure_ascii=False)+'\n').encode())


def originals(c, args):
    ns = arguments(c, args)
    require(not ns.linea_pr, 'originales: --linea-pr solo para encargos', 2)
    directory = STATE/'humo'
    safe_dir(STATE)
    safe_dir(directory)
    body, issue = linear(c, ns.issue)
    if ns.pr is None:
        save_initial(directory, issue)
        print(directory/'issue.json')
        return
    require(issue.get('state', {}).get('name') == 'Done', 'originales: etapa Done fichero issue-done.json no está Done')
    slug = c['answers']['repo_url'].split('github.com/', 1)[1].removesuffix('.git')
    pr_body = run(['gh', 'pr', 'view', ns.pr, '--repo', slug, '--json',
                   'number,state,headRefOid,mergeCommit,body,files,statusCheckRollup'],
                  diagnostic='originales: etapa merge fichero merge.json consulta GitHub fallida')
    pr = json.loads(pr_body)
    from originales import pr_record
    pr_record(pr, ns.issue, number=int(ns.pr))
    require(pr.get('state') == 'MERGED' and re.fullmatch(r'[0-9a-f]{40}', pr.get('headRefOid', '')) and
            re.fullmatch(r'[0-9a-f]{40}', (pr.get('mergeCommit') or {}).get('oid', '')) and
            re.search(r'(?i)\b(?:closes|fixes|resolves)\s+'+re.escape(ns.issue)+r'\b', pr.get('body', '')),
            'originales: etapa merge fichero merge.json sin fusión/head/vínculo')
    save_initial(directory, issue)
    immutable(directory/'merge.json', pr_body.encode())
    immutable(directory/'issue-done.json', body.encode())
    print('originales conservados: merge.json issue-done.json')
