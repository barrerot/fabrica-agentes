"""Exclusiones compartidas de inventario y huellas del núcleo."""
from pathlib import Path


def exclusions(root):
    path = Path(root)/'instalacion/nucleo.exclude'
    if not path.is_file() or path.is_symlink():
        raise ValueError('núcleo: lista de exclusiones ausente o enlazada')
    rules = []
    for line in path.read_text().splitlines():
        rule = line.strip()
        if not rule or rule.startswith('#'):
            continue
        if rule.startswith('/') or '..' in Path(rule).parts or any(c in rule for c in '*?['):
            raise ValueError('núcleo: exclusión inválida '+rule)
        rules.append(rule)
    return rules


def excluded(relative, rules):
    name = Path(relative).as_posix()
    if '__pycache__' in Path(relative).parts or Path(relative).suffix == '.pyc':
        return True
    return any(name == rule.rstrip('/') or
               (rule.endswith('/') and name.startswith(rule)) for rule in rules)
