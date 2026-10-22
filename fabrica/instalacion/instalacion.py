#!/usr/bin/env python3
"""Cuestionario y renderizado de datos; validadores del paquete como autoridad."""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

HERE = Path(__file__).resolve().parent
PACKAGE = HERE.parent
SKILLS = PACKAGE / 'skills'
MEMBERS = ('talent-channel-operation', 'talent-merger', 'talent-ceo', 'talent-coordination')
# Identidad exacta de los ejemplos distribuidos; la suite exige coherencia byte a byte.
EXAMPLES = {
    'ledger/cuentas.json': 'ba58669d0f06b0c6006bd2a237a807ee9b071fab98bb471c5c842b70ebea2d15',
    'manifiestos/ejemplo.conf': '9dd7396e79ffdccc1c3e0a9412e5ac206a44eb82021fd77a119025704778b3a9',
}
UUID = r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
SECRET = re.compile(r'gh[pousr]_|github_pat_|lin_api_|sk-|eyJ[A-Za-z0-9_-]{12}', re.I)


class Error(Exception):
    def __init__(self, message, rc=2):
        super().__init__(message)
        self.rc = rc


def text(path):
    data = path.read_bytes()
    if b'\x00' in data or b'\r' in data or data.startswith(b'\xef\xbb\xbf'):
        raise Error(f'{path}: BOM, CR o NUL; guarde texto UTF-8 con LF')
    return data.decode('utf-8')


def questions():
    result = {}
    for line in text(HERE / 'preguntas.tsv').splitlines():
        if not line or line.startswith('#'):
            continue
        row = line.split('\t')
        if len(row) != 9 or row[0] in result:
            raise Error('preguntas.tsv: columnas o identificador duplicado')
        result[row[0]] = row
    return result


def applies(row, answers):
    dep = row[7]
    if not dep:
        return True
    key, value = dep.split('=', 1)
    if key.endswith('!'):
        return answers.get(key[:-1]) != value
    return answers.get(key) == value


def validate(key, value, row):
    # No incluir nunca el valor rechazado en diagnósticos.
    if SECRET.search(value) or '\n' in value or '\r' in value or '\x00' in value:
        raise Error(f'{key}: credencial o bytes prohibidos; use solo datos públicos')
    if key == 'repo_rama' and value != 'main':
        raise Error('repo_rama: esta versión requiere main')
    if not re.fullmatch(row[5], value, re.ASCII):
        raise Error(f'{key}: se esperaba {row[3]}')
    if key == 'repo_url' and any(x in value.split('/')[-1] for x in ('..',)):
        raise Error(f'{key}: nombre de repositorio con traversal')
    if key == 'pozos_alias' and len(value.split(',')) != len(set(value.split(','))):
        raise Error(f'{key}: alias repetidos')
    if key in ('validador_rama', 'e2e_registro', 'migraciones_dir', 'vault_gate') and any(part in ('.', '..', '') for part in value.split('/')):
        raise Error(f'{key}: ruta relativa sin componentes ./.. ni vacíos')
    if key == 'superficies_paths' and value:
        surfaces = [item.split(':', 1)[0] for item in value.split(',')]
        if len(surfaces) != len(set(surfaces)) or any(
                part in ('.', '..', '') for item in value.split(',')
                for part in item.split(':', 1)[1].split('/')):
            raise Error(f'{key}: superficies únicas y patterns relativos sin traversal')
    if (key.startswith('gate_cmd_') or key in ('instalar_cmd', 'e2e_wrapper')) and not value.strip():
        raise Error(f'{key}: comando vacío; indique una orden o un script del repositorio')


def load(path, qs, missing_ok=False):
    if not path.exists() and missing_ok:
        return {}
    result = {}
    for n, line in enumerate(text(path).splitlines(), 1):
        if not line or line.startswith('#'):
            continue
        if '=' not in line:
            raise Error(f'{path}:{n}: se esperaba clave=valor')
        key, value = line.split('=', 1)
        if key in result:
            raise Error(f'{path}:{n}: clave desconocida o duplicada')
        result[key] = value
    expand_gates(qs, result)
    for key, value in result.items():
        if key not in qs:
            raise Error(f'{path}: clave desconocida')
        validate(key, value, qs[key])
    return result


def expand_gates(qs, answers):
    ids = answers.get('gates_ids', '')
    if ids:
        validate('gates_ids', ids, qs['gates_ids'])
        normalized = [gate.replace('-', '_') for gate in ids.split()]
        if len(normalized) != len(set(normalized)):
            raise Error('gates_ids: identificadores repetidos o colisión entre guion y subrayado')
    expanded = {}
    for key, row in qs.items():
        if key.startswith('gate_cmd_'):
            continue
        expanded[key] = row
        if key == 'gates_ids':
            for gate in ids.split():
                gid = 'gate_cmd_'+gate.replace('-', '_')
                expanded[gid] = [gid, 'gates', 'Comando del gate '+gate,
                                 'Letras, dígitos, espacio y ._/:@=,-; envuelva comandos complejos en un script del repositorio.',
                                 'texto', r'^[A-Za-z0-9 ._/:@=,-]+$', '', '', 'manifiesto']
    qs.clear()
    qs.update(expanded)


def default(row, answers):
    value = row[6]
    if value == '@SUPERFICIES':
        return 'auth migraciones credenciales' if answers.get('supabase') == 'si' else 'auth credenciales'
    if value == '$USUARIO':
        return os.environ.get('USER', 'operador')
    if value == '$HOSTNAME':
        return os.uname().nodename
    if value.startswith('@ORG:'):
        return answers.get(value[5:], '').split('/')[3] if answers.get(value[5:]) else ''
    return re.sub(r'\{([a-z0-9_]+)\}', lambda m: answers.get(m[1], m[0]), value)


def pending(qs, answers):
    return [k for k, row in qs.items() if applies(row, answers) and k not in answers]


def distinct_users(answers, qs, rc=2):
    if answers.get('cuser') == 'root':
        raise Error('usuario root no permitido dentro de los contenedores', rc)
    users = {}
    for key in ('usuario_ceo', 'usuario_c1', 'usuario_m1', 'usuario_orq', 'usuario_pm', 'usuario_incus'):
        if key not in answers or not applies(qs[key], answers):
            continue
        user = answers[key]
        if user == 'root':
            raise Error('usuario root no permitido; elija un usuario normal distinto para cada rol', rc)
        if user in users:
            raise Error(f'perfil: usuario repetido en {key} y {users[user]}; asigne usuarios distintos', rc)
        users[user] = key


def absolute(value):
    path = Path(value)
    if not path.is_absolute() or not re.fullmatch(r'/[A-Za-z0-9._/-]+', value):
        raise Error('ruta: se esperaba absoluta, sin espacios ni metacaracteres')
    if '..' in path.parts or '.' in value.split('/'):
        raise Error('ruta: componentes ./.. prohibidos')
    return path


def no_links(path):
    for part in (path, *path.parents):
        if part.is_symlink():
            raise Error(f'{path}: enlace simbólico; use una ruta física')


