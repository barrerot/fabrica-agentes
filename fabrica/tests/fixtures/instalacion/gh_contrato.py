"""Validador cerrado de opciones de la ayuda real de GitHub CLI 2.45.0.

gh-2.45.0.json deriva de las secciones FLAGS e INHERITED FLAGS de la referencia
del ensayo. True indica argumento obligatorio; False, opción sin valor.
Las dos capturas versionadas acreditan opciones y campos JSON en 2.45.0.
"""
import json
import os
import re
import shlex
import sys
from pathlib import Path


# Nombre del ejecutable, incluso con ruta estática. Una ruta que continúa
# después de gh (por ejemplo .config/gh/hosts.yml) no es el ejecutable.
REFERENCIA_GH = re.compile(
    r'(?<![\w/.$-])(?:/+(?:[^/\'"$`;\n&|<>]+/+)*|(?:\.{1,2}/)?(?:[\w.-]+/+)+)?gh(?![\w/.-])')


def validar(args):
    contrato = json.loads(Path(__file__).with_name('gh-2.45.0.json').read_text())
    if args == ['--version']:
        return
    command = args[0] if args and args[0] == 'api' else ' '.join(args[:2])
    if command not in contrato['commands']:
        raise ValueError('subcomando no acreditado: '+command)
    spec = contrato['commands'][command]
    tokens = iter(args[1:] if command == 'api' else args[2:])
    for token in tokens:
        if not token.startswith('-'):
            continue
        flag, sep, value = token.partition('=')
        if flag not in spec['flags']:
            raise ValueError('unknown flag: '+flag)
        if spec['flags'][flag]:
            if not sep:
                try:
                    value = next(tokens)
                except StopIteration:
                    raise ValueError('argumento ausente: '+flag) from None
            if flag == '--json':
                campos = spec.get('fields')
                if campos is None:
                    raise ValueError('campos JSON sin acreditar: '+command)
                for campo in value.split(','):
                    if campo not in campos:
                        raise ValueError('Unknown JSON field: '+campo)
        elif sep:
            raise ValueError('opción sin argumento: '+flag)


def validar_orden(args):
    """Valida argv y órdenes shell de sudo/Incus/su sin ejecutarlas."""
    args = list(map(str, args))
    # Un basename conocido dentro de una asignación o expansión no acredita
    # un ejecutable ni un prefijo. No reinterpretar X=/bin/env como env.
    if args and re.search(r'[$`=]', args[0]):
        if any(REFERENCIA_GH.search(arg) or re.search(r'\$(?:GH\b|\{GH\})', arg, re.I) for arg in args):
            raise ValueError('forma de invocación no analizable')
        return False
    if args and REFERENCIA_GH.fullmatch(args[0]):
        validar(args[1:])
        return True
    if args and Path(args[0]).name in ('command', 'exec', 'env', 'timeout', 'nohup'):
        tool, rest = Path(args[0]).name, args[1:]
        if tool == 'command' and any(x in ('-v', '-V') for x in rest[:2]):
            return True  # Consulta de resolución, sin ejecutar el cliente.
        while rest and (rest[0].startswith('-') or
                        (tool == 'env' and re.match(r'^[A-Za-z_][A-Za-z_0-9]*=', rest[0]))):
            if rest[0] == '--':
                rest = rest[1:]
                break
            count = 2 if ((tool == 'env' and rest[0] in ('-u', '--unset')) or
                          (tool == 'timeout' and rest[0] in ('-k', '--kill-after', '-s', '--signal')) or
                          (tool == 'exec' and rest[0] == '-a')) else 1
            rest = rest[count:]
        if tool == 'env':
            while rest and re.match(r'^[A-Za-z_][A-Za-z_0-9]*=', rest[0]):
                rest = rest[1:]
        if tool == 'timeout':
            rest = rest[1:]  # Duración antes del ejecutable.
        return validar_orden(rest)
    if args and Path(args[0]).name == 'sudo':
        rest = args[1:]
        while rest and rest[0].startswith('-'):
            count = 2 if rest[0] in ('-u', '-g') else 1
            if rest[0] == '--':
                rest = rest[1:]
                break
            rest = rest[count:]
        return validar_orden(rest)
    for i, token in enumerate(args[:-1]):
        if token in ('-c', '-lc') and Path(args[0]).name in ('su', 'bash', 'sh', 'dash', 'zsh'):
            validar_shell(args[i+1])
            return True
    if args[:2] == ['incus', 'exec'] and '--' in args:
        return validar_orden(args[args.index('--')+1:])
    if any(REFERENCIA_GH.search(arg) or re.search(r'\$(?:GH\b|\{GH\})', arg, re.I) for arg in args):
        raise ValueError('forma de invocación no analizable')
    return False


