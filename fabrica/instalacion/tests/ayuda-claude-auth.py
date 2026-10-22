"""La ayuda conserva el formato y explica cuándo acreditar con token."""
from pathlib import Path
import re


def comprobar(root):
    rows = [line.split('\t') for line in (root/'instalacion/preguntas.tsv').read_text().splitlines()
            if line.startswith('claude_auth\t')]
    assert len(rows) == 1 and len(rows[0]) == 9
    row = rows[0]
    assert row[6] == 'login'
    assert re.fullmatch(row[5], 'login') and re.fullmatch(row[5], 'token')
    assert 'una cuenta para varios roles sin iniciar sesión en cada uno' in row[3]
    assert 'registrar claude_auth token' in row[3] and 'regenerar' in row[3]
    assert '\n' not in row[3] and '\r' not in row[3]


if __name__ == '__main__':
    comprobar(Path(__file__).resolve().parents[2])
    print('PASS ayuda de acreditación: formato, opción inicial y cambio posterior')
