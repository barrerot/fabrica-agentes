"""Esquemas y vínculos de los originales del ciclo, compartidos por sus consumidores."""
import hashlib
from datetime import datetime
import json
import re
from fases import STATE, regular, require


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError('clave JSON repetida')
        value[key] = item
    return value


def normalized_text(text):
    # Solo la lectura semántica tolera CRLF; los sellos conservan los bytes.
    return text.replace('\r\n', '\n')


class StructuralObject(dict):
    def __init__(self, pairs):
        super().__init__(pairs)
        self.pairs = pairs

    def values_for(self, key):
        return [value for name, value in self.pairs if name == key]


def verdicts(text, fragments=None, carriers=None):
    # Un corte del panel puede dividir cualquier token, incluso un escape.
    text = re.sub(r'\r?\n[ \t]*', '', text)
    # La estructura conserva el encierro aunque la validación rechace duplicados.
    decoder = json.JSONDecoder(object_pairs_hook=unique_object)
    structural = json.JSONDecoder(object_pairs_hook=StructuralObject)
    decoded = {}
    failures = {}
    duplicates = set()
    for opening in re.finditer(r'[\{\[]', text):
        start = opening.start()
        try:
            value, end = structural.raw_decode(text, start)
        except json.JSONDecodeError as error:
            failures[start] = (error.pos, error.msg)
        else:
            if isinstance(value, (dict, list)):
                decoded[start] = (value, end)
                try:
                    decoder.raw_decode(text, start)
                except ValueError:
                    duplicates.add(start)
    found = {}
    illegible = []
    for key in re.finditer(r'("(?:[^"\\]|\\.)*")\s*:', text):
        try:
            is_verdict = json.loads(key.group(1)) == 'verdict'
        except ValueError:
            is_verdict = 'verdict' in key.group(1).replace('\\', '')
        if not is_verdict:
            continue
        position = key.start()
        for start in reversed(decoded):
            value, end = decoded[start]
            if start < position < end and isinstance(value, dict):
                if 'verdict' in value:
                    found[start] = (value, end)
                else:
                    illegible.append(position)
                break
        else:
            illegible.append(position)
    if fragments is not None:
        for position in illegible:
            left = max((end for _, end in found.values() if end <= position), default=0)
            right = min((start for start in found if start > position), default=len(text))
            fragments.append(text[left:right])
    rows = []
    for start, (value, end) in sorted(found.items()):
        enclosed = [outer for begin, (outer, finish) in decoded.items()
                    if begin < start and finish >= end]
        # El parser que alcanza el portador y falla demuestra
        # un fragmento incompleto; no se adivinan aperturas ni se recorren pilas.
        incomplete = any(begin < start and (position >= end or
                         (position == start and message == "Expecting ',' delimiter"))
                         for begin, (position, message) in failures.items())
        rows.append((value, bool(enclosed) or incomplete,
                     (any(isinstance(outer, list) for outer in enclosed) and
                      not any(isinstance(outer, dict) for outer in enclosed)) or incomplete,
                     any(begin <= start and decoded[begin][1] >= end for begin in duplicates)))
    if carriers is not None:
        carriers.extend(rows)
    return [value for value, _, _, _ in rows]


def approval(text, typ, digest, issue, run_id=None):
    fragments = []
    carriers = []
    verdicts(text, fragments, carriers)
    for fragment in fragments:
        # Todas las apariciones, incluidas las escapadas, ya fueron clasificadas.
        # Solo un vínculo completo y distinto demuestra que la ronda es ajena.
        pattern = (r'"run_id"\s*:\s*("(?:[^"\\]|\\.)*")' if run_id is not None
                   else r'"artifact_sha"\s*:\s*"([0-9a-fA-F]{64})"')
        links = re.findall(pattern, fragment)
        if run_id is not None:
            try:
                links = [json.loads(link) for link in links]
            except ValueError:
                links = []
        else:
            links = [link.lower() for link in links]
        require(links and all(link != (run_id if run_id is not None else digest) for link in links),
                'veredicto ilegible vinculado a la ronda vigente')
    approved = False
    for v, enclosed, fragment, duplicated in carriers:
        # Solo un vínculo propio completo demuestra que el portador es ajeno.
        if run_id is not None:
            links = v.values_for('run_id')
            other = bool(links) and all(isinstance(link, str) and bool(link) and
                                       link != run_id for link in links)
        else:
            types = v.values_for('artifact_type')
            links = v.values_for('artifact_sha')
            # Cada combinación debe ser completa y ajena; ninguna repetición
            # puede esconder un vínculo vigente ni uno incompleto.
            other = bool(types and links) and all(
                isinstance(kind, str) and bool(kind) and isinstance(link, str) and
                re.fullmatch(r'[0-9a-fA-F]{40}' if kind == 'code' else r'[0-9a-fA-F]{64}', link) and
                (kind != typ or link.lower() != digest)
                for kind in types for link in links)
        if other:
            continue
        require(not duplicated, 'veredicto ilegible vinculado a la ronda vigente')
        require(v.get('artifact_type') == typ and v.get('verdict') == 'GO' and
                v.get('blocking_findings') == [] and v.get('artifact_sha') == digest and
                isinstance(v.get('run_id'), str) and
                re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', v['run_id']) and
                ('issue' not in v or v['issue'] == issue), 'veredicto contradictorio o esquema inválido')
        require(not fragment, 'veredicto ilegible vinculado a la ronda vigente')
        approved = approved or not enclosed
    require(approved, 'veredicto sin vínculo con registro o plan')


