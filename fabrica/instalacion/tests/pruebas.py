#!/usr/bin/env python3
"""Casos de contrato, con guard de conteo y negativos de fallo único."""
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import subprocess
import tempfile
import sys
import time

HERE = Path(__file__).resolve().parent
INSTALL = HERE.parent
PACKAGE = INSTALL.parent
sys.path.insert(0, str(INSTALL/'scripts'))
from nucleo import exclusions, excluded
FIX = HERE/'fixtures'
TOTAL_ESPERADO = 444
PASS = 0
FAIL = 0


def check(name, condition):
    global PASS, FAIL
    if condition:
        PASS += 1
        print('ok '+name, flush=True)
    else:
        FAIL += 1
        print('FAIL '+name, flush=True)


def cli(script, *args, env=None):
    return subprocess.run(['bash', str(INSTALL/script), *map(str, args)], env=env,
                          capture_output=True, text=True)


def digest(root, *, core=False):
    h = hashlib.sha256()
    core = core or root == PACKAGE
    rules = exclusions(root) if core else []
    if root.exists():
        for f in sorted(root.rglob('*')):
            if core and excluded(f.relative_to(root), rules):
                continue
            if f.is_file():
                h.update(str(f.relative_to(root)).encode())
                h.update(f.read_bytes())
                h.update(str(f.stat().st_mode & 0o777).encode())
    return h.hexdigest()


def snapshot(root):
    # Incluye directorios: un rechazo previo no puede crear ni cambiar sus modos.
    return [(str(f.relative_to(root)), f.stat().st_mode & 0o777,
             f.read_bytes() if f.is_file() else None)
            for f in sorted(root.rglob('*'))]


def sensitive_modes(out, home, project, phase):
    for path in (home/project/'.env.local', out/'instalacion/generado/env.local.tmpl',
                 home/'.config/talent-channel-operation/agents.conf',
                 home/'.config/talent-orchestrator/agents.conf'):
        check(project+' permisos '+phase+' '+path.name+' '+str(path.parent.name),
              path.is_file() and path.stat().st_mode & 0o777 == 0o600)


def fixture(name):
    return dict(line.split('=', 1) for line in (FIX/name).read_text().splitlines())


def account_home(user):
    try:
        return Path(pwd.getpwnam(user).pw_dir)
    except KeyError:
        return Path('/home')/user


def put(path, values):
    path.write_text(''.join(f'{k}={v}\n' for k, v in values.items()))


def copiar_paquete(origen, destino, copiar=shutil.copy2):
    """Copia el paquete para verificarlo; `copiar` permite a las pruebas intercalar una carrera.

    Lo que `nucleo.exclude` declara fuera del núcleo (p. ej. `instalacion/estado/`) es estado vivo: otra
    prueba puede crearlo y borrarlo mientras se copia. Se usa la MISMA lista y la MISMA función que el
    manifiesto (`exclusions`/`excluded` de nucleo.py): un fichero así que desaparece no es un error;
    cualquier otro que desaparezca sí lo es.
    """
    reglas = exclusions(origen)
    def copiar_tolerante(src, dst, *, follow_symlinks=True):
        try:
            return copiar(src, dst, follow_symlinks=follow_symlinks)
        except FileNotFoundError:
            if excluded(Path(src).relative_to(origen), reglas) and not Path(src).exists():
                return dst
            raise
    shutil.copytree(origen, destino, copy_function=copiar_tolerante)


def copia_con_desaparicion(t, nombre, exclude, victima):
    """Mini paquete cuyo fichero `victima` desaparece justo antes de copiarlo; (error o None, raíz, destino)."""
    root = t/nombre
    (root/'instalacion/estado').mkdir(parents=True)
    (root/victima).parent.mkdir(parents=True, exist_ok=True)
    (root/'instalacion/nucleo.exclude').write_text(exclude)
    (root/'nucleo.txt').write_text('núcleo')
    (root/victima).write_text('vivo')
    perdido = root/victima
    def carrera(src, dst, *, follow_symlinks=True):
        if Path(src) == perdido:
            perdido.unlink()
        return shutil.copy2(src, dst, follow_symlinks=follow_symlinks)
    dst = t/(nombre+'-copia')
    try:
        copiar_paquete(root, dst, carrera)
    except (OSError, shutil.Error) as exc:
        return exc, root, dst
    return None, root, dst


def copia_paquete_con_estado_vivo(t):
    """Un fichero de estado vivo puede desaparecer durante la copia; la lista del manifiesto decide qué es estado."""
    canonical = (INSTALL/'nucleo.exclude').read_text()
    error, root, dst = copia_con_desaparicion(t, 'estado-vivo', canonical, 'instalacion/estado/log.tmp')
    check('copia del paquete tolera estado vivo que desaparece', error is None and (dst/'nucleo.txt').is_file())
    error, root, dst = copia_con_desaparicion(t, 'nucleo-pierde', canonical, 'nucleo.txt')
    check('copia del paquete falla si desaparece un fichero del núcleo', error is not None)
    error, root, dst = copia_con_desaparicion(t, 'lista-propia', 'volatil/\n', 'volatil/x.tmp')
    check('copia del paquete sigue la lista nucleo.exclude del árbol que copia', error is None)
    error, root, dst = copia_con_desaparicion(t, 'lista-sin-regla', '# sin reglas\n', 'volatil/x.tmp')
    check('copia del paquete sin la regla falla igual que cualquier fichero', error is not None)


