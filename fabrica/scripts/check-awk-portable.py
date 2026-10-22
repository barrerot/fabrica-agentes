#!/usr/bin/env python3
"""Lint por patrones de escapes de awk; no ejecuta el código inspeccionado.

Un ejecutable dinámico cuyo nombre o texto contiene awk se cuenta no analizado.
Una variable cuyo nombre no menciona la herramienta ($X) queda fuera del análisis
estático: no se resuelven valores del entorno ni asignaciones arbitrarias.
"""
import argparse
import ast
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile


def substitution_end(text, start):
    """Fin de $(...) con comillas y sustituciones anidadas, sin expansión."""
    i, depth, quote = start+2, 1, None
    while i < len(text):
        char = text[i]
        if char == '\\' and quote != "'":
            i += 2
            continue
        if quote != "'" and text[i:i+2] == '$(':
            i = substitution_end(text, i)
            continue
        if char in "'\"" and quote in (None, char):
            quote = None if quote else char
        elif quote is None:
            if char == '(':
                depth += 1
            elif char == ')':
                depth -= 1
                if depth == 0:
                    return i+1
        i += 1
    return i


def shell_word(text, start):
    """Decodifica una palabra shell sin expandir variables ni ejecutar sustituciones."""
    i, value, dynamic = start, [], False
    while i < len(text) and not text[i].isspace() and text[i] not in ';|&<>()':
        char = text[i]
        if char == "'":
            end = text.find("'", i+1)
            if end < 0:
                return len(text), ''.join(value), True
            value.append(text[i+1:end])
            i = end+1
        elif char == '"':
            i += 1
            while i < len(text) and text[i] != '"':
                char = text[i]
                if text[i:i+2] == '$(':
                    end = substitution_end(text, i)
                    value.append(text[i:end])
                    dynamic = True
                    i = end
                    continue
                if char == '\\' and i+1 < len(text):
                    following = text[i+1]
                    if following in '$`"\\\n':
                        if following != '\n':
                            value.append(following)
                        i += 2
                        continue
                if char in '$`':
                    dynamic = True
                value.append(char)
                i += 1
            if i == len(text):
                return i, ''.join(value), True
            i += 1
        elif text[i:i+2] == '$(':
            end = substitution_end(text, i)
            value.append(text[i:end])
            dynamic = True
            i = end
        elif char == '\\' and i+1 < len(text):
            if text[i+1] != '\n':
                value.append(text[i+1])
            i += 2
        else:
            if char in '$`':
                dynamic = True
            value.append(char)
            i += 1
    return i, ''.join(value), dynamic


def shlex_words(raw, comments=False):
    """shlex POSIX por contexto: $(...) tiene comillas independientes del exterior."""
    masked, i, quote = [], 0, None
    while i < len(raw):
        char = raw[i]
        if char == '\\' and quote != "'" and i+1 < len(raw):
            masked.append(raw[i:i+2])
            i += 2
            continue
        if raw[i:i+2] == '$(' and quote != "'":
            end = substitution_end(raw, i)
            if end <= i+2 or raw[end-1] != ')':
                raise ValueError('sustitución sin cierre')
            shlex_words(raw[i+2:end-1], comments=True)
            masked.append('SUBSTITUTION')
            i = end
            continue
        if char in "'\"" and quote in (None, char):
            quote = None if quote else char
        masked.append(char)
        i += 1
    return shlex.split(''.join(masked), posix=True, comments=comments)


TOOLS = {'awk', 'gawk', 'mawk', 'nawk', 'original-awk'}
APPEARANCE = re.compile(r'\b(?:original-awk|awk|gawk|mawk|nawk)\b|\$\{?[A-Za-z_0-9]*awk[A-Za-z_0-9]*', re.I)
# Lista estricta de intérpretes ajenos a shell; ampliarla exige revisión explícita.
# Solo rutas absolutas y argumentos literales seguros, sin expansión ni comillas.
NON_SHELL_SHEBANG = re.compile(
    r'#![ \t]*(?:/usr/bin/env[ \t]+(?:-S[ \t]+)?)?'
    r'(?:/[A-Za-z0-9_./-]*/)?(?:python3?|node|perl|ruby|npx[ \t]+tsx)'
    r'(?:[ \t]+[A-Za-z0-9_.=/-]+)*')


def shell_inventory(path, parts, text):
    """Vías independientes de inventario; pueden coincidir en un mismo fichero."""
    header = text.split('\n', 1)[0].removeprefix('\ufeff').removesuffix('\r')
    shebang = header.startswith('#!') and NON_SHELL_SHEBANG.fullmatch(header) is None
    return (path.suffix == '.sh', shebang,
            any(part in ('githooks', '.githooks') for part in parts[:-1]))


def command_words(text, offset=0, dynamic_commands=True, arithmetic=False):
    """Palabras de orden con posición cruda; nunca expande ni ejecuta shell.

    shlex POSIX valida las comillas. Se conserva la palabra cruda para distinguir
    expansiones de dólares escapados y para atribuir apariciones independientemente.
    Las sustituciones dentro de comillas dobles contienen otro contexto de orden.
    """
    i, command, wrapper, skip = 0, True, None, 0
    cases = []
    heredocs = []
    for match in re.finditer(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z_0-9]*)\2[^\n]*\n", text):
        terminator = re.search(r'(?m)^'+ ('\t*' if match[1] else '')+
                               re.escape(match[3])+r'$', text[match.end():])
        if terminator:
            heredocs.append((match.end(), match.end()+terminator.start()))
    while i < len(text):
        if text[i:i+2] == '\\\n':
            i += 2
            continue
        if text[i].isspace():
            if text[i] == '\n':
                command, wrapper, skip = True, None, 0
            i += 1
            continue
        if text[i] == '#':
            end = text.find('\n', i)
            i = len(text) if end < 0 else end
            continue
        if text[i] == '`' and dynamic_commands and not arithmetic:
            end = text.find('`', i+1)
            if end > i and re.search('awk', text[i+1:end], re.I) and command:
                yield offset+i, offset+end+1, False
                yield from command_words(text[i+1:end], offset+i+1)
                i = end+1
                command, wrapper = False, None
                continue
        if text[i] in ';|&({`!':
            if text[i:i+2] == ';;' and cases:
                cases[-1] = True
            command, wrapper, skip = True, None, 0
            i += 1
            continue
        if text[i] in ')<>}':
            if text[i] == ')':
                command, wrapper = True, None
                if cases:
                    cases[-1] = False
            i += 1
            continue
        start = i
        i, word, dynamic = shell_word(text, i)
        if i == start:
            i += 1
            continue
        raw = text[start:i]
        if raw == 'case':
            cases.append(None)
        elif raw == 'in' and cases and cases[-1] is None:
            cases[-1] = True
        elif raw == 'esac' and cases:
            cases.pop()
        try:
            decoded = shlex_words(raw)
            valid = len(decoded) == 1
        except ValueError:
            valid = False
        # Recorrer sustituciones, incluso dentro de una asignación entrecomillada.
        quote, j = None, 0
        while j < len(raw):
            char = raw[j]
            if char == '\\' and quote != "'":
                j += 2
                continue
            if char in "'\"" and quote in (None, char):
                quote = None if quote else char
            elif quote != "'" and (raw[j:j+2] == '$(' or char == '`'):
                begin = j+2 if char == '$' else j+1
                end = substitution_end(raw, j) if char == '$' else raw.find('`', begin)+1
                if end <= begin:
                    end = len(raw)
                yield from command_words(raw[begin:end-1], offset+start+begin,
                                         dynamic_commands=dynamic_commands,
                                         arithmetic=raw[j:j+3] == '$((')
                j = end
                continue
            j += 1
        if not command or (cases and cases[-1] is True):
            continue
        if skip:
            skip -= 1
            continue
        if re.match(r'^[A-Za-z_][A-Za-z_0-9]*=', word):
            continue
        base = word.rsplit('/', 1)[-1]
        expansion = raw.startswith(('$', '"$', '`', '"`'))
        closed = not word.startswith('$(') or word.endswith(')')
        # En un heredoc la sustitución se expande como datos; su orden interior
        # se recorre arriba, pero su salida no ocupa posición de ejecutable.
        heredoc_data = word.startswith('$(') and any(a <= start < b for a, b in heredocs)
        if base in TOOLS or (dynamic_commands and not arithmetic and dynamic and expansion and closed and
                             not heredoc_data and not word.startswith('$((') and re.search('awk', word, re.I)):
            yield offset+start, offset+i, valid and not dynamic
            command, wrapper = False, None
        elif word in ('if', 'then', 'else', 'elif', 'do', 'while', 'until', '$') and raw == word:
            wrapper = None
        elif base in ('command', 'env', 'exec', 'nohup', 'timeout', 'xargs', 'sudo'):
            wrapper = base
            if base == 'timeout':
                skip = 1
        elif wrapper and word.startswith('-'):
            if wrapper == 'command' and word in ('-v', '-V'):
                command, wrapper = False, None
            # Opciones que consumen argumento de los ejecutores habituales.
            if word in ('-u', '-g', '-h', '-p', '-C', '-n', '-P', '-I', '-L',
                        '--user', '--group', '--max-args', '--max-procs', '--replace',
                        '--chdir', '--unset', '-S', '-s', '-k', '--signal', '--kill-after'):
                skip = 1
        else:
            command, wrapper = False, None


