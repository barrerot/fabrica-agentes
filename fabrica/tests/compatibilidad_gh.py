"""Regresión autónoma con el mismo cliente estricto que las fases."""
import json
import ast
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
from unittest.mock import patch


def casos(package, expect):
    sys.path.insert(0, str(package/'tests/fixtures/instalacion'))
    from gh_contrato import validar_orden, validar_shell, respuesta_estricta
    from generar_gh_contrato import generar
    expect('gh contrato reproducible desde ayudas reales 2.45.0', generar() ==
           json.loads((package/'tests/fixtures/instalacion/gh-2.45.0.json').read_text()))
    try:
        validar_orden(['incus', 'exec', 'runner-example', '--', 'bash', '-c',
                       (package/'scripts/lib/preflight.sh').read_text()])
        compatible = True
    except ValueError:
        compatible = False
    expect('gh contrato distingue directorios gh en el preflight real', compatible)
    sys.path.insert(0, str(package/'instalacion/scripts'))
    import fases
    import etiquetas
    with tempfile.TemporaryDirectory(prefix='gh-compatibilidad-') as td:
        tmp = Path(td)
        bindir = tmp/'bin'
        bindir.mkdir()
        for fixture in ('gh_contrato.py', 'gh-2.45.0.json'):
            shutil.copyfile(package/'tests/fixtures/instalacion'/fixture, bindir/fixture)
        shutil.copyfile(package/'tests/fixtures/instalacion/cliente.py', bindir/'gh')
        (bindir/'gh').chmod(0o755)
        env = dict(os.environ, PATH=str(bindir))
        model_bin = tmp/'model-bin'
        model_bin.mkdir()
        shutil.copyfile(package/'tests/fixtures/instalacion/cliente.py', model_bin/'claude')
        (model_bin/'claude').chmod(0o755)
        model = subprocess.run([str(model_bin/'claude'), '--version'], capture_output=True, text=True,
                               env=dict(os.environ, DOBLE_VERSION='2.1.288'))
        expect('gh contrato conserva cliente Claude aislado sin dependencia gh',
               model.returncode == 0 and model.stdout.strip() == '2.1.288')
        for tool in ('sudo', 'incus'):
            shutil.copyfile(package/'tests/fixtures/instalacion/cliente.py', bindir/tool)
            (bindir/tool).chmod(0o755)
        for tool in ('bash', 'sh'):
            (bindir/tool).symlink_to('/bin/'+tool)
        # Bash contrasta el argv expandido con el cliente cerrado. El análisis
        # estático debe rechazar M01 en las tres rutas antes de atribuir gh.
        redirecciones = [
            ('gh auth status > /dev/null "$FLAGS"', True, None),
            ("bash -c 'gh auth status > /dev/null \"$FLAGS\"'", True, None),
            ("eval 'FLAGS=--slurp; gh auth status > /dev/null \"$FLAGS\"'", True, None),
            ('gh auth status > /dev/null --slurp', True, None),
            ('gh auth status 2>/dev/null --slurp', True, None),
            ('gh auth status < /dev/null --slurp', True, None),
            ('gh auth status > "$DESTINO"', True, None),
            ('gh auth status > /dev/null 2>&1', False, ['gh', 'auth', 'status']),
            ('gh api x 2>/dev/null --jq .y', False, ['gh', 'api', 'x', '--jq', '.y']),
            ('gh auth status >/dev/null', False, ['gh', 'auth', 'status']),
            ('gh auth status >>/dev/null', False, ['gh', 'auth', 'status']),
            ('gh auth status </dev/null', False, ['gh', 'auth', 'status']),
            ('gh auth status &>/dev/null', False, ['gh', 'auth', 'status']),
            ('gh auth status >&1', False, ['gh', 'auth', 'status']),
            ('gh auth status 2>> /dev/null', False, ['gh', 'auth', 'status']),
            ('gh api 2>/dev/null x --jq .y', False, ['gh', 'api', 'x', '--jq', '.y']),
            ("gh api x 2>/dev/null --jq ';'", False, ['gh', 'api', 'x', '--jq', ';']),
            ("gh api x 2>/dev/null --jq '>'", False, ['gh', 'api', 'x', '--jq', '>']),
            ('gh api x "2">/dev/null --jq .y', False, ['gh', 'api', 'x', '2', '--jq', '.y']),
            ('>/dev/null gh auth status', False, ['gh', 'auth', 'status']),
            ("eval >/dev/null 'gh auth status'", False, ['gh', 'auth', 'status']),
            ("bash -c >/dev/null 'gh auth status'", False, ['gh', 'auth', 'status']),
        ]
        redir_env = dict(env, FLAGS='--slurp', DESTINO='/dev/null')
        import gh_contrato
        for order, rejected, argv in redirecciones:
            with patch.object(gh_contrato, 'validar_orden', wraps=validar_orden) as captured:
                try:
                    validar_shell(order)
                    accepted = not rejected
                except ValueError:
                    accepted = rejected
                expect('gh redirección analizador '+order, accepted)
                if argv is not None:
                    expect('gh redirección argv completo '+order,
                           any(call.args == (argv,) for call in captured.call_args_list))
            actual = subprocess.run(['/bin/bash', '-c', order], env=redir_env,
                                    capture_output=True, text=True, timeout=30)
            # El destino dinámico es válido en Bash y queda fuera del contrato
            # estático; no confundir su rechazo deliberado con incompatibilidad.
            bash_rc = int(rejected and '$DESTINO' not in order)
            expect('gh redirección Bash cerrado '+order, actual.returncode == bash_rc)
            if '$FLAGS' in order:
                expect('gh redirección Bash acredita slurp '+order,
                       'unknown flag: --slurp' in actual.stderr)
            nested = ['incus', 'exec', 'canal-example', '--', 'su', '-', 'actor', '-c', order]
            result = subprocess.run(nested, env=redir_env, capture_output=True, text=True, timeout=30)
            expect('gh redirección envuelta '+order, result.returncode == int(rejected))
            with patch.dict(os.environ, redir_env):
                try:
                    fases.actor('operador', nested, diagnostic='gh sin sesión: canal canal-example')
                    accepted = not rejected
                except fases.Error as exc:
                    accepted = rejected and 'rc=1' in str(exc) and 'gh sin sesión:' in str(exc)
            expect('gh redirección actor '+order, accepted)
        for order in ('gh auth status << /dev/null', 'gh auth status <> /dev/null',
                      'gh auth status >', 'gh auth status >& destino',
                      'gh auth status > /dev/null "$FLAGS"; echo fin'):
            try:
                validar_shell(order)
                rejected = False
            except ValueError:
                rejected = True
            expect('gh redirección cola no clasificable '+order, rejected)
        prefixes = ('command', 'command --', 'command -p', 'env VAR=example',
                    'env -- VAR=example', 'exec', 'exec --', 'sudo -u operador',
                    'timeout 3', 'nohup')
        probes = (('auth status', ''), ('auth status --slurp', '--slurp'),
                  ('inventado nuevo', 'inventado nuevo'), ('pr view --json merged', 'merged'))
        for prefix in prefixes:
            for suffix, diagnostic in probes:
                order = prefix+' gh '+suffix
                try:
                    validar_orden(shlex.split(order))
                    validated = not diagnostic
                except ValueError as exc:
                    validated = bool(diagnostic) and diagnostic in str(exc)
                expect('gh prefijo argv '+order, validated)
                # El cliente directo recibe el argv de gh. Los prefijos shell
                # se comprueban en el envoltorio sin ejecutar utilidades reales.
                direct = subprocess.run(['gh', *shlex.split(suffix)], env=env,
                                        capture_output=True, text=True)
                expect('gh prefijo directo '+order, direct.returncode == int(bool(diagnostic)) and
                       (not diagnostic or diagnostic in direct.stderr))
                nested = ['incus', 'exec', 'canal-example', '--', 'su', '-', 'actor', '-c', order]
                result = subprocess.run(nested, env=env, capture_output=True, text=True)
                expect('gh prefijo envuelto '+order, result.returncode == int(bool(diagnostic)) and
                       (not diagnostic or diagnostic in result.stderr))
                with patch.dict(os.environ, env):
                    try:
                        fases.actor('operador', nested, diagnostic='gh sin sesión: canal canal-example')
                        accepted = not diagnostic
                    except fases.Error as exc:
                        # El actor redacta el cuerpo tras -c. El detalle del
                        # contrato se acredita arriba en stderr del envoltorio.
                        accepted = (bool(diagnostic) and 'rc=1' in str(exc) and
                                    'gh sin sesión: canal canal-example' in str(exc) and
                                    'contenedor canal-example' in str(exc))
                expect('gh prefijo actor '+order, accepted)
        for flag in ('-v', '-V'):
            order = 'if command '+flag+' gh >/dev/null 2>&1; then gh auth status; fi'
            direct = subprocess.run(['/bin/bash', '-c', order], env=env, capture_output=True, text=True)
            expect('gh consulta directa '+flag, direct.returncode == 0)
            nested = ['incus', 'exec', 'canal-example', '--', 'su', '-', 'actor', '-c', order]
            result = subprocess.run(nested, env=env, capture_output=True, text=True)
            expect('gh consulta envuelta '+flag, result.returncode == 0)
            with patch.dict(os.environ, env):
                try:
                    fases.actor('operador', nested, diagnostic='gh sin sesión: canal canal-example')
                    accepted = True
                except fases.Error:
                    accepted = False
            expect('gh consulta actor '+flag, accepted)
        shells = [("eval 'gh "+suffix+"'", diagnostic) for suffix, diagnostic in probes]
        shells += [(order, 'forma de invocación no analizable') for order in (
            'eval "$ORDEN"', '$GH auth status', '${GH} auth status', 'xargs gh',
            'cliente() { gh auth status; }; cliente', "alias cliente='gh auth status'; cliente",
            'printf "%s" "$(gh auth status)"', 'echo `gh auth status`',
            'otro gh auth status', 'echo gh; xargs gh', '$TO gh auth status',
            "xargs bash -c 'gh auth status'", "otro -- gh auth status", 'command eval "$ORDEN"')]
        shells += [(path+' '+suffix, diagnostic) for path in (
            '/opt/example/bin/gh', './gh', "'/opt/example dir/gh'", '/opt//example/bin/gh')
                   for suffix, diagnostic in probes]
        shells += [(order, 'forma de invocación no analizable') for order in (
            'xargs /opt/example/bin/gh', 'otro ./gh auth status', "'gh auth status",
            '$gh auth status', '${gh} auth status', 'GH=./gh auth status',
            'GH=/opt/example/bin/gh auth status', 'X=/bin/env gh auth status',
            "X=/bin/bash -c 'gh auth status'", "printf 'gh auth status --slurp' | bash",
            "echo 'gh auth status' | xargs", 'command -v gh | xargs', 'command -V gh | bash',
            "echo 'gh auth status' > orden; sh orden", 'command -v gh > orden; sh orden')]
        shells += [(order, 'forma de invocación no analizable') for order in (
            'gh auth status "$OPCIONES"', 'gh auth status $OPCIONES', 'gh auth status "$@"',
            'gh auth status *', "gh auth status $'\\x2d\\x2dslurp'", 'gh pr view --json "$CAMPOS"',
            'OPCIONES=--slurp; gh auth status "$OPCIONES"')]
        shells += [(order, 'forma de invocación no analizable') for order in (
            'if command -v timeout >/dev/null 2>&1; then TO="timeout 30"; else TO=""; fi; rm -f ~/.config/gh/hosts.yml 2>/dev/null; $TO gh auth login --with-token',
            'if command -v timeout >/dev/null 2>&1; then TO="timeout 30"; else TO=""; fi; $TO gh auth setup-git >/dev/null 2>&1 && echo "  gh autenticado per-carril"')]
        shells += [(order, '') for order in (
            'echo "gh autenticado"', "printf '%s' gh", 'command -v gh', 'command -V gh',
            "bash -c 'eval \"gh auth status\"'", "sh -c 'gh auth status'",
            'echo gh >/dev/null', 'command -v gh >/dev/null',
            "gh api repos/org-example/producto --jq '.[] | select(.name == \"$name\")'")]
        for order, diagnostic in shells:
            # En formas dinámicas la ruta directa es el analizador, sin ejecutar
            # funciones, alias ni expansiones ajenas al contrato de pruebas.
            try:
                validar_shell(order)
                accepted = not diagnostic
            except ValueError as exc:
                accepted = bool(diagnostic) and diagnostic in str(exc)
            expect('gh shell directa '+order, accepted)
            if order.startswith("eval 'gh "):
                result = subprocess.run(['/bin/bash', '-c', order], env=env,
                                        capture_output=True, text=True)
                expect('gh eval ejecutada directa '+order,
                       result.returncode == int(bool(diagnostic)) and
                       (not diagnostic or diagnostic in result.stderr))
            elif order.startswith('OPCIONES=--slurp;'):
                result = subprocess.run(['/bin/bash', '-c', order], env=env,
                                        capture_output=True, text=True)
                expect('gh shell flags ejecutada directa '+order,
                       result.returncode == 1 and 'unknown flag: --slurp' in result.stderr)
            nested = ['incus', 'exec', 'canal-example', '--', 'su', '-', 'actor', '-c', order]
            result = subprocess.run(nested, env=env, capture_output=True, text=True)
            expect('gh shell envuelta '+order, result.returncode == int(bool(diagnostic)) and
                   (not diagnostic or diagnostic in result.stderr))
            with patch.dict(os.environ, env):
                try:
                    fases.actor('operador', nested, diagnostic='gh sin sesión: canal canal-example')
                    accepted = not diagnostic
                except fases.Error as exc:
                    accepted = bool(diagnostic) and 'rc=1' in str(exc) and 'gh sin sesión:' in str(exc)
            expect('gh shell actor '+order, accepted)
        wrapped = [
            ['sudo', '-n', '-H', '-u', 'operador', '--', 'incus', 'exec', 'canal-example', '--',
             'su', '-', 'actor', '-c', 'gh auth status'],
            ['incus', 'exec', 'canal-example', '--', 'gh', 'auth', 'status'],
            ['incus', 'exec', 'canal-example', '--', 'su', '-', 'actor', '-c',
             'rm -f ~/.config/gh/hosts.yml 2>/dev/null; if command -v timeout >/dev/null 2>&1; then timeout 30 gh auth login --with-token; else gh auth login --with-token; fi'],
            ['incus', 'exec', 'canal-example', '--', 'su', '-', 'actor', '-c',
             'if command -v timeout >/dev/null 2>&1; then timeout 30 gh auth setup-git; else gh auth setup-git; fi >/dev/null 2>&1 && echo "  gh autenticado per-carril"'],
        ]
        for order in wrapped:
            good = subprocess.run(order, env=env, capture_output=True, text=True)
            expect('gh envuelto control compatible '+str(order), good.returncode == 0)
            bad = order.copy()
            if '-c' in bad:
                # La opción incompatible se coloca tras el subcomando real.
                bad[-1] = order[-1].replace('auth status', 'auth status --slurp').replace(
                    'auth login', 'auth login --slurp').replace('auth setup-git', 'auth setup-git --slurp')
            else:
                bad.append('--slurp')
            result = subprocess.run(bad, env=env, capture_output=True, text=True)
            expect('gh envuelto rechaza slurp '+str(order), result.returncode == 1 and '--slurp' in result.stderr)
            print('EVIDENCIA envuelto rc='+str(result.returncode)+' '+result.stderr.strip())
        nested = wrapped[0][6:]
        nested[-1] += ' --slurp'
        with patch.dict(os.environ, env):
            try:
                fases.actor('operador', nested, diagnostic='gh sin sesión: canal canal-example')
                rejected = False
            except fases.Error as exc:
                rejected = 'gh sin sesión: canal canal-example' in str(exc) and 'rc=1' in str(exc)
        expect('gh actor real de F3 rechaza orden envuelta incompatible', rejected)
        shell = tmp/'gh-shell'
        shell.write_text('#!/bin/bash\necho respuesta-sintetica\n')
        shell.chmod(0o755)
        subprocess.run(['/usr/bin/python3', str(bindir/'gh_contrato.py'), '--envolver', str(shell)], check=True)
        subprocess.run(['/usr/bin/python3', str(bindir/'gh_contrato.py'), '--envolver', str(shell)], check=True)
        good = subprocess.run([str(shell), 'auth', 'status'], capture_output=True, text=True, timeout=10)
        expect('gh shell cerrado idempotente conserva respuesta', good.returncode == 0 and 'respuesta-sintetica' in good.stdout)
        for args, diagnostic in ((['api', '--slurp'], '--slurp'), (['pr', 'checks', '--json', 'name'], '--json'),
                                 (['pr', 'view', '--json', 'merged'], 'merged'), (['inventado', 'nuevo'], 'inventado nuevo')):
            result = subprocess.run([str(shell), *args], capture_output=True, text=True)
            expect('gh shell cerrado rechaza '+str(args), result.returncode == 1 and diagnostic in result.stderr)
        tree = ast.parse((package/'tests/test-instalacion-fases.py').read_text())
        for name in ('fake_run', 'label_client'):
            node = next(node for node in ast.walk(tree) if isinstance(node, ast.FunctionDef) and node.name == name)
            namespace = dict(json=json, calls=[], label_calls=[], present_labels={'cr-review'}, validar_orden=validar_orden)
            exec(compile(ast.Module(body=[node], type_ignores=[]), '<doble interno>', 'exec'), namespace)
            client = namespace[name]
            good = client(['gh', 'api', '--paginate', 'repos/org-example/producto/labels?per_page=100'])
            expect('gh interno compatible '+name, 'cr-review' in good)
            for args, diagnostic in ((['gh', 'api', '--slurp'], '--slurp'),
                                     (['gh', 'pr', 'view', '--json', 'merged'], 'merged'),
                                     (['gh', 'inventado', 'nuevo'], 'inventado nuevo')):
                try:
                    client(args)
                    rejected = False
                except ValueError as exc:
                    rejected = diagnostic in str(exc)
                expect('gh interno cerrado '+name+' '+str(args), rejected)
            source = (package/'instalacion/scripts/etiquetas.py').read_text().replace(
                "'api', '--paginate',", "'api', '--paginate', '--slurp',")
            mutated = {'__name__': 'etiquetas_variante'}
            exec(compile(source, '<opción incompatible>', 'exec'), mutated)
            mutated['run'] = client
            try:
                mutated['ensure_review_label']({'answers': {'repo_url': 'https://github.com/org-example/producto.git'}}, False)
                rejected = False
            except ValueError as exc:
                rejected = '--slurp' in str(exc)
            expect('gh variante productiva queda roja con '+name, rejected)
            print('EVIDENCIA variante '+name+' rechazada='+str(rejected))
        c = {'answers': {'repo_url':'https://github.com/org-example/producto.git'}}
        old_order = ['gh', 'api', '--paginate', '--slurp', 'repos/org-example/producto/labels?per_page=100']
        old = subprocess.run(old_order, env=env, capture_output=True, text=True)
        expect('gh 2.45.0 orden antigua roja', old.returncode == 1 and 'unknown flag: --slurp' in old.stderr)
        print('EVIDENCIA antigua rc='+str(old.returncode)+' '+old.stderr.strip())
        with patch.dict(os.environ, env, clear=True):
            labels = etiquetas.repository_labels(c)
        expect('gh 2.45.0 orden nueva verde con dos páginas', labels == {'bug', 'cr-review'})
        print('EVIDENCIA nueva rc=0 etiquetas='+','.join(sorted(labels)))
        label_log = tmp/'etiquetas-llamadas.jsonl'
        with patch.dict(os.environ, dict(env, DOBLE_GH_LLAMADAS=str(label_log)), clear=True):
            etiquetas.ensure_review_label(c, False)
        present_calls = [json.loads(line) for line in label_log.read_text().splitlines()]
        expect('gh etiqueta en página dos impide creación', not any(args[:2] == ['label', 'create'] for args in present_calls))
        label_log.unlink()
        with patch.dict(os.environ, dict(env, DOBLE_GH_LLAMADAS=str(label_log), DOBLE_SIN_CR_LABEL='1',
                                        DOBLE_GH_ETIQUETA_CREADA=str(tmp/'creada')), clear=True):
            etiquetas.ensure_review_label(c, False)
            etiquetas.ensure_review_label(c, False)
        absent_calls = [json.loads(line) for line in label_log.read_text().splitlines()]
        expect('gh etiqueta ausente crea una vez con cliente estricto', len([args for args in absent_calls if args[:2] == ['label', 'create']]) == 1)
        with patch.dict(os.environ, dict(env, DOBLE_FALLO='gh'), clear=True):
            try:
                etiquetas.repository_labels(c)
                diagnostic = ''
            except fases.Error as exc:
                diagnostic = str(exc)
        expect('gh error de etiquetas nombra orden completa', 'orden=gh api --paginate' in diagnostic and
               '/labels?per_page=100' in diagnostic)
        for raw in (' ', '{"name":"cr-review"}', '[{}]', '[[]', '[{"name":"cr-review"}]\n{}'):
            with patch.object(etiquetas, 'run', respuesta_estricta(raw)):
                try:
                    etiquetas.repository_labels(c)
                    rejected = False
                except fases.Error as exc:
                    rejected = 'etiquetas formato inválido' in str(exc)
            expect('gh respuesta inválida cerrada '+repr(raw), rejected)
        with patch.object(etiquetas, 'run', respuesta_estricta('[{"name":"cr-review\\notra"}]\n[]')):
            labels = etiquetas.repository_labels(c)
        expect('gh conserva nombre completo sin falso cr-review', labels == {'cr-review\notra'} and 'cr-review' not in labels)
        for args, diagnostic in ((['gh', 'api', '--opcion-inexistente'], 'unknown flag'),
                                 (['gh', 'pr', 'view', '1', '--json', 'merged'], 'Unknown JSON field'),
                                 (['gh', 'auth', 'status', '--json', 'state'], 'unknown flag'),
                                 (['gh', 'pr', 'view', '1', '--json'], 'argumento ausente')):
            result = subprocess.run(args, env=env, capture_output=True, text=True)
            expect('gh doble cerrado '+str(args), result.returncode == 1 and diagnostic in result.stderr)
        # El motor conserva sus bytes y su modo de consulta sin transportarse como shell.
        transfer_log = tmp/'transferencias.jsonl'
        manifest = tmp/'manifest.conf'
        manifest.write_text('TF_REPO_ROOT=/home/runner/repo\n')
        runner_script = package/'instalacion/scripts/verificar-runner.sh'
        transfer_env = dict(env, PATH=str(bindir)+':'+os.environ['PATH'],
                            DOBLE_INCUS_LLAMADAS=str(transfer_log))
        arguments = ['bash', str(runner_script), 'runner-example',
                     'https://github.com/org-example/producto', 'F5', str(manifest)]
        result = subprocess.run(arguments, env=transfer_env, capture_output=True, text=True, timeout=30)
        calls = [json.loads(line) for line in transfer_log.read_text().splitlines()]
        expect('runner transporte directo compatible con contrato gh cerrado', result.returncode == 0)
        pushes = [args for args in calls if args[:2] == ['file', 'push']]
        expect('runner copia motor y manifiesto exactos', pushes == [
            ['file', 'push', str(runner_script.parent/'../../scripts/run-local-gates.sh'),
             'runner-example/tmp/tmp.fixture1/motor.sh'],
            ['file', 'push', str(manifest), 'runner-example/tmp/tmp.fixture1/manifest.conf']])
        expect('runner mantiene consulta del repositorio y gate docs', [
            'exec', 'runner-example', '--', 'sudo', '-H', '-u', 'runner', 'env',
            'TF_CHECK_REPO_ONLY=1', 'bash', '/tmp/tmp.fixture1/motor.sh', '/home/runner/repo',
            '--gate', 'docs', '--manifest', '/tmp/tmp.fixture1/manifest.conf'] in calls)
        expect('runner limpia únicamente su temporal validado',
               calls[-1] == ['exec', 'runner-example', '--', 'rm', '-rf', '--', '/tmp/tmp.fixture1'])
        transfer_log.unlink()
        rejected = subprocess.run(arguments, env=dict(transfer_env, DOBLE_RUNNER_TEMPORAL='/tmp/ajeno'),
                                  capture_output=True, text=True, timeout=30)
        rejected_calls = [json.loads(line) for line in transfer_log.read_text().splitlines()]
        expect('runner temporal ajeno rojo sin copia ni borrado', rejected.returncode == 1 and
               'runner temporal inválido' in rejected.stderr and
               not any(args[:2] == ['file', 'push'] or 'rm' in args for args in rejected_calls))
    sys.path.pop(0)
    # La suite de fases carga su propia copia temporal y conserva su aislamiento.
    sys.modules.pop('etiquetas', None)
    sys.modules.pop('fases', None)


