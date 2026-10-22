"""Ejecutar los bloques publicados con terminales separadas y clientes dobles."""
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import sys
from fases import ROOT, require


def check_arguments(cited, arguments):
    """Contrasta el parser real sin ejecutar sus acciones ni cargar sus librerías."""
    for marker in ('/skills/', '/instalacion/scripts/'):
        if marker in cited:
            relative = marker[1:]+cited.split(marker, 1)[1]
            break
    else:
        require(False, 'markdown: script no reconocido '+cited)
    path = ROOT/relative
    require(path.is_file(), 'markdown: script citado inexistente '+cited)
    if relative.startswith('instalacion/'):
        # Los envoltorios tienen su contrato estático en lint_commands.
        require(not arguments if path.stem.startswith('check-F') else True,
                'markdown: argumentos desconocidos '+cited)
        return
    # Límites del bloque de argumentos publicados por cada consumidor real.
    spans = {
        'talent-channel-operation/scripts/preparar-sesiones.sh': ('  [ "$#" -eq 2 ]', '  tco_preparar_sesion'),
        'talent-channel-operation/scripts/preparar-modelo-canal.sh': ('[ $# -eq 2 ]', 'model='),
        'talent-channel-operation/scripts/dispatch.sh': ('  DRY=no;', '  c="$(tco_container'),
        'talent-channel-operation/scripts/capture-pane-fixtures.sh': ('  FORCE=no;', '    CLI_VERSION="$(_tco_pane_cli_version'),
        'talent-ceo/scripts/reacreditar.sh': ('_exige_valor(){', 'perfil_path >/dev/null'),
        'talent-ceo/scripts/bus-sellar.sh': ('_exige_valor(){', '# ── NI LF NI CR'),
        'talent-ceo/scripts/doctor.sh': ('case "${1-}" in', '\ndie2()'),
    }
    key = relative.removeprefix('skills/')
    require(key in spans, 'markdown: consumidor sin ensayo de argumentos '+cited)
    source = path.read_text()
    start, end = spans[key]
    require(start in source and end in source, 'markdown: parser cambiado '+cited)
    parser = source.split(start, 1)[1].split(end, 1)[0]
    parser = start+parser
    if path.name == 'capture-pane-fixtures.sh':
        # El bloque llega hasta la primera consulta externa de la rama normal.
        parser += '\nfi\n'
    helpers = 'set -eu -o pipefail\nTCO_DEV_CARRILES=11\n'
    helpers += 'tco_die() { exit 2; }; tco_err() { return 0; }; die2() { exit 2; }; cat() { return 0; }; sed() { return 0; }\n'
    helpers += 'tco_valid_token() { [[ $1 =~ ^[A-Za-z0-9_-]+$ ]]; }; tco_pane_audit() { echo v:.1; }\n'
    result = subprocess.run(['/bin/bash', '-c', helpers+parser, cited, *arguments],
                            env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'},
                            text=True, capture_output=True, timeout=10)
    require(result.returncode == 0, 'markdown: argumentos rechazados '+cited+' '+repr(arguments))


def check_blocks(text, name):
    with tempfile.TemporaryDirectory(prefix='guias-') as td:
        root = Path(td)
        pkg, home, evidence, clients = (root/p for p in ('paquete', 'hogar', 'evidencias', 'bin'))
        for directory in (pkg/'instalacion/estado', home/'.config/talent-channel-operation', evidence, clients):
            directory.mkdir(parents=True)
        answers = root/'respuestas'
        answers.write_text('proyecto=ejemplo\nusuario_ceo=operador\nusuario_c1=ejemplo-c1\nusuario_m1=ejemplo-m1\nusuario_incus=ejemplo-incus\ncuser=operador\n')
        (pkg/'instalacion/estado/contexto.conf').write_text(
            'clon='+str(home/'producto')+'\nhome='+str(home)+'\nrespuestas='+str(answers)+'\n')
        (home/'.config/talent-channel-operation/agents.conf').write_text('TCO_DEV_CARRILES="11"\n')
        # Solo sed lee los datos públicos preparados; ningún cliente llega a servicios.
        sed = clients/'sed'
        sed.write_text('#!/bin/bash\nexec /usr/bin/sed "$@"\n')
        sed.chmod(0o755)
        validator = clients/'validar'
        validator.write_text('#!/bin/bash\nexec '+shlex.join([sys.executable, str(Path(__file__).resolve())])+' "$@"\n')
        validator.chmod(0o755)
        prelude = r'''
set -eu -o pipefail
bash() {
  case "$1" in
    */talent-channels/scripts/verify.sh) echo 'verify sin entorno de instancia' >&2; return 1 ;;
    *.sh) validar "$@" ;;
    *) return 1 ;;
  esac
}
git() { return 0; }
test() { return 0; }
mkdir() { return 0; }
cd() { return 0; }
cat() { return 0; }
tar() { return 0; }
tmux() { return 0; }
incus() { return 0; }
sudo() {
  while [ "$#" -gt 0 ]; do
    case "$1" in -u) shift 2 ;; -H|-n|--) shift ;; *) break ;; esac
  done
  "$@"
}
'''
        terminals = {}
        terminal = None
        pattern = r'<!-- terminal: (instalador|C1|actor) -->|```(?:bash|sh)\n(.*?)```'
        count = 0
        for match in re.finditer(pattern, text, re.S):
            if match[1]:
                terminal = match[1]
                continue
            require(terminal is not None, 'markdown: terminal no declarada '+name)
            block = match[2]
            # ! es el escape del CLI para órdenes de la persona, no negación Bash.
            block = re.sub(r'(?m)^! ', '', block)
            for source, target in (('/srv/fabrica/talent-factory', pkg), ('/srv/producto', home/'producto'),
                                   ('/srv/evidencias', evidence), ('/home/instalador', home)):
                block = block.replace(source, str(target))
            terminals[terminal] = terminals.get(terminal, prelude)+'\n'+block+'\n'
            result = subprocess.run(['/bin/bash', '-c', terminals[terminal]],
                                    env={'HOME': str(home), 'PATH': str(clients), 'LC_ALL': 'C'},
                                    text=True, capture_output=True, timeout=30)
            count += 1
            require(result.returncode == 0, 'markdown: bloque '+str(count)+' '+name+' terminal '+terminal+
                    ' rc='+str(result.returncode)+' '+result.stderr.strip())


if __name__ == '__main__':
    try:
        check_arguments(sys.argv[1], sys.argv[2:])
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