def invocation_records(text, dynamic_commands=True):
    seen = set()
    for start, i, valid in command_words(text, dynamic_commands=dynamic_commands):
        if start in seen:
            continue
        seen.add(start)
        options = []
        program = None
        options_done = False
        while i < len(text):
            while i < len(text) and (text[i] in ' \t' or text[i:i+2] == '\\\n'):
                i += 2 if text[i:i+2] == '\\\n' else 1
            begin = i
            i, word, dynamic = shell_word(text, i)
            if i == begin:
                break
            if word == '--' and not dynamic:
                options_done = True
                continue
            if not options_done and word.startswith(('-F', '-v')):
                option = word[:2]
                if len(word) == 2:
                    while i < len(text) and (text[i] in ' \t' or text[i:i+2] == '\\\n'):
                        i += 2 if text[i:i+2] == '\\\n' else 1
                    begin_value = i
                    i, word, dynamic = shell_word(text, i)
                    if i == begin_value:
                        break
                else:
                    word = word[2:]
                if option == '-v' and '=' not in word:
                    break
                options.append((option, word, dynamic))
                continue
            if not options_done and word.startswith('-'):
                # -f, --file y opciones desconocidas: nunca omitir por defecto.
                if word in ('-f', '--file'):
                    while i < len(text) and (text[i] in ' \t' or text[i:i+2] == '\\\n'):
                        i += 2 if text[i:i+2] == '\\\n' else 1
                    i, _, _ = shell_word(text, i)
                break
            program = None if dynamic or not valid else word
            break
        end = text.find('\n', i)
        if end < 0: end = len(text)
        yield start, i, text.count('\n', 0, start)+1, program, options, text[start:end]


def invocations(text):
    for _, _, line, program, options, invocation in invocation_records(text):
        yield line, program, options, invocation


def unparseable_lines(text):
    """Valida líneas lógicas completas, incluidas palabras después del programa.

    Un literal conocido no acredita una orden cuya cola tenga comillas abiertas.
    Conserva los saltos de línea de los programas y sustituciones entrecomillados.
    """
    start = i = 0
    bad_word = False
    while i < len(text):
        if text[i:i+2] == '\\\n':
            i += 2
        elif text[i] == '\n':
            try:
                shlex_words(text[start:i], comments=True)
            except ValueError:
                bad_word = True
            if bad_word:
                yield start, i
            i += 1
            start, bad_word = i, False
        elif text[i] == '#':
            end = text.find('\n', i)
            i = len(text) if end < 0 else end
        elif text[i].isspace() or text[i] in ';|&<>(){}!`':
            i += 1
        else:
            end, _, _ = shell_word(text, i)
            try:
                shlex_words(text[i:end])
            except ValueError:
                bad_word = True
            i = max(i+1, end)
    try:
        shlex_words(text[start:], comments=True)
    except ValueError:
        bad_word = True
    if bad_word:
        yield start, len(text)


def record_programs(records):
    for line, program, options, _ in records:
        if program is not None:
            yield line, program
        for option, value, dynamic in options:
            if option == '-v':
                value = value.partition('=')[2]
            if not dynamic:
                # Solo escapes: una comilla en el valor no delimita código awk.
                escaped = value.replace('"', '\\"')
                yield line, 'BEGIN { value="'+escaped+'" }'
            else:
                # Conserva el chequeo de escapes en defaults shell dinámicos.
                for escape in re.finditer(r'\\(.)', value, re.S):
                    if escape.group(1) not in '\\"abfnrtv01234567\n':
                        yield line, 'BEGIN { value="'+escape.group()+'" }'


def programs(text):
    yield from record_programs(invocations(text))


def inspection_records(text, suffix):
    """Conserva también órdenes de bloques Markdown y plantillas Python literales."""
    records = {start: record for record in invocation_records(text, suffix != '.md')
               for start in (record[0],)}
    if suffix == '.md':
        offset, begin = 0, None
        for line in text.splitlines(keepends=True):
            if line.lstrip().startswith('```'):
                if begin is None:
                    begin = offset+len(line)
                else:
                    for start, end, number, program, options, invocation in invocation_records(text[begin:offset]):
                        records[begin+start] = (begin+start, begin+end,
                                                text.count('\n', 0, begin)+number,
                                                program, options, invocation)
                    begin = None
            offset += len(line)
    if suffix == '.py':
        for node in ast.walk(ast.parse(text)):
            if isinstance(node, ast.Constant) and isinstance(node.value, str) and node.value.count('\n') >= 2:
                for _, _, number, program, options, invocation in invocation_records(node.value):
                    key = -len(records)-1
                    records[key] = (key, key, node.lineno+number-1, program, options, invocation)
    return list(records.values())


# Excepciones exactas por ruta e invocación, siempre con motivo. Una modificación
# del programa deja de coincidir y vuelve a fallar cerrada.
EXCEPTIONS = {
    ("skills/talent-channel-operation/tests/test-dialog-autonomy.sh", "awk() { command \"$AWK_BIN\" \"$@\"; }"):
        "Envoltorio de prueba que ejecuta la misma batería con el intérprete elegido por TCO_TEST_AWK; los programas ejercitados se analizan en el código del producto",
    ("skills/talent-channel-operation/tests/test-dialog-autonomy.sh", "\"$AWK_BIN\" \"$@\"; }"):
        "Envoltorio de prueba que ejecuta la misma batería con el intérprete elegido por TCO_TEST_AWK; los programas ejercitados se analizan en el código del producto",
    ("skills/talent-channel-operation/tests/test-slash-composer.sh", "awk() { command \"$AWK_BIN\" \"$@\"; }"):
        "Envoltorio de prueba que ejecuta la misma batería con el intérprete elegido por TCO_TEST_AWK; los programas ejercitados se analizan en el código del producto",
    ("skills/talent-channel-operation/tests/test-slash-composer.sh", "\"$AWK_BIN\" \"$@\"; }"):
        "Envoltorio de prueba que ejecuta la misma batería con el intérprete elegido por TCO_TEST_AWK; los programas ejercitados se analizan en el código del producto",
    ("skills/talent-channels/scripts/migrate-channel-identity.sh", 'a'+"wk -F, '$2==\"RUNNING\" && $1 ~ /^'\"$PREFIX\"'/ {print $1}')"):
        "Programa dinámico que concatena PREFIX de la configuración; cuerpo literal POSIX revisado, sin escapes no portables.",
}