def paquete_integro(t):
    source = (INSTALL/'instalacion.py').read_text()
    for name in ('ledger/cuentas.json', 'manifiestos/ejemplo.conf'):
        sha = hashlib.sha256((PACKAGE/name).read_bytes()).hexdigest()
        check('ejemplo coherente '+name, re.search(re.escape(repr(name))+r": '"+sha+r"'", source) is not None)
    out, home, dst = t/'paquete', t/'hogar', t/'producto'
    copiar_paquete(PACKAGE, out)
    def cli(script, *args, env=None):
        return subprocess.run(['bash', str(out/'instalacion'/script), *map(str, args)], env=env,
                              capture_output=True, text=True)
    answers = t/'integracion.resp'
    values = fixture('minima.resp')
    values['proyecto'] = 'prueba'
    put(answers, values)
    cmd = ('--respuestas', answers, '--salida', out, '--home', home)
    check('cuestionario fixture completo',
          cli('cuestionario.sh', '--respuestas', answers, 'siguiente').stdout.strip() == 'COMPLETO')
    result = cli('generar-instancia.sh', *cmd, '--solo-env')
    check('solo-env paquete íntegro', result.returncode == 0)
    result = cli('generar-instancia.sh', *cmd, '--linear-config', FIX/'linear.json')
    print('primera generación rc='+str(result.returncode)+'\n'+result.stdout+result.stderr)
    check('primera generación sustituye ejemplo', result.returncode == 0 and
          'sustituye el ejemplo de la distribución' in result.stdout)
    if result.returncode:
        return
    before = digest(out)+digest(home)
    check('segunda generación idempotente', cli('generar-instancia.sh', *cmd,
          '--linear-config', FIX/'linear.json').returncode == 0 and digest(out)+digest(home) == before)
    ledger = out/'ledger/cuentas.json'
    original = ledger.read_bytes()
    ledger.write_bytes(original+b' ')
    before = snapshot(out)+snapshot(home)
    check('ledger editado rc3 sin escribir', cli('generar-instancia.sh', *cmd).returncode == 3
          and snapshot(out)+snapshot(home) == before)
    ledger.write_bytes(original)
    dst.mkdir()
    subprocess.run(['git', '-C', str(dst), 'init', '-q'], check=True)
    subprocess.run(['git', '-C', str(dst), 'remote', 'add', 'origin', values['repo_url']], check=True)
    skills = dst/'.claude/skills'
    for member in ('propio-uno', 'propio-dos', 'skill-creator'):
        (skills/member).mkdir(parents=True)
        (skills/member/'SKILL.md').write_text('# Skill propio '+member+'\n')
    subprocess.run(['git', '-C', str(dst), 'add', '.'], check=True)
    subprocess.run(['git', '-C', str(dst), '-c', 'user.name=Operador',
                    '-c', 'user.email=operador@example.invalid', 'commit', '-qm', 'Skills propios'], check=True)
    adjud = ('--salida', out, '--home', home, '--destino', dst)
    before = snapshot(dst)
    result = cli('adjudicar-identidad.sh', *adjud)
    print('sin sustitución rc='+str(result.returncode)+'\n'+result.stdout+result.stderr)
    check('homónimo rc3 nombrado y salidas', result.returncode == 3 and
          'skill-creator' in result.stderr and 'renombrar' in result.stderr and '--sustituir' in result.stderr)
    check('rechazo nada escrito', snapshot(dst) == before)
    (skills/'talent-buzz').mkdir()
    (skills/'talent-buzz/SKILL.md').write_text('# Otro miembro previo\n')
    collective = snapshot(dst)
    result = cli('adjudicar-identidad.sh', *adjud)
    check('miembros todos los conflictos de una vez', result.returncode == 3 and
          'skill-creator' in result.stderr and 'talent-buzz' in result.stderr and
          'otro skill con el mismo nombre, o una versión anterior o modificada de este paquete' in result.stderr and snapshot(dst) == collective)
    result = cli('adjudicar-identidad.sh', *adjud, '--sustituir-todos')
    check('sustituir todos rechaza miembro sin guardar sin escribir', result.returncode == 3 and snapshot(dst) == collective)
    shutil.rmtree(skills/'talent-buzz')
    result = cli('adjudicar-identidad.sh', *adjud, '--sustituir', 'inventado')
    check('sustitución desconocida rc2 sin escribir', result.returncode == 2 and snapshot(dst) == before)
    (skills/'skill-creator/SKILL.md').write_text('# Cambio sin guardar\n')
    dirty = snapshot(dst)
    result = cli('adjudicar-identidad.sh', *adjud, '--sustituir', 'skill-creator')
    check('sustitución exige historial limpio', result.returncode == 3 and
          'historial de git' in result.stderr and snapshot(dst) == dirty)
    (skills/'skill-creator/SKILL.md').write_text('# Skill propio skill-creator\n')
    (skills/'skill-creator/sin-guardar.txt').write_text('Contenido propio\n')
    unsaved = snapshot(dst)
    result = cli('adjudicar-identidad.sh', *adjud, '--sustituir', 'skill-creator')
    check('fichero sin seguimiento impide sustitución', result.returncode == 3 and snapshot(dst) == unsaved)
    (skills/'skill-creator/sin-guardar.txt').unlink()
    before = snapshot(dst)
    result = cli('adjudicar-identidad.sh', *adjud, '--sustituir', 'skill-creator',
                 env=dict(os.environ, TCO_REPO_DIR='otro'))
    check('fallo carga restaura por miembro', result.returncode == 1 and
          'OVERRIDE DIVERGENTE' in result.stderr and snapshot(dst) == before)
    # El último gate también debe restaurar, sin convertirlo en aviso.
    src = out/'skills/talent-ceo/SKILL.md'
    good = src.read_text()
    src.write_text(good.replace('## Paquete de fábrica', '## Paquete incompleto'))
    result = cli('adjudicar-identidad.sh', *adjud, '--sustituir', 'skill-creator')
    print('fallo validador rc='+str(result.returncode)+'\n'+result.stdout+result.stderr)
    check('fallo validación restaura por miembro', result.returncode == 4 and snapshot(dst) == before)
    src.write_text(good)
    foreign = snapshot(skills/'propio-uno')+snapshot(skills/'propio-dos')
    result = cli('adjudicar-identidad.sh', *adjud, '--sustituir', 'skill-creator', '--sustituir', 'skill-creator')
    print('adjudicación rc='+str(result.returncode)+'\n'+result.stdout+result.stderr)
    check('ejemplo idéntico ignorado sustitución repetible', result.returncode == 0)
    if result.returncode:
        return
    check('miembros ausentes sembrados', all((skills/m/'SKILL.md').is_file() for m in
          ('talent-ceo', 'talent-orchestrator', 'skill-creator')))
    check('skills propios intactos', snapshot(skills/'propio-uno')+snapshot(skills/'propio-dos') == foreign)
    old = subprocess.run(['git', '-C', str(dst), 'show', 'HEAD:.claude/skills/skill-creator/SKILL.md'],
                         capture_output=True, text=True)
    check('homónimo conservado en git', old.returncode == 0 and old.stdout == '# Skill propio skill-creator\n')
    before = snapshot(dst)
    result = cli('adjudicar-identidad.sh', *adjud)
    check('repetición sin sustituir idempotente', result.returncode == 0 and snapshot(dst) == before)
    result = cli('adjudicar-identidad.sh', *adjud, '--sustituir', 'skill-creator')
    check('repetición con sustituir idempotente', result.returncode == 0 and snapshot(dst) == before)
    result = cli('adjudicar-identidad.sh', *adjud, '--sustituir-todos')
    check('sustituir todos repetición idempotente', result.returncode == 0 and snapshot(dst) == before)
    shutil.rmtree(skills/'talent-buzz')
    result = cli('adjudicar-identidad.sh', *adjud)
    check('instalación parcial siembra miembro ausente', result.returncode == 0 and
          (skills/'talent-buzz/SKILL.md').is_file())
    check('instalación parcial conserva ajenos', snapshot(skills/'propio-uno')+snapshot(skills/'propio-dos') == foreign)
    before = snapshot(dst)
    example = out/'manifiestos/ejemplo.conf'
    original = example.read_bytes()
    example.write_bytes(original+b'\n')
    result = cli('adjudicar-identidad.sh', *adjud)
    check('ejemplo editado rc2 nombra candidatos', result.returncode == 2 and
          'ejemplo.conf' in result.stderr and 'prueba.conf' in result.stderr and snapshot(dst) == before)
    example.write_bytes(original)
    shutil.copyfile(out/'manifiestos/prueba.conf', out/'manifiestos/otro.conf')
    result = cli('adjudicar-identidad.sh', *adjud)
    check('dos generados rc2 nombrados', result.returncode == 2 and
          'otro.conf' in result.stderr and 'prueba.conf' in result.stderr and snapshot(dst) == before)
    (out/'manifiestos/otro.conf').unlink()
    (out/'manifiestos/prueba.conf').unlink()
    result = cli('adjudicar-identidad.sh', *adjud)
    check('cero generados rc2', result.returncode == 2 and 'ninguno' in result.stderr and snapshot(dst) == before)


def proc_m13(skills, dst, stack, compatible=False):
    result = subprocess.run(['bash', str(skills/'talent-merger/references/proc-m13.selftest.sh'),
                             '--estado', 'instancia'], cwd=dst, capture_output=True, text=True,
                            env=dict(os.environ, GH_CONTRATO=str(PACKAGE/'tests/fixtures/instalacion/gh_contrato.py')),
                            timeout=240)
    output = result.stdout+result.stderr
    if stack != 'supabase':
        check(stack+' PROC-M13 omisión declarada', result.returncode == 0 and output.strip()
              == f'SKIP: PROC-M13 no aplica al stack {stack} — 0 asserts ejecutados')
        return
    red = [line for line in output.splitlines() if line.startswith('  ✗ ')]
    summaries = re.findall(r'^RESULTADO: (\d+) PASS / (\d+) FAIL / (\d+) NO-MEDIDO '
                           r' ·  huella de entradas [0-9a-f]+$', output, re.M)
    print(output, end='')
    label = 'supabase compatible' if compatible else 'supabase'
    check(label+' PROC-M13 rc real', result.returncode == 0)
    check(label+' PROC-M13 341 PASS sin FAIL ni NO-MEDIDO', summaries == [('341', '0', '0')])
    check(label+' PROC-M13 cero líneas rojas', not red)


