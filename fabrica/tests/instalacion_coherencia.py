"""Correspondencia bidireccional entre recursos adjudicados y anexos reales."""
import re


def comprobar(generated, project, settings):
    profile = generated['manifiestos/'+project+'.perfil.tsv']
    runners = [line.split('\t') for line in profile.splitlines() if line.startswith('runner\t')]
    assert len(runners) == 1, 'perfil debe adjudicar un runner local'
    row = runners[0]
    attrs = dict(item.split('=', 1) for item in row[5].split(';'))
    assert row[1] == row[3] == settings['TF_RUNNERS'], 'runner perfil/station.conf divergente'
    assert attrs['usuario_contenedor'] == settings['TF_RUNNER_USER']
    assert attrs['repo'] == settings['TF_RUNNER_REPO']
    machine = next(line.split('\t') for line in profile.splitlines() if line.startswith('maquina\t'))
    assert machine[1] == row[2] and 'host='+settings['TF_STATION_HOST'] in machine[5]
    assert generated['manifiestos/runner-identity.map'] == settings['TF_STATION_HOST']+'='+settings['TF_STATION_HOST']+'\n'
    anexos = {name: content for name, content in generated.items() if name.startswith('instalacion/generado/anexos/')}
    assert {name.split('/')[3] for name in anexos} == {'talent-ceo', 'talent-coordination', 'talent-merger', 'talent-channel-operation'}
    for name, annex in anexos.items():
        for key in ('TF_RUNNERS', 'TF_RUNNER_USER', 'TF_RUNNER_REPO', 'TF_STATION_HOST'):
            assert key+'='+settings[key] in annex, name+' omite '+key
        for value in (attrs['usuario'], row[2], 'station.conf', 'seal-suite.sh'):
            assert value in annex, name+' omite '+value
        assert not re.search(r'no (?:hay|existen) (?:filas\s+)?runners?\b|no hay satélites, runners|runners[^\n]*no aplican', annex, re.I), name+' niega runner'


def mutantes(generated, project, settings):
    cases = []
    profile = 'manifiestos/'+project+'.perfil.tsv'
    cases.append(('perfil sin runner', profile, '\n'.join(line for line in generated[profile].splitlines() if not line.startswith('runner\t'))+'\n'))
    cases.append(('mapa ajeno', 'manifiestos/runner-identity.map', 'otro-host=otro-host\n'))
    for name in generated:
        if name.startswith('instalacion/generado/anexos/'):
            cases.append(('anexo omite runner '+name, name, generated[name].replace('TF_RUNNERS=', 'RECURSO=')))
            cases.append(('anexo niega runner '+name, name, generated[name]+'\nNo hay runners adjudicados.\n'))
    for label, name, value in cases:
        modified = dict(generated, **{name:value})
        try:
            comprobar(modified, project, settings)
        except AssertionError:
            print('coherencia rojo: '+label)
        else:
            raise AssertionError('mutación aceptada: '+label)
    comprobar(generated, project, settings)
    print('coherencia verde: perfil, mapa, station.conf y cuatro anexos')
