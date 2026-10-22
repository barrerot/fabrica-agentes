"""Doctor real y fila runner del generador con servicios herméticos."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile

package = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('generador', package/'instalacion/instalacion.py')
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)
answers = dict(line.split('=', 1) for line in (package/'instalacion/tests/fixtures/minima.resp').read_text().splitlines())
answers['usuario_incus'] = 'bin'
with tempfile.TemporaryDirectory(prefix='doctor-montaje-') as directory:
    root = Path(directory)
    generated = gen.render(answers, root/'motor', root/'ceo')
    row = next(line for line in generated['manifiestos/ejemplo.perfil.tsv'].splitlines() if line.startswith('runner\t'))
    fields = row.split('\t')
    source = package/'skills/talent-ceo/tests/test-supervision.sh'
    script = source.read_text().replace(
        'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"', 'HERE='+repr(str(source.parent)))
    old = "  tab runner run-uno maq-mando cont-runner-1 - 'usuario=bin'"
    assert old in script
    script = script.replace(old, '  tab '+' '.join(fields[:5])+" '"+fields[5]+"'")
    script = script.replace('maq-mando', fields[2]).replace('cont-runner-1', fields[3])
    # Solo el positivo del doctor: los mutantes completos ya corren en la suite CEO.
    script = script.split('# ═══ C2 · rc 2 sin evaluar', 1)[0]
    script += '\n[ "$FAIL" -eq 0 ] || exit 1\nprintf "doctor positivo: PASS=%s FAIL=%s\\n" "$PASS" "$FAIL"\n'
    target = root/'doctor.sh'
    target.write_text(script)
    result = subprocess.run(['bash', str(target)], capture_output=True, text=True, timeout=60)
    print(result.stdout+result.stderr)
    assert result.returncode == 0 and 'verde: PUERTA ABIERTA es la ultima linea' in result.stdout
    print('doctor-montaje: PASS=1 FAIL=0 (fila generada, doctor real, Incus doblado y PUERTA ABIERTA)')