def proc_m13_payload_negativos(refs):
    # El runner limita cada suite a 600 s. Estos controles ejercitan el mismo
    # analizador con JSON, sin repetir los 341 asserts ajenos a cada mutación.
    source = (refs/'proc-m13.selftest.sh').read_text()
    start = source.index('payload_sql() {\n')
    end = source.index('\necho "== T20:', start)
    lock = 'lock table supabase_migrations.schema_migrations in exclusive mode;'
    where = "where version = '20270101000000'"
    exception = "raise exception 'ABC: version 20270101000000 ya aplicada -- dato';"
    guard = ("do $$\nbegin\n  if exists (select 1 from supabase_migrations.schema_migrations "
             +where+") then\n    "+exception+"\n  end if;\nend $$;")
    sql = 'begin;\n'+lock+'\n'+guard+'\ncreate table t_20270101000000 (id int);\ncommit;\n'
    ddl = 'create table t_20270101000000 (id int);'
    variants = [
        ('lock comentario línea', sql.replace(lock, '-- '+lock), 1, -1),
        ('lock comentario bloque', sql.replace(lock, '/* '+lock+' */'), 1, -1),
        ('lock como dato', sql.replace(lock, 'select $dato$'+lock+'$dato$;'), 1, -1),
        ('where comentario bloque', sql.replace(where, '/* '+where+' */'), 4, 0),
        ('guard comentario bloque', sql.replace(guard, '/* '+guard+' */'), 3, -1),
        ('begin comentario línea', sql.replace('begin;\n', '-- begin;\n', 1), 0, -1),
        ('DDL comentario línea', sql.replace(ddl, '-- '+ddl), 2, -1),
        ('DDL como dato', sql.replace(ddl, 'select $dato$'+ddl+'$dato$;'), 2, -1),
        ('excepción como dato', sql.replace('raise exception', 'perform'), 5, 0),
        ('excepción fuera del guard', sql.replace(exception, '').replace(
            '  end if;', '  end if;\n    '+exception), 5, 0),
        ('where otra versión', sql.replace(where, where.replace('20270101000000', '20279999999999')), 4, 0),
        ('mensaje sin ya aplicada', sql.replace('ya aplicada', 'pendiente'), 5, 0),
        ('versión con escape octal no reconocido', sql.replace(where, "where version = E'2\\0270101000000'"), 5, 0),
        ('número pegado a palabra', sql.replace('select 1 from', 'select 1from'), 5, 0),
        ('identificador Unicode no es lock', sql.replace(lock, lock.replace('lock', 'loc\u212a')), 1, -1),
        ('espacio Unicode ante delimitador', sql.replace('do $$', 'do \u00a0$$'), 5, 0),
        ('identificador con dólar', sql.replace('do $$', 'do$guard$').replace('end $$;', 'end $guard$;'), 5, 0),
        ('rama else', sql.replace(exception, 'null; else null; '+exception), 5, 0),
        ('if falso anidado', sql.replace(exception, 'if false then null; '+exception+' end if;'), 5, 0),
        ('rama elsif', sql.replace(exception, 'null; elsif true then '+exception), 5, 0),
        ('segundo raise', sql.replace(exception, exception+' '+exception), 5, 0),
        ('sentencia antes del if', sql.replace('begin\n  if', 'begin\n  null; if'), 3, -1),
        ('argumentos de formato', sql.replace(exception, exception[:-1]+", 'dato';"), 5, 0),
        ('lenguaje sql explícito', sql.replace('do $$', 'do language sql $$'), 3, -1),
        ('sentencia después del if', sql.replace('end if;', 'end if; null;'), 5, 0),
        ('punto y coma final ajeno a plantilla', sql.replace('end $$;', 'end; $$;'), 5, 0),
        ('símbolo desconocido', sql+'\x00', 0, -1),
    ]
    # Una frontera en el comentario evita rechazos accidentales por proximidad.
    for label, fragment, field, expected in (
            ('lock', lock, 1, -1), ('guard', guard, 3, -1),
            ('where', where, 4, 0), ('excepción', exception, 5, 0)):
        for kind, commented in (('línea', '-- nota; '+fragment.replace('\n', ' ')+'\n'),
                                ('bloque', '/* nota; '+fragment+' */')):
            variants.append((label+' comentario '+kind+' con frontera',
                             sql.replace(fragment, commented), field, expected))
    for label, message in (
            ('dólar', '$$ABC: version 20270101000000 ya aplicada$$'),
            ('dólar etiquetado', '$m$ABC: version 20270101000000 ya aplicada$m$'),
            ('escape E', "E'ABC \\'dato: version 20270101000000 ya aplicada'")):
        variants.append((label, sql.replace('do $$', 'do $guard$').replace('end $$;', 'end $guard$;')
                         .replace(exception, 'raise exception '+message+';'), 5, 1))
    # Forma canónica completa: comentarios y saltos intercalados en cada frontera.
    for label, message in (
            ('comillas', "'ABC: version 20270101000000 ya aplicada'"),
            ('escape E', "E'ABC \\'dato: version 20270101000000 ya aplicada'"),
            ('dólar', '$m$ABC: version 20270101000000 ya aplicada$m$')):
        canonical = ("BEGIN /* nota */\n IF -- nota\n EXISTS ( SELECT 1 FROM "
                     "supabase_migrations . schema_migrations WHERE version = '20270101000000' "
                     ") THEN /* exterior /* interior */ fin */ RAISE -- nota\n EXCEPTION "
                     +message+" ; END IF ; END")
        variants.append(('canónico '+label+' mayúsculas comentarios y saltos',
                         sql.replace(guard, 'do $guard$'+canonical+'$guard$;'), 5, 1))
    with tempfile.TemporaryDirectory(prefix='proc-payload-') as tmp:
        root = Path(tmp)
        reader, payload = root/'leer.sh', root/'payload.json'
        reader.write_text(source[start:end]+'\npayload_sql "$1"\n')
        for label, changed, field, expected in variants:
            payload.write_text(json.dumps({'query': changed}))
            result = subprocess.run(['bash', str(reader), str(payload)],
                                    capture_output=True, text=True, timeout=10)
            values = result.stdout.split()
            check('PROC-M13 payload negativo '+label, result.returncode == 0
                  and len(values) == 6 and values[field] == str(expected))
        bad = guard.replace('20270101000000', '20279999999999').replace(
            exception.replace('20270101000000', '20279999999999'), '')
        for label, changed, chosen, version, raised in (
                ('dos guards separados por lock', 'begin;\n'+guard+'\n'+lock+'\n'+bad+'\n'+ddl, guard, 1, 1),
                ('primero pertinente inválido', 'begin;\n'+lock+'\n'+bad+'\n'+guard+'\n'+ddl, guard, 1, 1),
                ('primero pertinente sin candidato válido', 'begin;\n'+lock+'\n'+bad+'\n'+bad+'\n'+ddl, bad, 0, 0),
                ('primer guard válido', 'begin;\n'+lock+'\n'+guard+'\n'+guard+'\n'+ddl, guard, 1, 1)):
            payload.write_text(json.dumps({'query': changed}))
            result = subprocess.run(['bash', str(reader), str(payload)],
                                    capture_output=True, text=True, timeout=10)
            values = result.stdout.split()
            check('PROC-M13 payload '+label, result.returncode == 0 and len(values) == 6
                  and values[3:] == [str(changed.index(chosen)), str(version), str(raised)])
        # Mide tokenización y búsqueda dentro del caso, sin generar el payload cronometrado.
        payload.write_text(json.dumps({'query': sql+';'*256000}))
        started = time.monotonic()
        result = subprocess.run(['bash', str(reader), str(payload)],
                                capture_output=True, text=True, timeout=10)
        elapsed = time.monotonic()-started
        print(f'PROC-M13 256000 separadores: {elapsed:.6f} s', flush=True)
        check('PROC-M13 payload coste lineal 256000 separadores',
              result.returncode == 0 and result.stdout.split()[4:] == ['1', '1'] and elapsed < 2)


def proc_m13_negativos(skills, dst):
    refs = skills/'talent-merger/references'
    annex = next(refs.glob('anexo-*.md'))
    original = annex.read_text()
    message = "raise exception 'PROC-M13: version %s ya aplicada -- retry duplicado tras carrera de lock, abortando sin repetir DDL';"
    assertion = 'el guard aborta con raise exception nombrando la version'
    variants = [
        ('excepción comentario línea', message, '-- '+message, assertion),
        ('excepción comentario bloque', message, '/* '+message+' */', assertion),
        ('sin excepción', message, '', assertion),
        ('otra versión', message, message.replace('version %s', 'version 20279999999999'), assertion),
        ('identificador con dólar', 'printf "do ', 'printf "do', 'orden lock < guard < DDL'),
        ('rama else', message, 'null; else null; '+message, assertion),
        ('if falso anidado', message, 'if false then null; '+message+' end if;', assertion),
    ]
    # Reproduce el fixture completo: un guard antes del lock y otro sin excepción después.
    guard_start = original.index('      printf "do ')
    guard_end = original.index('\n      cat "$SQL_FILE"', guard_start)
    guard_printf = original[guard_start:guard_end]
    lock_printf = "      printf 'lock table supabase_migrations.schema_migrations in exclusive mode;\\n'"
    bad_guard = guard_printf.replace("version = '%s'", "version = '20279999999999'").replace(message, '')
    combined = (original[:guard_start]+bad_guard+original[guard_end:]).replace(
        lock_printf, guard_printf+'\n'+lock_printf)
    variants.append(('dos guards separados por lock', original, combined, 'orden lock < guard < DDL'))
    try:
        for label, anchor, changed, expected_red in variants:
            if original.count(anchor) != 1:
                check('PROC-M13 negativo '+label, False)
                continue
            annex.write_text(original.replace(anchor, changed))
            result = subprocess.run(['bash', str(refs/'proc-m13.selftest.sh'), '--estado', 'instancia'],
                                    env=dict(os.environ, GH_CONTRATO=str(PACKAGE/'tests/fixtures/instalacion/gh_contrato.py')),
                                    cwd=dst, capture_output=True, text=True, timeout=240)
            output = result.stdout+result.stderr
            print('PROC-M13 negativo '+label+' rc='+str(result.returncode), flush=True)
            for line in output.splitlines():
                if line.startswith(('  ✗ ', 'RESULTADO:')):
                    print(line, flush=True)
            check('PROC-M13 negativo '+label, result.returncode == 1
                  and '  ✗ '+expected_red+' (' in output)
        # Comillas SQL duplicadas y marcadores de comentario dentro del mensaje son datos.
        annex.write_text(original.replace('PROC-M13: version', "ABC -- /* ''dato'': version"))
        proc_m13(skills, dst, 'supabase')
        # Bash y printf consumen dos niveles: cuatro barras en el anexo emiten una en SQL.
        annex.write_text(original.replace("'PROC-M13: version", "E'ABC "+'\\'*4+"'dato: version"))
        proc_m13(skills, dst, 'supabase')
    finally:
        annex.write_text(original)
    check('PROC-M13 negativos restauración exacta', annex.read_text() == original)
    proc_m13(skills, dst, 'supabase')
    proc_m13_payload_negativos(refs)