# Ruta y línea completa exacta; nunca patrones abiertos ni altas automáticas.
MENTIONS = {
    ("skills/talent-channel-operation/tests/test-dialog-autonomy.sh", "AWK_BIN=\"${TCO_TEST_AWK:-awk}\""):
        "Selector del intérprete de prueba mediante TCO_TEST_AWK; asignación de configuración, no ejecutable.",
    ("skills/talent-channel-operation/tests/test-dialog-autonomy.sh", "command -v \"$AWK_BIN\" >/dev/null || { printf 'FAIL falta %s\\n' \"$AWK_BIN\"; exit 1; }"):
        "Consulta de disponibilidad del intérprete seleccionado y diagnóstico de su nombre; no ejecuta programas.",
    ("skills/talent-channel-operation/tests/test-dialog-autonomy.sh", "      ok \"flujo real $scenario $suffix $AWK_BIN teclas exactas\" \"$(real_sequence \"$scenario\" \"$suffix\")\" \"$expected\""):
        "Etiqueta de caso que identifica el intérprete seleccionado; argumento textual de prueba.",
    ("skills/talent-channel-operation/tests/test-dialog-autonomy.sh", "      ok \"Switch model $variant $suffix $AWK_BIN sin teclas\" \"$("):
        "Etiqueta de caso que identifica el intérprete seleccionado; argumento textual de prueba.",
    ("skills/talent-channel-operation/tests/test-dialog-autonomy.sh", "        ok \"efecto real $kind solo $evidence $suffix $AWK_BIN\" \"$("):
        "Etiqueta de caso que identifica el intérprete seleccionado; argumento textual de prueba.",
    ("skills/talent-channel-operation/tests/test-dialog-autonomy.sh", "      ok \"recibo histórico $kind no acredita efecto $suffix $AWK_BIN\" \"$("):
        "Etiqueta de caso que identifica el intérprete seleccionado; argumento textual de prueba.",
    ("skills/talent-channel-operation/tests/test-dialog-autonomy.sh", "    ok \"título libre conserva significado $suffix $AWK_BIN\" \"$("):
        "Etiqueta de caso que identifica el intérprete seleccionado; argumento textual de prueba.",
    ("skills/talent-channel-operation/tests/test-dialog-autonomy.sh", "    ok \"clasificación tras dígito $scenario $suffix $AWK_BIN\" \"$(transition_sequence \"$scenario\" \"$suffix\")\" \"$expected\""):
        "Etiqueta de caso que identifica el intérprete seleccionado; argumento textual de prueba.",
    ("skills/talent-channel-operation/tests/test-dialog-autonomy.sh", "  ok \"fotogramas reales tras dígito $scenario $AWK_BIN\" \"$(real_transition_sequence \"$scenario\")\" \"$expected\""):
        "Etiqueta de caso que identifica el intérprete seleccionado; argumento textual de prueba.",
    ("skills/talent-channel-operation/tests/test-dialog-autonomy.sh", "unset -f awk"):
        "Retirada del envoltorio de prueba al terminar; nombre de función, no invocación.",
    ("skills/talent-channel-operation/tests/test-slash-composer.sh", "AWK_BIN=\"${TCO_TEST_AWK:-awk}\""):
        "Selector del intérprete de prueba mediante TCO_TEST_AWK; asignación de configuración, no ejecutable.",
    ("skills/talent-channel-operation/tests/test-slash-composer.sh", "command -v \"$AWK_BIN\" >/dev/null || { printf 'FAIL falta %s\\n' \"$AWK_BIN\"; exit 1; }"):
        "Consulta de disponibilidad del intérprete seleccionado y diagnóstico de su nombre; no ejecuta programas.",
    ("skills/talent-channel-operation/tests/test-slash-composer.sh", "      label=\"$kind$suffix $AWK_BIN $locale\""):
        "Etiqueta de caso que identifica el intérprete seleccionado; argumento textual de prueba.",
    ("skills/talent-channel-operation/tests/test-slash-composer.sh", "      ok \"forma normal conserva ancla $kind$suffix $AWK_BIN $locale\" \"$(printf '%s' \"$cap\" | rc_of tco_tui_anchor_from)\" 0"):
        "Etiqueta de caso que identifica el intérprete seleccionado; argumento textual de prueba.",
    ("skills/talent-channel-operation/tests/test-slash-composer.sh", "    ok \"envío real un tecleo un Enter $suffix $AWK_BIN $locale\" \"$(send_sequence idle \"$suffix\")\" '0:1:1:modal'"):
        "Etiqueta de caso que identifica el intérprete seleccionado; argumento textual de prueba.",
    ("skills/talent-channel-operation/tests/test-slash-composer.sh", "    ok \"diálogo real bloquea sin tecleo $suffix $AWK_BIN $locale\" \"$(send_sequence modal \"$suffix\")\" '2:0:0:modal'"):
        "Etiqueta de caso que identifica el intérprete seleccionado; argumento textual de prueba.",
    ("skills/talent-channel-operation/tests/test-slash-composer.sh", "  ok \"texto normal exige pie $AWK_BIN $locale\" \"$(printf '%s' \"$fake\" | rc_of tco_tui_anchor_from)\" 2"):
        "Etiqueta de caso que identifica el intérprete seleccionado; argumento textual de prueba.",
    ("skills/talent-channel-operation/tests/test-slash-composer.sh", "    ok \"fila ajena rechaza ancla $extra $AWK_BIN $locale\" \"$(printf '%s\\n%s\\n' \"$cap\" \"$extra\" | rc_of tco_tui_anchor_from)\" 2"):
        "Etiqueta de caso que identifica el intérprete seleccionado; argumento textual de prueba.",
    ("skills/talent-channel-operation/tests/test-slash-composer.sh", "  ok \"barra sin sugerencias exige pie $AWK_BIN $locale\" \"$(printf '%s' \"$no_rows\" | rc_of tco_tui_anchor_from)\" 2"):
        "Etiqueta de caso que identifica el intérprete seleccionado; argumento textual de prueba.",
    ("skills/talent-channel-operation/tests/test-slash-composer.sh", "  ok \"continuación sin sugerencia rechazada $AWK_BIN $locale\" \"$(printf '%s\\n                                    continuación\\n' \"$no_rows\" | rc_of tco_tui_anchor_from)\" 2"):
        "Etiqueta de caso que identifica el intérprete seleccionado; argumento textual de prueba.",
    ("skills/talent-channel-operation/tests/test-slash-composer.sh", "  ok \"barra con diálogo real activo $AWK_BIN $locale\" \"$(printf '%s' \"$dialog\" | tco_pane_anomaly)\" modal"):
        "Etiqueta de caso que identifica el intérprete seleccionado; argumento textual de prueba.",
    ("skills/talent-channel-operation/tests/test-slash-composer.sh", "  ok \"barra con diálogo impide envío $AWK_BIN $locale\" \"$(printf '%s' \"$dialog\" | rc_of tco_send_ready_from)\" 2"):
        "Etiqueta de caso que identifica el intérprete seleccionado; argumento textual de prueba.",
    ("skills/talent-channel-operation/tests/run-tests.sh", '  "$([ "$PROCSTAT_OLD_AWK" != "9999" ] && echo si || echo no)" "si"'):
        "Valor de resultado del parser anterior comparado como argumento de test.",
    ("scripts/lib/carveout.sh", '  [ "$awk_rc" -eq 0 ] || return 1'):
        "Estado numérico de salida; argumento de test, no ejecutable.",
    ("skills/talent-merger/references/proc-m13.selftest.sh", 'o="$(run "$b" env "PATH=$awkstub:$MOCKBIN:$PATH")"'):
        "Directorio del doble dentro de PATH; no ocupa posición de orden.",
    ("skills/talent-merger/references/proc-m13.selftest.sh", '    [ -s "$_t36_awkp" ] && _t36_discover "$WORK/t36-s4.log" "" "bash \'$_t36_awkp\'" "$SITES" "$loc"'):
        "Ruta del guion Bash generado, pasada a test y al descubridor; no es un ejecutable awk.",
    ("skills/skill-creator/scripts/validate-package.sh", "  for d in grep awk realpath find tr wc head mktemp sort sed od; do"): "Lista de dependencias que se comprueban por nombre.",
    ("skills/talent-buzz/tests/probar-sonda.sh", "for real in bash sh uname awk head cut tr grep sed cat mktemp dirname; do"): "Lista de herramientas reales para preparar dobles.",
    ("skills/talent-ceo/tests/run-tests.sh", "assert_eq \"[r8-9] perfil_attr devuelve el valor LITERAL, sin pasar escapes por awk\" \\"): "Descripción de una aserción sobre escapes literales.",
    ("skills/talent-channel-operation/tests/run-tests.sh", "ok \"_tco_picker_option_lines: conserva la fila con cursor ❯ (glifo multibyte no se pierde en awk)\" \\"): "Descripción de una aserción del selector.",
    ("skills/talent-channel-operation/tests/run-tests.sh", "ok \"ROJO — el parser VIEJO ('awk \\$22') sobre la MISMA línea da un valor erróneo (≠9999, prueba no-op)\" \\"): "Descripción del control negativo del extractor antiguo.",
    ("skills/talent-channel-operation/tests/run-tests.sh", "ok \"_tco_carril_session: ya NO usa 'awk .\\$22.' bare (consume el seam puro)\" \\"): "Descripción de la aserción de ausencia del extractor.",
    ("skills/talent-channel-operation/tests/run-tests.sh", "  \"$(grep -c \"awk '{print \\\\\\\\\\$22}'\" \"$SC/lib.sh\")\" \"0\""): "Patrón inerte de grep para comprobar la ausencia del extractor antiguo.",
    ("skills/talent-channel-operation/tests/run-tests.sh", "ok \"extract-plan.sh: la guarda de encargo (awk ini con enc) y el exit 11 están presentes\" \\"): "Descripción de la aserción de guarda del encargo.",
    ("skills/talent-context/tests/run-tests.sh", "for b in jq sort cmp mktemp cp mv chmod date dirname grep head tail tr cat sed timeout bash rm mkdir printf realpath readlink awk; do"): "Lista de herramientas para preparar el entorno de pruebas.",
    ("skills/talent-memoria/scripts/00-config.sh", "TM_ALLOWED_CMDS=\"bash cat pwd grep diff tar git find sort comm join wc sed awk head tail cut tr mktemp date basename dirname chmod mkdir cp mv rm stat sha256sum shasum uname\""): "Lista textual de herramientas permitidas.",
    ("skills/talent-memoria/tests/probar-invariants.sh", "      \"if\"|\"then\"|\"else\"|\"elif\"|\"fi\"|\"for\"|\"while\"|\"do\"|\"done\"|\"case\"|\"esac\"|\"return\"|\"exit\"|\"local\"|\"printf\"|\"echo\"|\"read\"|\"shift\"|\"trap\"|\"set\"|\"cd\"|\"command\"|\"source\"|\"break\"|\"continue\"|\"true\"|\"false\"|\"test\"|\"eval\"|\"export\"|\"unset\"|\"next\"|\"print\"|tm_*|\"norm\"|\"snap_cat\"|\"prepara\"|\"corre\"|\"caso\"|\"ok\"|\"mal\"|\"consume\") : ;;  # next/print: keywords de awk dentro de programas entrecomillados"): "Comentario al final de una lista de palabras shell y del programa inspeccionado.",
    ("skills/talent-merger/references/proc-m13.selftest.sh", "awkstub=\"$(mktemp -d \"$WORK/awkstub.XXXXXX\")\"; printf '#!/usr/bin/env bash\\nexit 2\\n' > \"$awkstub/awk\"; chmod +x \"$awkstub/awk\""): "Rutas del doble de herramienta que devuelve rc 2.",
    ("skills/talent-merger/references/proc-m13.selftest.sh", "  rg=\"$(command -v grep)\"; ra=\"$(command -v awk)\""): "Consulta command -v de la ruta del intérprete.",
    ("skills/talent-merger/references/proc-m13.selftest.sh", "  for b in grep egrep awk gawk mawk; do case \"$b\" in grep) real=\"$rg\";; egrep) real=\"$rg -E\";; *) real=\"$ra\";; esac"): "Lista de nombres de herramientas para construir dobles.",
    ("skills/talent-merger/references/proc-m13.selftest.sh", "  astart=\"$(grep -n 'awk .*-v RE_EST=' \"$src\" | head -1 | cut -d: -f1)\"; [ -n \"$astart\" ] || return 1"): "Patrón inerte de grep para localizar un programa.",
    ("skills/talent-merger/references/proc-m13.selftest.sh", "  { [ -s \"$_t36_acq\" ] && grep -qE 'awk .*-v RE_EST=' \"$_t36_acq\"; } || _C_nm=\"$_C_nm acq-invalido(§8)\""): "Patrón inerte de grep para acreditar el fixture.",
    ("skills/talent-merger/references/proc-m13.selftest.sh", "  _t36_mk_awkp \"$_t36_acq\" \"$_t36_awkp\" || _C_nm=\"$_C_nm awk-parser-no-extraible\""): "Etiqueta textual de error de extracción.",
    ("skills/talent-merger/references/proc-m13.selftest.sh", "  [ \"$awk_stat\" -gt 0 ] && [ \"$awk_disc\" -eq 0 ] && _C_nm=\"$_C_nm awk-estatico-no-descubierto(stat=$awk_stat)\""): "Etiqueta textual de error del censo.",
    ("skills/talent-merger/references/proc-m13.selftest.sh", "      awk|gawk|mawk) case \"$_argv\" in *'~'*|*RE_*) [ \"$_loc\" = C ] || _C_unc=\"$_C_unc awk@$_loc:no-C\";; *) : ;; esac ;;"): "Alternativas de case y etiqueta textual de locale.",
    ("skills/talent-merger/references/proc-m13.selftest.sh", "  0) echo \"  ✓ censo COMPLETO por EJECUCION: bash =~ (clave unica linea:seq, incl. TERMINAL) + awk (shim) + grep de las fuentes reales, todos bajo C efectivo\"; pass=$((pass+1));;"): "Mensaje de resultado de la prueba del censo.",
    ("skills/talent-merger/references/proc-m13.selftest.sh", "_fxa=\"$WORK/t36-fx-awkv.sh\"; printf 'comp_awkv(){ printf \"%%s\\\\n\" \"$1\" | awk -v r=\"$TM_RE_EST\" %s$0 ~ r{f=1} END{exit !f}%s; }\\n' \"'\" \"'\" > \"$_fxa\""): "Plantilla printf con marcadores de comillas; programa generado POSIX comprobado por la suite del comparador.",
    ("skills/talent-merger/references/proc-m13.selftest.sh", "{ [ \"$_seen\" -ge 2 ] && [ \"$_nonC\" -ge 2 ]; } && _t36_ok \"control(b-awkv): awk -v r= sin C -> shim lo VE (x$_seen), LC_ALL efectivo != C (x$_nonC) -> UNCOVERED\" || _t36_kf \"control(b-awkv): seen=$_seen nonC=$_nonC\""): "Descripción del control del locale.",
    ("skills/talent-merger/references/proc-m13.selftest.sh", "_t36_save=\"$_t36_acq\"; _t36_mutacq=\"$WORK/t36-acq-mut.sh\"; sed 's/LC_ALL=C awk /awk /' \"$_t36_acq\" > \"$_t36_mutacq\"; _t36_acq=\"$_t36_mutacq\""): "Patrón y reemplazo de sed de una mutación de prueba.",
    ("skills/talent-merger/references/proc-m13.selftest.sh", "[ \"$_rcm\" -ne 0 ] && _t36_ok \"control(d-awkmut): parser awk sin prefijo C -> el censo REAL sale rc=$_rcm (no verde; awk descubierto fuera de C por la medicion)\" || _t36_kf \"control(d-awkmut): rc=$_rcm (esperaba no-cero)\""): "Descripción del resultado esperado de la mutación.",
    ("skills/talent-merger/references/proc-m13.selftest.sh", "  rg=\"$(command -v grep)\"; ra=\"$(command -v awk)\""): "Consulta command -v de la ruta del intérprete.",
    ("skills/talent-merger/references/proc-m13.selftest.sh", "  for b in grep egrep awk gawk mawk; do case \"$b\" in grep) real=\"$rg\";; egrep) real=\"$rg -E\";; *) real=\"$ra\";; esac"): "Lista de nombres de herramientas para construir dobles.",
    ("tests/run-tests.sh", "python3 \"$MOTOR/scripts/check-awk-portable.py\" --self-test || awk_rc=$?"): "Ruta del comprobador Python; el nombre del fichero contiene la palabra censada.",
    ("tests/run-tests.sh", "check \"autoprueba del lint de awk portable\" 0 \"$awk_rc\""): "Descripción de la autoprueba.",
    ("tests/run-tests.sh", "python3 \"$MOTOR/scripts/check-awk-portable.py\" --root \"$MOTOR\" || awk_rc=$?"): "Ruta del comprobador Python; el nombre del fichero contiene la palabra censada.",
    ("tests/run-tests.sh", "check \"programas awk portables del paquete\" 0 \"$awk_rc\""): "Descripción de la comprobación del paquete.",
    ("tests/scripts/cr-review-harness.sh", "for b in jq git sha256sum shasum od date sed awk sort comm grep printf mktemp cat rm mkdir cp mv chmod true false sleep basename dirname tr; do"): "Lista de herramientas para preparar dobles.",
}


