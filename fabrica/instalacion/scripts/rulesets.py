"""Reglas efectivas de rama: lectura y rechazo de requisitos ajenos."""
import json
from fases import require, run


def effective_rules(c):
    a = c['answers']
    slug = a['repo_url'].removesuffix('.git').split('github.com/')[1]
    raw = run(['gh', 'api', 'repos/'+slug+'/rules/branches/'+a['repo_rama']],
              diagnostic='ruleset: reglas efectivas no verificables')
    try:
        rules = json.loads(raw)
    except ValueError:
        require(False, 'ruleset: formato no verificable')
    require(isinstance(rules, list), 'ruleset: formato no verificable')
    print('Reglas efectivas: '+json.dumps(rules, sort_keys=True))
    allowed = {'local-gates'}
    for row in rules:
        require(isinstance(row, dict) and isinstance(row.get('type'), str), 'ruleset: formato no verificable')
        kind = row['type']
        params = row.get('parameters', {})
        require(isinstance(params, dict), 'ruleset: formato no verificable')
        if kind == 'required_status_checks':
            checks = params.get('required_status_checks')
            require(isinstance(checks, list) and all(isinstance(x, dict) and isinstance(x.get('context'), str)
                                                   for x in checks), 'ruleset: formato no verificable')
            foreign = sorted({x['context'] for x in checks}-allowed)
            require(not foreign, 'ruleset: checks ajenos '+','.join(foreign)+
                    '; adaptar o retirar el ruleset en GitHub; el instalador no lo modifica')
        elif kind == 'pull_request':
            require(type(params.get('required_approving_review_count')) is int,
                    'ruleset: formato no verificable')
            require(params['required_approving_review_count'] == 0 and
                    not params.get('require_code_owner_review') and not params.get('require_last_push_approval'),
                    'ruleset: aprobaciones de revisión; adaptar o retirar el ruleset en GitHub')
        else:
            # Hasta verificar la documentación de otros tipos, no presumir compatibilidad.
            require(kind in ('non_fast_forward', 'deletion', 'required_linear_history', 'required_conversation_resolution'),
                    'ruleset: regla no acreditada '+kind+'; adaptar o retirar el ruleset en GitHub')
    return rules
