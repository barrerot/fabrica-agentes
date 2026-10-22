"""Importar un tar de C1 sin enlaces, escapes ni extracción arbitraria."""
import io
from pathlib import PurePosixPath
import re
import sys
import tarfile
import tempfile
from pathlib import Path
from fases import STATE, Error, require, safe_dir, write, run, config, ROOT
from recibos import ORIGINALS


def main():
    require(sys.argv[1:] in ([], ['--repetir-capturas']), 'uso f8-importar [--repetir-capturas]', 2)
    repeat = bool(sys.argv[1:])
    safe_dir(STATE)
    payload = sys.stdin.buffer.read(16 * 1024 * 1024 + 1)
    require(len(payload) <= 16 * 1024 * 1024, 'evidencias: archivo demasiado grande')
    pending = []
    seen = set()
    with tarfile.open(fileobj=io.BytesIO(payload), mode='r:') as archive:
        for member in archive.getmembers():
            rel = PurePosixPath(member.name)
            require(not rel.is_absolute() and '..' not in rel.parts and rel.parts and
                    str(rel) == member.name.rstrip('/') and rel.parts[0] in ('pane', 'humo') and
                    re.fullmatch(r'[A-Za-z0-9_./-]+', member.name),
                    'evidencias: '+member.name+': ruta inválida')
            require(member.isdir() or member.isfile(), 'evidencias: '+member.name+': enlace o tipo no permitido')
            require(member.name not in seen, 'evidencias: '+member.name+': ruta repetida')
            seen.add(member.name)
            dest = STATE.joinpath(*rel.parts)
            require(not any(path.is_symlink() for path in (dest, *dest.parents)), 'evidencias: '+member.name+': destino enlazado')
            if member.isdir():
                continue
            else:
                capture = bool(re.fullmatch(r'pane/(claude|codex)_[0-9]+\.[0-9]+\.[0-9]+/(idle|busy|done|modal|redraw)\.txt', str(rel)))
                original = len(rel.parts) == 2 and rel.parts[0] == 'humo' and rel.name in (*ORIGINALS.values(), 'veredicto-plan.txt', 'audit-last.env')
                if not capture and not original:
                    print('no importado: '+member.name+' (nombre incidental)')
                    continue
                content = archive.extractfile(member).read()
                require(content, 'evidencias: '+member.name+': fichero vacío')
                if not (repeat and capture):
                    require(not dest.exists() or (dest.is_file() and not dest.is_symlink() and dest.read_bytes() == content),
                            'evidencias: '+member.name+': destino existente distinto')
                require(not dest.exists() or dest.is_file(), 'evidencias: '+member.name+': destino no regular')
                try:
                    text = content.decode('utf-8')
                except UnicodeError:
                    raise Error('evidencias: '+member.name+': texto UTF-8 inválido') from None
                pending.append((dest, text))
    if repeat:
        # Antes de sustituir cualquier captura, clasificar el juego completo nuevo.
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            for dest, content in pending:
                if dest.is_relative_to(STATE/'pane'):
                    rel = dest.relative_to(STATE/'pane')
                    (base/rel.parent).mkdir(exist_ok=True)
                    (base/rel).write_text(content)
            for directory in base.iterdir():
                run(['bash', ROOT/'instalacion/scripts/calibrar-pane.sh', config()['clon'], directory],
                    diagnostic='evidencias: '+directory.name+': repetición rechazada', relay_errors=True)
    for dest, content in pending:
        safe_dir(dest if content is None else dest.parent)
        if content is not None:
            write(dest, content)
    print('evidencias incorporadas en estado privado; originales preservados en C1')


if __name__ == '__main__':
    try:
        main()
    except Error as exc:
        print('falla '+str(exc)+'; conservar archivo original', file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, tarfile.TarError):
        print('falla importación de evidencias; conservar archivo original', file=sys.stderr)
        sys.exit(1)
