"""Equivalentes de producto: fusión conservadora y repetible."""
import json
from pathlib import Path
import re
import shlex


def yaml_nodes(text):
    """Nodos de mapa por indentación; excluir texto, comentarios y bloques."""
    stack, block = [], None
    for line in text.splitlines():
        indent = len(line)-len(line.lstrip(' '))
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        if block is not None and indent > block:
            continue
        block = None
        # Quitar comentarios únicamente fuera de cadenas.
        quote, clean = None, ''
        for char in line:
            if char in ('"', "'"):
                quote = None if quote == char else (char if quote is None else quote)
            if char == '#' and quote is None:
                break
            clean += char
        m = re.match(r'^ *(?:["\']?)([A-Za-z_][A-Za-z0-9_]*|<<)(?:["\']?):\s*(.*)$', clean)
        if not m:
            if re.match(r'^ *-\s+[&*][A-Za-z_]', clean):
                yield (), 'alias', True
            continue
        while stack and stack[-1][0] >= indent:
            stack.pop()
        path = tuple(k for _, k in stack)+(m[1],)
        tail = m[2].strip()
        yield path, tail, bool(re.match(r'[&*][A-Za-z_]', tail))
        if re.match(r'[|>][+-]?[0-9]?$', tail):
            block = indent
        elif not tail or re.fullmatch(r'&[A-Za-z_][A-Za-z0-9_-]*', tail):
            stack.append((indent, m[1]))


def required_yaml_values(nodes):
    """Resolver solo los mapas obligatorios, incluidos mapas de flujo y alias.

    Cualquier ambigüedad en esos mapas impide aceptar el fichero sin fusión.
    El resto se conserva byte a byte y no se reserializa.
    """
    anchors = {}
    for path, tail, _ in nodes:
        match = re.match(r'&([A-Za-z_][A-Za-z0-9_-]*)(?:\s|$)', tail)
        if match:
            if match[1] in anchors:
                return {}
            anchors[match[1]] = (path, tail[match.end():].strip())

    def flow(text):
        tokens = re.findall(r'"(?:\\.|[^"\\])*"|\'(?:[^\']|\'\')*\'|[{}:,]|[^\s{}:,]+', text)
        cursor = 0

        def value():
            nonlocal cursor
            token = tokens[cursor]
            cursor += 1
            if token != '{':
                return token
            result = {}
            while tokens[cursor] != '}':
                key = tokens[cursor].strip('"\'')
                cursor += 1
                if tokens[cursor] != ':' or key in result:
                    raise ValueError
                cursor += 1
                result[key] = value()
                if tokens[cursor] == ',':
                    cursor += 1
                elif tokens[cursor] != '}':
                    raise ValueError
            cursor += 1
            return result
        result = value()
        if cursor != len(tokens):
            raise ValueError
        return result

    def mapping(path, tail='', seen=()):
        if tail.startswith('*'):
            name = tail[1:]
            if name not in anchors or name in seen:
                raise ValueError
            prefix, rest = anchors[name]
            return mapping(prefix, rest, (*seen, name))
        if tail.startswith('&'):
            tail = re.sub(r'^&[A-Za-z_][A-Za-z0-9_-]*\s*', '', tail)
        if tail.startswith('{'):
            result = flow(tail)
            if not isinstance(result, dict):
                raise ValueError
            return result
        if tail:
            raise ValueError
        result, inherited = {}, {}
        for node, content, _ in nodes:
            if node[:-1] != path:
                continue
            key = node[-1]
            if key not in ('<<', 'request_changes_workflow', 'auto_review', 'enabled', 'drafts'):
                continue
            if key == '<<':
                inherited.update(mapping(node, content, seen))
            else:
                if key in result:
                    raise ValueError
                result[key] = (mapping(node, content, seen) if not content or content.startswith(('*', '&', '{'))
                               else content)
        inherited.update(result)
        return inherited
    try:
        reviews = [(path, tail) for path, tail, _ in nodes if path == ('reviews',)]
        if len(reviews) != 1:
            return {}
        return mapping(*reviews[0])
    except (ValueError, KeyError, IndexError, TypeError):
        return {}


