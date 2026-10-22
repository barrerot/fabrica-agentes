"""Regenera el contrato únicamente desde las capturas reales versionadas."""
import json
from pathlib import Path
import re


def generar():
    base = Path(__file__).parent
    blocks = {}
    references = ['gh-ayuda-1.txt', 'gh-ayuda-2.txt']
    for name in references:
        for block in (base/name).read_text().split('######## ')[1:]:
            head, _, body = block.partition('\n')
            # La segunda captura repite API pero termina a mitad de FLAGS.
            # La primera contiene su ayuda completa: nunca sobrescribirla.
            blocks.setdefault(head.strip(), body)
    commands = {}
    for head, body in blocks.items():
        if not head.startswith('gh ') or not head.endswith(' --help'):
            continue
        command = head[3:-7]
        flags = {}
        active = False
        for line in body.splitlines():
            if line in ('FLAGS', 'INHERITED FLAGS'):
                active = True
                continue
            if re.fullmatch('[A-Z][A-Z ]+', line):
                active = False
            if not active:
                continue
            match = re.match(r'\s+(?:(-[A-Za-z]), )?(--[\w-]+)(?: (\S+))?', line)
            if not match:
                continue
            short, flag, value = match.groups()
            argument = bool(value and not value.startswith('--') and re.match(r'[a-z\[]', value))
            # La ayuda imprime «--interval --watch» y declara segundos/default 10.
            if flag == '--interval':
                argument = True
            flags[flag] = argument
            if short:
                flags[short] = argument
        spec = {'flags': flags}
        fields = blocks.get('gh '+command+' --json', '')
        if fields.startswith('Specify'):
            spec['fields'] = [line.strip() for line in fields.splitlines()[1:]
                              if re.fullmatch(r'[A-Za-z]\w*', line.strip())]
        commands[command] = spec
    return dict(version='2.45.0', commands=commands, reference=references, field_reference_version='2.45.0')


if __name__ == '__main__':
    Path(__file__).with_name('gh-2.45.0.json').write_text(json.dumps(generar(), indent=2)+'\n')
