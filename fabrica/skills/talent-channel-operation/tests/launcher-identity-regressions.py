"""Identidad con lanzadores alias; transporte local y procesos propios dentro del arnés."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

scripts = Path(__file__).resolve().parent.parent / "scripts"
mode, entry = sys.argv[1:3]
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    remote = root / "remote"
    remote.mkdir()
    cwd = root / "cwd"
    cwd.mkdir()
    collision = mode.startswith(("builtin_", "function_"))
    name = "claude" if mode == "alias_claude" else "codex"
    if collision:
        name = "printf" if mode.startswith("builtin_") else "x"
    executable = remote / name
    shutil.copyfile(shutil.which("python3"), executable)
    executable.chmod(0o755)
    # PATH cerrado: ningún lanzador o agente instalado en el runner puede suplir el fixture.
    for utility in ("bash", "cat", "readlink", "pgrep"):
        (remote / utility).symlink_to(shutil.which(utility))
    cli = name + "-root"
    setup = ""
    if collision:
        executable.rename(cwd / name)
        executable = cwd / name
        if mode.endswith("_declared"):
            cli = name
        if mode.startswith("function_"):
            setup = "x() { :; }; export -f x; "
    if mode == "absolute":
        cli = str(executable)
    elif mode == "launcher_file":
        launcher = remote / cli
        executable.rename(launcher)
        executable = launcher
        # Si se invierte la prioridad, este homónimo derivado no acredita el proceso.
        shutil.copyfile(shutil.which("sleep"), remote / name)
        (remote / name).chmod(0o755)
    elif mode == "missing_both":
        cli = "absent-root"
    assert mode in ("alias_claude", "alias_codex", "absolute", "launcher_file", "missing_both",
                    "builtin_derived", "function_derived", "builtin_declared", "function_declared")
    if collision:
        assert not (remote / name).exists() and executable.parent == cwd
    if mode.startswith("alias_"):
        assert not (remote / cli).exists() and (remote / name).is_file()
    if mode == "missing_both":
        assert not (remote / cli).exists() and not (remote / "absent").exists()
    process = subprocess.Popen([str(executable), "-c", "import time; time.sleep(60)"],
                               start_new_session=True)
    try:
        shim = root / "shim"
        shim.mkdir()
        transport = shim / "incus"
        transport.write_text('''#!/bin/bash
while [ "$#" -gt 0 ] && [ "$1" != -c ]; do shift; done
[ "$#" -gt 1 ] || exit 2
shift
case "$1" in
  *display-message*) printf '%s\\n' "$TEST_PID" ;;
  *) cd "$TEST_CWD" || exit 2; SETUP_PLACEHOLDER PATH="$TEST_REMOTE_PATH" exec /bin/bash -c "$1" ;;
esac
'''.replace("SETUP_PLACEHOLDER", setup))
        transport.chmod(0o755)
        env = dict(os.environ, PATH=str(shim) + ":/usr/bin:/bin",
                   TEST_REMOTE_PATH=str(remote), TEST_PID=str(process.pid), TEST_CWD=str(cwd))
        if entry == "reader":
            command = ["/bin/bash", str(scripts.parent.parent / "talent-ceo/scripts/leer-auditor.sh"),
                       "fixture", "v:0.1", "fixture", cli]
        else:
            assert entry == "operation"
            code = f'. {shlex.quote(str(scripts / "lib.sh"))}\n'
            code += 'tco_container() { echo fixture; }; TCO_CUSER=fixture\n'
            code += '_tco_pane_agent_exes 01 v:0.1 "$1"\n'
            command = ["/bin/bash", "-c", code, "fixture", cli]
        result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=10)
        rejected = mode == "missing_both" or collision
        expected_rc = 2 if rejected else 0
        expected_name = "" if rejected else name + "\n"
        assert result.returncode == expected_rc, f"{entry}/{mode}: esperado rc={expected_rc}: {result}"
        assert result.stdout == expected_name, f"{entry}/{mode}: identidad inesperada: {result}"
        assert process.poll() is None, "el lector alteró el proceso del fixture"
        print(f"OK {entry}/{mode} rc={result.returncode} identidad={result.stdout.strip() or 'vacia'}")
        if entry == "operation":
            code = f'. {shlex.quote(str(scripts / "lib.sh"))}\n'
            code += 'tco_container() { echo fixture; }; TCO_CUSER=fixture\n'
            code += 'tco_pane_dev() { echo v:0.0; }; tco_pane_audit() { echo v:0.1; }\n'
            code += 'TCO_DEV_CLI="$1"; TCO_AUDIT_CLI="$1"; TCO_AUDIT_TOPOLOGY=mismo-adversarial\n'
            code += 'TCO_PANE_IDENT_WAIT=0; tco_pane_identity_preflight 01\n'
            result = subprocess.run(["/bin/bash", "-c", code, "fixture", cli],
                                    env=env, text=True, capture_output=True, timeout=10)
            expected_rc = 1 if rejected else 0
            assert result.returncode == expected_rc, f"preflight/{mode}: {result}"
            if rejected:
                assert result.stdout == "", f"preflight/{mode}: acreditación inesperada: {result}"
            else:
                assert f"AUDITOR: {name} " in result.stdout, f"preflight/{mode}: {result}"
            assert process.poll() is None, "el preflight alteró el proceso del fixture"
            print(f"OK preflight/{mode} rc={result.returncode}")
    finally:
        process.kill()
        process.wait()