def merge_yaml(text):
    """Fusionar la política de borradores sin cambiar la revisión automática de la App."""
    from fases import require
    lines = text.splitlines()
    nodes = list(yaml_nodes(text))
    values = required_yaml_values(nodes)
    if values.get('request_changes_workflow') == 'true' and isinstance(values.get('auto_review'), dict) and \
            values['auto_review'].get('drafts') == 'false':
        return text
    require(not any('\t' in line for line in lines) and not any(alias for _, _, alias in nodes),
            'coderabbit: YAML con alias/tabs requiere fusión humana')
    for path, value in ((('reviews', 'request_changes_workflow'), 'true'),
                        (('reviews', 'auto_review', 'drafts'), 'false')):
        first, last, indent = 0, len(lines), 0
        for number, key in enumerate(path):
            positions = [i for i in range(first, last) if re.match('^'+' '*indent+re.escape(key)+r':(?:\s|$)', lines[i])]
            require(len(positions) <= 1, 'coderabbit: clave duplicada requiere fusión humana')
            leaf = number == len(path)-1
            if positions:
                index = positions[0]
                tail = lines[index].split(':', 1)[1].split('#', 1)[0].strip()
                require(leaf or not tail, 'coderabbit: mapa inline requiere fusión humana')
                if leaf:
                    lines[index] = ' '*indent+key+': '+value
            else:
                index = last
                lines.insert(index, ' '*indent+key+':'+(' '+value if leaf else ''))
            if not leaf:
                first = index+1
                last = next((i for i in range(first, len(lines)) if lines[i].strip() and
                             not lines[i].lstrip().startswith('#') and
                             len(lines[i])-len(lines[i].lstrip()) <= indent), len(lines))
                children = [len(lines[i])-len(lines[i].lstrip()) for i in range(first, last)
                            if lines[i].strip() and not lines[i].lstrip().startswith('#')]
                indent = min(children) if children else indent+2
    return '\n'.join(lines)+'\n'


def clone_destination(clone, rel):
    from fases import require
    clone, rel = Path(clone), Path(rel)
    require(clone.is_absolute() and not rel.is_absolute() and '..' not in rel.parts,
            'destino fuera del clon: '+str(rel))
    path = clone/rel
    require(not any(p.is_symlink() for p in (path, *path.parents)),
            'destino enlazado en clon: '+str(rel))
    require(all(not p.exists() or p.is_dir() for p in path.parents),
            'padre no directorio en clon: '+str(rel))
    require(not path.exists() or path.is_file(), 'destino no regular en clon: '+str(rel))
    require(path.resolve().is_relative_to(clone.resolve()), 'destino fuera del clon: '+str(rel))
    return path


def equivalent_payloads(c):
    from fases import ROOT, require, write, regular
    templates = ROOT/'instalacion/plantillas/producto'
    assets = ROOT/'skills/talent-repo-onboarding/assets'
    a = c['answers']
    gates = '\n'.join('bash -c '+shlex.quote(a['gate_cmd_'+g.replace('-', '_')])
                      for g in a['gates_ids'].split())
    rules = (assets/'bloque-reglas-fabrica.md').read_text().split('````markdown\n', 1)[1].split('````', 1)[0]
    rules = re.sub(r'<!--.*?-->\n', '', rules, flags=re.S)
    rules = re.sub(r'\b[A-Z]{3}-[0-9]+\b', 'referencia del motor', rules)
    rules = rules.replace('<KEY>', a['linear_clave']).replace(
        'npm run typecheck && npm run lint && npm run build && npm run test:unit', gates)
    coordination = 'manifiestos/anexo-coordinacion-'+c['project']+'.md'
    rules += '\nCoordinación: leer `'+coordination+'` antes de adjudicar canales o runners.\n'
    payloads = {
        coordination: regular(ROOT/('instalacion/generado/anexos/talent-coordination/anexo-'+c['project']+'.md')).read_text(),
        'scripts/draft-handoff.sh': (templates/'draft-handoff.sh.tmpl').read_text().replace('__GATES__', gates),
        '.coderabbit.yaml': re.sub(r'(?m)^ *enabled: true\n', '', (assets/'coderabbit-politica.yaml').read_text()),
        'CLAUDE.md': rules, 'AGENTS.md': rules,
        '.github/PULL_REQUEST_TEMPLATE.md': (templates/'pr-template.md.tmpl').read_text().replace('__KEY__', a['linear_clave']),
        '.gitignore': (templates/'gitignore.tmpl').read_text(),
        '.claude/hooks/check-skill.sh': (templates/'check-skill.sh.tmpl').read_text(),
        '.claude/settings.json': json.loads((templates/'settings.json.tmpl').read_text()),
    }
    profile = (ROOT/'skills/talent-issue-craft/templates/perfil-de-repo.md').read_text()
    profile = profile.replace('Plantilla VACÍA.',
        'Perfil generado con las respuestas públicas. Los valores neutros restantes están pendientes de completar por el equipo.')
    profile = profile.replace('| Nombre del repo/producto | |',
        '| Nombre del repo/producto | '+a['repo_url']+' |\n| Clave del equipo | '+a['linear_clave']+' |')
    profile = profile.replace('| Stack principal (solo lo que afecta a matrices: ¿UI web? ¿BD relacional con políticas de fila? ¿API pública?) | |',
        '| Stack principal (solo lo que afecta a matrices: ¿UI web? ¿BD relacional con políticas de fila? ¿API pública?) | '+
        ('Supabase' if a['supabase'] == 'si' else 'ninguno')+' |')
    first = profile.index('| [typecheck]')
    last = profile.index('\n\n## 3.', first)
    profile = profile[:first]+'\n'.join('| '+g+' | `'+a['gate_cmd_'+g.replace('-', '_')]+'` | Sí |'
        for g in a['gates_ids'].split())+profile[last:]
    payloads['docs/reference/issue-craft-perfil-'+a['proyecto']+'.md'] = profile
    return payloads


