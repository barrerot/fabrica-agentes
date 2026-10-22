"""Etiqueta de respaldo de revisión: comprobar antes de crear, sin modificar la App."""
import json
from fases import require, run


def repository_labels(c):
    slug = c['answers']['repo_url'].split('github.com/', 1)[1].removesuffix('.git')
    pending = run(['gh', 'api', '--paginate', 'repos/'+slug+'/labels?per_page=100'],
                  diagnostic='etiquetas del repositorio no verificables').lstrip()
    require(pending, 'etiquetas formato inválido')
    decoder = json.JSONDecoder()
    labels = set()
    while pending:
        try:
            page, end = decoder.raw_decode(pending)
        except ValueError:
            require(False, 'etiquetas formato inválido')
        require(isinstance(page, list) and all(isinstance(row, dict) and isinstance(row.get('name'), str)
                                               for row in page), 'etiquetas formato inválido')
        labels.update(row['name'] for row in page)
        pending = pending[end:].lstrip()
    return labels


def ensure_review_label(c, plan):
    if plan:
        print('Crear etiqueta cr-review solo si falta')
        return
    slug = c['answers']['repo_url'].split('github.com/', 1)[1].removesuffix('.git')
    if 'cr-review' not in repository_labels(c):
        run(['gh', 'label', 'create', 'cr-review', '--repo', slug, '--color', 'ededed',
             '--description', 'Revisión de respaldo por la App'], diagnostic='crear etiqueta cr-review falló')