def main(t):
    result = subprocess.run([sys.executable, str(HERE/'ayuda-claude-auth.py')], capture_output=True, text=True)
    check('ayuda de acreditación conserva formato y explica token', result.returncode == 0)
    os.umask(0o022)
    sample = t/'huella-paquete'
    (sample/'instalacion').mkdir(parents=True)
    shutil.copyfile(INSTALL/'nucleo.exclude', sample/'instalacion/nucleo.exclude')
    (sample/'nucleo.txt').write_text('núcleo')
    before = digest(sample, core=True)
    (sample/'instalacion/estado').mkdir()
    (sample/'instalacion/estado/log').write_text('estado vivo')
    check('huella excluye estado vivo', digest(sample, core=True) == before)
    (sample/'instalacion/generado').mkdir()
    (sample/'instalacion/generado/config').write_text('configuración generada')
    check('huella excluye generado con lista compartida', digest(sample, core=True) == before)
    (sample/'nucleo.txt').write_text('núcleo cambiado')
    check('huella detecta byte cambiado del núcleo', digest(sample, core=True) != before)
    (sample/'nucleo.txt').write_text('núcleo')
    check('huella restaurada verde', digest(sample, core=True) == before)
    package_hash = digest(PACKAGE)
    templates = subprocess.run(['grep', '-rEif', str(HERE/'denylist-casa.txt'),
                                str(INSTALL/'plantillas')], capture_output=True)
    check('plantillas neutras', templates.returncode == 1 and not templates.stdout)
    answers = t/'respuestas'
    result = cli('cuestionario.sh', '--respuestas', answers, 'siguiente')
    check('una pregunta inicial', result.returncode == 0 and len(result.stdout.splitlines()) == 1
          and result.stdout.startswith('proyecto\t'))
    result = cli('cuestionario.sh', '--respuestas', answers, 'registrar', 'proyecto', 'ejemplo')
    check('registro 0600', result.returncode == 0 and answers.stat().st_mode & 0o777 == 0o600)
    check('reanudar siguiente', cli('cuestionario.sh', '--respuestas', answers, 'siguiente').stdout.startswith('repo_url\t'))
    # Los errores previos al parser tampoco pueden reproducir credenciales.
    commands = [
        ('cuestionario.sh', '--respuestas', answers, 'registrar', 'proyecto'),
        ('generar-instancia.sh', '--respuestas', FIX/'minima.resp', '--salida', t/'secreto-salida', '--home', t/'secreto-home'),
        ('adjudicar-identidad.sh', '--salida', t/'secreto-salida', '--home', t/'secreto-home', '--destino', t/'secreto-destino'),
        ('consultar-estados-linear.sh', '--equipo', 'ABC', '--fixture', FIX/'linear.json', '--out', t/'secreto.json')]
    for command in commands:
        for marker in ('--lin_api_marcador_sintetico', '--extra=github_pat_sintetico',
                       'sk-marcador_sintetico', '--eyJabcdefghijklmnop'):
            before = digest(t)
            result = cli(*command, marker)
            check('argumentos públicos '+command[0]+' '+str(commands.index(command))+' '+str(len(marker)),
                  result.returncode == 2 and digest(t) == before
                  and marker.removeprefix('--') not in result.stdout+result.stderr
                  and marker not in result.stdout+result.stderr)
    invalid = [('linear_clave', 'abc'), ('canales_n', '0'), ('canales_n', '10'),
               ('linear_equipo_uuid', 'mal'), ('repo_url', 'https://user@github.com/org/repo'),
               ('proyecto', 'lin_api_secreto'), ('repo_url', 'https://github.com/org/repo con espacio'),
               ('proyecto', '$(touch /tmp/prohibido)'), ('pozos_alias', 'a,a'),
               ('superficies_paths', 'auth:../src/**'),
               ('superficies_paths', 'auth:src/**,auth:db/**'),
               ('linear_workspace', 'workspace con espacio'), ('initiative_uuid', 'no-uuid')]
    for key, value in invalid:
        before = digest(t)
        result = cli('cuestionario.sh', '--respuestas', answers, 'registrar', key, value)
        check('rechazo '+key+' '+str(invalid.index((key, value))), result.returncode == 2 and digest(t) == before
              and 'lin_api_secreto' not in result.stdout+result.stderr)
    for key, value in (('migraciones_dir', '../db'), ('vault_gate', 'scripts//vault.sh')):
        bad = fixture('completa.resp')
        bad[key] = value
        path = t/'ruta-db-invalida.resp'
        put(path, bad)
        before = digest(t)
        result = cli('generar-instancia.sh', '--respuestas', path,
                     '--salida', t/'db-invalida', '--home', t/'db-invalida-home')
        check('ruta DB rechazada '+key, result.returncode == 2 and key in result.stderr
              and digest(t) == before)
    unknown = t/'desconocida'
    unknown.write_text('desconocida=si\n')
    check('clave desconocida', cli('cuestionario.sh', '--respuestas', unknown, 'revisar').returncode == 2)
    duplicate = t/'duplicada'
    duplicate.write_text('proyecto=ejemplo\nproyecto=demo\n')
    check('clave duplicada', cli('cuestionario.sh', '--respuestas', duplicate, 'siguiente').returncode == 2)
    for name, content in [('nul', b'proyecto=ejemplo\x00\n'), ('cr', b'proyecto=ejemplo\r\n'), ('bom', b'\xef\xbb\xbfproyecto=ejemplo\n')]:
        path = t/name
        path.write_bytes(content)
        check('bytes '+name, cli('cuestionario.sh', '--respuestas', path, 'revisar').returncode == 2)
    dependency = t/'dependencia'
    dependency.write_text('proyecto=ejemplo\ncodex=si\ncodex_n=2\n')
    result = cli('cuestionario.sh', '--respuestas', dependency, 'registrar', 'codex', 'no')
    check('dependencia elimina respuesta', result.returncode == 0 and 'codex_n' not in dependency.read_text())
    check('dependencia rechaza pregunta', cli('cuestionario.sh', '--respuestas', dependency, 'registrar', 'codex_n', '2').returncode == 2)
    complete = t/'completa'
    complete.write_text((FIX/'minima.resp').read_text())
    check('COMPLETO', cli('cuestionario.sh', '--respuestas', complete, 'siguiente').stdout.strip() == 'COMPLETO')
    check('revisar datos', 'linear_clave=ABC' in cli('cuestionario.sh', '--respuestas', complete, 'revisar').stdout)
    result = cli('cuestionario.sh', '--respuestas', answers, 'registrar', 'repo_rama', '--defecto')
    check('defecto explícito', result.returncode == 0 and 'repo_rama=main' in answers.read_text())
    before = answers.read_bytes()
    result = cli('cuestionario.sh', '--respuestas', answers, 'registrar', 'repo_rama', 'develop')
    check('rama principal incompatible rechazada sin escrituras', result.returncode == 2 and
          'esta versión requiere main' in result.stderr and answers.read_bytes() == before)
    for key in ('superficies_paths', 'playwright_flujos'):
        for _ in range(3):
            result = cli('cuestionario.sh', '--respuestas', complete, 'registrar', key, '--defecto')
        check('defecto opcional repetido conserva una línea '+key, result.returncode == 0 and
              complete.read_text().splitlines().count(key+'=') == 1 and
              cli('cuestionario.sh', '--respuestas', complete, 'siguiente').stdout.strip() == 'COMPLETO')
        duplicated = t/'opcional-duplicada.resp'
        duplicated.write_text(complete.read_text()+key+'=\n')
        before = duplicated.read_bytes()
        result = cli('cuestionario.sh', '--respuestas', duplicated, 'registrar', key, '--defecto')
        check('opcional vacío duplicado sigue rechazado '+key, result.returncode == 2 and
              duplicated.read_bytes() == before)
    topology = t/'usuarios.resp'
    for actor in ('usuario_ceo', 'usuario_c1', 'usuario_m1', 'usuario_incus', 'usuario_orq', 'usuario_pm', 'cuser'):
        put(topology, fixture('completa.resp'))
        check('root rechazado '+actor, cli('cuestionario.sh', '--respuestas', topology, 'registrar', actor, 'root').returncode == 2)
    put(topology, fixture('completa.resp'))
    result = cli('cuestionario.sh', '--respuestas', topology, 'registrar', 'usuario_incus', '--defecto')
    check('F5 defecto usuario incus', result.returncode == 0
          and 'usuario_incus=demo-incus' in topology.read_text())
    for actor in ('usuario_ceo', 'usuario_c1', 'usuario_m1', 'usuario_orq', 'usuario_pm'):
        for key, value in [('usuario_incus', fixture('completa.resp')[actor]),
                           (actor, 'operador-incus')]:
            values = fixture('completa.resp')
            values['usuario_incus'] = 'operador-incus'
            put(topology, values)
            before = snapshot(t)
            result = cli('cuestionario.sh', '--respuestas', topology, 'registrar', key, value)
            check('F5 rechazo repetición '+actor+' '+key,
                  result.returncode == 2 and snapshot(t) == before)
    values = fixture('minima.resp')
    values.pop('usuario_incus', None)
    put(topology, values)
    result = cli('cuestionario.sh', '--respuestas', topology, 'siguiente')
    check('F5 pregunta incus una por turno', result.stdout.startswith('usuario_incus\t')
          and len(result.stdout.splitlines()) == 1)
    check('F5 incus obligatorio sin escritura', cli('generar-instancia.sh', '--respuestas', topology,
          '--salida', t/'sin-incus', '--home', t/'sin-incus-home').returncode == 2
          and not (t/'sin-incus').exists())
    dynamic = t/'gates.resp'
    put(dynamic, {k: v for k, v in fixture('minima.resp').items() if not k.startswith('gate_cmd_')})
    cli('cuestionario.sh', '--respuestas', dynamic, 'registrar', 'gates_ids', 'lint unit-test')
    result = cli('cuestionario.sh', '--respuestas', dynamic, 'siguiente')
    check('F1 una pregunta derivada', result.stdout.startswith('gate_cmd_lint\t') and len(result.stdout.splitlines()) == 1)
    cli('cuestionario.sh', '--respuestas', dynamic, 'registrar', 'gate_cmd_lint', 'true')
    check('F1 siguiente gate', cli('cuestionario.sh', '--respuestas', dynamic, 'siguiente').stdout.startswith('gate_cmd_unit_test\t'))
    cli('cuestionario.sh', '--respuestas', dynamic, 'registrar', 'gate_cmd_unit_test', 'true')
    check('F1 gates completo', cli('cuestionario.sh', '--respuestas', dynamic, 'siguiente').stdout.strip() == 'COMPLETO')
    cli('cuestionario.sh', '--respuestas', dynamic, 'registrar', 'gates_ids', 'lint')
    check('F1 cambiar lista retira comando', 'gate_cmd_unit_test=' not in dynamic.read_text())
    for key, value in [('gates_ids', ''), ('gates_ids', 'unit unit'), ('gates_ids', 'unit-test unit_test'),
                       ('gate_cmd_lint', 'true;false'), ('gate_cmd_lint', 'echo $(id)'), ('gate_cmd_lint', 'true|false')]:
        before = digest(t)
        check('F1 charset y unicidad '+str(value), cli('cuestionario.sh', '--respuestas', dynamic,
              'registrar', key, value).returncode == 2 and digest(t) == before)
    result = cli('cuestionario.sh', '--respuestas', dynamic, 'registrar', 'gate_cmd_lint', 'env MODE=test bash scripts/lint.sh --quiet')
    check('F1 comando con igual', result.returncode == 0)
    for value in ('./scripts/lint.sh', '/usr/bin/true'):
        check('F1 comando ruta '+value, cli('cuestionario.sh', '--respuestas', dynamic,
              'registrar', 'gate_cmd_lint', value).returncode == 0)
    before = digest(t)
    check('F1 comando solo espacios rechazado', cli('cuestionario.sh', '--respuestas', dynamic,
          'registrar', 'gate_cmd_lint', '   ').returncode == 2 and digest(t) == before)
    sensitive = fixture('minima.resp')
    sensitive.pop('superficies_sensibles')
    put(dynamic, sensitive)
    check('F1 defecto superficies adaptado', cli('cuestionario.sh', '--respuestas', dynamic,
          'siguiente').stdout.rstrip().endswith('\tauth credenciales'))
    only = t/'solo'
    result = cli('generar-instancia.sh', '--respuestas', answers, '--salida', only, '--home', t/'solo-home', '--solo-env')
    check('solo env parcial', result.returncode == 0 and not (only/'manifiestos').exists())
    check('privacidad directorio nuevo 0700 con umask 022',
          (t/'solo-home/ejemplo').stat().st_mode & 0o777 == 0o700)
    check('incompleto sin escritura', cli('generar-instancia.sh', '--respuestas', answers, '--salida', t/'no-generar', '--home', t/'no-home').returncode == 2 and not (t/'no-generar').exists())
    # Tres fixtures válidos, idempotencia, formatos, neutralidad y adjudicación real.
    for name in ('minima.resp', 'completa.resp', 'nueve.resp'):
        a = fixture(name)
        p = a['proyecto']
        out = t/p
        home = t/(p+'-home')
        home.mkdir(mode=0o755)
        (home/'.config').mkdir(mode=0o755)
        shared_modes = (home.stat().st_mode, (home/'.config').stat().st_mode)
        owned = [home/p, home/'.config/talent-channel-operation', home/'.config/talent-orchestrator']
        for directory in owned:
            directory.mkdir(mode=0o755)
            directory.chmod(0o755)
        cmd = ('--respuestas', FIX/name, '--salida', out, '--home', home)
        previous_umask = os.umask(0o022)
        try:
            result = cli('generar-instancia.sh', *cmd)
        finally:
            os.umask(previous_umask)
        print(result.stdout, end='')
        if result.returncode:
            print(result.stderr)
        check(p+' generar', result.returncode == 0)
        check(p+' privacidad propios preexistentes 0700',
              all(directory.stat().st_mode & 0o777 == 0o700 for directory in owned))
        sensitive_modes(out, home, p, 'generación')
        hash1 = digest(out)+digest(home)
        for directory in owned:
            directory.chmod(0o755)
        for sensitive_path in (home/p/'.env.local', out/'instalacion/generado/env.local.tmpl',
                               *(directory/'agents.conf' for directory in owned[1:])):
            sensitive_path.chmod(0o644)
        result = cli('generar-instancia.sh', *cmd)
        hash2 = digest(out)+digest(home)
        print('sha256 '+hash1+'\nsha256 '+hash2)
        check(p+' idempotencia', result.returncode == 0 and hash1 == hash2)
        check(p+' privacidad regeneración propios 0700',
              all(directory.stat().st_mode & 0o777 == 0o700 for directory in owned))
        check(p+' privacidad home y compartido intactos',
              shared_modes == (home.stat().st_mode, (home/'.config').stat().st_mode))
        sensitive_modes(out, home, p, 'regeneración')
        envpath = home/p/'.env.local'
        check(p+' env vacío 0600', envpath.stat().st_mode & 0o777 == 0o600
              and all(line.endswith('=') for line in envpath.read_text().splitlines()))
        ledger = json.loads((out/'ledger/cuentas.json').read_text())
        check(p+' ledger', len(ledger['pozos']) == len(a['pozos_alias'].split(','))
              and ledger['coordinator_host'] == a['host_nombre']
              and all(v['habilitada_fabrica'] for v in ledger['pozos'].values()))
        profile = (out/f'manifiestos/{p}.perfil.tsv').read_text()
        manifest = (out/f'manifiestos/{p}.conf').read_text()
        check(p+' identidad local de estación y runners', (out/'manifiestos/runner-identity.map').read_text() ==
              a['host_nombre']+'='+a['host_nombre']+'\n')
        check(p+' F1 manifiesto con gates ejecutables', bool(re.search(r'^TF_GATE_IDS="[^"]+"$', manifest, re.M))
              and bool(re.search(r'^TF_GATE_CMD_[a-z0-9_]+="[^"]+"$', manifest, re.M)))
        check(p+' F2 bus bajo home', f'path={home}/{p}/bus;' in profile)
        check(p+' F3 agents en defaults', (home/'.config/talent-channel-operation/agents.conf').is_file()
              and (home/'.config/talent-orchestrator/agents.conf').is_file())
        rows = [line.split('\t') for line in profile.splitlines()[1:]]
        check(p+' F4 convenciones runtime', all(row[4] == 'torre-'+row[1].lower() for row in rows if row[0] == 'torre')
              and all(row[3] == 'vibe-channel-'+row[1] and row[4] == 'v' for row in rows if row[0] == 'canal'))
        if p == 'ejemplo':
            without = fixture(name)
            for key in list(without):
                if key == 'gates_ids' or key.startswith('gate_cmd_'):
                    del without[key]
            path = t/'sin-gates.resp'
            put(path, without)
            check('F1 sin gates rechazo sin escritura', cli('generar-instancia.sh', '--respuestas', path,
                  '--salida', t/'sin-gates', '--home', t/'sin-gates-home').returncode == 2
                  and not (t/'sin-gates').exists())
            without = fixture(name)
            del without['gate_cmd_humo']
            put(path, without)
            check('F1 sin comando rechazo sin escritura', cli('generar-instancia.sh', '--respuestas', path,
                  '--salida', t/'sin-comando', '--home', t/'sin-comando-home').returncode == 2
                  and not (t/'sin-comando').exists())
        check(p+' F1 defaults stack E2E', ('TF_DB_GATE="always"' in manifest if a['supabase'] == 'si'
              else 'TF_DB_GATE="never"' in manifest and 'TF_MIGRATIONS_DIR=""' in manifest)
              and ('TF_E2E_FAMILIES="e2e-core"' in manifest if a['e2e'] == 'si'
                   else all(f'{key}=""' in manifest for key in ('TF_E2E_FAMILIES', 'TF_E2E_WRAPPER', 'TF_SHARDS_REGISTRY'))))
        auditor = 'codex' if a['codex'] == 'si' else 'claude-root'
        channels = [line.split('\t') for line in profile.splitlines() if line.startswith('canal\t')]
        check(p+' auditor configurado auditor en cada canal', len(channels) == int(a['canales_n'])
              and all([attr for attr in row[5].split(';') if attr.startswith('auditor=')] == ['auditor='+auditor]
                      for row in channels))
        agents = (home/'.config/talent-channel-operation/agents.conf').read_text().splitlines()
        check(p+' F4 coherencia agents perfil', 'TCO_PREFIX="vibe-channel-"' in agents
              and 'TCO_TMUX="v"' in agents and 'TORC_CHANNEL_PREFIX="vibe-channel-"' in agents)
        check(p+' auditor configurado auditor agents', [line for line in agents if line.startswith('TCO_AUDIT_CLI=')]
              == [f'TCO_AUDIT_CLI="{auditor}"'])
        for member in ('talent-channel-operation', 'talent-merger', 'talent-ceo'):
            anexo = (out/f'instalacion/generado/anexos/{member}/anexo-{p}.md').read_text()
            check(p+' canon '+member, all(f'## §{n} — ' in anexo for n in range(1, 7))
                  and '## Notas operativas' in anexo)
            check(p+' contexto '+member, all(value in anexo for value in
                  (a['linear_inprogress_uuid'], a['linear_inreview_uuid'], a['linear_equipo_uuid'],
                   a['repo_rama'], a.get('usuario_incus', p+'-incus'), str(out/f'manifiestos/{p}.perfil.tsv')))
                  and f'| Stack | `{ "supabase" if a["supabase"] == "si" else "ninguno" }` |' in anexo)
            check(p+' sin marcadores '+member, not re.search(r'\{\{[a-z0-9_]+\}\}|<NOMBRE|<KEY>|<uuid>|\bTODO\b', anexo)
                  and 'Autoridades de onboarding: vacías' in anexo)
            check(p+' contrato DB '+member,
                  (a['supabase_ref'] in anexo and 'migration_slots' in anexo if a['supabase'] == 'si'
                   else 'no hay base de datos gestionada' in anexo and 'PROC-M13 no aplica' in anexo))
            if member == 'talent-merger' and a['supabase'] == 'si':
                inv = (PACKAGE/'skills/talent-merger/invariants.tsv').read_text().splitlines()
                ids = {'INV-ME-'+n for n in ('052', '137', '138', '139', '148', '318', '319', '326', '345', '352')}
                selected = [row.split('\t') for row in inv if row.split('\t')[0] in ids]
                check(p+' diez MUST reales', len(selected) == 10
                      and {fields[0] for fields in selected} == ids
                      and all(len(fields) == 5 and fields[2] == 'MUST' for fields in selected))
                for fields in selected:
                    # Misma coincidencia ERE por línea que validate-package.sh, sin copiar patrones.
                    match = subprocess.run(['grep', '-Eq', '-e', fields[3]], input=anexo, text=True)
                    check(p+' contenido '+fields[0], fields[2] == 'MUST' and match.returncode == 0)
                block = re.search(r'```bash\n(#!/usr/bin/env bash\n.*?)\n```', anexo, re.S)
                syntax = subprocess.run(['bash', '-n'], input=block[1] if block else '',
                                        text=True, capture_output=True)
                check(p+' sintaxis PROC-M13 generado', block is not None and syntax.returncode == 0)
            check(p+' auditor configurado auditor anexo '+member,
                  re.findall(r'Auditor de los canales: ([^.]+)\.', anexo) == [auditor])
        attrs = {row[1]: dict(item.split('=', 1) for item in row[5].split(';')) for row in rows}
        actors = [row for row in rows if row[0] in ('ceo', 'torre', 'estacion', 'pm')]
        runner = 'runner-'+p
        check(p+' runner perfil y anexos coherentes',
              attrs.get(runner) == {'usuario': a['usuario_incus'], 'usuario_contenedor': 'runner', 'repo': '/home/runner/repo'}
              and any(row[:4] == ['runner', runner, 'maquina-'+a['maquina_n'], runner] for row in rows)
              and all(all(value in (out/f'instalacion/generado/anexos/{member}/anexo-{p}.md').read_text()
                          for value in (runner, 'TF_RUNNERS='+runner, 'TF_RUNNER_USER=runner',
                                        'TF_RUNNER_REPO=/home/runner/repo', 'TF_STATION_HOST='+a['host_nombre'], 'seal-suite.sh'))
                      and not re.search(r'no hay (?:filas\s+)?runner|no hay satélites, runners',
                                        (out/f'instalacion/generado/anexos/{member}/anexo-{p}.md').read_text(), re.I)
                      for member in ('talent-ceo', 'talent-merger', 'talent-channel-operation', 'talent-coordination')))
        check(p+' estado bus generado antes del montaje', all(attrs[row[1]]['estado_bus'] ==
              str(account_home(attrs[row[1]]['usuario'])/'.local/state/talent-ceo')
              for row in actors))
        check(p+' perfil roles usuarios', all(attrs[actor[1]].get('usuario')
              and all(attrs[other[1]].get('usuario') != attrs[actor[1]]['usuario']
                      for other in rows if other[0] in ('ceo', 'torre', 'estacion', 'canal', 'runner', 'pm')
                      and other[1] != actor[1] and other[2] == actor[2]) for actor in actors)
              and profile.count('\ncanal\t') == int(a['canales_n'])
              and ('\npm\t' in profile) == (a['pm'] == 'si'))
        check(p+' F5 canales usuario incus compartido',
              {attrs[row[1]].get('usuario') for row in channels} == {a.get('usuario_incus', p+'-incus')})
        check(p+' F5 bus lectores sin atributo inerte', attrs['BUS'] ==
              {'path': str(home/p/'bus'), 'lectores': ','.join(row[1] for row in actors)})
        cron = subprocess.run(['bash', str(PACKAGE/'skills/talent-ceo/scripts/tablas-cron.sh'),
                               '--minutos', 'CRON'], env=dict(os.environ,
                               TA_PERFIL=str(out/f'manifiestos/{p}.perfil.tsv')), capture_output=True, text=True)
        check(p+' F5 cron consumidor real', cron.returncode == 0 and cron.stdout.strip() == '07,22,37,52'
              and attrs['CRON'] == {'dueno': 'CEO', 'minutos': '07,22,37,52'})
        check(p+' F5 PM explícito coherente', not any(row[0] == 'pm' for row in rows) if a['pm'] == 'no'
              else attrs['PM'] == {'usuario': a['usuario_pm'], 'estado_bus': str(account_home(a['usuario_pm'])/'.local/state/talent-ceo')}
              and next(row for row in rows if row[0] == 'pm')[2] == 'maquina-'+a['maquina_n'])
        # Los UUID de la distribución de ejemplo se obtienen como datos: no se incrustan en fixtures.
        denyfile = t/'denylist'
        uuids = set(re.findall(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}',
                              (PACKAGE/'skills/linear-skill/examples/talent-engine-config.json').read_text()))
        denyfile.write_text((HERE/'denylist-casa.txt').read_text()+'\n'.join(sorted(uuids))+'\n')
        deny = subprocess.run(['grep', '-rEif', str(denyfile), str(out), str(home)], capture_output=True)
        print('denylist rc='+str(deny.returncode))
        check(p+' denylist', deny.returncode == 1 and not deny.stdout)
        check(p+' sin identidad en distribución generada', not list(out.rglob('repo-identity.conf')))
        # Crear el destino sintético de la prueba, sin red.
        dst = t/(p+'-producto')
        dst.mkdir()
        subprocess.run(['git', '-C', str(dst), 'init', '-q'], check=True)
        subprocess.run(['git', '-C', str(dst), 'remote', 'add', 'origin', a['repo_url']], check=True)
        adjud = ('--salida', out, '--home', home, '--destino', dst)
        result = cli('adjudicar-identidad.sh', *adjud)
        print(result.stdout, end='')
        if result.returncode != 0:
            print(result.stderr)
        skills = dst/'.claude/skills'
        check(p+' migración propagación carga', result.returncode == 0
              and 'carga real de ambos configs rc=0' in result.stdout and 'PARIDAD-NUCLEO: OK' in result.stdout)
        proc_m13(skills, dst, 'supabase' if a['supabase'] == 'si' else 'ninguno')
        if a['supabase'] == 'si':
            proc_m13_negativos(skills, dst)
            compatible = dict(a, migraciones_dir='supabase/migrations',
                              vault_gate='scripts/ci/check-cron-secrets-provisioned.sh')
            path = t/'proc-compatible.resp'
            put(path, compatible)
            compatible_out = t/'proc-compatible-out'
            compatible_home = t/'proc-compatible-home'
            compatible_dst = t/'proc-compatible-producto'
            result = cli('generar-instancia.sh', '--respuestas', path, '--salida', compatible_out,
                         '--home', compatible_home)
            check('PROC-M13 compatible generación', result.returncode == 0)
            compatible_dst.mkdir()
            subprocess.run(['git', '-C', str(compatible_dst), 'init', '-q'], check=True)
            subprocess.run(['git', '-C', str(compatible_dst), 'remote', 'add', 'origin', a['repo_url']], check=True)
            result = cli('adjudicar-identidad.sh', '--salida', compatible_out, '--home', compatible_home,
                         '--destino', compatible_dst)
            check('PROC-M13 compatible adjudicación', result.returncode == 0)
            # El prefijo histórico procede del ancla existente de T22, sin fijar
            # la clave de ningún equipo en el fixture. Solo cambia el anexo de prueba.
            compatible_skills = compatible_dst/'.claude/skills'
            invariant = next(line.split('\t') for line in
                             (compatible_skills/'talent-merger/invariants.tsv').read_text().splitlines()
                             if line.startswith('INV-ME-155\t'))
            prefix = invariant[4].split('-r21-', 1)[0]
            annex = next((compatible_skills/'talent-merger/references').glob('anexo-*.md'))
            content = annex.read_text()
            anchor = "raise exception 'PROC-M13: version"
            check('PROC-M13 compatible prefijo histórico único', content.count(anchor) == 1
                  and re.fullmatch(r'[A-Z]+-[0-9]+', prefix) is not None)
            annex.write_text(content.replace(anchor, "raise exception '"+prefix+": version"))
            proc_m13(compatible_dst/'.claude/skills', compatible_dst, 'supabase', compatible=True)
        if p == 'ejemplo':
            identity = skills/'talent-channel-operation/scripts/repo-identity.conf'
            original = identity.read_text()
            try:
                identity.write_text(re.sub(r'^TCO_REPO_STACK=.*$', 'TCO_REPO_STACK=convex',
                                          original, flags=re.M))
                proc_m13(skills, dst, 'convex')
            finally:
                identity.write_text(original)
        runtime = dict(os.environ, HOME=str(home), HOST_HOME=str(home))
        for key in ('SECRET_DIR', 'TORC_SECRET_DIR', 'TA_PERFIL', 'AM_LEDGER', 'TF_MANIFEST', 'TF_ROOT'):
            runtime.pop(key, None)
        result_load = subprocess.run(['bash', '-c', '. "$1"; tco_load_tokens; '
                                     'printf "%s\\n" "$TCO_AUDIT_CLI" "$AM_LEDGER" "$TCO_TF_MANIFEST"; '
                                     '. "$2"; torc_load_tokens; printf "%s\\n" "$TORC_TEAM_ID" "$TF_MANIFEST"; '
                                     '. "$3"; pozos_list',
                                     'carga', str(skills/'talent-channel-operation/scripts/00-config.sh'),
                                     str(skills/'talent-orchestrator/scripts/00-config.sh'),
                                     str(skills/'talent-orchestrator/scripts/pozos-lib.sh')],
                                    env=runtime, capture_output=True, text=True)
        check(p+' F3 carga real solo HOME HOST_HOME', result_load.returncode == 0 and result_load.stdout.splitlines()
              == [auditor, str(out/'ledger/cuentas.json'), str(out/f'manifiestos/{p}.conf'),
                  a['linear_equipo_uuid'], str(out/f'manifiestos/{p}.conf'),
                  ' '.join('p'+str(i) for i in range(1, len(a['pozos_alias'].split(','))+1))])
        found = subprocess.run(['bash', '-c', '. "$1"; perfil_path', 'perfil',
                                str(skills/'talent-ceo/scripts/lib-perfil.sh')], env=runtime, capture_output=True, text=True)
        check(p+' F3 perfil producto por defecto', found.returncode == 0
              and found.stdout.strip() == str(dst/f'manifiestos/{p}.perfil.tsv'))
        if p == 'ejemplo':
            for location, ignored in [(dst/'skills/talent-ceo/scripts/manifiestos', True),
                                      (dst/'.claude/manifiestos', False),
                                      (dst/'.claude/skills/talent-ceo/scripts/manifiestos', False)]:
                location.mkdir(parents=True, exist_ok=True)
                other = location/'otro.perfil.tsv'
                other.write_text(profile)
                before = snapshot(dst)
                discovered = subprocess.run(['bash', '-c', '. "$1"; perfil_path', 'perfil',
                                             str(skills/'talent-ceo/scripts/lib-perfil.sh')],
                                            env=runtime, capture_output=True, text=True)
                result_profile = cli('adjudicar-identidad.sh', *adjud)
                check('confinamiento producto '+str(location.relative_to(dst)), snapshot(dst) == before
                      and (result_profile.returncode == result.returncode and discovered.returncode == 0 if ignored
                           else result_profile.returncode == 1 and discovered.returncode == 2
                           and 'AMBIGUO desde' in result_profile.stderr))
                other.unlink(missing_ok=True)
        # Modo sellado: todas las identidades/digests reales, ninguna ruta de fetch.
        (dst/'producto.txt').write_text('producto sintético\n')
        subprocess.run(['git', '-C', str(dst), 'add', 'producto.txt'], check=True)
        subprocess.run(['git', '-C', str(dst), '-c', 'user.name=Operador', '-c', 'user.email=operador@example.invalid',
                        'commit', '-qm', 'Producto sintético'], check=True)
        sha = subprocess.check_output(['git', '-C', str(dst), 'rev-parse', 'HEAD'], text=True).strip()
        engine = PACKAGE/'scripts/run-local-gates.sh'
        carveout = PACKAGE/'scripts/lib/carveout.sh'
        assignment = t/(p+'-asignacion.json')
        manifest_path = out/f'manifiestos/{p}.conf'
        assignment.write_text(json.dumps({'schema_version': 1, 'run_group': 'humo', 'repo': 'org-example/'+a['repo_url'].split('/')[-1].removesuffix('.git'),
            'sha': sha, 'base_sha': sha, 'base_tip_sha': sha, 'gate_id': 'humo',
            'manifest_digest': hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
            'motor_sha256': hashlib.sha256(engine.read_bytes()).hexdigest(),
            'carveout_sha256': hashlib.sha256(carveout.read_bytes()).hexdigest()}))
        receipt = t/(p+'-receipt.json')
        measured = subprocess.run(['bash', str(engine), str(dst), '--manifest', str(manifest_path),
                                  '--assignment', str(assignment), '--lib-carveout', str(carveout), '--receipt', str(receipt)],
                                 env=runtime, capture_output=True, text=True)
        print(measured.stdout, end='')
        print(measured.stderr, end='')
        check(p+' F1 motor real gate humo PASS', measured.returncode == 0 and receipt.is_file()
              and json.loads(receipt.read_text())['result'] == 'PASS'
              and json.loads(receipt.read_text())['assignment'] == 'sealed')
        identity = skills/'talent-channel-operation/scripts/repo-identity.conf'
        torc = skills/'talent-orchestrator/scripts/repo-identity.conf'
        check(p+' identidades reales', identity.is_file() and torc.is_file()
              and f'TCO_REPO_SLUG=org-example/{a["repo_url"].split("/")[-1].removesuffix(".git")}' in identity.read_text()
              and f'PKG_IDENTITY_PROJECT={p}' in torc.read_text())
        expected_identity = {
            'TCO_REPO_STACK': 'supabase' if a['supabase'] == 'si' else 'ninguno',
            'TCO_LINEAR_INPROGRESS_STATE': a['linear_inprogress_uuid'],
            'TCO_LINEAR_INREVIEW_STATE': a['linear_inreview_uuid'],
            'TCO_ANEXO_FILE': f'references/anexo-{p}.md',
        }
        check(p+' coherencia identidad anexos',
            dict(line.split('=', 1) for line in identity.read_text().splitlines()
                 if line and not line.startswith('#')).items() >= expected_identity.items()
            and all((skills/member/f'references/anexo-{p}.md').read_bytes()
                    == (out/f'instalacion/generado/anexos/{member}/anexo-{p}.md').read_bytes()
                    for member in ('talent-channel-operation', 'talent-merger', 'talent-ceo')))
        log = out/'instalacion/generado/validacion-instancia.log'
        actual = set(re.findall(r'^FAIL \S+ (\S+)', log.read_text(), re.M)) if log.exists() else set()
        pending_file = 'pendientes-tal8041-supabase.txt' if a['supabase'] == 'si' else 'pendientes-tal8041.txt'
        # Guarda de cierre: ninguna entrada pendiente puede aceptar un fallo real.
        check(p+' validación instancia sin pendientes', not (HERE/pending_file).read_bytes()
              and not actual and result.returncode == 0)
        hash1 = digest(skills)
        again = cli('adjudicar-identidad.sh', *adjud)
        check(p+' adjudicación idempotente', again.returncode == result.returncode and digest(skills) == hash1)
        check(p+' paquete byte-idéntico', digest(PACKAGE) == package_hash)
        calibrated = home/'.config/talent-channel-operation/agents.conf'
        previous = calibrated.read_text()
        calibrated.write_text(previous+'TCO_PANE_CALIBRATED="claude:2.1.288|codex:0.1.0"\n')
        check(p+' calibración lista real permite readjudicar', cli('adjudicar-identidad.sh', *adjud).returncode == result.returncode)
        for label, extra in (
                ('versión truncada', 'TCO_PANE_CALIBRATED="claude:2.1"\n'),
                ('separador final', 'TCO_PANE_CALIBRATED="claude:2.1.288|"\n'),
                ('metacaracteres', 'TCO_PANE_CALIBRATED="claude:2.1.288;echo prueba"\n'),
                ('clave ajena junto a válida', 'TCO_PANE_CALIBRATED="claude:2.1.288"\nCLAVE_AJENA=si\n')):
            calibrated.write_text(previous+extra)
            before = snapshot(t)
            invalid = cli('adjudicar-identidad.sh', *adjud)
            check(p+' rechaza calibración '+label+' sin escrituras',
                  invalid.returncode != 0 and snapshot(t) == before)
        calibrated.write_text(previous)
    out, home = t/'ejemplo', t/'ejemplo-home'
    # C4 conflicto y forzar, sin escrituras previas al rechazo.
    manual = home/'.config/talent-channel-operation/agents.conf'
    manual.write_text(manual.read_text()+'# edición manual\n')
    before = digest(out)+digest(home)
    cmd = ('--respuestas', FIX/'minima.resp', '--salida', out, '--home', home)
    result = cli('generar-instancia.sh', *cmd)
    check('conflicto accionable sin escritura', result.returncode == 3 and '--- ' in result.stderr and digest(out)+digest(home) == before)
    check('forzar', cli('generar-instancia.sh', *cmd, '--forzar').returncode == 0)
    envpath = home/'ejemplo/.env.local'
    envpath.write_text('# edición de plantilla conservada\n')
    envpath.chmod(0o644)
    result = cli('generar-instancia.sh', *cmd, '--forzar')
    check('env existente se conserva', result.returncode == 0 and envpath.read_text() == '# edición de plantilla conservada\n')
    check('env existente restringe permisos', envpath.stat().st_mode & 0o777 == 0o600)
    # Descubrimiento sin override: otro perfil en cualquier nivel hasta la raíz.
    profile_path = out/'manifiestos/ejemplo.perfil.tsv'
    consumer = out/'skills/talent-ceo/scripts/lib-perfil.sh'
    consumer.parent.mkdir(parents=True, exist_ok=True)
    consumer.write_bytes((PACKAGE/'skills/talent-ceo/scripts/lib-perfil.sh').read_bytes())
    foreign = out/'.claude/skills/talent-ceo/scripts/manifiestos/otro.perfil.tsv'
    foreign.parent.mkdir(parents=True, exist_ok=True)
    foreign.write_text(profile_path.read_text())
    before = snapshot(t)
    result = cli('generar-instancia.sh', *cmd)
    discovered = subprocess.run(['bash', '-c', '. "$1"; perfil_path', 'perfil', str(consumer)],
                                env=runtime, capture_output=True, text=True)
    check('confinamiento generación perfil ajeno ignorado', result.returncode == 0
          and snapshot(t) == before and discovered.returncode == 0
          and discovered.stdout.strip() == str(profile_path))
    foreign.unlink()
    for ignored in ('.oculto.perfil.tsv', 'otro.perfil.tsv.bak', 'otro-perfil.tsv'):
        other = out/'manifiestos'/ignored
        other.write_text(profile_path.read_text())
        before = digest(t)
        result = cli('generar-instancia.sh', *cmd)
        discovered = subprocess.run(['bash', '-c', '. "$1"; perfil_path', 'perfil', str(consumer)],
                                    env=runtime, capture_output=True, text=True)
        check('identidad ignorado '+ignored, result.returncode == 0 and digest(t) == before
              and discovered.returncode == 0 and discovered.stdout.strip() == str(profile_path))
        other.unlink()
    for location, force in [(out/'manifiestos', False), (out/'manifiestos', True),
                            (t/'manifiestos', False), (out/'skills/talent-ceo/scripts/manifiestos', False)]:
        location.mkdir(parents=True, exist_ok=True)
        other = location/'otro.perfil.tsv'
        other.write_text(profile_path.read_text())
        before = snapshot(t)
        result = cli('generar-instancia.sh', *cmd, *(['--forzar'] if force else []))
        discovered = subprocess.run(['bash', '-c', '. "$1"; perfil_path', 'perfil', str(consumer)],
                                    env=runtime, capture_output=True, text=True)
        check('selección de perfil perfiles ambiguos '+str(location.relative_to(t))+' forzar='+str(force),
              result.returncode == 1 and snapshot(t) == before and discovered.returncode == 2
              and str(other) in result.stderr and str(profile_path) in result.stderr
              and 'AMBIGUO' in result.stderr and 'retire' in result.stderr)
        other.unlink()
    ambiguous = fixture('minima.resp')
    ambiguous['usuario_c1'] = ambiguous['usuario_ceo']
    path = t/'ambigua'
    put(path, ambiguous)
    result = cli('generar-instancia.sh', '--respuestas', path, '--salida', t/'ambiguo', '--home', home)
    check('usuario ambiguo', result.returncode == 1 and not (t/'ambiguo').exists())
    check('Claude sin backend', 'TCO_AUDIT_CLI="claude-root"' in manual.read_text()
          and 'TCO_REPO_STACK=ninguno' in (out/'instalacion/generado/identidad-aprobada.conf').read_text())
    check('F2 home dentro del paquete rechazo', cli('generar-instancia.sh', '--respuestas', FIX/'minima.resp',
          '--salida', out, '--home', out/'home').returncode == 2 and not (out/'home').exists())
    check('F2 home dentro de repo rechazo', cli('generar-instancia.sh', '--respuestas', FIX/'minima.resp',
          '--salida', out, '--home', t/'ejemplo-producto/home').returncode == 2
          and not (t/'ejemplo-producto/home').exists())
    (home/'ejemplo/bus').symlink_to(t/'ejemplo-producto')
    before = digest(out)
    check('F2 bus symlink rechazo', cli('generar-instancia.sh', *cmd).returncode == 2 and digest(out) == before)
    (home/'ejemplo/bus').unlink()
    no_git = t/'sin-git'
    no_git.mkdir()
    check('destino sin git', cli('adjudicar-identidad.sh', '--salida', out, '--home', home, '--destino', no_git).returncode == 2 and not list(no_git.iterdir()))
    wrong = t/'origin-distinto'
    wrong.mkdir()
    subprocess.run(['git', '-C', str(wrong), 'init', '-q'], check=True)
    subprocess.run(['git', '-C', str(wrong), 'remote', 'add', 'origin', 'https://github.com/org-example/otro.git'], check=True)
    before = digest(wrong)
    check('origin distinto nada escrito', cli('adjudicar-identidad.sh', '--salida', out, '--home', home, '--destino', wrong).returncode == 2 and digest(wrong) == before)
    subprocess.run(['git', '-C', str(wrong), 'remote', 'set-url', 'origin', fixture('minima.resp')['repo_url']], check=True)
    approved = t/'incompleto.conf'
    approved.write_text('\n'.join(line for line in (out/'instalacion/generado/identidad-aprobada.conf').read_text().splitlines() if not line.startswith('TCO_POSTMERGE_CMD='))+'\n')
    before = digest(wrong)
    check('fragmento incompleto rc3 nada escrito', cli('adjudicar-identidad.sh', '--salida', out, '--home', home, '--destino', wrong, '--approved', approved).returncode == 3 and digest(wrong) == before)
    original = (out/'instalacion/generado/identidad-aprobada.conf').read_text()
    for name, content in [('stack', original.replace('TCO_REPO_STACK=ninguno', 'TCO_REPO_STACK=inventado')),
                          ('uuid', original.replace('22222222-2222-2222-2222-222222222222', 'no-uuid')),
                          ('ajeno', original.replace('PKG_IDENTITY_PROJECT=ejemplo', 'PKG_IDENTITY_PROJECT=otro')),
                          ('marcador', original.replace('TCO_POSTMERGE_CMD=true', 'TCO_POSTMERGE_CMD=TODO')),
                          ('secreto', original.replace('TCO_POSTMERGE_CMD=true', 'TCO_POSTMERGE_CMD=lin_api_sintetico'))]:
        approved.write_text(content)
        before = digest(wrong)
        result = cli('adjudicar-identidad.sh', '--salida', out, '--home', home, '--destino', wrong, '--approved', approved)
        check('fragmento '+name+' rechazo sin escritura', result.returncode == 3 and digest(wrong) == before
              and 'lin_api_sintetico' not in result.stdout+result.stderr)
    approved.write_text(original.replace('TCO_HOST_ENV_REL=ejemplo/.env.local', 'TCO_HOST_ENV_REL=ausente/.env.local'))
    before = digest(wrong)
    check('env ausente rechazo sin escritura', cli('adjudicar-identidad.sh', '--salida', out, '--home', home, '--destino', wrong, '--approved', approved).returncode == 3 and digest(wrong) == before)
    manual.write_text('TCO_DEV_CLI="$(touch /tmp/no-ejecutar)"\n')
    before = digest(wrong)
    check('agents inseguro sin source', cli('adjudicar-identidad.sh', '--salida', out, '--home', home, '--destino', wrong).returncode == 3 and digest(wrong) == before)
    cli('generar-instancia.sh', *cmd, '--forzar')
    approved.write_text(original.replace('22222222-2222-2222-2222-222222222222', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'))
    existing = t/'ejemplo-producto'
    before = digest(existing)
    check('identidad divergente sin escritura', cli('adjudicar-identidad.sh', '--salida', out, '--home', home, '--destino', existing, '--approved', approved).returncode == 3 and digest(existing) == before)
    # Un fallo real de carga (override divergente) revierte el bootstrap completo.
    corrupt_env = dict(os.environ, TCO_REPO_DIR='otro')
    before = digest(wrong)
    result = cli('adjudicar-identidad.sh', '--salida', out, '--home', home, '--destino', wrong, env=corrupt_env)
    check('carga real fallida rollback', result.returncode == 1 and 'OVERRIDE DIVERGENTE' in result.stderr and digest(wrong) == before)
    check('paquete intacto tras rechazos', digest(PACKAGE) == package_hash)
    states = t/'linear.json'
    result = cli('consultar-estados-linear.sh', '--equipo', 'ABC', '--fixture', FIX/'linear.json', '--out', states)
    check('consulta fixture', result.returncode == 0 and 'ESTADO In Progress' in result.stdout)
    check('labels de instancia', cli('generar-instancia.sh', *cmd, '--linear-config', states, '--forzar').returncode == 0
          and json.loads((out/'instalacion/generado/linear-instancia.json').read_text())['labels'][0]['name'] == 'feature')
    check('Linear equipo distinto', cli('consultar-estados-linear.sh', '--equipo', 'OTRO', '--fixture', FIX/'linear.json').returncode == 2)
    check('Linear clave minúscula', cli('consultar-estados-linear.sh', '--equipo', 'abc', '--fixture', FIX/'linear.json').returncode == 2)
    missing_env = dict(os.environ)
    missing_env.pop('TOKEN_INEXISTENTE', None)
    check('token ausente sin red', cli('consultar-estados-linear.sh', '--equipo', 'ABC', '--token-nombre', 'TOKEN_INEXISTENTE', env=missing_env).returncode == 2)
    bad_linear = t/'linear-mal.json'
    bad_linear.write_text('{"errors":[{"message":"fallo sintético"}]}')
    check('GraphQL error fail-closed', cli('consultar-estados-linear.sh', '--equipo', 'ABC', '--fixture', bad_linear).returncode == 2)
    with_labels = json.loads((FIX/'linear.json').read_text())
    with_labels['labels'][0]['name'] = 'kind:función'
    bad_linear.write_text(json.dumps(with_labels))
    result = cli('consultar-estados-linear.sh', '--equipo', 'ABC', '--fixture', bad_linear)
    check('labels con acentos y dos puntos', result.returncode == 0 and 'kind:función' in result.stdout)
    check('ruta con espacio sin escritura', cli('generar-instancia.sh', '--respuestas', FIX/'minima.resp', '--salida', t/'ruta espacio', '--home', home).returncode == 2 and not (t/'ruta espacio').exists())
    load_env = dict(os.environ, HOST_HOME=str(t/'home-sin-conf'), SECRET_DIR=str(t/'escrow'))
    result = subprocess.run(['bash', '-c', '. "$1"', 'carga', str(PACKAGE/'skills/talent-channel-operation/scripts/00-config.sh')],
                            env=load_env, capture_output=True, text=True)
    check('sin identidad fail-closed', result.returncode == 1 and 'ERROR identidad' in result.stderr)


with tempfile.TemporaryDirectory(prefix='tests-copia-paquete-') as tmp:
    copia_paquete_con_estado_vivo(Path(tmp))

# Caso permanente: otro proceso escribe estado durante toda la suite.
live_root = INSTALL/'estado'
live_root.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='prueba-viva-', dir=live_root) as live:
    started = time.monotonic()
    writer = subprocess.Popen([sys.executable, '-c',
        'import pathlib, sys, time\np=pathlib.Path(sys.argv[1]); tmp=p.with_suffix(".tmp")\n'
        'while True:\n tmp.write_text(str(time.monotonic()))\n tmp.replace(p)\n time.sleep(0.01)\n', str(Path(live)/'log')])
    try:
        with tempfile.TemporaryDirectory(prefix='tests-instalacion-') as tmp:
            main(Path(tmp))
        with tempfile.TemporaryDirectory(prefix='tests-paquete-integro-') as tmp:
            paquete_integro(Path(tmp))
        check('estado concurrente escribió durante la suite', writer.poll() is None and
              float((Path(live)/'log').read_text()) > started)
    finally:
        writer.terminate()
        writer.wait()
if PASS+FAIL != TOTAL_ESPERADO:
    print(f'FAIL guard: corrieron {PASS+FAIL}, esperados {TOTAL_ESPERADO}')
    FAIL += 1
print(f'== {PASS} ok, {FAIL} FAIL (esperados: {TOTAL_ESPERADO} casos) ==')
raise SystemExit(1 if FAIL else 0)