def equivalents(c, plan, collect=False):
    from fases import Error, require, write
    payloads = equivalent_payloads(c)
    start, end = '<!-- fabrica:inicio -->', '<!-- fabrica:fin -->'
    pending, conflicts = {}, []
    for rel, value in payloads.items():
        try:
            pending[rel] = merge_equivalent(c, rel, value, start, end)
        except (Error, ValueError, OSError) as exc:
            conflicts.append(str(exc) if isinstance(exc, Error) else 'equivalente ilegible: '+rel)
    if collect:
        return pending, conflicts
    require(not conflicts, '\n'.join(conflicts))
    for rel, text in pending.items():
        path = clone_destination(c['clon'], rel)
        print(('fusionar ' if path.exists() else 'crear ')+rel)
        if not plan:
            path.parent.mkdir(parents=True, exist_ok=True)
            write(path, text, 0o755 if rel.endswith('.sh') else 0o644)


def merge_equivalent(c, rel, value, start, end):
    from fases import require
    path = clone_destination(c['clon'], rel)
    old = path.read_text() if path.exists() else ''
    if rel == '.claude/settings.json':
        try:
            data = json.loads(old) if old else {}
        except ValueError:
            require(False, 'settings inválidos: JSON no verificable')
        require(isinstance(data, dict), 'settings inválidos: objeto requerido')
        hooks = data.setdefault('hooks', {})
        require(isinstance(hooks, dict), 'settings: hooks inválidos')
        # Migrar solo las dos órdenes exactas de la instalación anterior.
        legacy = {'bash scripts/check-push-audit.sh': 'bash "${CLAUDE_PROJECT_DIR:?}/scripts/check-push-audit.sh"',
                  'bash .claude/hooks/check-skill.sh': 'bash "${CLAUDE_PROJECT_DIR:?}/.claude/hooks/check-skill.sh"'}
        for entries in hooks.values():
            if isinstance(entries, list):
                for entry in entries:
                    if isinstance(entry, dict) and isinstance(entry.get('hooks'), list):
                        for hook in entry['hooks']:
                            if isinstance(hook, dict) and hook.get('command') in legacy:
                                hook['command'] = legacy[hook['command']]
        for event, entries in value['hooks'].items():
            current = hooks.setdefault(event, [])
            require(isinstance(current, list), 'settings: evento inválido')
            for entry in entries:
                if entry not in current:
                    current.append(entry)
        text = json.dumps(data, indent=2)+'\n'
    elif rel.endswith('.md') or rel == '.gitignore':
        first, last = (('# fabrica:inicio', '# fabrica:fin') if rel == '.gitignore' else (start, end))
        require(old.count(first) == old.count(last) and old.count(first) <= 1,
                'bloque de fábrica inválido: '+rel)
        if rel == '.gitignore' and first in old:
            previous = old.split(first, 1)[1].split(last, 1)[0]
            exceptions = [line for line in previous.splitlines() if line.startswith('!/') or
                          (line.startswith('/') and line.endswith('/*'))]
            value = value.rstrip()+'\n'+'\n'.join(exceptions)+'\n'
        block = first+'\n'+value.rstrip()+'\n'+last
        if first in old:
            text = re.sub(re.escape(first)+r'.*?'+re.escape(last), lambda _: block, old, flags=re.S)
        else:
            text = old.rstrip()+'\n\n'+block+'\n'
    elif rel == '.coderabbit.yaml' and old:
        text = merge_yaml(old)
    elif rel == 'scripts/draft-handoff.sh' and old and old != value:
        first, last = '# fabrica:original:inicio', '# fabrica:original:fin'
        require(old.count(first) == old.count(last) and old.count(first) <= 1, 'draft-handoff: bloque inválido')
        original = old
        if first in old:
            original = old.split(first+'\n(\n', 1)[1].split('\n)\n'+last, 1)[0]
        # Mantener código ajeno en subshell y exigir también los gates nuevos.
        # Un fallo de cualquiera elimina el sentinel, incluso si lo emitió el original.
        body = value.split('\n', 1)[1]
        text = ('#!/usr/bin/env bash\nset -euo pipefail\ncd "$(git rev-parse --show-toplevel)"\n'
                'trap \'rc=$?; if [ "$rc" -ne 0 ]; then rm -f .claude/.draft-handoff; fi\' EXIT\n'+
                first+'\n(\n'+original+'\n)\n'+last+'\nrm -f .claude/.draft-handoff\n'+body)
    elif rel == '.claude/hooks/check-skill.sh' and old and old != value:
        require('tool_input' in old and 'file_path' in old and old.startswith('#!'),
                'check-skill existente incompatible; fusionar con revisión humana')
        marker = '# fabrica: conserva hook de producto que lee tool_input.file_path\n'
        text = old if marker in old else old.rstrip()+'\n'+marker
    else:
        text = value
    return text
