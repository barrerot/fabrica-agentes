"""Casos por fila: se contrastan contra diagnósticos de fallos realmente provocados."""
import json
from pathlib import Path
import subprocess
import os

OBSERVACIONES = []


def observar(fase, rc, salida):
    OBSERVACIONES.append({'fase':fase, 'rc':rc, 'salida':salida})


def observar_orden(nombre, args, rc, salida):
    nombre = Path(nombre).stem
    fase = None
    if nombre.startswith('check-F'):
        fase = nombre[-2:]
    elif nombre == 'estado' and len(args) == 2 and args[0] == 'avanzar':
        fase = args[1]
    elif nombre.startswith(('f0-', 'f1-', 'f2-', 'f3-', 'f4-', 'f5-', 'f6-', 'f8-')):
        fase = 'F'+nombre[1]
    elif nombre in ('generar-instancia', 'cuestionario'):
        fase = 'F1'
    elif nombre == 'adjudicar-identidad':
        fase = 'F4'
    elif nombre == 'cron-tablas':
        fase = 'F6'
    elif nombre == 'preparar':
        fase = 'F0'
    if nombre in ('verificar-nucleo', 'manifiesto-nucleo'):
        observar('F0', rc, salida)
        observar('F2', rc, salida)
    if fase:
        observar(fase, rc, salida)


def comprobar(package, tmp, expect):
    # El doctor tiene fixtures propios: conservar cada salida real de sus mutantes.
    evidence = tmp/'remediaciones-doctor.jsonl'
    environment = dict(os.environ, TF_REMEDIACIONES_LOG=str(evidence), TF_PAQUETE_ESTADO='distribucion')
    # Tope de la supervisión: medida 800 s en Ubuntu 26.04 (Python 3.14.4, bash 5.3.9) y 591 s en 24.04,
    # en un host Intel N100 de 4 núcleos y una VM de 4 vCPU, el 15-oct-2026; margen x2 (antes 600 s).
    result = subprocess.run(['bash', str(package/'skills/talent-ceo/tests/test-supervision.sh')],
                            env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, timeout=1600)
    print('Remediaciones del doctor: rc='+str(result.returncode))
    if result.returncode:
        print(result.stdout[-3000:])
    if evidence.exists():
        OBSERVACIONES.extend(json.loads(line) for line in evidence.read_text().splitlines())
    if os.environ.get('SALIDA'):
        (Path(os.environ['SALIDA'])/'E45g-remediaciones-observaciones.jsonl').write_text(
            ''.join(json.dumps(item, ensure_ascii=False)+'\n' for item in OBSERVACIONES))
    rows = json.loads((package/'tests/remediaciones.json').read_text())
    for row in rows:
        observations = [item for item in OBSERVACIONES if item['fase'] == row['fase'] and
                        ((item['rc'] == 0) if row['verde'] else (item['rc'] != 0))]
        matched = [item for item in observations if any(text in item['salida'] for text in row['textos'])]
        expect('remediación '+row['fase']+' '+row['fila'], bool(matched))
        if not matched:
            print('Sin diagnóstico observado: '+repr(row['textos']))