def coverage(text, records, relative):
    """Censo independiente: toda palabra fuera de comentarios completos se atribuye."""
    appearances, mentions, missing = 0, 0, []
    spans = []
    for start, end, _, program, *_ in records:
        word_end, _, _ = shell_word(text, start)
        if text[start:start+1] == '`':
            closing = text.find('`', start+1)
            if closing >= 0:
                word_end = closing+1
        spans.append((start, word_end))
        if program is None:
            continue
        i = word_end
        while i < end:
            if text[i].isspace():
                i += 1
                continue
            if text[i:i+2] == '\\\n':
                i += 2
                continue
            word_end, _, dynamic = shell_word(text, i)
            if word_end == i:
                break
            # Una opción dinámica puede contener otra orden. No atribuir su
            # contenido a la invocación exterior: la orden interior tiene que
            # contarse por sí misma o dejar una aparición sin atribuir.
            if not dynamic:
                spans.append((i, word_end))
            i = word_end
    offset = 0
    for number, line in enumerate(text.splitlines(keepends=True), 1):
        if not line.lstrip().startswith('#'):
            for match in APPEARANCE.finditer(line):
                appearances += 1
                position = offset+match.start()
                if any(start <= position < end for start, end in spans):
                    continue
                reason = MENTIONS.get((relative, line.rstrip('\n')))
                if reason:
                    mentions += 1
                else:
                    missing.append((number, line.rstrip('\n')))
        offset += len(line)
    return appearances, mentions, missing


