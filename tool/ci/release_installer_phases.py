"""Required native build/install/upgrade/remove references in original command logs."""
from release_acceptance_receipts import verified_bytes


def validate_phases(proof, directory, path_type):
    receipt = proof['installer']
    records = receipt['commands']
    acceptance = proof['acceptance']
    source = path_type(acceptance['source_root'])
    python = path_type(acceptance['python'])
    bundle = path_type(proof['relocation']['executed'])
    compiler = path_type(receipt['compiler']['path'])
    artifact = path_type(acceptance['output_root']).parent / 'installer' / receipt['artifact']['name']
    target = proof['target']

    def find(predicate, after=-1):
        for index, record in enumerate(records):
            if index > after and record['exit'] == 0 and predicate(record['arguments']):
                return index, record['arguments']
        raise ValueError('Native installer required build/lifecycle phase is missing or reordered')

    def continuous(start, end, resets):
        if any(resets(record['arguments']) for record in records[start + 1:end]):
            raise ValueError('Native installer upgrade was interrupted by an uninstall/reset')

    def builder(arguments, owner, length):
        return (len(arguments) == length and path_type(arguments[0]) == python
                and path_type(arguments[1]) == source / 'tool/installers' / owner)

    if target == 'linux-x64':
        def deb(arguments, final):
            return (builder(arguments, 'linux/build.py', 8)
                    and arguments[2] == '--bundle' and arguments[4:7] ==
                    ['--expected-commit', proof['source']['commit'], '--output']
                    and (path_type(arguments[3]) == bundle if final else path_type(arguments[3]) != bundle)
                    and (path_type(arguments[7]) == artifact if final else
                         path_type(arguments[7]).name == 'test-only-old.deb'))
        old_index, old = find(lambda a: deb(a, False))
        build_index, final = find(lambda a: deb(a, True), old_index)
        old_artifact = path_type(old[7])
        for index, name, digest in [(old_index, old_artifact.name, receipt['old_fixture']['artifact_sha256']),
                                    (build_index, artifact.name, receipt['artifact']['sha256'])]:
            record = records[index]
            stdout = verified_bytes(directory / record['stdout'], record['stdout_sha256'])
            if (digest + '  ' + name).encode() not in stdout.splitlines():
                raise ValueError('Debian build log does not bind expected artifact bytes')
        def dpkg(arguments, action, operand):
            return (len(arguments) == 8 and arguments[:3] == ['sudo', '-n', 'dpkg']
                    and arguments[3].startswith('--root=') and arguments[4].startswith('--log=')
                    and arguments[5:7] == ['--force-script-chrootless', action]
                    and path_type(arguments[7]) == path_type(operand))
        install_index, installed = find(lambda a: dpkg(a, '--install', old_artifact), build_index)
        upgrade_index, _ = find(lambda a: dpkg(a, '--install', artifact) and a[:6] == installed[:6], install_index)
        continuous(install_index, upgrade_index, lambda a: len(a) == 8 and a[:3] == installed[:3]
                   and a[3].startswith('--root=')
                   and path_type(a[3].split('=', 1)[1]) == path_type(installed[3].split('=', 1)[1])
                   and a[6] in ('--remove', '--purge') and a[7] == 'archway')
        find(lambda a: dpkg(a, '--remove', 'archway') and a[:6] == installed[:6], upgrade_index)
    elif target == 'macos-arm64':
        def pkg(arguments, final):
            return (builder(arguments, 'macos/build.py', 6) and arguments[2] == '--bundle'
                    and arguments[4] == '--output'
                    and (path_type(arguments[3]) == bundle if final else path_type(arguments[3]) != bundle))
        old_index, old = find(lambda a: pkg(a, False))
        build_index, final = find(lambda a: pkg(a, True), old_index)
        for index, stage, version, digest in [(old_index, old[5], '0.0.0', receipt['old_fixture']['artifact_sha256']),
                (build_index, final[5], '0.1.0', receipt['artifact']['sha256'])]:
            package = path_type(stage) / f'archway-{version}-macos-arm64-unsigned.pkg'
            record = records[index]
            stdout = verified_bytes(directory / record['stdout'], record['stdout_sha256'])
            if (digest + '  ' + str(package)).encode() not in stdout.splitlines():
                raise ValueError('macOS builder log does not bind staged pkg path and tested bytes')
        old_artifact = path_type(old[5]) / 'archway-0.0.0-macos-arm64-unsigned.pkg'
        def installer(arguments, package):
            return (len(arguments) == 7 and arguments[:4] == ['sudo', '-n', '/usr/sbin/installer', '-pkg']
                    and path_type(arguments[4]) == package and arguments[5:] == ['-target', '/'])
        install_index, _ = find(lambda a: installer(a, old_artifact), build_index)
        upgrade_index, _ = find(lambda a: installer(a, artifact), install_index)
        continuous(install_index, upgrade_index, lambda a: len(a) >= 4 and
                   a[:3] == ['sudo', '-n', '/bin/sh'] and path_type(a[3]).name == 'uninstall.sh')
        find(lambda a: a == ['sudo', '-n', '/bin/sh', '/usr/local/lib/archway/uninstall.sh'], upgrade_index)
    else:
        def prepared(arguments, final):
            return (builder(arguments, 'windows/prepare.py', 4)
                    and (path_type(arguments[2]) == bundle if final else path_type(arguments[2]) != bundle))
        old_prepared, old = find(lambda a: prepared(a, False))
        def inno(arguments, version, inputs):
            return (len(arguments) == 4 and path_type(arguments[0]) == compiler
                    and arguments[1] == '/DAppVersion=' + version
                    and arguments[2].startswith('/DOutputDir=')
                    and path_type(arguments[3]) == path_type(inputs) / 'archway.iss')
        old_build, old_compile = find(lambda a: inno(a, '0.0.0', old[3]), old_prepared)
        final_prepared, final = find(lambda a: prepared(a, True), old_build)
        final_build, final_compile = find(lambda a: inno(a, '0.1.0', final[3]), final_prepared)
        if path_type(final_compile[2].split('=', 1)[1]) != artifact.parent:
            raise ValueError('Inno final compiler output differs from tested installer')
        old_artifact = path_type(old_compile[2].split('=', 1)[1]) / 'archway-0.0.0-windows-x64-unsigned.exe'
        switches = ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-']
        install_index, _ = find(lambda a: len(a) == 5 and path_type(a[0]) == old_artifact and a[1:] == switches, final_build)
        upgrade_index, _ = find(lambda a: len(a) == 5 and path_type(a[0]) == artifact and a[1:] == switches, install_index)
        root = path_type(receipt['installed']['installation_root'])
        continuous(install_index, upgrade_index, lambda a: path_type(a[0]).parent == root and
                   path_type(a[0]).name.lower().startswith('unins') and path_type(a[0]).suffix.lower() == '.exe')
        find(lambda a: len(a) == 5 and path_type(a[0]).parent == root and
             path_type(a[0]).name.lower().startswith('unins') and path_type(a[0]).suffix.lower() == '.exe'
             and a[1:] == switches, upgrade_index)
