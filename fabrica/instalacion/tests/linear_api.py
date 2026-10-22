#!/usr/bin/env python3
"""Contrato del servicio mediante inyección del transporte, sin sockets ni tokens reales."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch
from linear_transporte import Transporte

INSTALL = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('instalador_linear', INSTALL/'instalacion.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def cases():
    fixture = json.loads((INSTALL/'tests/fixtures/linear.json').read_text())
    results = []
    with tempfile.TemporaryDirectory() as td:
        out = Path(td)/'consulta.json'
        args = SimpleNamespace(equipo='ABC', fixture=None, token_nombre='TOKEN_PRUEBA', out=str(out))
        for mode, diagnostic in [('ok', ''), ('401', 'token rechazado'), ('403', 'token rechazado'),
                                 ('429', 'límite de peticiones'), ('400', 'consulta rechazada por el servicio'),
                                 ('200-errors', 'consulta rechazada por el servicio'), ('red', 'sin conexión'),
                                 ('timeout', 'sin conexión'), ('ausente', 'equipo ABC no encontrado con este token'),
                                 ('tope', 'tope de 20 páginas'), ('cursor', 'paginación inválida')]:
            transport = Transporte(fixture, mode)
            out.unlink(missing_ok=True)
            rc, output = 0, io.StringIO()
            with patch.dict(os.environ, TOKEN_PRUEBA='token-sintetico'), patch.object(mod.urllib.request, 'urlopen', transport), contextlib.redirect_stdout(output):
                try:
                    mod.linear_query(args)
                except mod.Error as exc:
                    rc = exc.rc
                    output.write(str(exc))
            good = (rc == 2 and diagnostic in output.getvalue() and not out.exists()) if diagnostic else (
                rc == 0 and len(json.loads(out.read_text())['states']) == 9 and
                len(json.loads(out.read_text())['labels']) == 230 and len(transport.calls) == 5)
            results.append((mode, good and 'token-sintetico' not in output.getvalue(), rc, output.getvalue()))
        old = '''query($key:String!){teams(filter:{key:{eq:$key}}){nodes{id key
            states(first:250){nodes{id name} pageInfo{hasNextPage}}
            labels(first:250){nodes{id name} pageInfo{hasNextPage}}}}}'''
        with patch.object(mod.urllib.request, 'urlopen', Transporte(fixture)):
            old_rc, old_output = 0, ''
            try:
                mod.linear_request(old, {'key':'ABC'}, 'token-sintetico')
                rejected = False
            except mod.Error as exc:
                old_rc, old_output = exc.rc, str(exc)
                rejected = 'INPUT_ERROR: Query too complex' in str(exc)
        results.append(('consulta antigua ROJA complejidad 25000', rejected, old_rc, old_output))
        original_request = mod.linear_request
        def unchanged(path, before):
            after = path.lstat()
            return all(getattr(after, key) == getattr(before, key) for key in (
                'st_ino', 'st_mode', 'st_size', 'st_mtime_ns'))
        def without_cursor(query, variables, token):
            return original_request(query.replace('(first:100,after:$c)', '(first:100)'), variables, token)
        out.unlink(missing_ok=True)
        rejected_rc, rejected_output = 0, ''
        with patch.dict(os.environ, TOKEN_PRUEBA='token-sintetico'), patch.object(
                mod.urllib.request, 'urlopen', Transporte(fixture)), patch.object(mod, 'linear_request', without_cursor):
            try:
                mod.linear_query(args)
                good = False
            except mod.Error as exc:
                rejected_rc, rejected_output = exc.rc, str(exc)
                good = exc.rc != 0 and 'paginación inválida' in str(exc) and not out.exists()
        results.append(('consulta sin cursor rechazada', good, rejected_rc, rejected_output))
        with contextlib.redirect_stdout(io.StringIO()), patch.dict(os.environ, TOKEN_PRUEBA='token-sintetico'), patch.object(
                mod.urllib.request, 'urlopen', Transporte(fixture)):
            mod.linear_query(args)
            before = out.stat()
            mod.linear_query(args)
            results.append(('salida privada y repetición intacta', unchanged(out, before) and
                            out.stat().st_mode & 0o777 == 0o600, 0, ''))
            for kind in ('distinto', 'directorio', 'enlace', 'fifo', 'permisos', 'especial', 'padre'):
                target = Path(td)/('destino-'+kind)
                if kind == 'directorio':
                    target.mkdir()
                elif kind == 'enlace':
                    target.symlink_to(out)
                elif kind == 'fifo':
                    os.mkfifo(target)
                elif kind == 'padre':
                    target.mkdir()
                    target.chmod(0o777)
                    target = target/'consulta.json'
                else:
                    target.write_bytes(out.read_bytes() if kind in ('permisos', 'especial') else b'ajeno\n')
                    target.chmod({'permisos': 0o644, 'especial': 0o4600}.get(kind, 0o600))
                before = target.lstat() if target.exists() or target.is_symlink() else None
                rejected_rc, rejected_output = 0, ''
                try:
                    mod.linear_query(SimpleNamespace(**{**vars(args), 'out': str(target)}))
                    good = False
                except mod.Error as exc:
                    rejected_rc, rejected_output = exc.rc, str(exc)
                    good = exc.rc == 3 and str(target) in str(exc) and 'otra ruta' in str(exc) and (
                        unchanged(target, before) if before else not target.exists())
                results.append(('destino conservado '+kind, good, rejected_rc, rejected_output))
        # Sustituir el padre exactamente entre su validación y la apertura final.
        real_open = os.open
        for existing in (False, True):
            safe = Path(td)/('seguro-'+str(existing))
            moved = Path(td)/('retirado-'+str(existing))
            unsafe = Path(td)/('inseguro-'+str(existing))
            safe.mkdir(mode=0o700)
            unsafe.mkdir(mode=0o700)
            unsafe.chmod(0o777)
            target = safe/'resultado.json'
            content = '{"equipo":"ABC"}\n'
            if existing:
                target.write_text(content)
                target.chmod(0o600)
                before = target.lstat()
            swapped = False
            def swap_parent(path, flags, *args, **kwargs):
                nonlocal swapped
                if not swapped and (existing or flags & os.O_CREAT) and (Path(path) == target or (
                        path == target.name and kwargs.get('dir_fd') is not None)):
                    safe.rename(moved)
                    safe.symlink_to(unsafe, target_is_directory=True)
                    swapped = True
                return real_open(path, flags, *args, **kwargs)
            rc, diagnostic = 0, ''
            with patch.object(mod.os, 'open', swap_parent):
                try:
                    mod.write_linear(target, content)
                except mod.Error as exc:
                    rc, diagnostic = exc.rc, str(exc)
            preserved = (unchanged(moved/target.name, before) and
                         (moved/target.name).read_text() == content) if existing else not (moved/target.name).exists()
            results.append(('carrera padre '+('lectura' if existing else 'creación'),
                            swapped and rc == 3 and not (unsafe/target.name).exists() and preserved and
                            str(target) in diagnostic and 'otra ruta' in diagnostic, rc, diagnostic))
        # Un competidor crea el nombre final después de la lectura y antes de O_EXCL.
        target = Path(td)/'colision.json'
        def collision(path, flags, *args, **kwargs):
            if flags & os.O_CREAT and (Path(path) == target or (
                    path == target.name and kwargs.get('dir_fd') is not None)):
                target.write_bytes(b'ajeno concurrente\n')
                target.chmod(0o600)
            return real_open(path, flags, *args, **kwargs)
        rc, diagnostic = 0, ''
        with patch.object(mod.os, 'open', collision):
            try:
                mod.write_linear(target, content)
            except mod.Error as exc:
                rc, diagnostic = exc.rc, str(exc)
        results.append(('colisión concurrente conservada', rc == 3 and
                        target.read_bytes() == b'ajeno concurrente\n' and 'otra ruta' in diagnostic, rc, diagnostic))
        # El bloque temprano de la guía no debe congelar la plantilla antes de decidir Supabase.
        package, home = Path(td)/'opcional', Path(td)/'hogar'
        partial = Path(td)/'parcial.resp'
        partial.write_text('proyecto=demo\nlinear_clave=XYZ\n')
        complete = INSTALL/'tests/fixtures/completa.resp'
        values = mod.load(complete, mod.questions())
        options = SimpleNamespace(respuestas=str(partial), salida=str(package), home=str(home),
                                  solo_env=True, forzar=False, linear_config=None)
        optional_fixture = {'team': {'id': values['linear_equipo_uuid'], 'key': 'XYZ'},
                            'states': [{'id': values['linear_inprogress_uuid'], 'name': 'In Progress'},
                                       {'id': values['linear_inreview_uuid'], 'name': 'In Review'}], 'labels': []}
        consultation = package/'instalacion/generado/linear-consulta.json'
        early_block = (INSTALL.parent/'CLAUDE.md').read_text().split('Para los UUID de Linear', 1)[1].split('```bash', 1)[1].split('```', 1)[0]
        rc, output, good = 0, io.StringIO(), False
        with contextlib.redirect_stdout(output), patch.dict(os.environ, TOKEN_PRUEBA='token-sintetico'), patch.object(
                mod.urllib.request, 'urlopen', Transporte(optional_fixture)):
            try:
                if '--solo-env' in early_block:
                    mod.generator(options)
                mod.linear_query(SimpleNamespace(equipo='XYZ', fixture=None, token_nombre='TOKEN_PRUEBA', out=str(consultation)))
                absent_template = not (package/'instalacion/generado/env.local.tmpl').exists()
                consultation.parent.chmod(0o775)
                options.respuestas = str(complete)
                mod.generator(options)
                options.solo_env = False
                options.linear_config = str(consultation)
                mod.generator(options)
                def contents():
                    return [(str(p), p.read_bytes(), p.stat().st_mode) for root in (package, home)
                            for p in sorted(root.rglob('*')) if p.is_file()]
                before = contents()
                mod.generator(options)
                good = absent_template and consultation.parent.stat().st_mode & 0o777 == 0o700 and contents() == before and 'SUPABASE_ACCESS_TOKEN=\n' in (
                    package/'instalacion/generado/env.local.tmpl').read_text()
            except mod.Error as exc:
                rc = exc.rc
                output.write(str(exc))
        results.append(('consulta temprana y Supabase sin colisión ni forzar', good, rc, output.getvalue()))
    return results


if __name__ == '__main__':
    if len(sys.argv) > 1:
        # La misma CLI de producción, con su transporte sustituido en el proceso hijo.
        sys.argv = [str(INSTALL/'instalacion.py'), 'linear', *sys.argv[1:]]
        with patch.dict(os.environ, LINEAR_API_KEY='token-sintetico'), patch.object(
                mod.urllib.request, 'urlopen', Transporte(json.loads((INSTALL/'tests/fixtures/linear.json').read_text()))):
            mod.main()
    else:
        results = cases()
        for name, good, rc, output in results:
            print(('PASS ' if good else 'FAIL ')+name+' rc='+str(rc)+(' '+output if rc else ''))
        print('Linear: PASS='+str(sum(row[1] for row in results))+' FAIL='+str(sum(not row[1] for row in results)))
        raise SystemExit(0 if all(row[1] for row in results) else 1)
