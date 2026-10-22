"""Acreditación sin valores en argv, panes ni diagnósticos."""
import getpass
import json
import os
from pathlib import Path
import pwd
import re
import shlex
import subprocess
import sys
from fases import ROOT, Error, actor, command_context, credential_channels, privileged, regular, require, run, secret_values, user_home, wells, write


def input_command(argv, payload, diagnostic):
    try:
        result = subprocess.run(list(map(str, argv)), input=payload, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=180)
    except (OSError, subprocess.TimeoutExpired):
        raise Error(diagnostic+'; '+command_context(argv)) from None
    require(result.returncode == 0, diagnostic+'; '+command_context(argv))


def read_tokens(c):
    require(c['answers'].get('claude_auth') == 'token', 'modo Claude no es token', 2)
    require(sys.stdin.isatty(), 'lectura oculta requiere terminal', 2)
    directory = c['escrow']/'tokens'
    require(not any(p.is_symlink() for p in (directory, *directory.parents)), 'escrow tokens enlazado', 2)
    directory.mkdir(mode=0o700, exist_ok=True)
    directory.chmod(0o700)
    require(directory.stat().st_uid == os.getuid(), 'escrow tokens ajeno', 2)
    for alias in c['answers']['pozos_alias'].split(','):
        token = getpass.getpass('Token Claude del alias '+alias+': ')
        require(re.fullmatch(r'[A-Za-z0-9_.-]+', token), 'token vacío o formato inválido', 2)
        write(directory/(alias+'.token'), token)
        print(alias+': present')


def install_tokens(c, plan):
    a = c['answers']
    aliases = a['pozos_alias'].split(',')
    print('Instalar token 0600 por stdin usando token_env_write; sin relanzar sesiones. Roles usan alias '+aliases[0]+'.')
    print('Canales asignan alias por orden circular; pozos usan el alias de su ledger. Perfil runner excluido.')
    if plan:
        return
    privileged()
    require(a.get('claude_auth') == 'token', 'modo Claude no es token', 2)
    recipient_channels = credential_channels(c)
    tokens = {}
    owner = pwd.getpwnam(a['usuario_ceo'])
    for alias in aliases:
        tokens[alias] = regular(c['escrow']/'tokens'/(alias+'.token'), True, owner.pw_uid).read_bytes()
        require(re.fullmatch(rb'[A-Za-z0-9_.-]+', tokens[alias]), 'token inválido: '+alias, 2)
    library = ROOT/'skills/talent-orchestrator/scripts/pozos-lib.sh'
    script = '. "$1"; token_env_write "$HOME/.claude_token.env"'
    for key in ('usuario_ceo', 'usuario_c1', 'usuario_m1'):
        user = a[key]
        require(not (user_home(user)/'.claude_token.env').is_symlink(), 'token destino enlazado: '+user, 2)
        input_command(['sudo', '-n', '-H', '-u', user, '--', 'bash', '-c', script, '_', library],
                      tokens[aliases[0]], 'instalación token fallida: '+user)
    ledger = json.loads(regular(ROOT/'ledger/cuentas.json').read_text())
    destinations = [(ch, aliases[n % len(aliases)]) for n, ch in enumerate(recipient_channels)]
    destinations += [(well, ledger['pozos'][well]['cuenta']) for well in wells(c)]
    remote_lib = '/home/'+a['cuser']+'/motor-paquete/skills/talent-orchestrator/scripts/pozos-lib.sh'
    remote = ('set -e; [ ! -L "$HOME/.claude_token.env" ] && [ ! -L "$HOME/.profile" ] && [ ! -L "$HOME/.bashrc" ]; . '+
              shlex.quote(remote_lib)+'; token_env_write "$HOME/.claude_token.env"; '
              'for profile in "$HOME/.profile" "$HOME/.bashrc"; do '
              'grep -qF ".claude_token.env" "$profile" 2>/dev/null || '
              'printf \'[ -f "$HOME/.claude_token.env" ] && . "$HOME/.claude_token.env"\\n\' >> "$profile"; done')
    for container, alias in destinations:
        input_command(['incus', 'exec', container, '--', 'su', '-', a['cuser'], '-c', remote],
                      tokens[alias], 'instalación token fallida: '+container)


def host_capacity(user, diagnostic):
    actor(user, ['bash', ROOT/'instalacion/scripts/claude-capacidad.sh'], diagnostic=diagnostic, timeout=120, relay_errors=True)


def container_capacity(c, container, diagnostic):
    script = '/home/'+c['answers']['cuser']+'/motor-paquete/instalacion/scripts/claude-capacidad.sh'
    actor(c['answers']['usuario_incus'], ['incus', 'exec', container, '--', 'su', '-', c['answers']['cuser'],
                                        '-c', shlex.join(['bash', script])], diagnostic=diagnostic, timeout=120, relay_errors=True)


def configure_host_git(c):
    token = secret_values(c)['GITHUB_TOKEN'].encode()
    for key in ('usuario_ceo', 'usuario_c1', 'usuario_m1'):
        user = c['answers'][key]
        input_command(['sudo', '-n', '-H', '-u', user, '--', 'gh', 'auth', 'login', '--with-token'],
                      token, 'gh sin sesión: '+user)
        actor(user, ['gh', 'auth', 'setup-git'], diagnostic='git sin autenticación: '+user)


def coderabbit(c, plan):
    pin = {}
    for line in regular(ROOT/'skills/talent-channels/scripts/coderabbit-pin.conf').read_text().splitlines():
        if line and not line.startswith('#'):
            key, value = line.split('=', 1)
            pin[key] = value
    require(re.fullmatch(r'[0-9]+(?:\.[0-9]+){2}', pin['CR_CLI_VERSION']), 'CodeRabbit pin inválido', 2)
    arch = run(['uname', '-m']).strip()
    key = {'x86_64':'X64', 'amd64':'X64', 'aarch64':'ARM64', 'arm64':'ARM64'}.get(arch)
    require(key, 'CodeRabbit arquitectura no soportada', 2)
    checksum = pin['CR_CLI_SHA256_'+key]
    require(re.fullmatch(r'[a-f0-9]{64}', checksum), 'CodeRabbit pin inválido', 2)
    url = 'https://cli.coderabbit.ai/releases/'+pin['CR_CLI_VERSION']+'/coderabbit-linux-'+key.lower()+'.zip'
    print('Instalar /usr/local/bin/coderabbit (todos los roles), artefacto '+url+' sha256='+checksum)
    if plan:
        return
    privileged()
    import tempfile
    import hashlib
    with tempfile.TemporaryDirectory() as directory:
        archive = Path(directory)/'cr.zip'
        run(['curl', '-fsSL', '--connect-timeout', '30', '--max-time', '300', url, '-o', archive], timeout=330,
            diagnostic='CodeRabbit descarga fallida')
        require(hashlib.sha256(archive.read_bytes()).hexdigest() == checksum, 'CodeRabbit sha256 distinto')
        run(['unzip', '-q', archive, '-d', Path(directory)/'extraido'])
        binaries = list((Path(directory)/'extraido').rglob('coderabbit'))
        require(len(binaries) == 1 and binaries[0].is_file() and not binaries[0].is_symlink(), 'CodeRabbit artefacto inválido')
        run(['install', '-m', '0755', binaries[0], '/usr/local/bin/coderabbit'])
        require(run(['/usr/local/bin/coderabbit', '--version']).strip(), 'CodeRabbit CLI ausente')