def casos_descriptores_ascii(package, expect):
    """Contrasta M02 con Bash sin confundir argumentos Unicode con fd."""
    sys.path.insert(0, str(package/'tests/fixtures/instalacion'))
    sys.path.insert(0, str(package/'instalacion/scripts'))
    import gh_contrato
    import fases
    with tempfile.TemporaryDirectory(prefix='gh-descriptores-') as td:
        tmp = Path(td)
        for fixture in ('gh_contrato.py', 'gh-2.45.0.json'):
            shutil.copyfile(package/'tests/fixtures/instalacion'/fixture, tmp/fixture)
        for tool in ('gh', 'incus', 'sudo'):
            shutil.copyfile(package/'tests/fixtures/instalacion/cliente.py', tmp/tool)
            (tmp/tool).chmod(0o755)
        for tool in ('bash', 'sh'):
            (tmp/tool).symlink_to('/bin/'+tool)
        llamadas = tmp/'argv.jsonl'
        env = dict(os.environ, PATH=str(tmp), DOBLE_HOME=str(tmp),
                   DOBLE_GH_LLAMADAS=str(llamadas))
        probes = []
        for digit in ('²', '١'):
            probes.append(('gh api '+digit+'>/dev/null', False, ['gh', 'api', digit]))
            probes.append(('gh auth status 2>&'+digit, True, None))
        for redirection in ('2>&1', '1>/dev/null', '>&2'):
            probes.append(('gh api x '+redirection+' --jq .y', False,
                           ['gh', 'api', 'x', '--jq', '.y']))
        for command, rejected, argv in probes:
            for route, order in (('directa', command), ('bash-c', 'bash -c '+shlex.quote(command)),
                                 ('eval', 'eval '+shlex.quote(command))):
                label = route+' '+command
                with patch.object(gh_contrato, 'validar_orden', wraps=gh_contrato.validar_orden) as captured:
                    try:
                        gh_contrato.validar_shell(order)
                        accepted = not rejected
                    except ValueError:
                        accepted = rejected
                expect('gh descriptor analizador '+label, accepted)
                expect('gh descriptor argv completo '+label,
                       not any(call.args[0][:1] == ['gh'] for call in captured.call_args_list) if rejected else
                       any(call.args == (argv,) for call in captured.call_args_list))
                llamadas.unlink(missing_ok=True)
                actual = subprocess.run(['/bin/bash', '-c', order], env=env, cwd=tmp,
                                        capture_output=True, text=True, timeout=30)
                calls = [json.loads(line) for line in llamadas.read_text().splitlines()] if llamadas.exists() else []
                expect('gh descriptor Bash rc '+label, actual.returncode == int(rejected))
                expect('gh descriptor Bash argv '+label, calls == ([] if rejected else [argv[1:]]))
                nested = ['incus', 'exec', 'canal-example', '--', 'su', '-', 'actor', '-c', order]
                result = subprocess.run(nested, env=env, capture_output=True, text=True, timeout=30)
                expect('gh descriptor envuelto '+label, result.returncode == int(rejected))
                with patch.dict(os.environ, env):
                    try:
                        fases.actor('operador', nested, diagnostic='gh sin sesión: canal canal-example')
                        accepted = not rejected
                    except fases.Error as exc:
                        accepted = rejected and 'rc=1' in str(exc) and 'gh sin sesión:' in str(exc)
                expect('gh descriptor actor '+label, accepted)
    sys.path.pop(0)
    sys.path.pop(0)
    sys.modules.pop('fases', None)


if __name__ == '__main__':
    passed = failed = 0

    def expect(label, result):
        global passed, failed
        passed += int(bool(result))
        failed += int(not result)
        print(('PASS ' if result else 'FAIL ')+label, flush=True)

    package = Path(__file__).resolve().parents[1]
    casos(package, expect)
    casos_descriptores_ascii(package, expect)
    print('PASS='+str(passed)+' FAIL='+str(failed))
    sys.exit(bool(failed))
