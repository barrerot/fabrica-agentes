"""Transporte GraphQL sintético: complejidad, cursores y errores HTTP reales."""
import io
import json
import re
import urllib.error


class Transporte:
    def __init__(self, fixture, mode='ok'):
        self.fixture = fixture
        self.mode = mode
        self.calls = []

    def __call__(self, request, timeout):
        body = json.loads(request.data)
        query, variables = body['query'], body['variables']
        self.calls.append(body)
        # Producto por cada rama anidada; 50 cuando falta first.
        parent = re.search(r'teams\((.*?)\)\{', query)
        first = re.search(r'first\s*:\s*(\d+)', parent[1]) if parent else None
        outer = int(first[1]) if first else (50 if 'teams' in query else 1)
        children = re.findall(r'(?:states|labels)\((.*?)\)', query)
        complexity = outer * sum(int(m[1]) if (m := re.search(r'first\s*:\s*(\d+)', child)) else 50
                                 for child in children) if children else outer
        error = {'errors': [{'message': 'Query too complex', 'extensions': {'code': 'INPUT_ERROR'}}]}
        if complexity > 10000 or self.mode == '400':
            raise urllib.error.HTTPError(request.full_url, 400, 'Bad Request', {}, io.BytesIO(json.dumps(error).encode()))
        if self.mode in ('401', '403', '429'):
            raise urllib.error.HTTPError(request.full_url, int(self.mode), 'error', {}, io.BytesIO(b'{}'))
        if self.mode == 'red':
            raise urllib.error.URLError('fallo sintético')
        if self.mode == 'timeout':
            raise TimeoutError('tiempo agotado')
        if self.mode == '200-errors':
            return io.BytesIO(json.dumps(error).encode())
        if 'teams(' in query:
            data = {'teams': {'nodes': [] if self.mode == 'ausente' else [self.fixture['team']]}}
        else:
            field = 'states' if 'states(' in query else 'labels'
            connection = re.search(field+r'\((.*?)\)', query)
            first = re.search(r'first\s*:\s*(\d+)', connection[1]) if connection else None
            size = int(first[1]) if first else 50
            cursor = re.search(r'after\s*:\s*\$(\w+)', connection[1]) if connection else None
            declared = cursor and re.search(r'\$'+cursor[1]+r'\s*:\s*String\b', query)
            start = int(variables.get(cursor[1]) or 0) if declared else 0
            items = list(self.fixture[field])
            if field == 'states':
                items += [{'id': f'{i:08x}-0000-0000-0000-000000000000', 'name': 'Estado '+str(i)} for i in range(1, 8)]
            else:
                items = [{'id': f'{i:08x}-1111-1111-1111-111111111111', 'name': 'Etiqueta '+str(i)} for i in range(230)]
            next_page = start+size < len(items) or self.mode in ('tope', 'cursor')
            data = {'team': {field: {'nodes': [] if self.mode in ('tope', 'cursor') else items[start:start+size],
                                    'pageInfo': {'hasNextPage': next_page,
                                                 'endCursor': None if self.mode == 'cursor' else str(start+size)}}}}
        return io.BytesIO(json.dumps({'data': data}).encode())