def audit_record(text):
    lines = text.splitlines()
    require(len(lines) == 4, 'audit-last.env debe tener cuatro líneas')
    record = {}
    for line in lines:
        key, sep, value = line.partition('=')
        require(sep and key in ('RUN_ID', 'SHA', 'TYP', 'TS') and key not in record and value,
                'audit-last.env campo inválido '+key)
        record[key] = value
    require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', record['RUN_ID']) and
            re.fullmatch(r'[0-9a-f]{40}', record['SHA']) and record['TYP'] == 'code' and
            re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', record['TS']),
            'audit-last.env esquema inválido')
    return record


def issue_record(value, issue, done=False):
    require(isinstance(value, dict) and not value.get('errors'), 'issue.json errores/esquema')
    require(isinstance(value.get('data'), dict), 'issue.json respuesta parcial: data')
    row = value.get('data', {}).get('issue', {})
    require(isinstance(row, dict) and row.get('identifier') == issue and
            isinstance(row.get('title'), str) and row['title'].strip() and
            isinstance(row.get('createdAt'), str) and
            re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})', row['createdAt']),
            'issue.json identificador/título/fecha inválidos')
    try:
        datetime.fromisoformat(row['createdAt'].replace('Z', '+00:00'))
    except ValueError:
        require(False, 'issue.json createdAt inválido')
    if done:
        require(row.get('state', {}).get('name') == 'Done', 'issue-done.json estado inválido')
    return row


def status_record(status):
    if not isinstance(status, dict):
        return False
    # Un CheckRun pendiente tiene conclusion nula y status presente.
    fields = ('name', 'context', 'conclusion', 'state', 'status')
    return (all(key not in status or status[key] is None or isinstance(status[key], str) for key in fields) and
            isinstance(status.get('name') or status.get('context'), str) and
            isinstance(status.get('conclusion') or status.get('state') or status.get('status'), str))


def pr_record(pr, issue, head=None, number=None):
    require(isinstance(pr, dict), 'merge.json respuesta parcial: objeto')
    types = {'number': int, 'state': str, 'headRefOid': str, 'mergeCommit': dict,
             'body': str, 'files': list, 'statusCheckRollup': list}
    for key, typ in types.items():
        require(type(pr.get(key)) is typ, 'merge.json respuesta parcial: '+key)
    require(isinstance(pr['mergeCommit'].get('oid'), str), 'merge.json respuesta parcial: mergeCommit.oid')
    require(pr['state'] == 'MERGED' and re.fullmatch(r'[0-9a-f]{40}', pr['headRefOid']) and
            re.fullmatch(r'[0-9a-f]{40}', pr['mergeCommit'].get('oid', '')) and
            (head is None or pr['headRefOid'] == head) and
            (number is None or pr['number'] == number) and
            re.search(r'(?i)\b(?:closes|fixes|resolves)\s+'+re.escape(issue)+r'\b', pr['body']),
            'merge.json fusión/PR/head/issue inválidos')
    require(len(pr['files']) == 1 and isinstance(pr['files'][0], dict) and
            isinstance(pr['files'][0].get('path'), str) and
            re.fullmatch(r'docs/.+\.md', pr['files'][0]['path']), 'merge.json files inválidos')
    require(all(status_record(s) for s in pr['statusCheckRollup']), 'merge.json statusCheckRollup inválido')


def auxiliaries(stage):
    names = {'plan-gate': ['veredicto-plan.txt'], 'auditoria': ['audit-last.env']}.get(stage, [])
    return {name: hashlib.sha256(regular(STATE/'humo'/name).read_bytes()).hexdigest() for name in names}


def validate(text, stage, issue, head, number=None, sealed=None, merge=None):
    text = normalized_text(text)
    require(text.strip(), 'original vacío')
    directory = STATE/'humo'
    if sealed is not None:
        require(sealed == auxiliaries(stage), 'original auxiliar ausente/alterado '+stage)
    names = {'issue':'issue.json', 'plan-gate':'plan-normalizado.norm', 'codigo':'informe-parada.md',
             'auditoria':'veredicto-codigo.txt', 'merge':'merge.json', 'Done':'issue-done.json'}
    if stage in names:
        require(normalized_text(regular(directory/names[stage]).read_bytes().decode()) == text,
                names[stage]+' original distinto del artefacto sellado')
    if stage == 'auditoria':
        record = audit_record(regular(directory/'audit-last.env').read_text())
        require(record['SHA'] == head, 'audit-last.env head distinto')
        approval(text, 'code', head, issue, record['RUN_ID'])
    elif stage == 'plan-gate':
        require(re.search(r'(?<![A-Za-z0-9-])'+re.escape(issue)+r'(?![A-Za-z0-9-])', text),
                'plan-normalizado.norm issue inválida')
        approval(regular(directory/'veredicto-plan.txt').read_text(), 'plan',
                 hashlib.sha256(regular(directory/'plan-normalizado.norm').read_bytes()).hexdigest(), issue)
    elif stage in ('issue', 'Done'):
        row = issue_record(json.loads(text), issue, stage == 'Done')
        if stage == 'Done':
            initial = issue_record(json.loads(regular(directory/'issue.json').read_text()), issue)
            require(row['createdAt'] == initial['createdAt'], 'issue-done.json creación distinta')
    elif stage == 'merge':
        value = json.loads(text)
        pr_record(value, issue, head, number)
        require(merge is not None and value['mergeCommit']['oid'] == merge, 'merge.json commit de fusión distinto')
    elif stage == 'codigo':
        require(re.match(r'^STOP-AUDIT\s*[—-]\s*'+re.escape(issue)+r'\b', text) and
                re.search(r'SHA auditado:\s*'+re.escape(head)+r'(?![0-9a-f])', text),
                'informe-parada.md cabecera/issue/head inválidos')
    elif stage == 'handoff':
        require(issue in text and head in text, 'handoff issue/head inválidos')