def write(path, content, mode=0o644):
    no_links(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.instalacion-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(content)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def json_text(data):
    return json.dumps(data, indent=2, ensure_ascii=False, sort_keys=True) + '\n'


def write_linear(path, content):
    diagnostic = f'{path}: destino inseguro o distinto; use otra ruta de salida o retire el anterior a mano'
    parent_fd = None
    try:
        no_links(path)
        path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        parent_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        def validate_parent():
            info = os.fstat(parent_fd)
            # El nombre proviene del descriptor fijado, sin resolver otra vez el padre.
            if (info.st_uid != os.geteuid() or info.st_mode & 0o022 or
                    os.readlink(f'/proc/self/fd/{parent_fd}') != str(path.parent)):
                raise Error(diagnostic, 3)
        validate_parent()
        expected = content.encode('utf-8')
        try:
            fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
        except FileNotFoundError:
            fd = None
        if fd is not None:
            with os.fdopen(fd, 'rb') as f:
                validate_parent()
                info = os.fstat(f.fileno())
                if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or f.read() != expected:
                    raise Error(diagnostic, 3)
                validate_parent()
            return
        # Crear sin reemplazar: una colisión concurrente también falla cerrada.
        validate_parent()
        fd = os.open(path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent_fd)
        with os.fdopen(fd, 'wb') as f:
            try:
                validate_parent()
            except (OSError, Error):
                os.unlink(path.name, dir_fd=parent_fd)
                raise
            os.fchmod(f.fileno(), 0o600)
            f.write(expected)
    except (OSError, Error) as exc:
        raise Error(diagnostic, 3) from exc
    finally:
        if parent_fd is not None:
            os.close(parent_fd)


def run(args, env=None, rc=1):
    result = subprocess.run([str(x) for x in args], env=env, capture_output=True, text=True)
    if result.stdout:
        print(result.stdout, end='')
    if result.stderr:
        print(result.stderr, end='', file=sys.stderr)
    if result.returncode:
        raise Error(f'{args[0]}: rc={result.returncode}; corrija el fichero indicado', rc)
    return result


def questionnaire(args):
    qs = questions()
    path = absolute(args.respuestas)
    no_links(path)
    answers = load(path, qs, True)
    if args.accion == 'registrar':
        if args.id not in qs or not applies(qs[args.id], answers):
            raise Error('id: desconocido o pregunta no aplicable')
        value = default(qs[args.id], answers) if args.valor == '--defecto' else args.valor
        if value is None:
            raise Error('registrar necesita id y valor')
        validate(args.id, value, qs[args.id])
        answers[args.id] = value
        expand_gates(qs, answers)
        # Al cambiar una condición, borrar respuestas que ya no aplican.
        answers = {k: v for k, v in answers.items() if k in qs and applies(qs[k], answers)}
        distinct_users(answers, qs)
        write(path, ''.join(f'{k}={answers[k]}\n' for k in qs if k in answers), 0o600)
        print(f'REGISTRADO {args.id}')
    elif args.accion == 'siguiente':
        todo = pending(qs, answers)
        if not todo:
            print('COMPLETO')
        else:
            row = qs[todo[0]]
            print('\t'.join((row[0], row[2], row[3], default(row, answers))))
    else:
        for key in qs:
            if key in answers and applies(qs[key], answers):
                print(f'{key}={answers[key]}')
        print('PENDIENTES ' + ','.join(pending(qs, answers)))


def render_anexo(template, context):
    result = re.sub(r'\{\{([a-z0-9_]+)\}\}', lambda m: str(context[m[1]]), template)
    if re.search(r'\{\{[a-z0-9_]+\}\}', result):
        raise Error('anexo: marcador sin resolver; nada escrito', 1)
    return result


def anexo_context(a, out, home, stack, rows):
    p = a['proyecto']
    supabase = stack == 'supabase'
    counts = {kind: sum(row[0] == kind for row in rows[1:])
              for kind in ('maquina', 'ceo', 'torre', 'estacion', 'canal', 'runner', 'pm', 'bus', 'cron')}
    context = dict(a)
    context.update({
        'repo_slug': a['repo_url'].removeprefix('https://github.com/').removesuffix('.git'),
        'initiative': '`'+a['initiative_uuid']+'`' if a['initiative_uuid'] else
                      'No aplica: esta instancia no declara una initiative de Linear.',
        'motor': str(out/'scripts/run-local-gates.sh'),
        'manifiesto': str(out/f'manifiestos/{p}.conf'),
        'gates': '\n'.join('| `'+g+'` | `'+a['gate_cmd_'+g.replace('-', '_')]+'` |'
                           for g in a['gates_ids'].split()),
        'e2e_info': ('Familias E2E: `'+a['e2e_familias']+'`; wrapper: `'+a['e2e_wrapper']+
                     '`; registro de shards: `'+a['e2e_registro']+'`.\n'
                     'Leer notes del registro para firmas de flakes; no heredar flakes de otro producto.')
                    if a['e2e'] == 'si' else 'Shards E2E: no aplican; no hay familias ni wrapper declarados.',
        'actor_db': 'talent-merger' if supabase else 'No aplica: no hay base de datos gestionada.',
        'migraciones_info': ('Supabase: sí; prod ref `'+a['supabase_ref']+'`.\n'
                            'Directorio: `'+a['migraciones_dir']+'`; método: Management API.\n'
                            '`migration_slots`: enumerar slots reales del PR en el HANDOFF;\n'
                            'standby `29990101000000` al desarrollar; renumeración del Mergeador.\n'
                            'Cantidad: la del diff real, nunca una constante del generador.') if supabase else
                           'Supabase: no; no hay base de datos gestionada en esta instancia.\n'
                           'Ref y método de apply: no aplican. `migration_slots: n/a`.\n'
                           'PROC-M13 no aplica; tampoco PROC-M14/M15, porque el stack es ninguno.',
        'procedimientos': '',
        'superficies_info': ('| Superficie | Path pattern | Acción extra |\n|---|---|---|\n'+
                            '\n'.join('| `'+s+'` | `'+path+'` | GO lead en destructivas; review de la superficie |'
                                      for s, path in (item.split(':', 1) for item in a['superficies_paths'].split(','))))
                           if a['superficies_paths'] else
                           'Excepciones por path-pattern: no aplican, no hay excepciones adjudicadas al default.',
        'postmerge_info': 'Deploy automático: no configurado; no aplica un deploy de plataforma en esta instalación.\n'
                          'No se ha declarado plataforma ni comando de deploy; no inferirlos del repositorio.\n'
                          'Actor de migraciones: '+('talent-merger, apply + advisors + ledger como gate de Done.'
                                                    if supabase else 'no aplica; stack ninguno.'),
        'audit_topology': 'distinto' if a['codex'] == 'si' else 'mismo-adversarial',
        'perfil_validator': str(out/'skills/talent-ceo/scripts/lib-perfil.sh'),
        'censo': '\n'.join('| `'+kind+'` | '+str(count)+' |' for kind, count in counts.items()),
        'pm_info': 'PM: fila explícita adjudicada a `'+a['usuario_pm']+'`; no derivar PM de CEO.'
                   if a['pm'] == 'si' else 'PM no aplica: no se solicitó este rol y no hay fila pm; no deducirla de CEO.',
        'bus': str(home/p/'bus'), 'ledger': str(out/'ledger/cuentas.json'),
        'playwright_info': ('Flujos del carril de auditoría Playwright: `'+a['playwright_flujos']+'`.\n'
                            'El coordinador los releva a mano al lanzar el carril; solo reporta findings, no crea issues.')
                           if a['playwright_flujos'] else
                           'Auditoría Playwright no aplica al montaje inicial: no hay flujos adjudicados;\n'
                           'no lanzar el carril sin definirlos en el cuestionario.',
        'flock_info': 'Flock de apply no aplica: no hay base de datos gestionada.',
        'm14_info': 'No aplica: stack ninguno; no hay slots de base de datos que renumerar.',
        'm15_info': 'No aplica: stack ninguno; no hay advisors ni baseline de base de datos.',
        'destructivas_info': 'No aplica la clasificación SQL: no hay base de datos gestionada.\n'
                             'Las acciones destructivas en otras superficies siguen requiriendo GO del lead.',
        'pgtap_info': 'pgTAP y pre-reseed SQL no aplican: stack ninguno, sin base de datos gestionada.\n'
                     'Los tests de producto deben verificar resultados y efectos y fallar ante noop/restore.',
    })
    if supabase:
        context['flock_info'] = (
            'Flock canónico: `TM_FLOCK_CANONICO_TRUSTED` es obligatorio en el entorno de la estación,\n'
            'sin default ni inferencia desde cwd; lo adjudica la capa del bus en el montaje.\n'
            '`flock_acreditado` compara `FLOCK_FILE -ef TM_FLOCK_CANONICO_TRUSTED`; ausencia bloquea.\n'
            '**PROCEDENCIA INDEPENDIENTE: NO MEDIDA, NO GARANTIZABLE DESDE ESTE ARTEFACTO**.\n'
            'Si el mismo wrapper configura ambas rutas juntas al mismo fichero equivocado,\n'
            'la comparación consigo mismo da verde sin acreditar procedencia independiente.\n'
            'El nombre TRUSTED declara intención, no crea un canal de confianza. Ningún script\n'
            'debe derivar una variable de la otra; el despliegue debe acreditar actos distintos.\n'
            '**Se declara NO MEDIDO, no cerrado, y así se mantiene**: el generador no certifica\n'
            'quién exporta cada variable ni si pueden discrepar en la flota real.')
        context['m14_info'] = (
            'Leer ledger real (PROC-M13 Paso 2), rama origin fresca y TODOS los drafts de la cola.\n'
            'Tope = unión de los tres conjuntos; no sustituir enumeración completa por --limit.\n'
            'Bajo claim flock, renumerar por encima del tope preservando orden de la rama.\n'
            'Eliminar standby 2999, nunca editar migraciones ya aplicadas. Rename = commit nuevo,\n'
            'head nuevo: reemitir HANDOFF, verify-handoff y gates. Capturar rc del rebase sin\n'
            'pipe que lo enmascare; fallo exige abortar y diagnosticar, nunca seguir renombrando.\n'
            'No se declara automatización propia del producto: aplicar la mecánica del núcleo.')
        context['m15_info'] = (
            'Tras PROC-M13 consultar security y performance: ERROR bloquea Done; WARN sobre\n'
            'objetos tocados es hallazgo. Confirmar schema/name/type y leer el SQL aplicado\n'
            'antes de atribuir defecto; nunca inferirlo del log o de un ERROR ajeno.\n'
            'Fix por migración nueva, nunca edición remota. Una pendiente rota no se desbloquea\n'
            'añadiendo otra migración: escalar. Clasificar el cierre leyendo CLASS_FILE, nunca log.\n'
            'Timeout del POST no cancela transacción: investigar pg_locks y revalidación bajo\n'
            'lock antes de reintentar. No repetir DDL con resultado ambiguo.\n'
            'Impl interna puede admitir REVOKE; RPC directa authenticated con gate interno\n'
            'requiere revisar callers y ACL: REVOKE puede romper producción. Wrapper invoker\n'
            'no es el objeto secdef señalado. Baseline aceptado exige evidencia dura de callers\n'
            'y gate interno; reconsultar hasta que desaparezca el hallazgo específico.\n'
            'No aplica un fichero de baseline específico adjudicado: el cuestionario no configura\n'
            'ratchet propio del producto. Si el producto lo tiene, leer su gate y declarar el\n'
            'pre-reseed en HANDOFF. Tras rebase comprobar que sobreviven AMBOS conjuntos de\n'
            'aceptaciones y tests aditivos; union puede dropear cambios sin conflicto.')
        context['destructivas_info'] = (
            '| Patrón SQL | Clasificación | Acción |\n|---|---|---|\n'
            '| DELETE en cuerpo de función | No destructivo | Review de lógica |\n'
            '| REVOKE de grants | No destructivo por sí solo | Comprobar ACL/callers |\n'
            '| CREATE OR REPLACE / DROP FUNCTION + recreate | No destructivo por sí solo | Auditar contra canónico |\n'
            '| DROP TABLE/COLUMN, TRUNCATE, ALTER TYPE irreversible, DELETE batch top-level | Destructivo | GO lead antes del apply |\n'
            'Ante duda, `destructive: true`. No usar esta tabla para omitir el GO de una acción con pérdida.')
        context['pgtap_info'] = (
            'Si el producto usa pgTAP, exigir fixtures reales insertadas por el test, is() del\n'
            'valor devuelto y SELECT posterior de side-effects. ok(SELECT TRUE) es tautología;\n'
            'lives_ok solo demuestra ausencia de excepción. Asserts deben fallar ante noop/restore.\n'
            'Reconstruir funciones desde última CREATE OR REPLACE canónica en `'+a['migraciones_dir']+'`,\n'
            'añadiendo solo delta; no reescribir de memoria. Catch-all EXCEPTION WHEN OTHERS\n'
            'THEN RETURN en SECURITY DEFINER es bloqueante; usar errcode específico recuperable.\n'
            'Pre-reseed: si existe ratchet de advisors del producto, declarar nueva secdef, grant\n'
            'y aceptación con evidencia en HANDOFF. No inventar baseline ni herramientas de tests\n'
            'no declaradas: la presencia de Supabase por sí sola no demuestra que haya pgTAP.\n'
            'Validar reset local desde cero antes de entregar migraciones; omisión explícita\n'
            'debe quedar en HANDOFF, nunca pasar OMITIDO por VALIDADO.')
        context['procedimientos'] = render_anexo(text(HERE/'plantillas/proc-m13-supabase.md.tmpl'), context)
    return context


def render(answers, out, home):
    a = answers
    p = a['proyecto']
    auditor = 'codex' if a['codex'] == 'si' else 'claude-root'
    stack = 'supabase' if a['supabase'] == 'si' else 'ninguno'
    machine = 'maquina-' + a['maquina_n']
    channels = [a['maquina_n'] + str(i) for i in range(1, int(a['canales_n']) + 1)]
    aliases = a['pozos_alias'].split(',')
    manifest = {
        'TF_PROJECT': p, 'TF_REPO_URL': a['repo_url'], 'TF_REPO_BRANCH': a['repo_rama'],
        'TF_GH_ORG': a['gh_org'], 'TF_LINEAR_TEAM_KEY': a['linear_clave'],
        'TF_SENSITIVE_SURFACES': a['superficies_sensibles'],
        'TF_CHANNEL_GIT_NAME_TMPL': a['git_nombre_tmpl'],
        'TF_CHANNEL_GIT_EMAIL_TMPL': a['git_email_tmpl'],
        'TF_CUSER': a['cuser'], 'TF_CLAUDE_ACCOUNT_POOL': ' '.join(aliases),
        'TF_CODEX_ACCOUNT_POOL': ' '.join(f'codex{i}' for i in range(1, int(a.get('codex_n', '0'))+1)),
        'TF_REPO_DIR': a['repo_url'].split('/')[-1].removesuffix('.git'),
        'TF_GH_TOKEN_NAME': 'GITHUB_TOKEN', 'TF_LINEAR_TOKEN_NAME': 'LINEAR_API_KEY',
        'TF_CR_KEY_NAMES': 'CODERABBIT_API_KEY',
        'TF_GH_MERGER_TOKEN_NAMES': 'GITHUB_TOKEN',
        'TF_GATE_IDS': a['gates_ids'], 'TF_INSTALL': a['instalar_cmd'],
        'TF_BRANCH_VALIDATOR': a['validador_rama'],
        'TF_DB_GATE': 'always' if stack == 'supabase' else 'never',
        'TF_MIGRATIONS_DIR': a['migraciones_dir'] if stack == 'supabase' else '',
        'TF_E2E_FAMILIES': a.get('e2e_familias', ''),
        'TF_E2E_WRAPPER': a.get('e2e_wrapper', ''),
        'TF_SHARDS_REGISTRY': a.get('e2e_registro', ''),
        'TF_BASE_REF': 'origin/'+a['repo_rama'],
        'TF_CARVEOUT_DOCS_ONLY': '0', 'TF_CARVEOUT_KEEP_GATES': '',
        'TF_CARVEOUT_PATHS': '', 'TF_CARVEOUT_INERT_GATE': '', 'TF_CARVEOUT_INERT_DIGEST': '',
    }
    for gate in a['gates_ids'].split():
        key = gate.replace('-', '_')
        manifest['TF_GATE_CMD_'+key] = a['gate_cmd_'+key]
    files = {f'manifiestos/{p}.conf': ''.join(f'{k}="{v}"\n' for k, v in manifest.items())}
    files['manifiestos/runner-identity.map'] = a['host_nombre']+'='+a['host_nombre']+'\n'
    rows = [('tipo', 'id', 'maquina', 'contenedor', 'sesion', 'atributos'),
            ('maquina', machine, '-', '-', '-', f'acceso=local;host={a["host_nombre"]};pool={a["pool_gib"]}GiB')]
    def role(kind, rid, user, container='-', attrs=''):
        session = 'torre-'+rid.lower() if kind == 'torre' else ('v' if kind == 'canal' else rid.lower())
        if kind in ('ceo', 'torre', 'estacion', 'pm'):
            try:
                actor_home = Path(pwd.getpwnam(user).pw_dir)
            except KeyError:
                actor_home = Path('/home')/user
            if not re.fullmatch(r'/[A-Za-z0-9_./-]+', str(actor_home)) or '..' in actor_home.parts:
                raise Error('home de rol inválido: '+rid)
            attrs += ';estado_bus='+str(actor_home/'.local/state/talent-ceo')
        rows.append((kind, rid, machine, container, session, f'usuario={user}' + attrs))
    role('ceo', 'CEO', a['usuario_ceo'])
    role('torre', 'C1', a['usuario_c1'])
    role('estacion', 'M1', a['usuario_m1'])
    if a['orq'] == 'si':
        role('torre', 'ORQ', a['usuario_orq'])
    if a['pm'] == 'si':
        role('pm', 'PM', a['usuario_pm'])
    readers = ','.join(row[1] for row in rows if row[0] in ('ceo', 'torre', 'estacion', 'pm'))
    for ch in channels:
        role('canal', ch, a['usuario_incus'], f'vibe-channel-{ch}',
             f';cpu={a["canal_cpu"]};mem={a["canal_mem_gib"]}GiB;auditor={auditor}')
    role('runner', 'runner-'+p, a['usuario_incus'], 'runner-'+p,
         ';usuario_contenedor=runner;repo=/home/runner/repo')
    rows.extend([('bus', 'BUS', machine, '-', '-', f'path={home}/{p}/bus;lectores={readers}'),
                 ('cron', 'CRON', '-', '-', '-', 'dueno=CEO;minutos=07,22,37,52')])
    files[f'manifiestos/{p}.perfil.tsv'] = ''.join('\t'.join(r)+'\n' for r in rows)
    agents = {'TCO_DEV_CLI': 'claude-root', 'TCO_AUDIT_CLI': auditor,
              'TCO_CUSER': a['cuser'], 'TCO_PREFIX': 'vibe-channel-',
              'TCO_TMUX': 'v', 'TORC_CHANNEL_PREFIX': 'vibe-channel-',
              'TCO_AUDIT_TOPOLOGY': 'distinto' if a['codex'] == 'si' else 'mismo-adversarial',
              'TCO_DEV_CARRILES': ' '.join(channels), 'TCO_AUDIT_CARRILES': '',
              'TCO_MAX_ACTIVE': a['canales_n'], 'TORC_TEAM_ID': a['linear_equipo_uuid'],
              'TORC_STATE_INPROGRESS': a['linear_inprogress_uuid']}
    for key, target in [('modelo_plan', 'TCO_PLAN_MODEL'), ('modelo_codigo', 'TCO_DEV_MODEL')]:
        if a.get(key):
            agents[target] = a[key]
            if key == 'modelo_codigo':
                agents['TCO_DEV_MODEL_ARGS'] = '--model '+a[key]
    files['agents.conf'] = ''.join(f'{k}="{v}"\n' for k, v in agents.items())
    wells = {f'p{i}': {'cuenta': alias, 'estado': 'PENDIENTE-ACREDITACION', 'habilitada_fabrica': True}
             for i, alias in enumerate(aliases, 1)}
    accounts = [{'alias': alias, 'pozo_origen': f'p{i}', 'estado': 'PENDIENTE-ACREDITACION',
                 'grants_vivos': [], 'tipo': 'claude'} for i, alias in enumerate(aliases, 1)]
    accounts += [{'alias': f'codex{i}', 'tipo': 'codex', 'estado': 'PENDIENTE-ACREDITACION',
                  'grants_vivos': []} for i in range(1, int(a.get('codex_n', '0'))+1)]
    files['ledger/cuentas.json'] = json_text({'coordinator_host': a['host_nombre'],
                                            'pozos': wells, 'cuentas': accounts})
    linear = {'team': {'id': a['linear_equipo_uuid'], 'key': a['linear_clave']},
              'project': a['linear_proyecto'], 'states': [
                  {'id': a['linear_inprogress_uuid'], 'name': 'In Progress'},
                  {'id': a['linear_inreview_uuid'], 'name': 'In Review'}], 'labels': []}
    files['instalacion/generado/linear-instancia.json'] = json_text(linear)
    identity = {'PKG_IDENTITY_PROJECT': p, 'TCO_REPO_STACK': stack,
                'TCO_ANEXO_FILE': f'references/anexo-{p}.md',
                'TCO_LINEAR_INPROGRESS_STATE': a['linear_inprogress_uuid'],
                'TCO_LINEAR_INREVIEW_STATE': a['linear_inreview_uuid'],
                'TCO_POSTMERGE_CMD': 'true', 'TCO_HOST_ENV_REL': p+'/.env.local',
                'TORC_HOST_ENV_REL': p+'/.env.local', 'TCO_TF_MANIFEST': str(out / f'manifiestos/{p}.conf')}
    if stack == 'supabase':
        identity['TCO_SUPABASE_REF'] = a['supabase_ref']
    files['instalacion/generado/identidad-aprobada.conf'] = ''.join(f'{k}={v}\n' for k, v in identity.items())
    context = dict(a, auditor=auditor, stack=stack, perfil=str(out / f'manifiestos/{p}.perfil.tsv'),
                   linear_config=str(out / 'instalacion/generado/linear-instancia.json'))
    context.update(anexo_context(a, out, home, stack, rows))
    context['runner_info'] = (
        'Runner local adjudicado: `runner-'+p+'`, contenedor `runner-'+p+'` en `'+machine+'`\n'
        '(host `'+a['host_nombre']+'`, según `manifiestos/runner-identity.map`).\n'
        'Operador Incus del host: `'+a['usuario_incus']+'`; usuario sin privilegios del\n'
        'contenedor: `runner`; repositorio: `/home/runner/repo`. No hay máquinas remotas adjudicadas.\n'
        'La estación lee `~/.config/talent-factory/station.conf`: `TF_RUNNERS=runner-'+p+'`,\n'
        '`TF_RUNNER_USER=runner`, `TF_RUNNER_REPO=/home/runner/repo`, `TF_STATION_HOST='+a['host_nombre']+'`.\n'
        'Desde la sesión M1, cargar esa configuración pública y ejecutar/publicar los gates:\n\n'
        '```bash\nset -a\n. "$HOME/.config/talent-factory/station.conf"\nset +a\n'
        'bash '+shlex.quote(str(out/'scripts/seal-suite.sh'))+' "$PR" "$SHA" '+
        shlex.quote('origin/'+a['repo_rama'])+' "$RUNGROUP"\n```\n'
        'PR, SHA y RUNGROUP corresponden al handoff validado; seal-suite agrega receipts\n'
        'y publica `local-gates`. Exigir éxito de todos los gates; no usar --no-post al entregar.')
    for member in MEMBERS:
        context['rol'] = member
        # Mando y coordinación comparten el censo y la autoridad de recursos.
        template_member = 'talent-ceo' if member == 'talent-coordination' else member
        template = text(HERE / f'plantillas/anexo-{template_member}.md.tmpl')
        files[f'instalacion/generado/anexos/{member}/anexo-{p}.md'] = render_anexo(template, context)
    return files


def env_template(answers):
    names = ['GITHUB_TOKEN', 'LINEAR_API_KEY', 'CODERABBIT_API_KEY']
    if answers.get('supabase') == 'si':
        names.append('SUPABASE_ACCESS_TOKEN')
    return ''.join(f'{name}=\n' for name in names)


def distribution_example(path, name):
    return path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == EXAMPLES[name]


def compare(files, out, force, replace_ledger=False):
    for name, data in files.items():
        target = out / name
        no_links(target)
        if target.exists() and text(target) != data and not force:
            if replace_ledger and name == 'ledger/cuentas.json' and distribution_example(target, name):
                continue
            if SECRET.search(text(target)):
                raise Error(f'{target}: contiene una credencial; retire el valor antes de comparar', 3)
            print(''.join(difflib.unified_diff(text(target).splitlines(True), data.splitlines(True),
                                             fromfile=str(target), tofile='generado')), end='', file=sys.stderr)
            raise Error(f'{target}: contenido distinto; revise el diff o use --forzar', 3)


def unique_profile(out, project, consumer_root):
    # El consumidor decide patrón, legibilidad y recorrido; solo se reubica su raíz.
    start = consumer_root/'talent-ceo/scripts'
    generated = out/f'manifiestos/{project}.perfil.tsv'
    env = dict(os.environ)
    for key in ('TA_PERFIL', 'SECRET_DIR', 'BASH_ENV', 'BASHOPTS', 'SHELLOPTS', 'GLOBIGNORE'):
        env.pop(key, None)
    result = subprocess.run(['bash', '-c', '. "$1"; _perfil_start="$2"; _perfil_here() { printf "%s\\n" "$_perfil_start"; }; '
                             'perfil_path', 'perfil', str(SKILLS/'talent-ceo/scripts/lib-perfil.sh'), str(start)],
                            env=env, capture_output=True, text=True)
    # Cero candidatos es normal antes de la primera generación. Uno debe ser el previsto.
    if result.stderr or (result.returncode == 0 and result.stdout.strip() != str(generated)):
        listing = result.stderr or '  - '+result.stdout.strip()+'\n'
        raise Error(f'perfil: AMBIGUO desde {start}; perfil previsto: {generated}\n{listing}'
                    'retire o mueva los otros perfiles fuera del recorrido antes de generar; nada escrito', 1)
    if result.returncode not in (0, 2):
        raise Error('perfil: descubrimiento fallido; nada escrito', 1)


def generator(args):
    qs = questions()
    answers = load(absolute(args.respuestas), qs)
    out, home = absolute(args.salida), absolute(args.home)
    no_links(out)
    no_links(home)
    if 'proyecto' not in answers:
        raise Error('proyecto: respuesta requerida')
    if not args.solo_env:
        todo = pending(qs, answers)
        if todo:
            raise Error('respuestas incompletas: '+','.join(todo))
        if any(not applies(qs[k], answers) for k in answers):
            raise Error('respuestas no aplicables; use registrar para actualizar las dependencias')
        distinct_users(answers, qs, rc=1)
        bus = home/answers['proyecto']/'bus'
        no_links(bus)
        if out in (bus, *bus.parents) or PACKAGE in (bus, *bus.parents):
            raise Error('bus: --home debe situar el estado fuera del paquete')
        if any((parent/'.git').exists() for parent in (bus, *bus.parents)):
            raise Error('bus: --home debe situar el estado fuera de cualquier repositorio')
    envdata = env_template(answers)
    files = {'instalacion/generado/env.local.tmpl': envdata}
    homefiles = {}
    if not args.solo_env:
        unique_profile(out, answers['proyecto'], out/'skills')
        files.update(render(answers, out, home))
        agents = files.pop('agents.conf')
        exports = {'AM_LEDGER': str(out/'ledger/cuentas.json'), 'TF_ROOT': str(out),
                   'TF_MANIFEST': str(out/f'manifiestos/{answers["proyecto"]}.conf')}
        agents += ''.join(f'export {k}="{v}"\n' for k, v in exports.items())
        homefiles['.config/talent-channel-operation/agents.conf'] = agents
        homefiles['.config/talent-orchestrator/agents.conf'] = agents
        if args.linear_config:
            linear = normalize_linear(json.loads(text(absolute(args.linear_config))), answers['linear_clave'])
            if linear['team']['id'] != answers['linear_equipo_uuid']:
                raise Error('Linear: UUID de equipo distinto de las respuestas', 1)
            ids = {s['id'] for s in linear['states']}
            if not {answers['linear_inprogress_uuid'], answers['linear_inreview_uuid']} <= ids:
                raise Error('Linear: estados respondidos ausentes en la consulta', 1)
            linear['project'] = answers['linear_proyecto']
            files['instalacion/generado/linear-instancia.json'] = json_text(linear)
        with tempfile.TemporaryDirectory(prefix='validar-instancia-') as temp:
            stage = Path(temp)
            for name, data in files.items():
                write(stage/name, data)
            p = answers['proyecto']
            run(['bash', SKILLS/'talent-channels/scripts/validate-manifest.sh', stage/f'manifiestos/{p}.conf',
                 '--require', 'TF_LINEAR_TEAM_KEY,TF_SENSITIVE_SURFACES'])
            run(['bash', SKILLS/'talent-ceo/scripts/lib-perfil.sh', '--check', stage/f'manifiestos/{p}.perfil.tsv'])
            run(['bash', HERE/'validar-aprobado.sh', stage/f'manifiestos/{p}.conf',
                 stage/'instalacion/generado/identidad-aprobada.conf'])
    # Todas las colisiones se comprueban antes de escribir. Nunca leer ni pisar env con tokens.
    compare(files, out, args.forzar, replace_ledger=True)
    compare(homefiles, home, args.forzar)
    envpath = home / answers['proyecto'] / '.env.local'
    no_links(envpath)
    if envpath.exists() and not envpath.is_file():
        raise Error('env: destino no es fichero regular')
    # Restringir exclusivamente los directorios propios, nunca home ni .config.
    private_dirs = [envpath.parent, out/'instalacion/generado'] + [(home/name).parent for name in homefiles]
    for directory in private_dirs:
        no_links(directory)
        if directory.exists() and (not directory.is_dir() or directory.stat().st_uid != os.geteuid()):
            raise Error(f'{directory}: directorio privado no pertenece al usuario; nada escrito')
    for directory in private_dirs:
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        directory.chmod(0o700)
    for name, data in files.items():
        if name == 'ledger/cuentas.json' and distribution_example(out/name, name):
            print(f'{out/name}: sustituye el ejemplo de la distribución')
        write(out/name, data, 0o600 if name.endswith('env.local.tmpl') else 0o644)
    for name, data in homefiles.items():
        write(home/name, data, 0o600)
    if not envpath.exists():
        write(envpath, envdata, 0o600)
    else:
        os.chmod(envpath, 0o600)
    print(f'GENERADO {out}; env {envpath} (existente se conserva sin leer)')


def data_conf(path):
    values = {}
    for line in text(path).splitlines():
        if not line or line.startswith('#'):
            continue
        key, value = line.removeprefix('export ').split('=', 1)
        if key in values:
            raise Error(f'{path}: clave duplicada')
        values[key] = value.strip('"')
    return values


def package_members():
    members, exact, prefixes = [], set(), []
    for line in text(SKILLS/'skill-creator/assets/package.manifest').splitlines():
        if line.startswith('member='):
            member = line.split('=', 1)[1]
            if not re.fullmatch(r'[a-z][a-z0-9-]*', member) or member in members:
                raise Error('paquete: miembro inválido o duplicado')
            members.append(member)
        elif line.startswith('overlay='):
            exact.add(line.split('=', 1)[1].replace(':', '/', 1))
        elif line.startswith('overlay-prefix='):
            prefixes.append(line.split('=', 1)[1].replace(':', '/', 1))
    if not members:
        raise Error('paquete: sin miembros')
    return members, exact, prefixes


def package_core(member, root, exact, prefixes):
    # Procedencia conservadora: núcleo idéntico al paquete, salvo overlays declarados.
    result = {}
    for path in sorted((root/member).rglob('*')):
        rel = str(path.relative_to(root))
        if rel in exact or any(rel.startswith(prefix) for prefix in prefixes):
            continue
        if path.is_symlink():
            raise Error(f'{path}: enlace en miembro del paquete; nada escrito', 3)
        if path.is_file():
            # Un env privado nunca se lee para reconocer procedencia.
            content = None if path.name == '.env.local' else path.read_bytes()
            result[rel] = (content, path.stat().st_mode & 0o777)
    return result


def seed_members(args, dst, skills):
    members, exact, prefixes = package_members()
    replacements = set(args.sustituir) | (set(members) if args.sustituir_todos else set())
    if replacements - set(members):
        raise Error('sustituir: miembros desconocidos: '+', '.join(sorted(replacements-set(members))))
    seed, conflicts = [], []
    for member in members:
        target = skills/member
        try:
            no_links(target)
        except Error as exc:
            conflicts.append(str(exc))
            continue
        if not target.exists():
            seed.append(member)
            continue
        if not target.is_dir():
            conflicts.append(f'{target}: miembro no es directorio')
            continue
        try:
            identical = package_core(member, skills, exact, prefixes) == package_core(member, SKILLS, exact, prefixes)
        except Error as exc:
            conflicts.append(str(exc))
            continue
        if identical:
            continue
        if member not in replacements:
            conflicts.append(f'{target}: otro skill con el mismo nombre, o una versión anterior o modificada de este paquete. Puede renombrar su skill '
                        f'o repetir con --sustituir {member} tras el visto bueno de la persona; '
                        'la versión anterior debe quedar en el historial de git')
            continue
        relative = str(target.relative_to(dst))
        saved = subprocess.run(['git', '-C', str(dst), 'ls-tree', '-r', 'HEAD', '--', relative],
                               capture_output=True, text=True)
        dirty = subprocess.run(['git', '-C', str(dst), 'status', '--porcelain',
                               '--untracked-files=all', '--ignored', '--', relative],
                               env=dict(os.environ, GIT_OPTIONAL_LOCKS='0'), capture_output=True, text=True)
        if saved.returncode or not saved.stdout or dirty.returncode or dirty.stdout:
            conflicts.append(f'{target}: antes de sustituir guarde la versión completa y sus cambios en el historial de git')
            continue
        seed.append(member)
    if conflicts:
        raise Error('\n'.join(conflicts)+'; nada escrito. --sustituir-todos exige las mismas garantías para todos los miembros', 3)
    return members, seed


def adjudicate(args):
    out, home, dst = absolute(args.salida), absolute(args.home), absolute(args.destino)
    for path in (out, home, dst):
        no_links(path)
    manifests = []
    for candidate in sorted((out/'manifiestos').glob('*.conf')):
        no_links(candidate)
        if candidate.name == 'ejemplo.conf' and distribution_example(candidate, 'manifiestos/ejemplo.conf'):
            continue
        manifests.append(candidate)
    if len(manifests) != 1:
        raise Error('autoridad: se esperaba un único manifiesto generado; candidatos: '+
                    (', '.join(str(path) for path in manifests) or 'ninguno'))
    auth = manifests[0]
    authority = data_conf(auth)
    for line in text(auth).splitlines():
        if not re.fullmatch(r'TF_[A-Za-z0-9_]+="[A-Za-z0-9._/:@{}=, -]*"', line) or SECRET.search(line):
            raise Error('autoridad: contenido fuera del charset cerrado; regenere el manifiesto')
    p = authority['TF_PROJECT']
    validate('proyecto', p, questions()['proyecto'])
    validate('repo_url', authority['TF_REPO_URL'], questions()['repo_url'])
    # Repo exacto: no aceptar un directorio descendiente que herede git de su padre.
    top = subprocess.run(['git', '-C', str(dst), 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
    if top.returncode or Path(top.stdout.strip()).resolve() != dst.resolve():
        raise Error('destino: debe ser la raíz de un clon git de producto; nada escrito')
    origin = subprocess.run(['git', '-C', str(dst), 'remote', 'get-url', 'origin'], capture_output=True, text=True)
    def slug(url):
        url = re.sub(r'^(https://github\.com/|ssh://git@github\.com/|git@github\.com:)', '', url)
        return re.sub(r'\.git/?$|/$', '', url)
    if origin.returncode or slug(origin.stdout.strip()) != slug(authority['TF_REPO_URL']):
        raise Error('origin: distinto de TF_REPO_URL; corrija el clon o la autoridad; nada escrito')
    approved = absolute(args.approved) if args.approved else out/'instalacion/generado/identidad-aprobada.conf'
    ap = data_conf(approved)
    if any(SECRET.search(v) for v in ap.values()):
        raise Error('fragmento: contiene una credencial; nada escrito', 3)
    run(['bash', HERE/'validar-aprobado.sh', auth, approved], rc=3)
    # Solo la ruta relativa adjudicada; no leer un env existente.
    for key in ('TCO_HOST_ENV_REL', 'TORC_HOST_ENV_REL'):
        no_links(home/ap[key])
        if not (home/ap[key]).is_file():
            raise Error(f'{key}: env ausente; ejecute generar-instancia.sh --solo-env', 3)
    if ap['TCO_ANEXO_FILE'] != f'references/anexo-{p}.md':
        raise Error('anexo: fragmento distinto del proyecto generado; nada escrito', 3)
    overlays = {}
    for member in MEMBERS:
        src = out/f'instalacion/generado/anexos/{member}/anexo-{p}.md'
        if not src.is_file():
            raise Error(f'{src}: anexo ausente; regenere la instancia', 3)
        # Coordinación no tiene overlay en el contrato del sincronizador.
        # F4 instala su anexo en manifiestos, referenciado por CLAUDE/AGENTS.
        if member != 'talent-coordination':
            overlays[f'{member}/references/anexo-{p}.md'] = text(src)
    skills = dst/'.claude/skills'
    no_links(skills)
    product_profile = dst/f'manifiestos/{p}.perfil.tsv'
    profile_data = text(out/f'manifiestos/{p}.perfil.tsv')
    compare({f'manifiestos/{p}.perfil.tsv': profile_data}, dst, False)
    unique_profile(dst, p, skills)
    members, seed = seed_members(args, dst, skills)
    compare({name: content for name, content in overlays.items() if name.split('/')[0] not in seed}, skills, False)
    # agents.conf lo carga el runtime: exigir el formato seguro del generador antes del source real.
    allowed = {'TCO_DEV_CLI', 'TCO_AUDIT_CLI', 'TCO_CUSER', 'TCO_PREFIX', 'TCO_DEV_CARRILES',
               'TCO_AUDIT_CARRILES', 'TCO_MAX_ACTIVE', 'TORC_TEAM_ID', 'TORC_STATE_INPROGRESS',
               'TCO_PLAN_MODEL', 'TCO_DEV_MODEL', 'TCO_DEV_MODEL_ARGS', 'TCO_TMUX',
               'TORC_CHANNEL_PREFIX', 'TCO_AUDIT_TOPOLOGY', 'AM_LEDGER', 'TF_ROOT', 'TF_MANIFEST',
               'TCO_PANE_CALIBRATED'}
    for member in ('talent-channel-operation', 'talent-orchestrator'):
        agents = home/f'.config/{member}/agents.conf'
        for line in text(agents).splitlines():
            if line.startswith('TCO_PANE_CALIBRATED='):
                if not re.fullmatch(r'TCO_PANE_CALIBRATED="(?:[a-z][a-z0-9_.-]*:[0-9]+\.[0-9]+\.[0-9]+(?:\|[a-z][a-z0-9_.-]*:[0-9]+\.[0-9]+\.[0-9]+)*)?"', line):
                    raise Error('agents.conf: calibración inválida', 3)
                continue
            if not re.fullmatch(r'(export )?[A-Z][A-Z0-9_]*="[A-Za-z0-9._/ -]*"', line) or SECRET.search(line):
                raise Error('agents.conf: formato inseguro; regenere la configuración', 3)
        if set(data_conf(agents)) - allowed:
            raise Error('agents.conf: claves ajenas al generador; regenere la configuración', 3)
    run(['bash', SKILLS/'talent-channels/scripts/validate-manifest.sh', auth,
         '--require', 'TF_LINEAR_TEAM_KEY,TF_SENSITIVE_SURFACES'])
    run(['bash', SKILLS/'talent-ceo/scripts/lib-perfil.sh', '--check', out/f'manifiestos/{p}.perfil.tsv'])
    for member, keys in [('talent-channel-operation', set(ap)-{'TORC_HOST_ENV_REL'}),
                         ('talent-orchestrator', {'PKG_IDENTITY_PROJECT', 'TORC_HOST_ENV_REL'})]:
        conf = skills/member/'scripts/repo-identity.conf'
        if member not in seed and conf.is_file():
            existing = data_conf(conf)
            if any(existing.get(k) != ap[k] for k in keys):
                raise Error('identidad existente distinta del fragmento; revise la adjudicación; nada escrito', 3)
    runtime = dict(os.environ, PKG_HOST_HOME=str(home), HOST_HOME=str(home), HOME=str(home))
    for key in ('SECRET_DIR', 'TORC_SECRET_DIR', 'TA_PERFIL'):
        runtime.pop(key, None)
    sync = SKILLS/'skill-creator/scripts/sync-package.sh'
    # Respaldo para garantizar cero cambios si la vía real rechaza la adjudicación.
    with tempfile.TemporaryDirectory(prefix='respaldo-adjudicacion-') as temp:
        backup = Path(temp)/'skills'
        existed = skills.exists()
        claude_existed = (dst/'.claude').exists()
        profile_existed = product_profile.exists()
        manifests_existed = product_profile.parent.exists()
        existing_members = [member for member in members if (skills/member).exists()]
        for member in existing_members:
            shutil.copytree(skills/member, backup/member, symlinks=True)
        if profile_existed:
            shutil.copy2(product_profile, Path(temp)/'perfil.tsv')
        try:
            # Bootstrap por miembro; nunca recorrer los skills ajenos.
            for member in seed:
                if (skills/member).exists():
                    shutil.rmtree(skills/member)
                shutil.copytree(SKILLS/member, skills/member)
            for name, content in overlays.items():
                write(skills/name, content)
            write(product_profile, profile_data)
            run(['bash', sync, '--migrate-identity', '--to', skills, '--authority', auth,
                 '--approved', approved], runtime, rc=3)
            run(['bash', sync, '--from', SKILLS, '--to', skills, '--apply', '--authority', auth], runtime)
            run(['bash', '-c', '. "$1"', 'carga', skills/'talent-channel-operation/scripts/00-config.sh'], runtime)
            run(['bash', '-c', '. "$1"; torc_load_tokens', 'carga',
                 skills/'talent-orchestrator/scripts/00-config.sh'], runtime)
            run(['bash', skills/'talent-ceo/scripts/lib-perfil.sh', '--check'], runtime)
            # El último gate pertenece a la misma transacción que la propagación y carga.
            validation = subprocess.run(['bash', str(SKILLS/'skill-creator/scripts/validate-package.sh'),
                                         '--root', str(skills), '--estado', 'instancia'], capture_output=True, text=True)
            write(out/'instalacion/generado/validacion-instancia.log', validation.stdout+validation.stderr)
            for line in validation.stdout.splitlines():
                if line.startswith('FAIL ') or 'PASS=' in line:
                    print(line)
            if validation.returncode:
                raise Error('validación de instancia fallida; destino restaurado; revise validacion-instancia.log', 4)
            print('IDENTIDAD ADJUDICADA; propagación y carga real de ambos configs rc=0')
        except Exception:
            if profile_existed:
                shutil.copy2(Path(temp)/'perfil.tsv', product_profile)
            if not profile_existed and product_profile.exists():
                product_profile.unlink()
                if not manifests_existed and not any(product_profile.parent.iterdir()):
                    product_profile.parent.rmdir()
            for member in members:
                if (skills/member).exists():
                    shutil.rmtree(skills/member)
                if member in existing_members:
                    shutil.copytree(backup/member, skills/member, symlinks=True)
            if not existed and skills.exists() and not any(skills.iterdir()):
                skills.rmdir()
            if not claude_existed and (dst/'.claude').exists() and not any((dst/'.claude').iterdir()):
                (dst/'.claude').rmdir()
            raise


def normalize_linear(data, key):
    if data.get('errors'):
        raise Error('Linear: respuesta GraphQL con errores')
    if 'data' in data:
        teams = data['data']['teams']['nodes']
        teams = [t for t in teams if t['key'] == key]
        if len(teams) != 1:
            raise Error('Linear: clave sin equipo único')
        team = teams[0]
        data = {'team': {'id': team['id'], 'key': team['key']},
                'states': team['states']['nodes'], 'labels': team['labels']['nodes']}
        if team['states'].get('pageInfo', {}).get('hasNextPage') or team['labels'].get('pageInfo', {}).get('hasNextPage'):
            raise Error('Linear: consulta truncada; complete la paginación antes de generar')
    if data['team']['key'] != key or not re.fullmatch(UUID, data['team']['id']):
        raise Error('Linear: equipo o UUID inválido')
    result = {'team': {'id': data['team']['id'], 'key': key}, 'states': [], 'labels': []}
    for field in ('states', 'labels'):
        seen = set()
        for item in data[field]:
            if not re.fullmatch(UUID, item['id']) or item['id'] in seen:
                raise Error(f'Linear: UUID inválido o duplicado en {field}')
            # JSON no se sourcea: conservar nombres de labels con dos puntos o acentos.
            name = item['name']
            if not isinstance(name, str) or not name or len(name) > 200 or any(ord(c) < 32 or ord(c) == 127 for c in name) or SECRET.search(name):
                raise Error(f'Linear: nombre inválido o credencial en {field}')
            seen.add(item['id'])
            result[field].append({'id': item['id'], 'name': item['name']})
        result[field].sort(key=lambda x: (x['name'], x['id']))
    if not result['states']:
        raise Error('Linear: no hay estados')
    return result


def linear_request(query, variables, token):
    req = urllib.request.Request('https://api.linear.app/graphql',
                                 data=json.dumps({'query': query, 'variables': variables}).encode(),
                                 headers={'Content-Type': 'application/json', 'Authorization': token})
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            data = json.load(response)
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            raise Error('Linear: token rechazado') from None
        if exc.code == 429:
            raise Error('Linear: límite de peticiones; espere y repita') from None
        if exc.code != 400:
            raise Error('Linear: servicio HTTP '+str(exc.code)) from None
        try:
            data = json.load(exc)
        except (ValueError, OSError):
            raise Error('Linear: consulta rechazada por el servicio: HTTP 400') from None
        if not data.get('errors'):
            raise Error('Linear: consulta rechazada por el servicio: HTTP 400') from None
    except (OSError, TimeoutError):
        raise Error('Linear: sin conexión') from None
    if data.get('errors'):
        # Solo campos públicos; eliminar secretos incluso si el servicio los refleja.
        details = []
        for error in data['errors']:
            code = str(error.get('extensions', {}).get('code', 'GRAPHQL_ERROR'))
            message = str(error.get('message', 'error sin mensaje'))
            public = (code+': '+message).replace(token, '[redactado]')
            public = SECRET.sub('[redactado]', public)
            details.append(' '.join(public.split())[:500])
        raise Error('Linear: consulta rechazada por el servicio: '+'; '.join(details))
    return data['data']


def linear_query(args):
    if not re.fullmatch(r'[A-Z][A-Z0-9]{0,9}', args.equipo):
        raise Error('equipo: se esperaba una clave en mayúsculas')
    if args.fixture:
        data = json.loads(text(absolute(args.fixture)))
    else:
        if not re.fullmatch(r'[A-Z][A-Z0-9_]*', args.token_nombre):
            raise Error('token-nombre: se esperaba un nombre de variable')
        token = os.environ.get(args.token_nombre)
        if not token:
            raise Error('token: variable de entorno ausente; exporte el nombre indicado')
        query = 'query($key:String!){teams(first:1,filter:{key:{eq:$key}}){nodes{id key}}}'
        teams = linear_request(query, {'key': args.equipo}, token)['teams']['nodes']
        if len(teams) != 1 or teams[0]['key'] != args.equipo:
            raise Error('Linear: equipo '+args.equipo+' no encontrado con este token')
        data = {'team': teams[0]}
        for field in ('states', 'labels'):
            data[field] = []
            cursor, seen = None, set()
            query = ('query($id:String!,$c:String){team(id:$id){'+field+
                     '(first:100,after:$c){nodes{id name} pageInfo{hasNextPage endCursor}}}}')
            for page in range(20):
                connection = linear_request(query, {'id': teams[0]['id'], 'c': cursor}, token)['team'][field]
                data[field].extend(connection['nodes'])
                info = connection['pageInfo']
                if info['hasNextPage'] is False:
                    break
                if info['hasNextPage'] is not True or not info.get('endCursor') or info['endCursor'] in seen:
                    raise Error('Linear: paginación inválida en '+field)
                cursor = info['endCursor']
                seen.add(cursor)
            else:
                raise Error('Linear: tope de 20 páginas en '+field+'; consulta incompleta')
    normalized = normalize_linear(data, args.equipo)
    if args.out:
        write_linear(absolute(args.out), json_text(normalized))
    print('EQUIPO '+normalized['team']['key']+' '+normalized['team']['id'])
    for item in normalized['states']:
        print('ESTADO '+item['name']+' '+item['id'])
    for item in normalized['labels']:
        print('LABEL '+item['name']+' '+item['id'])


def main():
    # Antes de argparse: sus errores y su ayuda pueden reproducir argumentos.
    if any(SECRET.search(value) for value in sys.argv[1:]):
        raise Error('argumentos: credencial detectada; use solo datos públicos o el nombre de variable; nada escrito')
    parser = argparse.ArgumentParser(description='Instalación: datos públicos y validación estricta')
    sub = parser.add_subparsers(dest='command', required=True)
    q = sub.add_parser('cuestionario')
    q.add_argument('--respuestas', required=True)
    q.add_argument('accion', choices=['siguiente', 'registrar', 'revisar'])
    q.add_argument('id', nargs='?')
    q.add_argument('valor', nargs='?')
    q.add_argument('--defecto', action='store_true')
    g = sub.add_parser('generar')
    g.add_argument('--respuestas', required=True)
    g.add_argument('--salida', required=True)
    g.add_argument('--home', required=True)
    g.add_argument('--solo-env', action='store_true')
    g.add_argument('--forzar', action='store_true')
    g.add_argument('--linear-config')
    a = sub.add_parser('adjudicar')
    a.add_argument('--salida', required=True)
    a.add_argument('--home', required=True)
    a.add_argument('--destino', required=True)
    a.add_argument('--approved')
    a.add_argument('--sustituir', action='append', default=[], metavar='MIEMBRO')
    a.add_argument('--sustituir-todos', action='store_true')
    l = sub.add_parser('linear')
    l.add_argument('--equipo', required=True)
    l.add_argument('--fixture')
    l.add_argument('--token-nombre', default='LINEAR_API_KEY')
    l.add_argument('--out')
    args = parser.parse_args()
    if getattr(args, 'defecto', False):
        args.valor = '--defecto'
    {'cuestionario': questionnaire, 'generar': generator, 'adjudicar': adjudicate, 'linear': linear_query}[args.command](args)


if __name__ == '__main__':
    try:
        main()
    except Error as exc:
        print('ERROR: '+str(exc), file=sys.stderr)
        sys.exit(exc.rc)
    except (OSError, ValueError, KeyError, TypeError):
        print('ERROR: fichero ilegible, formato inválido o escritura incompleta; revise las entradas y destinos', file=sys.stderr)
        sys.exit(1)