def literals(program):
    strings, regexes, code = [], [], []
    i = 0
    previous = ''
    while i < len(program):
        char = program[i]
        if char == '#':
            end = program.find('\n', i)
            end = len(program) if end < 0 else end
            code.append(' '*(end-i)); i = end
            continue
        regex = char == '/' and (not previous or previous in '~(=,!{;&|?:')
        if char == '"' or regex:
            start, delimiter = i, char
            i += 1
            bracket = False
            while i < len(program):
                if program[i] == '\\':
                    i += 2
                    continue
                if regex and program[i] == '[':
                    bracket = True
                elif regex and program[i] == ']':
                    bracket = False
                elif program[i] == delimiter and not bracket:
                    i += 1
                    break
                i += 1
            raw = program[start:i]
            (regexes if regex else strings).append(raw)
            code.append(' '*(i-start))
            previous = 'x'
            continue
        code.append(char)
        if char == '\n':
            previous = ''
        elif not char.isspace():
            previous = char
        i += 1
    return strings, regexes, ''.join(code)


def defects(program):
    findings = []
    strings, regexes, code = literals(program)
    arrays = set(re.findall(r'\b([A-Za-z_][A-Za-z_0-9]*)\[', code))
    for name in arrays:
        if re.search(r'\blength\(\s*'+re.escape(name)+r'\s*\)', code):
            findings.append('length(array) no es POSIX: '+name)
    # En cadenas, POSIX solo admite escapes definidos y octales. Una barra doble
    # conserva el escape para una expresión dinámica; no debe marcarse como defecto.
    for string in strings:
        for escape in re.finditer(r'\\(.)', string, re.S):
            if escape.group(1) not in '\\"abfnrtv01234567\n':
                findings.append('escape no portable en cadena: '+escape.group())
    for regex in regexes:
        if re.search(r'\\[y<>bBswWdDx]', regex):
            findings.append('escape no POSIX en expresión: '+regex)
    return findings