def palabra_estatica(raw):
    """No confundir datos entre comillas con expansiones de argumentos."""
    quote = None
    escape = False
    for char in raw:
        if quote == "'":
            if char == "'":
                quote = None
            continue
        if escape:
            escape = False
            continue
        if char == '\\':
            escape = True
        elif char == quote:
            quote = None
        elif char in ('"', "'") and quote is None:
            quote = char
        elif char in '$`' or (quote is None and char in '*?['):
            return False
    return True


def validar_shell(text):
    """Atribuye referencias a gh; nunca presume que un argumento es una orden."""
    referencia = REFERENCIA_GH
    error = 'forma de invocación no analizable'
    # Mantener el texto de cada palabra permite distinguir cadenas estáticas y
    # expansiones. Los intervalos cubren incluso referencias que shlex omitiría.
    palabra = r"(?:'[^']*'|\"(?:\\.|[^\"\\])*\"|\$\{[^}]*\}|\\.|[^\s;&|<>(){}'\"\\])+"
    patron = re.compile(palabra+r'|&>|[<>]+&?|[;&|]+|[(){}]|\n')
    piezas = list(patron.finditer(text))
    if not referencia.search(text) and not re.search(r'\$(?:GH\b|\{GH\})|\beval\b', text, re.I):
        return
    cursor = 0
    for pieza in piezas:
        if text[cursor:pieza.start()].strip():
            raise ValueError(error)
        cursor = pieza.end()
    if text[cursor:].strip():
        raise ValueError(error)
    try:
        tokens = [shlex.split(p.group(), comments=False)[0] if p.group().strip() else ';'
                  for p in piezas]
    except (ValueError, IndexError):
        raise ValueError(error) from None
    atribuidos = set()
    limites = (';', '&&', '||', '|', '&', '\n')
    for i, token in enumerate(tokens):
        if piezas[i].group() in limites:
            continue
        start = i
        while start and piezas[start-1].group() not in limites:
            start -= 1
        while start < i and tokens[start] in ('if', 'then', 'elif', 'else', 'do', '!'):
            start += 1
        end = i+1
        while end < len(tokens) and piezas[end].group() not in limites:
            end += 1
        # Retirar solo redirecciones completas; conservar el resto del argv,
        # incluso cuando aparece después de un destino o una duplicación de fd.
        indices = []
        destinos = []
        pos = start
        while pos < end:
            token_actual = piezas[pos].group()
            if re.fullmatch(r'[0-9]+', token_actual) and pos+1 < end and piezas[pos+1].group().startswith(('<', '>')) and piezas[pos].end() == piezas[pos+1].start():
                pos += 1
                token_actual = piezas[pos].group()
            if token_actual in ('>', '>>', '<', '&>', '>&'):
                if pos+1 >= end or not palabra_estatica(piezas[pos+1].group()) or re.fullmatch(r'[<>&|;]+', piezas[pos+1].group()):
                    raise ValueError(error)
                if token_actual == '>&' and not re.fullmatch(r'[0-9]+', tokens[pos+1]):
                    raise ValueError(error)
                if token_actual in ('>', '>>', '&>'):
                    destinos.append(tokens[pos+1])
                pos += 2
            elif re.fullmatch(r'[<>&|;]+', token_actual):
                raise ValueError(error)
            else:
                indices.append(pos)
                pos += 1
        orden = [tokens[j] for j in indices]
        if i not in indices:
            continue
        raw = piezas[i].group()
        # Una salida literal puede convertirse en programa por una tubería o
        # un fichero posterior. Solo acreditar salidas sin ese destino dinámico.
        salida_segura = (end == len(tokens) or piezas[end].group() != '|') and all(
            destino == '/dev/null' for destino in destinos)
        if token == 'eval':
            if not indices or indices[0] != i:
                raise ValueError(error)
            if len(indices) != 2:
                raise ValueError(error)
            argumento = indices[1]
            cadena = piezas[argumento].group()
            if not (cadena.startswith("'") and cadena.endswith("'")) and re.search(r'[$`]', cadena):
                raise ValueError(error)
            validar_shell(tokens[argumento])
            atribuidos.add(argumento)
        elif token in ('-c', '-lc') and i in indices and indices.index(i)+1 < len(indices) and any(
                Path(word).name in ('su', 'bash', 'sh', 'dash', 'zsh') for word in tokens[start:i]):
            if not orden or Path(orden[0]).name not in (
                    'su', 'bash', 'sh', 'dash', 'zsh', 'sudo', 'command', 'exec', 'env', 'timeout', 'nohup'):
                continue
            argumento = indices[indices.index(i)+1]
            cadena = piezas[argumento].group()
            if not (cadena.startswith("'") and cadena.endswith("'")) and re.search(r'[$`]', cadena):
                raise ValueError(error)
            if validar_orden(orden):
                atribuidos.add(argumento)
        elif referencia.search(raw) or re.search(r'\$(?:GH\b|\{GH\})', raw, re.I):
            if i in atribuidos:
                continue
            # Sustituciones, definiciones y prefijos desconocidos no reciben
            # atribución, aunque contengan una invocación literal válida.
            if any(re.search(r'\$\(|`', p.group()) for p in piezas[start:end]) or any(
                    t in ('alias', 'function', '(', ')', '{', '}') for t in tokens):
                continue
            if orden and orden[0] in ('echo', 'printf'):
                if salida_segura:
                    atribuidos.add(i)
            elif referencia.fullmatch(token):
                if orden[0] == 'command' and any(t in ('-v', '-V') for t in orden[1:]) and not salida_segura:
                    continue
                consulta = orden[0] == 'command' and any(t in ('-v', '-V') for t in orden[1:])
                if not consulta and not all(palabra_estatica(piezas[j].group()) for j in indices if j > i):
                    raise ValueError(error)
                if validar_orden(orden):
                    atribuidos.add(i)
    # Regla de cierre: ninguna referencia puede desaparecer por tokenización,
    # ni quedar verde simplemente porque no se reconoció su posición sintáctica.
    for match in referencia.finditer(text):
        if not any(i in atribuidos and p.start() <= match.start() and match.end() <= p.end()
                   for i, p in enumerate(piezas)):
            raise ValueError(error)
    for i, raw in enumerate(p.group() for p in piezas):
        if re.search(r'\$(?:GH\b|\{GH\})', raw, re.I) and i not in atribuidos:
            raise ValueError(error)


def respuesta_estricta(value):
    def client(args, **kw):
        validar_orden(args)
        return value
    return client


def envolver(path):
    """Anteponer el contrato al doble shell conservando su respuesta."""
    body = path.with_name(path.name+'.respuesta')
    wrapper = ('#!/bin/bash\nexec python3 '+shlex.quote(str(Path(__file__).resolve()))+
               ' --doble '+shlex.quote(str(body.resolve()))+' "$@"\n')
    if path.read_text() == wrapper:
        return
    body.write_bytes(path.read_bytes())
    body.chmod(path.stat().st_mode)
    path.write_text(wrapper)


if __name__ == '__main__':
    try:
        if sys.argv[1:2] == ['--envolver']:
            envolver(Path(sys.argv[2]))
        elif sys.argv[1:2] == ['--doble']:
            validar(sys.argv[3:])
            os.execv(sys.argv[2], sys.argv[2:3]+sys.argv[3:])
        elif sys.argv[1:2] == ['--orden']:
            validar_orden(sys.argv[2:])
        else:
            validar(sys.argv[1:])
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
