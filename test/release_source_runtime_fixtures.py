"""Synthetic source/runtime receipt fixtures; never real platform acceptance."""
import hashlib
import io
import json
from pathlib import PureWindowsPath, PurePosixPath
import shutil
import subprocess
import tarfile
import zipfile

from prepare_native_acceptance import NODE


def source_checkout_fixture(repository, destination):
    """Copy tracked working files; exclude untracked files and reject linked ancestors."""
    tracked = subprocess.check_output(['git', '-C', str(repository), 'ls-files', '-z']).decode().split('\0')
    destination.mkdir()
    for name in filter(None, tracked):
        parent = repository
        for part in PurePosixPath(name).parts[:-1]:
            parent = parent / part
            if parent.is_symlink():
                raise ValueError('Refuse symlinked source ancestor: ' + name)
        source = repository / name
        if not source.is_symlink() and not source.exists():
            continue  # Preserve an uncommitted tracked deletion.
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target, follow_symlinks=False)
    git = ['git', '-C', str(destination)]
    subprocess.run([*git, 'init', '--quiet', '--template='], check=True, capture_output=True)
    subprocess.run([*git, 'config', 'core.autocrlf', 'false'], check=True, capture_output=True)
    subprocess.run([*git, 'add', '--force', '.'], check=True, capture_output=True)
    # Finish any automatic maintenance before callers remove the temporary checkout.
    subprocess.run([*git, '-c', 'user.name=Synthetic receipt fixture',
                    '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false',
                    '-c', 'core.hooksPath=' + str(destination / '.git/hooks'),
                    '-c', 'maintenance.autoDetach=false',
                    'commit', '--quiet', '-m', 'Synthetic current-working-tree fixture'],
                   check=True, capture_output=True)
    return destination


def archive_fixture(release, target, source):
    bridge = {'linux-x64': 'libarchway_io.so', 'macos-arm64': 'libarchway_io.dylib', 'windows-x64': 'archway_io.dll'}[target]
    contents = {'native/' + target + '/' + bridge: b'SYNTHETIC BRIDGE',
                'assets/typescript/vendor/typescript/lib/typescript.js': b'SYNTHETIC COMPILER'}
    manifest = {'source': source, 'target': target, 'files': {
        n: {'sha256': hashlib.sha256(v).hexdigest(), 'size': len(v), 'mode': 0o644} for n,v in contents.items()}}
    contents['manifest.json'] = json.dumps(manifest).encode()
    filename = 'archway-0.1.0-' + target + ('.zip' if target == 'windows-x64' else '.tar.gz')
    if target == 'windows-x64':
        with zipfile.ZipFile(release / filename, 'w') as archive:
            for name, value in contents.items():
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = 0o100644 << 16
                archive.writestr(info, value)
    else:
        with tarfile.open(release / filename, 'w:gz') as archive:
            for name,value in contents.items():
                info = tarfile.TarInfo(name)
                info.size, info.mode = len(value), 0o644
                archive.addfile(info, io.BytesIO(value))
    return manifest


def source_fixture(directory, target, source, repository, archive, fixtures):
    path_type = PureWindowsPath if target == 'windows-x64' else PurePosixPath
    dart = path_type(fixtures['dart_sdk']) / 'bin' / ('dart.exe' if target == 'windows-x64' else 'dart')
    tracked = subprocess.check_output(['git', '-C', str(repository), 'ls-files', '-z']).decode().split('\0')
    saved = {name: hashlib.sha256((repository / name).read_bytes()).hexdigest() for name in tracked if name}
    output = directory / 'acceptance'
    manifest = output / 'source-files.json'
    manifest.write_text(json.dumps(saved))
    files = sorted(n for n in saved if n.startswith('test/') and n.endswith('_test.dart'))
    events = []
    for index,name in enumerate(files):
        events += [{'type':'suite','suite':{'id':index,'path':name}},
                   {'type':'testStart','test':{'id':index,'suiteID':index,'name':'synthetic fixture',
                                              'metadata':{'skipReason':None}}},
                   {'type':'testDone','testID':index,'result':'success','skipped':False,'hidden':False}]
    events.append({'type':'done','success':True})
    receipts = []
    for name,command,stdout in [
            ('source-pub-get', [str(dart),'--suppress-analytics','pub','get','--enforce-lockfile'], b'SYNTHETIC PREPARATION'),
            ('source-tests', [str(dart),'test','--reporter=json'], '\n'.join(json.dumps(e) for e in events).encode())]:
        receipt = {'suite':name,'command':command,'exit_code':0,'timed_out':False,
                   'elapsed_seconds':1.0,'timeout_seconds':600}
        for stream,value in [('stdout',stdout),('stderr',b'')]:
            path = output / (name + '.' + stream + '.log')
            path.write_bytes(value)
            receipt[stream],receipt[stream+'_sha256'] = path.name,hashlib.sha256(value).hexdigest()
        (output / (name+'.json')).write_text(json.dumps(receipt))
        receipts.append(receipt)
    return {'source':source,'target':target,'snapshot_root':str(path_type(fixtures['dart_sdk']).parent / 'snapshot'),
            'dart':str(dart),'snapshot_manifest':manifest.name,'snapshot_manifest_sha256':hashlib.sha256(manifest.read_bytes()).hexdigest(),
            'assets':{n:e['sha256'] for n,e in archive['files'].items()},
            'preparation':receipts[0],'execution':receipts[1],
            'tests':{'suites':files,'passed':len(files),'skipped':[]}}


def npm_runtime_fixture(directory, target):
    platform,arch = {'linux-x64':('linux','x64'),'macos-arm64':('darwin','arm64'),'windows-x64':('win32','x64')}[target]
    record = {'target':target,'version':'24.19.0','url':'https://nodejs.org/dist/v24.19.0/node-v24.19.0-'+NODE[target][0],
              'archive_sha256':NODE[target][1],'executable':('C:/fixture/node.exe' if target=='windows-x64' else '/fixture/node'),
              'executable_sha256':'a'*64}
    (directory/'runtime.json').write_text(json.dumps(record))
    commands = [{'case':n,'arguments':a,'exit':e,'native_parity':True} for n,a,e in [
        ('validate-native-parity',['validate'],0),('node-native-parity',['node'],0),
        ('export-native-parity',['export','--format','mermaid'],0),
        ('literal-argv-native-parity',['unknown; $(touch should-not-exist) & café'],64)]]
    commands += [{'case':'missing-bridge-validate','exit':0},{'case':'missing-bridge-export','exit':2,'error':'EXPORT_WRITE_FAILED'},
                 {'case':'restored-bridge-export','exit':0}]
    return {'command_controls':commands,'runtime_controls':{
        'wrong_node':{'version':'24.19.0','platform':platform,'arch':arch,'executable_sha256':'a'*64},
        'cases':[{'case':'wrong-analysis-node','invocation':'installed-route','exit':2,'error':'NODE_UNAVAILABLE'},
                 {'case':'missing-launcher-node','invocation':'installed-route','exit':127,'launcher_stderr_only':True},
                 {'case':'native-supplement-missing-node-check','invocation':'installed-native-supplement','exit':2,'error':'NODE_UNAVAILABLE'},
                 {'case':'native-supplement-no-node-validate','invocation':'installed-native-supplement','exit':0}]}}
