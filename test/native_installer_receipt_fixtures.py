"""Literal synthetic native installer receipts for validator tests only."""
import hashlib
import json
from pathlib import Path, PureWindowsPath, PurePosixPath


def installer_fixture(directory, target, manifest_sha256, source_commit="f" * 40):
    output = directory / 'installer'
    output.mkdir()
    suffix = {'linux-x64': 'deb', 'macos-arm64': 'pkg', 'windows-x64': 'exe'}[target]
    artifact = output / f'archway-0.1.0-{target}-unsigned.{suffix}'
    artifact.write_bytes(b'SYNTHETIC INSTALLER FIXTURE ONLY')
    digest = lambda data: hashlib.sha256(data).hexdigest()
    binary = ('C:\\Users\\runner\\AppData\\Local\\Programs\\Archway\\bin\\windows-x64\\archway.exe'
              if target == 'windows-x64' else '/SYNTHETIC/installed/bin/' + target + '/archway')
    compiler = {'linux-x64': '/usr/bin/dpkg-deb', 'macos-arm64': '/usr/bin/pkgbuild',
                'windows-x64': 'C:\\Program Files (x86)\\Inno Setup 6\\ISCC.exe'}[target]
    def command(arguments, code, stdout, index, prefix):
        receipt = {'arguments': arguments, 'exit': code}
        for name, data in [('stdout', stdout), ('stderr', b'')]:
            path = output / f'{prefix}-{index}.{name}.log'
            path.write_bytes(data)
            receipt[name], receipt[name + '_sha256'] = path.name, digest(data)
        return receipt
    processes = []
    args = [['--help'], ['--version'], ['--root', '/project', 'init', '--template', 'mixed'],
            ['--root', '/project', 'validate'], ['--root', '/project', 'export', '--format', 'mermaid'],
            ['--root', '/project', 'check'], ['--root', '/project', 'check'],
            ['--root', '/project', 'check', '--unsupported'],
            ['--root', '/project', 'check'], ['--root', '/project', 'check']]
    for i, (arguments, code) in enumerate(zip(args, [0,0,0,0,0,0,1,64,2,2])):
        if i == 0:
            stdout = b'archway [--root ROOT] SYNTHETIC\n'
        elif i == 1:
            stdout = b'archway 0.1.0\n'
        elif i == 4:
            stdout = b'flowchart LR\n'
        else:
            example = {2:'init-created',3:'validate-ok',5:'check-empty',6:'check-violations',
                       7:'check-usage',8:'check-tool-error',9:'check-tool-error'}[i]
            value = json.loads((Path(__file__).resolve().parents[1] / 'contracts/json/fixtures' /
                                (example+'.json')).read_text())
            value['tool_versions']['archway'] = 'synthetic-unit-fixture'
            if i == 3:
                value['payload'] = {'policy_valid':True,'projects':0,'nodes':0}
            if i in (5,6):
                value['payload']['observed'] = {'files':2,'analyzed_files':2,'edges':code}
            if i >= 8:
                value['status'] = 'incomplete'
                value['diagnostics'] = value['payload']['tool_errors']
            stdout = (json.dumps(value)+'\n').encode()
        processes.append(command([binary, *arguments], code, stdout, i, 'installed'))
        if i == 4:
            value = json.loads((Path(__file__).resolve().parents[1] / 'contracts/json/fixtures/export-ok.json').read_text())
            diagnostic = (json.dumps(value)+'\n').encode()
            path = output / processes[-1]['stderr']
            path.write_bytes(diagnostic)
            processes[-1]['stderr_sha256'] = digest(diagnostic)
    suites = []
    suite_directory = output / 'suites'
    suite_directory.mkdir()
    base = 'C:/fixture' if target == 'windows-x64' else '/fixture'
    for name in ['plan_query', 'dart_check']:
        path_type = PureWindowsPath if target == 'windows-x64' else PurePosixPath
        arguments = [base + '/python', str(path_type(base + '/repo') / 'test' / (name + '_process_smoke.py')), binary]
        if name == 'dart_check':
            arguments += [base + '/dart_sdk', base + '/node', '--existing-installation']
        record = {'suite':name,'command':arguments,'exit_code':0,'timed_out':False,
                  'elapsed_seconds':1.0,'timeout_seconds':600}
        for stream, data in [('stdout',b'SYNTHETIC suite fixture\n'),('stderr',b'')]:
            path = suite_directory / (name + '.' + stream + '.log')
            path.write_bytes(data)
            record[stream], record[stream + '_sha256'] = path.name, digest(data)
        (suite_directory / (name + '.json')).write_text(json.dumps(record))
        suites.append(record)
    path_type = PureWindowsPath if target == 'windows-x64' else PurePosixPath
    remote = path_type(base)
    bundle = remote / 'relocated café installation'
    old_bundle = remote / 'test-only-old-bundle'
    final_artifact = remote / 'installer' / artifact.name
    repository = remote / 'repo/tool/installers'
    py = str(remote / 'python')
    phases = [[compiler, '--version']]
    if target == 'linux-x64':
        old_artifact = remote / 'test-only-old.deb'
        for payload, destination in [(old_bundle,old_artifact),(bundle,final_artifact)]:
            phases.append([py,str(repository / 'linux/build.py'),'--bundle',str(payload),
                           '--expected-commit',source_commit,'--output',str(destination)])
        prefix = ['sudo','-n','dpkg','--root=/fixture/system','--log=/fixture/dpkg.log','--force-script-chrootless']
        phases += [prefix + ['--install',str(old_artifact)], prefix + ['--install',str(final_artifact)],
                   prefix + ['--remove','archway']]
    elif target == 'macos-arm64':
        for payload, stage in [(old_bundle,remote/'old-build'),(bundle,remote/'final-build')]:
            phases.append([py,str(repository/'macos/build.py'),'--bundle',str(payload),'--output',str(stage)])
        old_artifact = remote / 'old-build/archway-0.0.0-macos-arm64-unsigned.pkg'
        phases += [['sudo','-n','/usr/sbin/installer','-pkg',str(p),'-target','/'] for p in [old_artifact,final_artifact]]
        phases += [['sudo','-n','/bin/sh','/usr/local/lib/archway/uninstall.sh']]
    else:
        for label,payload,version,destination in [('old',old_bundle,'0.0.0',remote/'old-artifact'),
                                                  ('final',bundle,'0.1.0',remote/'installer')]:
            inputs = remote / (label+'-input')
            phases += [[py,str(repository/'windows/prepare.py'),str(payload),str(inputs)],
                       [compiler,'/DAppVersion='+version,'/DOutputDir='+str(destination),str(inputs/'archway.iss')]]
        old_artifact = remote / 'old-artifact/archway-0.0.0-windows-x64-unsigned.exe'
        installation_root = PureWindowsPath(binary).parents[2]
        switches = ['/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-']
        phases += [[str(p),*switches] for p in [old_artifact,final_artifact,installation_root/'unins000.exe']]
    phase_receipts = []
    for index, arguments in enumerate(phases):
        data = b'SYNTHETIC native phase output\n'
        if target == 'linux-x64' and index in (1,2):
            value = 'd'*64 if index == 1 else digest(artifact.read_bytes())
            data = (value + '  ' + path_type(arguments[-1]).name + '\n').encode()
        if target == 'macos-arm64' and index in (1,2):
            version = '0.0.0' if index == 1 else '0.1.0'
            value = 'd'*64 if index == 1 else digest(artifact.read_bytes())
            package = path_type(arguments[-1]) / f'archway-{version}-macos-arm64-unsigned.pkg'
            data = (value + '  ' + str(package) + '\n').encode()
        phase_receipts.append(command(arguments,0,data,index,'phase'))
    return {'scope': 'Native build and command-line lifecycle; GUI/trust/fresh desktop terminal pending',
        'bundle_manifest_sha256': manifest_sha256,
        'artifact': {'name': artifact.name, 'size': artifact.stat().st_size, 'sha256': digest(artifact.read_bytes())},
        'compiler': {'path': compiler, 'version': 'SYNTHETIC native compiler fixture', 'sha256': 'b'*64},
        'old_fixture': {'version':'0.0.0','test_only':True,'removed_file':'obsolete/installer-probe..txt',
                        'manifest_sha256':'c'*64,'artifact_sha256':'d'*64},
        'cases': ['install-old','upgrade-final','installed-command','remove','foreign-preserved'] + (
            ['raw-path-registry-types','preexisting-path-token','foreign-root-refusal','foreign-command-refusal',
             'duplicate-token-refusal','root-junction-refusal','locked-stale-file-failure',
             'obsolete-directory-junction-uninstall'] if target == 'windows-x64' else []),
        'installed': {'binary':binary,'installation_root':str(PureWindowsPath(binary).parents[2]) if target == 'windows-x64' else '/SYNTHETIC/installed', 'manifest_sha256':manifest_sha256,
            'native_commands':['help','version','init','validate','export'],
            'typescript':[{'case': n,'exit':c} for n,c in [('clean',0),('dependency-violation',1),('unsupported-option',64)]],
            'runtime_controls':[{'case':n,'exit':2,'errors':['NODE_UNAVAILABLE']} for n in ['missing-node','wrong-node']],
            'processes':processes, 'suites':suites},
        'commands':phase_receipts}
