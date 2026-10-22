"""Protección GitHub: valores cerrados, comparación tras aplicación."""
import json
import subprocess
import sys
from fases import Error, command_context, execute, config, require, run

BODY = {'required_status_checks': {'strict': True, 'checks': [{'context': 'local-gates'}]},
        'enforce_admins': False,
        'required_pull_request_reviews': {'required_approving_review_count': 0, 'dismiss_stale_reviews': True,
                                         'require_code_owner_reviews': False, 'require_last_push_approval': False},
        'restrictions': None, 'required_linear_history': True, 'allow_force_pushes': False,
        'allow_deletions': False, 'block_creations': False, 'required_conversation_resolution': True}
SETTINGS = {'allow_squash_merge': True, 'allow_merge_commit': True, 'allow_rebase_merge': True,
            'delete_branch_on_merge': False}


def matches(actual, expected):
    if isinstance(expected, dict):
        return isinstance(actual, dict) and all(
            (k == 'restrictions' and v is None and k not in actual) or
            (k in actual and matches(actual[k], v)) for k, v in expected.items())
    if isinstance(expected, list):
        return isinstance(actual, list) and len(actual) == len(expected) and all(
            matches(x, y) for x, y in zip(actual, expected))
    if isinstance(expected, bool) and isinstance(actual, dict):
        actual = actual.get('enabled')
    return type(actual) is type(expected) and actual == expected


def main():
    require(sys.argv[1:] in (['--plan'], ['--ejecutar']), 'uso f4-proteccion --plan|--ejecutar', 2)
    c = config()
    a = c['answers']
    from rulesets import effective_rules
    effective_rules(c)
    slug = a['repo_url'].removesuffix('.git').split('github.com/')[1]
    repo = 'repos/'+slug
    endpoint = repo+'/branches/'+a['repo_rama']+'/protection'
    current_repo = json.loads(run(['gh', 'api', repo]))
    require(isinstance(current_repo, dict), 'protección: respuesta no verificable')
    # 404 puede significar falta de protección/permisos: no se presume plan gratuito.
    p = execute(['gh', 'api', endpoint], stdin=subprocess.DEVNULL, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    current = json.loads(p.stdout) if p.returncode == 0 else None
    print('Estado actual repo: '+json.dumps({k: current_repo.get(k) for k in SETTINGS}, sort_keys=True))
    print('Estado actual protección: '+json.dumps(current, sort_keys=True))
    print('PUT '+endpoint+'\n'+json.dumps(BODY, sort_keys=True))
    print('PATCH '+repo+'\n'+json.dumps(SETTINGS, sort_keys=True))
    if sys.argv[1] == '--plan':
        if p.returncode:
            print('Protección no legible: confirmar permisos/plan; privado gratuito puede quedar pendiente procedimental.')
        return
    for method, url, body in [('PUT', endpoint, BODY), ('PATCH', repo, SETTINGS)]:
        result = execute(['gh', 'api', '--method', method, url, '--input', '-'], input=json.dumps(body),
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        require(result.returncode == 0, 'protección: aplicación rechazada; comprobar admin y plan del repo; '+
                command_context(['gh', 'api', '--method', method, url, '--input', '-']))
    require(matches(json.loads(run(['gh', 'api', endpoint])), BODY), 'protección: relectura distinta')
    require(matches(json.loads(run(['gh', 'api', repo])), SETTINGS), 'ajustes: relectura distinta')
    print('protección y ajustes verificados')


if __name__ == '__main__':
    try:
        main()
    except (Error, OSError, ValueError, KeyError) as exc:
        print('falla '+(str(exc) if isinstance(exc, Error) else 'respuesta no verificable'), file=sys.stderr)
        sys.exit(exc.rc if isinstance(exc, Error) else 1)
