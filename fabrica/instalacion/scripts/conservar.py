"""Copiar registros durables del coordinador sin interpretar ni ejecutar su entorno."""
import os
from pathlib import Path
import re
import sys
from fases import Error, require, regular, safe_dir
from recibos import immutable
from originales import audit_record


def main():
    require(len(sys.argv) == 4, 'uso f8-conservar ISSUE PROYECTO CARRIL', 2)
    issue, project, lane = sys.argv[1:]
    require(re.fullmatch(r'[A-Z][A-Z0-9]*-[1-9][0-9]*', issue) and
            re.fullmatch(r'[a-z][a-z0-9-]*', project) and re.fullmatch(r'[0-9]{2}', lane),
            'conservar: identidad inválida', 2)
    home = Path(os.environ['HOME'])
    runs = home/'.config/talent-channel-operation/runs'
    require(home.is_absolute() and not any(p.is_symlink() for p in (runs, *runs.parents)),
            'conservar: origen enlazado o home inválido')
    candidates = []
    for p in runs.glob('plan-'+lane+'-'+issue+'-r*.norm'):
        match = re.fullmatch(r'plan-'+lane+'-'+re.escape(issue)+r'-r([1-9][0-9]*)\.norm', p.name)
        if match:
            candidates.append((int(match[1]), p))
    require(candidates, 'conservar: plan normalizado ausente')
    plan = regular(max(candidates)[1]).read_bytes()
    record = regular(runs/('audit-last-'+lane+'.env')).read_bytes()
    require(plan.strip() and re.search(r'\b'+re.escape(issue)+r'\b', plan.decode()), 'conservar: plan de otra issue')
    audit_record(record.decode())
    dest = home/'evidencias-fabrica'/project/'humo'
    require(not any(p.is_symlink() for p in (dest, *dest.parents)), 'conservar: destino enlazado')
    safe_dir(dest)
    for name, content in [('plan-normalizado.norm', plan), ('audit-last.env', record)]:
        path = dest/name
        if path.exists() or path.is_symlink():
            require(regular(path).read_bytes() == content, 'conservar: destino existente distinto '+name)
    immutable(dest/'plan-normalizado.norm', plan)
    immutable(dest/'audit-last.env', record)
    print('conservados plan-normalizado.norm audit-last.env')


if __name__ == '__main__':
    try:
        main()
    except (Error, OSError, ValueError) as exc:
        print('falla '+str(exc), file=sys.stderr)
        sys.exit(getattr(exc, 'rc', 1))
