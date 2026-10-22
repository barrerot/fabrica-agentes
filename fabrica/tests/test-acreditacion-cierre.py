#!/usr/bin/env python3
"""Regresiones del cierre: reanudación, rechazo sin cambios y consumidores de guías."""
import os
import contextlib
import io
from pathlib import Path
import pwd
import sys
import tempfile
import subprocess
from unittest.mock import patch

PACKAGE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PACKAGE/'instalacion/scripts'))
import fases


def permisos_reales():
    owner = pwd.getpwuid(os.getuid())
    foreign_groups = [gid for gid in os.getgroups() if gid != owner.pw_gid]
    assert foreign_groups, 'el arnés necesita un grupo suplementario real para el negativo'
    reader = PACKAGE/'skills/talent-ceo/scripts/leer-acreditacion.sh'
    with tempfile.TemporaryDirectory(prefix='permisos-') as td:
        home = Path(td)/'hogar'
        base = home/'.local/state/talent-ceo'
        acc = base/'acreditacion'
        acc.mkdir(parents=True)
        config = home/'.config'
        config.mkdir()
        claude = home/'.claude'
        claude.mkdir()
        chain = [home, home/'.local', home/'.local/state', base]
        for path in [*chain, acc, config, claude]:
            os.chown(path, -1, owner.pw_gid)
            path.chmod(0o700)
        payload = acc/'CEO.estado'
        payload.write_bytes(b'ACREDITADO\n')
        payload.chmod(0o600)

        def read():
            return subprocess.run(['bash', str(reader), 'CEO'], capture_output=True, text=True,
                                  env=dict(os.environ, HOME=str(home), TA_BUS_STATE_DIR=str(base)))

        def snapshot():
            return {p: (p.lstat().st_uid, p.lstat().st_gid, p.lstat().st_mode,
                        p.lstat().st_ctime_ns, p.lstat().st_ino) for p in chain}

        def reject(target=base, user=owner.pw_name):
            before = snapshot()
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                try:
                    fases.role_directory(home, target, user)
                    raise AssertionError('destino inseguro aceptado')
                except fases.Error as error:
                    assert error.rc == 2 and 'corrección:' in str(error)
            assert snapshot() == before and not output.getvalue()
            assert payload.read_bytes() == b'ACREDITADO\n'

        # Cada componente existente, incluida la hoja y el home, conserva 0002 rojo.
        for path in chain:
            for mode in (0o777, 0o773):
                path.chmod(mode)
                reject()
                path.chmod(0o700)
        home.chmod(0o775)
        reject()
        home.chmod(0o700)
        # Padre corregible antes de un componente posterior con grupo ajeno.
        chain[1].chmod(0o775)
        os.chown(chain[2], -1, foreign_groups[0])
        chain[2].chmod(0o771)
        reject()
        os.chown(chain[2], -1, owner.pw_gid)
        chain[2].chmod(0o700)
        late = base/'enlace'
        late.symlink_to(acc, target_is_directory=True)
        reject(late/'nuevo')
        late.unlink()
        # Propietario ajeno real en el home; no se modifican sus descendientes.
        reject(user='root' if owner.pw_uid != 0 else 'nobody')
        print('permisos reales: 777/773, home 775, grupo ajeno, enlace tardío y dueño ajeno ROJOS sin cambios')
        chain[2].chmod(0o775)
        assert read().returncode == 2, 'lector sin preparación admite state 775'
        before = payload.stat()
        initial = {chain[1]: 0o775, chain[2]: 0o771, config: 0o771, claude: 0o775}
        for path, mode in initial.items():
            path.chmod(mode)
        identities = {p: (p.stat().st_uid, p.stat().st_gid) for p in initial}
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            fases.role_directory(home, base, owner.pw_name)
            fases.role_directory(home, config/'talent-channel-operation', owner.pw_name)
            fases.role_directory(home, claude, owner.pw_name)
        lines = output.getvalue().splitlines()
        assert len(lines) == len(initial)
        for path, mode in initial.items():
            expected = 0o700 if path == claude else mode & ~0o020
            assert path.stat().st_mode & 0o7777 == expected
            assert (path.stat().st_uid, path.stat().st_gid) == identities[path]
            assert lines.count('directorio de rol corregido: ruta='+str(path)+' modo anterior='+
                               format(mode, '04o')+' modo nuevo='+format(mode & ~0o020, '04o')) == 1
        assert base.stat().st_mode & 0o7777 == 0o700
        assert (config/'talent-channel-operation').stat().st_mode & 0o7777 == 0o700
        assert payload.stat() == before and read().stdout == 'ACREDITADO\n' and read().returncode == 0
        with contextlib.redirect_stdout(io.StringIO()) as repeated:
            fases.role_directory(home, base, owner.pw_name)
        assert not repeated.getvalue()
        # También preserva bits especiales y el modo observado al restringir padres.
        chain[1].chmod(0o2775)
        with contextlib.redirect_stdout(io.StringIO()):
            fases.role_directory(home, base, owner.pw_name)
        assert chain[1].stat().st_mode & 0o7777 == 0o2755
        print('permisos reales: 775/771/771/775 corregidos, modos finales estrictos, identidades y sello intactos, lector VERDE')


