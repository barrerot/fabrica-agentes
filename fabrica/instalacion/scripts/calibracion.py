"""Registrar solo el par ya clasificado, en la configuración de esta identidad."""
import re
import sys
from pathlib import Path
from fases import Error, pairs, regular, require, write


def main():
    directory = Path(sys.argv[1])
    require(directory.is_absolute() and not any(p.is_symlink() for p in (directory, *directory.parents)),
            'calibración: directorio inseguro')
    require(re.fullmatch(r'(claude|codex)_[0-9]+\.[0-9]+\.[0-9]+', directory.name),
            'calibración: nombre de par inválido')
    conf = Path.home()/'.config/talent-channel-operation/agents.conf'
    regular(conf, True)
    require(not any(p.is_symlink() for p in conf.parents), 'calibración: configuración enlazada')
    values = pairs(conf, quoted=True, exports=True)
    observed = set(filter(None, values.get('TCO_PANE_CALIBRATED', '').split('|')))
    require(all(re.fullmatch(r'(claude|codex):[0-9]+\.[0-9]+\.[0-9]+', p) for p in observed),
            'calibración: registro anterior inválido')
    observed.add(directory.name.replace('_', ':', 1))
    lines = [line for line in conf.read_text().splitlines()
             if not re.match(r'(export )?TCO_PANE_CALIBRATED=', line)]
    lines.append('TCO_PANE_CALIBRATED="'+'|'.join(sorted(observed))+'"')
    write(conf, '\n'.join(lines)+'\n')
    print('calibración registrada en '+str(conf))


if __name__ == '__main__':
    try:
        main()
    except (Error, OSError, ValueError) as exc:
        print('falla '+str(exc), file=sys.stderr)
        sys.exit(1)