def self_test():
    bad = [r'BEGIN { r="\." }', r'BEGIN { r="\y" }', r'{print "\x1f"}', r'/\</ { print }',
           r'{a[1]=1; print length(a)}', r'BEGIN {print "/ruta/\x1f"}', r'/^[^/]*\y$/ {print}']
    good = [r'BEGIN { r="\\." }', r'/\./ {print "\t"}', r'BEGIN {print "\037"}',
            r'/[[:space:]]/ {print}', r'BEGIN { r="[.]" }', r'/^rm -f "\$X"$/{print}',
            r'BEGIN {print "/ruta/\t"}', r'# ejemplo "\x1f"', r'BEGIN {x=4/2; print x}',
            '/x/{next}\n'+r'/^rm "\$X"$/{print}']
    assert all(defects(p) for p in bad)
    assert all(not defects(p) for p in good)
    sample = 'a'+'wk -F\'\\t\' -v n="3" \'{print "\\."}\''
    assert any(defects(p) for _, p in programs(sample))
    assert not list(programs('# '+sample))
    assert list(programs('a'+'wk \'/\\y/\''))
    assert any(defects(p) for _, p in programs('a'+'wk -F\'\\x1f\' \'{print}\''))
    legacy = 'a'+'wk -v re="${VALUE:-'+r'\\?'+' footer}" \'{print re}\''
    assert any(defects(p) for _, p in programs(legacy))
    anchored = 'a'+'wk -v re="fin'+r'\$'+'" \'$0 ~ re {print}\''
    assert all(not defects(p) for _, p in programs(anchored))
    double_bad = 'a'+'wk "BEGIN {print \\"\\\\.\\"}"'
    double_good = 'a'+'wk "BEGIN {print \\"[.]\\"}"'
    assert any(defects(p) for _, p in programs(double_bad))
    assert all(not defects(p) for _, p in programs(double_good))
    double_literal = 'a'+'wk "BEGIN {print \\"\\\\\\\\.\\"}"'
    assert all(not defects(p) for _, p in programs(double_literal))
    assert list(programs('a'+'wk "{print \\$0}"'))
    assert list(programs('a'+'wk -F":" -v n="3" "BEGIN {print n}"'))
    assert list(programs('a'+'wk -v n="$COUNT" \'BEGIN {print n}\''))
    for tool in ('awk', 'gawk', 'mawk', 'nawk', 'original-awk', '/usr/bin/awk', '"awk"', "'awk'"):
        assert list(invocations(tool+' "$program"'))[0][1] is None
    for unknown in ('$program', '"$program"', '-f programa.awk', '--file programa.awk',
                    '$(cat programa.awk)', '"$(cat programa.awk)"', '\x60cat programa.awk\x60'):
        records = list(invocations('a'+'wk '+unknown))
        assert len(records) == 1 and records[0][1] is None, unknown
    for quoted, expected in [(r'"a\\b"', r'a\b'), (r'"a\"b"', 'a"b'),
                             (r'"a\$b"', 'a$b'), (r'"a\.b"', r'a\.b'),
                             ('"a\\\nb"', 'ab'), ("'a'\\'\"b\"", "a'b")]:
        _, value, dynamic = shell_word(quoted, 0)
        assert value == expected and not dynamic, (quoted, value)
    separated = 'SUB\037herramienta\037C\n'
    octal = subprocess.run(['awk', '-F', r'\037', r'{print $1 "\037" $2 "\037" $3}'],
                           input=separated, capture_output=True, text=True)
    assert octal.returncode == 0 and octal.stdout == separated and not octal.stderr
    hardware = Path(__file__).resolve().parents[1]/'skills/talent-coordination/scripts/hw-probe.sh'
    counters = [p for _, p in programs(hardware.read_text()) if 'seen[' in p]
    assert len(counters) == 1
    counted = subprocess.run(['awk', '-F', ': ', counters[0]],
                             input='physical id: 0\ncore id: 0\ncore id: 0\nphysical id: 1\ncore id: 0\n',
                             capture_output=True, text=True)
    assert counted.returncode == 0 and counted.stdout == '2\n' and not counted.stderr
    portable = "'BEGIN {print 1}'"
    for prefix in ('', '| ', '|| ', '&& ', '; ', '( ', '$( ', '`', '! ', '{ ',
                   'do ', 'then ', 'else ', 'command ', 'env LC_ALL=C ', 'exec ',
                   'nohup ', 'timeout 3 ', 'xargs ', 'xargs -n 1 ', 'sudo -u nobody ',
                   'LC_ALL=C VALUE=neutral '):
        records = list(invocations(prefix+'"awk" '+portable))
        assert len(records) == 1 and records[0][1] == 'BEGIN {print 1}', (prefix, records)
    nested = 'value="$(printf "%s" neutral | "awk" '+portable+')"'
    assert len(list(invocations(nested))) == 1
    assert not list(invocations('$X '+portable))
    data = 'done <<EOF\n$(printf x | a'+'wk '+portable+')\nEOF\n'
    records = list(invocations(data))
    assert len(records) == 1 and records[0][1] == 'BEGIN {print 1}', records
    arithmetic = 'n=$(( $(a'+'wk '+portable+') ))'
    records = list(invocations(arithmetic))
    assert len(records) == 1 and records[0][1] == 'BEGIN {print 1}', records
    records = list(invocations('n=$(( $($A'+'WK '+portable+') ))'))
    assert len(records) == 1 and records[0][1] is None, records
    assert not list(invocations('echo "awk"'))
    assert not list(invocations('command -v awk'))
    assert not list(invocations('case "$tool" in '+'|'.join(sorted(TOOLS))+') echo tool;; esac'))
    with tempfile.TemporaryDirectory(prefix='awk-portable-') as directory:
        directory = Path(directory)/'paquete'
        directory.mkdir()
        fixture = Path(directory)/'prueba.sh'
        fixture.write_text('a'+'wk \'BEGIN {r="\\."}\'\n')
        bad_result = subprocess.run([sys.executable, __file__, '--root', directory], capture_output=True, text=True)
        assert bad_result.returncode == 1 and 'FAIL=1' in bad_result.stdout
        fixture.write_text('a'+'wk \'BEGIN {r="[.]"}\'\n')
        good_result = subprocess.run([sys.executable, __file__, '--root', directory], capture_output=True, text=True)
        assert good_result.returncode == 0 and 'FAIL=0' in good_result.stdout
        fixture.write_text(double_bad+'\n')
        double_result = subprocess.run([sys.executable, __file__, '--root', directory], capture_output=True, text=True)
        assert double_result.returncode == 1 and 'programas=1' in double_result.stdout
        fixture.write_text(double_good+'\n')
        restored = subprocess.run([sys.executable, __file__, '--root', directory], capture_output=True, text=True)
        assert restored.returncode == 0 and 'programas=1' in restored.stdout
        for unknown in ('$program', '"$program"', '-f programa.awk', '$(cat programa.awk)'):
            fixture.write_text('a'+'wk '+unknown+'\n')
            result = subprocess.run([sys.executable, __file__, '--root', directory], capture_output=True, text=True)
            assert result.returncode == 1 and 'no_analizados=1 excepciones=0' in result.stdout
        fixture.write_text('a'+'wk "$program"\n')
        checker = Path(directory).parent/'excepciones.py'
        marker = "\nif __name__ == '__main__':"
        entry = '\nEXCEPTIONS[("prueba.sh", \'a\'+\'wk "$program"\')] = "Fixture de programa variable revisado"\n'
        checker.write_text(Path(__file__).read_text().replace(marker, entry+marker))
        waived = subprocess.run([sys.executable, str(checker), '--root', directory], capture_output=True, text=True)
        assert waived.returncode == 0 and 'no_analizados=1 excepciones=1' in waived.stdout, waived.stdout
        fixture.write_text('a'+'wk "$different"\n')
        changed = subprocess.run([sys.executable, str(checker), '--root', directory], capture_output=True, text=True)
        assert changed.returncode == 1 and 'excepciones=0' in changed.stdout, changed.stdout
        cases = 0
        for executable in ('"awk"', "'awk'", '/usr/bin/awk', 'command awk',
                           'env LC_ALL=C awk', 'xargs awk'):
            for body, expected in ((double_bad.partition(' ')[2], 1),
                                   (double_good.partition(' ')[2], 0), ('"$program"', 1)):
                fixture.write_text(executable+' '+body+'\n')
                result = subprocess.run([sys.executable, __file__, '--root', directory],
                                        capture_output=True, text=True)
                assert result.returncode == expected, (executable, body, result.stdout)
                assert ('invocaciones_analizadas=1' if body != '"$program"' else
                        'no_analizados=1 excepciones=0') in result.stdout, result.stdout
                print('awk portable: caso '+repr(executable)+' programa='+repr(body)+
                      ' rc='+str(result.returncode)+'; '+result.stdout.splitlines()[-1])
                cases += 1
        for source in ('echo "awk"\n', '"awk" "unterminated\n',
                       '"awk" '+portable+' "unterminated\n',
                       'unsupported awk '+portable+'\n'):
            fixture.write_text(source)
            result = subprocess.run([sys.executable, __file__, '--root', directory],
                                    capture_output=True, text=True)
            assert result.returncode == 1, result.stdout
        fixture.write_text('a'+'wk -v n="$(unsupported a'+'wk '+portable+')" '+portable+'\n')
        result = subprocess.run([sys.executable, __file__, '--root', directory],
                                capture_output=True, text=True)
        assert result.returncode == 1 and 'sin_atribuir=1' in result.stdout, result.stdout
        fixture.write_text('echo "awk"\n')
        entry = '\nMENTIONS[("prueba.sh", \'echo "awk"\')] = "Mención inerte de prueba"\n'
        checker.write_text(Path(__file__).read_text().replace(marker, entry+marker))
        result = subprocess.run([sys.executable, str(checker), '--root', directory],
                                capture_output=True, text=True)
        assert result.returncode == 0 and 'menciones=1' in result.stdout, result.stdout
        fixture.write_text('echo "awk diferente"\n')
        result = subprocess.run([sys.executable, str(checker), '--root', directory],
                                capture_output=True, text=True)
        assert result.returncode == 1 and 'menciones=0' in result.stdout, result.stdout
        # Simula un detector averiado: la salvaguarda independiente debe seguir roja.
        fixture.write_text('"awk" '+portable+'\n')
        entry = '\ndef invocation_records(text, dynamic_commands=True):\n    return iter(())\n'
        checker.write_text(Path(__file__).read_text().replace(marker, entry+marker))
        result = subprocess.run([sys.executable, str(checker), '--root', directory],
                                capture_output=True, text=True)
        assert result.returncode == 1 and 'aparición sin atribuir' in result.stdout, result.stdout
        fixture.write_text('a'+'wk '+portable+'\n')
        for name, before, after in (
                ('guia.md', "Prosa con apóstrofo '\n```bash\n", '\n```\n'),
                ('plantilla.py', "code = r'''\n", "\n'''\n")):
            extra = Path(directory)/name
            for body, expected in ((double_bad, 1), (double_good, 0)):
                extra.write_text(before+body+after)
                result = subprocess.run([sys.executable, __file__, '--root', directory],
                                        capture_output=True, text=True)
                assert result.returncode == expected, (name, result.stdout, result.stderr)
            extra.unlink()
        fixture.unlink()
        for name, header, expected in (
                ('scripts/filtrar', '#!/bin/sh\n', 1),
                ('.githooks/pre-commit', '', 1),
                ('githooks/pre-push', '', 1),
                ('nested/.githooks/pre-commit', '', 1),
                ('plantilla.sh.tmpl', '#!/usr/bin/env -S bash -eu\n', 1),
                ('env-unset', '#!/usr/bin/env -S -u ABC bash\n', 1),
                ('env-chdir', '#!/usr/bin/env -S -C /tmp bash\n', 1),
                ('env-unset-largo', '#!/usr/bin/env --unset=X bash\n', 1),
                ('env-limpio', '#!/usr/bin/env -i PATH=/bin sh\n', 1),
                ('cabecera-espacios', '#! /bin/bash -eu\n', 1),
                ('cabecera-bom', '\ufeff#!/bin/bash\n', 1),
                ('python-argumento-shell', '#!/usr/bin/env python3 sh\n', 0),
                ('crlf-sh', '#!/bin/sh\r\n', 1),
                ('crlf-env', '#!/usr/bin/env bash\r\n', 1),
                ('crlf-env-S', '#!/usr/bin/env -S bash\r\n', 1),
                ('env-comillas-dobles', '#!/usr/bin/env -S "bash"\n', 1),
                ('env-comillas-simples', "#!/usr/bin/env -S 'bash'\n", 1),
                ('asignacion-sh', '#!/usr/bin/env =sh\n', 1),
                ('bash-version', '#!/bin/bash-5.2\n', 1),
                ('sh-eu', '#!/bin/sh-eu\n', 1),
                ('sh-comillas', '#!/usr/bin/env "sh"\n', 1),
                ('sh-exe', '#!/bin/sh.exe\n', 1),
                ('sh-guion', '#!/bin/sh-\n', 1),
                ('mayusculas', '#!/bin/BASH\n', 1),
                ('tabuladores', '#!\t/bin/bash\t-eu\n', 1),
                ('ruta-local', '#!/usr/local/bin/bash\n', 1),
                ('env-varias-opciones', '#!/usr/bin/env -S -i -u ABC -C /tmp PATH=/usr/bin:/bin bash -eu\n', 1),
                ('bashful', '#!/usr/bin/bashful\n', 1),
                ('fish', '#!/usr/bin/fish\n', 1),
                ('shx', '#!/bin/shx\n', 1),
                ('env-comillas-intercaladas', '#!/usr/bin/env -S ba"s"h\n', 1),
                ('env-comillas-intercaladas-simples', "#!/usr/bin/env -S ba's'h\n", 1),
                ('env-variable', '#!/usr/bin/env -S ${ABC}\n', 1),
                ('env-shell-variable', '#!/usr/bin/env -S $SHELL\n', 1),
                ('env-escape-letra', '#!/usr/bin/env -S ba\\sh\n', 1),
                ('env-espacio-escape', '#!/usr/bin/env -S bash\\_-eu\n', 1),
                ('env-cr-separador', '#!/usr/bin/env -S bash\r-eu\n', 1),
                ('python-punto-coma', '#!/usr/bin/env python3; sh\n', 1),
                ('python-argumento-comillas', '#!/usr/bin/env python3 "sh"\n', 1),
                ('python-argumento-comillas-simples', "#!/usr/bin/env python3 'sh'\n", 1),
                ('python-argumento-variable', '#!/usr/bin/env python3 $ABC\n', 1),
                ('python-argumento-llaves', '#!/usr/bin/env python3 {ABC}\n', 1),
                ('python-argumento-escape', '#!/usr/bin/env python3 a\\b\n', 1),
                ('python-env-S', '#!/usr/bin/env -S python3 -u\n', 0),
                ('python-local', '#!/usr/local/bin/python3\n', 0),
                ('python-directo', '#!/usr/bin/python3\n', 0),
                ('node', '#!/usr/bin/env node\n', 0),
                ('node-argumento', '#!/usr/bin/env node --max-old-space-size=512\n', 0),
                ('npx-tsx', '#!/usr/bin/env npx tsx\n', 0),
                ('npx-tsx-env-S', '#!/usr/bin/env -S npx tsx\n', 0),
                ('texto', '', 0), ('python', '#!/usr/bin/env python3\n', 0)):
            extra = Path(directory)/name
            extra.parent.mkdir(parents=True, exist_ok=True)
            extra.write_text(header+'awk '+"'BEGIN {a[1]=1; print length(a)}'\n")
            result = subprocess.run([sys.executable, __file__, '--root', directory],
                                    capture_output=True, text=True)
            assert result.returncode == expected, (name, result.stdout)
            assert ('programas=1' if expected else 'programas=0') in result.stdout
            if header:
                assert ('cabecera='+str(expected)+' hooks=0') in result.stdout, result.stdout
            print('awk portable: inventario caso='+name+' rc='+str(result.returncode))
            extra.unlink()
        for interpreter in ('sh', 'bash', 'dash', 'zsh', 'ksh', 'ash', 'mksh', 'busybox'):
            for prefix in ('#!/bin/', '#!/usr/bin/env '):
                assert shell_inventory(Path('sin-extension'), ('sin-extension',),
                                       prefix+interpreter+'\n')[1]
            for left in (' ', '\t', '/', '\r', '"', "'", '=', '-', '.', 'é'):
                for right in ('', ' ', '\t', '/', '\r', '"', "'", '=', '-', '.', 'é'):
                    header = '#!python'+left+interpreter+right
                    excluded = left in (' ', '\t') and right in ('', '\r', '/', '=', '-', '.')
                    assert shell_inventory(Path('sin-extension'), ('sin-extension',), header)[1] != excluded
            assert shell_inventory(Path('sin-extension'), ('sin-extension',), '#!'+interpreter)[1]
            assert not shell_inventory(Path('sin-extension'), ('sin-extension',),
                                       '#!python '+interpreter+'-eu')[1]
            for adjacent in ('x', 'Z', '0', '_'):
                assert shell_inventory(Path('sin-extension'), ('sin-extension',),
                                       '#! '+adjacent+interpreter)[1]
                assert shell_inventory(Path('sin-extension'), ('sin-extension',),
                                       '#! '+interpreter+adjacent)[1]
            assert shell_inventory(Path('sin-extension'), ('sin-extension',),
                                   '#!/bin/'+interpreter+'ful')[1]
            for header in ('#!python x'+interpreter, 'texto '+interpreter,
                           '\ufeff\ufeff#!/bin/'+interpreter, '#!python\n'+interpreter):
                assert not shell_inventory(Path('sin-extension'), ('sin-extension',), header)[1]
        for interpreter in ('python', 'python3', 'node', 'perl', 'ruby', 'npx tsx'):
            for prefix in ('#!', '#!\t', '#!/usr/bin/', '#!/usr/local/bin/',
                           '#!/usr/bin/env ', '#!/usr/bin/env -S '):
                for arguments in ('', ' -u', '\t--option=value /tmp/ABC'):
                    header = prefix+interpreter+arguments
                    for ending in ('\n', '\r\n'):
                        assert not shell_inventory(Path('sin-extension'), ('sin-extension',),
                                                   '\ufeff'+header+ending)[1]
                for arguments in (' "ABC"', " 'ABC'", ' $ABC', ' ${ABC}',
                                  ' {ABC}', ' a\\b', '; sh', ' é', ' ABC\rX'):
                    assert shell_inventory(Path('sin-extension'), ('sin-extension',),
                                           prefix+interpreter+arguments)[1]
        for header in ('#!/usr/bin/env -i python3', '#!/usr/bin/env -- python3',
                       '#!relative/python3', '#!/bin/python30', '#!npx', '#!npx tsxx',
                       '#!python3 ', '#!python3\t', '#!'):
            assert shell_inventory(Path('sin-extension'), ('sin-extension',), header)[1]
        # Ambas mutaciones deben ser rechazadas por esta misma autoprueba.
        original = Path(__file__).read_text()
        start = original.index('def shell_inventory(')
        end = original.index('\n\ndef command_words(', start)
        lexical = '''def shell_inventory(path, parts, text):
    header = text.split('\\n', 1)[0].removeprefix('\\ufeff')
    shebang = header.startswith('#!') and bool(re.search(
        r'(?<![A-Za-z0-9_])(?:sh|bash|dash|zsh|ksh|ash|mksh|busybox)(?![A-Za-z0-9_])', header))
    return (path.suffix == '.sh', shebang,
            any(part in ('githooks', '.githooks') for part in parts[:-1]))'''
        with tempfile.TemporaryDirectory(prefix='awk-inventario-mutacion-') as mutation_dir:
            mutation_root = Path(mutation_dir)
            mutation_checker = mutation_root/'scripts/check-awk-portable.py'
            mutation_hardware = mutation_root/'skills/talent-coordination/scripts/hw-probe.sh'
            mutation_checker.parent.mkdir(parents=True)
            mutation_hardware.parent.mkdir(parents=True)
            mutation_hardware.write_text(hardware.read_text())
            for name, mutated in (
                    ('regla-lexica', original[:start]+lexical+original[end:]),
                    ('argumentos-comillas', original.replace(
                        "r'(?:[ \\t]+[A-Za-z0-9_.=/-]+)*'",
                        repr(r"""(?:[ \t]+[A-Za-z0-9_.=/'"-]+)*"""), 1))):
                assert mutated != original
                mutation_checker.write_text(mutated)
                mutation = subprocess.run([sys.executable, str(mutation_checker), '--self-test'],
                                          capture_output=True, text=True)
                assert mutation.returncode == 1 and 'AssertionError' in mutation.stderr, mutation.stderr
                print('awk portable: mutación '+name+' autoprueba rc='+str(mutation.returncode))
        for executable in ('$AWK', '"${AWK[@]}"', '$awk_bin', '"${GAWK:-gawk}"',
                           '"$(printf AWK)"', '`printf AWK`'):
            source = executable+(' -f x' if executable == '$awk_bin' else " 'BEGIN {print 1}'")
            fixture.write_text(source+'\n')
            result = subprocess.run([sys.executable, __file__, '--root', directory],
                                    capture_output=True, text=True)
            assert result.returncode == 1 and 'no_analizados=1 excepciones=0' in result.stdout, result.stdout
            assert 'sin_atribuir=0' in result.stdout, result.stdout
            entry = '\nEXCEPTIONS[("prueba.sh", '+repr(source)+')] = "Ejecutable dinámico de fixture revisado"\n'
            checker.write_text(Path(__file__).read_text().replace(marker, entry+marker))
            waived = subprocess.run([sys.executable, str(checker), '--root', directory],
                                    capture_output=True, text=True)
            assert waived.returncode == 0 and 'no_analizados=1 excepciones=1' in waived.stdout, waived.stdout
            fixture.write_text(source+' diferente\n')
            changed = subprocess.run([sys.executable, str(checker), '--root', directory],
                                     capture_output=True, text=True)
            assert changed.returncode == 1 and 'excepciones=0' in changed.stdout, changed.stdout
            print('awk portable: dinámico='+executable+' rojo; excepción exacta verde; edición roja')
        fixture.write_text('$awk_bin -f x\n')
        result = subprocess.run([sys.executable, __file__, '--root', directory], capture_output=True, text=True)
        assert result.returncode == 1 and 'no_analizados=1 excepciones=0' in result.stdout
        fixture.unlink()
        extra = Path(directory)/'sin-extension'
        extra.write_text("#!/bin/sh\n"+'a'+"wk 'BEGIN {a[1]=1; print length(a)}'\n")
        original = Path(__file__).read_text()
        mutated = "shell_file = path.suffix == '.sh'".join(original.rsplit('shell_file = any(routes)', 1))
        mutated = "if path.suffix not in ('.sh', '.awk', '.md', '.tmpl', '.py'):".join(mutated.rsplit(
            "if path.suffix not in ('.sh', '.awk', '.md', '.tmpl', '.py') and not shell_file:", 1))
        checker.write_text(mutated)
        missed = subprocess.run([sys.executable, str(checker), '--root', directory], capture_output=True, text=True)
        assert missed.returncode == 0 and 'programas=0' in missed.stdout, missed.stdout+missed.stderr
        checker.write_text(original)
        restored_inventory = subprocess.run([sys.executable, str(checker), '--root', directory], capture_output=True, text=True)
        assert restored_inventory.returncode == 1 and 'programas=1' in restored_inventory.stdout
        # La autoprueba permanente debe rechazar el inventario mutado.
        checker.write_text(mutated)
        mutation = subprocess.run([sys.executable, str(checker), '--self-test'], capture_output=True, text=True)
        assert mutation.returncode == 1, mutation.stdout+mutation.stderr
        print('awk portable: mutación inventario autoprueba rc='+str(mutation.returncode)+
              '; restauración detecta programa rc='+str(restored_inventory.returncode))
        print('awk portable: matriz cerrada casos='+str(cases)+'; menciones y detector averiado rojos')
        print('awk portable: mutación rc='+str(bad_result.returncode)+'; restauración rc='+str(good_result.returncode))
        print('awk portable: dobles rojo rc='+str(double_result.returncode)+'; restauración rc='+str(restored.returncode)+'; no analizables rojos')
    print('awk portable: autoprueba verde (escapes, regex, opciones y comentarios)')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path)
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if not args.root and not args.self_test:
        parser.error('indique --root o --self-test')
    if args.self_test:
        self_test()
    if args.root:
        failed = 0
        count = 0
        unanalyzed = 0
        exceptions = 0
        analyzed_invocations = 0
        appearances = mentions = 0
        unassigned = 0
        inventory = [0, 0, 0]
        for path in sorted(args.root.rglob('*')):
            parts = path.relative_to(args.root).parts
            if any(part in ('.git', '__pycache__') for part in parts) or parts[:2] in (
                    ('instalacion', 'estado'), ('instalacion', 'generado')):
                continue
            if path.is_symlink() or not path.is_file():
                continue
            # Leer solo la cabecera antes de descartar contenido binario ajeno a shell.
            with path.open('rb') as stream:
                header = stream.readline().decode('utf-8', errors='replace')
            routes = shell_inventory(path, parts, header)
            shell_file = any(routes)
            if path.suffix not in ('.sh', '.awk', '.md', '.tmpl', '.py') and not shell_file:
                continue
            text = path.read_text(errors='replace')
            for index, selected in enumerate(routes):
                inventory[index] += int(selected)
            if routes[1] or routes[2]:
                print('awk portable: inventario '+path.relative_to(args.root).as_posix()+
                      ' cabecera='+str(int(routes[1]))+' hooks='+str(int(routes[2])))
            awk_file = path.suffix == '.awk' and not shell_file
            if not awk_file:
                records = inspection_records(text, '.sh' if shell_file else path.suffix)
                if shell_file:
                    invalid = list(unparseable_lines(text))
                    records = [(start, end, line,
                                None if any(a <= start < b for a, b in invalid) else program,
                                options, invocation)
                               for start, end, line, program, options, invocation in records]
                relative = path.relative_to(args.root).as_posix()
                found, mentioned, missing = coverage(text, records, relative) if shell_file else (0, 0, [])
                if found:
                    print(str(path)+': recuento apariciones='+str(found)+
                          ' analizadas='+str(sum(p is not None for _, _, _, p, *_ in records))+
                          ' no_analizadas='+str(sum(p is None for _, _, _, p, *_ in records))+
                          ' excepciones='+str(sum(p is None and bool(EXCEPTIONS.get((relative, inv)))
                                                  for _, _, _, p, _, inv in records))+
                          ' menciones='+str(mentioned)+' sin_atribuir='+str(len(missing)))
                appearances += found
                mentions += mentioned
                unassigned += len(missing)
                for line, raw in missing:
                    failed += 1
                    print(str(path)+':'+str(line)+': aparición sin atribuir: '+repr(raw))
                for _, _, line, program, _, invocation in records:
                    if program is not None:
                        analyzed_invocations += 1
                    if program is None:
                        unanalyzed += 1
                        reason = EXCEPTIONS.get((path.relative_to(args.root).as_posix(), invocation))
                        if reason:
                            exceptions += 1
                            print(str(path)+':'+str(line)+': excepción: '+reason)
                        else:
                            failed += 1
                            print(str(path)+':'+str(line)+': no analizada: '+repr(invocation))
            if awk_file:
                analyzed_invocations += 1
            items = [(1, text)] if awk_file else record_programs(
                (line, program, options, invocation) for _, _, line, program, options, invocation in records)
            for line, program in items:
                count += 1
                for defect in defects(program):
                    print(str(path)+':'+str(line)+': '+defect)
                    failed += 1
        print('awk portable: inventario extension='+str(inventory[0])+
              ' cabecera='+str(inventory[1])+' hooks='+str(inventory[2]))
        print('awk portable: programas='+str(count)+' no_analizados='+str(unanalyzed)+
              ' excepciones='+str(exceptions)+' invocaciones_analizadas='+str(analyzed_invocations)+
              ' apariciones='+str(appearances)+' menciones='+str(mentions)+
              ' sin_atribuir='+str(unassigned)+
              ' FAIL='+str(failed))
        return int(failed != 0)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