def main():
    permisos_reales()
    with tempfile.TemporaryDirectory(prefix='cierre-') as td:
        home = Path(td)/'hogar'
        base = home/'.local/state/talent-ceo'
        acc = base/'acreditacion'
        acc.mkdir(parents=True)
        for path in (home, home/'.local', home/'.local/state', base, acc):
            path.chmod(0o700)
        payload = acc/'CEO.estado'
        payload.write_bytes(b'ACREDITADO\n')
        payload.chmod(0o600)
        sealed = payload.stat()
        owner = pwd.getpwuid(os.getuid())
        managed = [home/'.local', home/'.local/state', base]
        owners = {path: 0 for path in managed}
        modes = {path: 0o777 for path in managed}
        actual_stat = Path.stat
        changes = []

        def observed(path, *args, **kw):
            info = actual_stat(path, *args, **kw)
            if path in owners:
                values = list(info)
                values[4] = owners[path]
                values[0] = (values[0] & ~0o7777) | modes[path]
                return os.stat_result(values)
            return info

        def chown(path, uid, gid):
            changes.append(Path(path))
            owners[Path(path)] = uid

        def chmod(path, mode):
            modes[Path(path)] = mode

        # Simulación explícita de UID root; ficheros, bytes e inodos son reales.
        with patch.object(Path, 'stat', observed), patch.object(os, 'chown', chown), \
                patch.object(Path, 'chmod', chmod):
            fases.role_directory(home, base, owner.pw_name)
            assert changes == managed
            assert all(owners[p] == owner.pw_uid and not modes[p] & 0o022 for p in managed)
            fases.role_directory(home, base, owner.pw_name)
            assert changes == managed
            assert payload.read_bytes() == b'ACREDITADO\n'
            assert (payload.stat().st_ino, payload.stat().st_uid, payload.stat().st_mode,
                    payload.stat().st_mtime_ns, payload.stat().st_size) == (
                    sealed.st_ino, sealed.st_uid, sealed.st_mode, sealed.st_mtime_ns, sealed.st_size)
            print('R03 migración sintética root, idempotencia y sello intacto: PASS')
            owners[managed[1]] = owner.pw_uid+10000
            changes.clear()
            try:
                fases.role_directory(home, base, owner.pw_name)
                raise AssertionError('padre tercero aceptado')
            except fases.Error as error:
                text = str(error)
                assert error.rc == 2 and str(managed[1]) in text and 'corrección:' in text
                assert 'propietario=' in text and 'modo=' in text
            assert not changes and payload.read_bytes() == b'ACREDITADO\n'
            print('R03/R04 tercero rechazado sin cambios y diagnóstico completo: PASS')
        link = home/'enlace'
        link.symlink_to(home/'.local', target_is_directory=True)
        try:
            fases.role_directory(home, link/'state/talent-ceo', owner.pw_name)
            raise AssertionError('enlace aceptado')
        except fases.Error as error:
            assert error.rc == 2 and str(link) in str(error) and 'retirar el enlace' in str(error)
        assert payload.read_bytes() == b'ACREDITADO\n'
        print('R03 enlace rechazado y sello intacto: PASS')
    guide = (PACKAGE/'instalacion/fases/F5.md').read_text()
    command = 'preparar-sesiones.sh" --ejecutar "$CARRIL"'
    mutant = guide.replace(command, 'preparar-sesiones.sh" --argumento-inexistente "$CARRIL"')
    assert mutant != guide
    try:
        fases.lint_commands(mutant, 'F5.md')
        raise AssertionError('opción inventada aceptada')
    except fases.Error as error:
        assert 'argumentos rechazados' in str(error)
    fases.lint_commands(guide, 'F5.md')
    print('R05 lint completo rechaza opción inventada y acepta restauración: PASS')
    from guias import check_arguments
    for skill, script in (
            ('talent-channel-operation', 'preparar-sesiones'),
            ('talent-channel-operation', 'preparar-modelo-canal'),
            ('talent-channel-operation', 'dispatch'),
            ('talent-channel-operation', 'capture-pane-fixtures'),
            ('talent-ceo', 'bus-sellar'), ('talent-ceo', 'reacreditar'), ('talent-ceo', 'doctor')):
        try:
            check_arguments('/paquete/skills/'+skill+'/scripts/'+script+'.sh', ['--argumento-inexistente'])
            raise AssertionError('opción desconocida aceptada: '+script)
        except fases.Error as error:
            assert 'argumentos rechazados' in str(error)
    print('R05 siete consumidores reales rechazan opción inventada: PASS')


if __name__ == '__main__':
    main()
