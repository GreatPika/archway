"""Shared bounded npm installation acceptance for caller-bound execution routes."""
import hashlib
import json

from npm_probe_budgets import NPM_PREPARATION_TIMEOUT
from aot_init_assertions import assert_aot_init
from npm_local_analysis import exercise as exercise_analysis
from npm_termination_controls import exercise as exercise_termination
from npm_runtime_controls import exercise as exercise_runtimes
from npm_command_controls import exercise as exercise_commands
from npm_asset_controls import exercise as exercise_assets, exercise_corpus

PACKAGE = 'archway-architecture-cli'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def accept_installation(shim, project, foreign, installed, installation_root,
                        evidence, init_base, environment, checked, command, *, target, wrong_node=None, cache_route=False):
    metadata = json.loads((installed / 'package.json').read_text(encoding='utf-8'))
    assert metadata['name'] == PACKAGE and metadata['version'] == '0.1.0'
    assert metadata['bin'] == {'archway': 'bin/archway.cjs'}
    assert digest(installed / 'manifest.json') == evidence['manifest_sha256']
    assert shim.is_file(), 'npm-generated installed shim missing'
    help_result = checked([str(shim), '--help'], foreign, environment)
    assert help_result.stderr == b'' and help_result.stdout.startswith(b'archway [--root ROOT]')
    version_result = checked([str(shim), '--version'], foreign, environment)
    assert version_result.stderr == b'' and version_result.stdout in (b'archway 0.1.0\n', b'archway 0.1.0\r\n')
    init_base.mkdir()
    assert_aot_init(shim, init_base, command=command, environment=environment,
                    timeout=NPM_PREPARATION_TIMEOUT if cache_route else 30)
    assert list(foreign.iterdir()) == []
    analysis = exercise_analysis(shim, project, foreign, installed, environment, checked,
                                 installation_root=installation_root)
    assets = exercise_assets(shim, project, foreign, installed, environment, checked, target)
    corpus = exercise_corpus(shim, project, foreign, installed, environment, checked)
    commands = exercise_commands(shim, project, foreign, installed, environment, checked, target)
    runtimes = exercise_runtimes(shim, project, foreign, installed, environment, checked, target, wrong_node)
    termination = exercise_termination(shim, project, foreign, installed, environment, command, target, cache_route=cache_route)
    return {'termination_control': termination, 'runtime_controls': runtimes, 'command_controls': commands, 'asset_controls': assets, 'corpus_control': corpus, 'shim': str(shim), 'help': 0, 'version': 0, 'init': 0,
            'analysis': analysis, 'project_root': str(project), 'installed_package': str(installed)}
